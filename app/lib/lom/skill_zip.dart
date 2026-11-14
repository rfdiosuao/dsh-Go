/// Strict ZIP validation and `SKILL.md` parsing for skill packages
/// (doc §07 §9). Kept separate from the registry (`skills.dart`) so
/// neither file grows past the 400-line limit.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'rpc_errors.dart';

/// Whole-package cap (10 MiB).
const skillMaxPackageBytes = 10 * 1024 * 1024;
const _maxEntries = 600;
const _maxFiles = 300;
const _maxExpandedBytes = 30 * 1024 * 1024;

/// Cap on a skill body (see `skills.dart`): `skills.read` must fit the
/// 350,000-byte reply limit, and the Lom store is not a file store.
const _maxBodyBytes = 150000;

/// A `SKILL.md` parsed out of a validated ZIP.
class LomParsedSkill {
  const LomParsedSkill({
    required this.name,
    required this.description,
    required this.version,
    required this.body,
  });

  final String name;
  final String description;
  final String version;
  final String body;
}

/// Strictly validates a skill ZIP (doc §07 §9) and parses its
/// `SKILL.md`. Throws [LomRpcException] with a `skill.*` code on any
/// rejection. The central directory is scanned **before** decoding, so
/// a zip bomb is refused on declared sizes instead of expanding it;
/// the decoded entries are re-validated because a crafted ZIP can
/// carry different names in its local headers than in the central
/// directory.
LomParsedSkill validateSkillZip(List<int> bytes) {
  if (bytes.length > skillMaxPackageBytes) {
    throw LomRpcException('skill.package_too_large');
  }
  final entries = _scanCentralDirectory(bytes);
  _validateEntries(entries);
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw LomRpcException('skill.invalid_zip');
  }
  final files = <String, List<int>>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    if (_isIgnored(name)) continue;
    _validatePath(name);
    if (files.containsKey(_normalized(name))) {
      throw LomRpcException('skill.duplicate_path');
    }
    files[_normalized(name)] = List<int>.from(file.content as List<int>);
  }
  if (files.length > _maxFiles) {
    throw LomRpcException('skill.too_many_files');
  }
  var expanded = 0;
  for (final content in files.values) {
    expanded += content.length;
    if (expanded > _maxExpandedBytes) {
      throw LomRpcException('skill.expanded_too_large');
    }
  }
  final manifestBytes = _manifestBytes(files);
  if (manifestBytes == null) throw LomRpcException('skill.missing_manifest');
  return _parseSkillMd(manifestBytes);
}

/// One central-directory entry, before decoding.
class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.isDir,
    required this.isSymlink,
    required this.uncompressedSize,
  });

  final String name;
  final bool isDir;
  final bool isSymlink;
  final int uncompressedSize;
}

/// Reads the central directory (EOCD → entries). Any structural problem
/// is `skill.invalid_zip`; a symlink entry is `skill.unsafe_path`.
List<_ZipEntry> _scanCentralDirectory(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);
  // The end-of-central-directory record is at most 64 KiB of comment
  // from the end of the file.
  var eocd = -1;
  final searchFrom = data.length < 65557 ? 0 : data.length - 65557;
  for (var i = data.length - 22; i >= searchFrom; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw LomRpcException('skill.invalid_zip');
  final count = view.getUint16(eocd + 10, Endian.little);
  final cdOffset = view.getUint32(eocd + 16, Endian.little);
  final entries = <_ZipEntry>[];
  var offset = cdOffset;
  for (var i = 0; i < count; i++) {
    if (offset + 46 > data.length ||
        view.getUint32(offset, Endian.little) != 0x02014b50) {
      throw LomRpcException('skill.invalid_zip');
    }
    final flags = view.getUint16(offset + 8, Endian.little);
    final method = view.getUint16(offset + 10, Endian.little);
    final uncompressedSize = view.getUint32(offset + 24, Endian.little);
    final nameLen = view.getUint16(offset + 28, Endian.little);
    final extraLen = view.getUint16(offset + 30, Endian.little);
    final commentLen = view.getUint16(offset + 32, Endian.little);
    final externalAttrs = view.getUint32(offset + 38, Endian.little);
    final nameStart = offset + 46;
    final nameEnd = nameStart + nameLen;
    if (nameEnd > data.length) throw LomRpcException('skill.invalid_zip');
    final name = _decodeName(
      data.sublist(nameStart, nameEnd),
      flags & 0x800 != 0,
    );
    if (flags & 0x1 != 0) throw LomRpcException('skill.invalid_zip');
    if (method != 0 && method != 8) {
      throw LomRpcException('skill.invalid_zip');
    }
    final mode = externalAttrs >> 16;
    final typeBits = mode & 0xF000;
    if (typeBits == 0xA000) throw LomRpcException('skill.unsafe_path');
    if (typeBits != 0 && typeBits != 0x8000 && typeBits != 0x4000) {
      throw LomRpcException('skill.unsafe_path');
    }
    entries.add(_ZipEntry(
      name: name,
      isDir: name.endsWith('/'),
      isSymlink: typeBits == 0xA000,
      uncompressedSize: uncompressedSize,
    ));
    offset = nameEnd + extraLen + commentLen;
  }
  return entries;
}

void _validateEntries(List<_ZipEntry> entries) {
  final seen = <String>{};
  var entryCount = 0;
  var fileCount = 0;
  var expanded = 0;
  for (final entry in entries) {
    if (_isIgnored(entry.name)) continue;
    entryCount++;
    if (entryCount > _maxEntries) {
      throw LomRpcException('skill.too_many_files');
    }
    _validatePath(entry.name);
    final normalized = _normalized(entry.name);
    if (!seen.add(normalized)) {
      throw LomRpcException('skill.duplicate_path');
    }
    if (!entry.isDir) {
      fileCount++;
      if (fileCount > _maxFiles) {
        throw LomRpcException('skill.too_many_files');
      }
      expanded += entry.uncompressedSize;
      if (expanded > _maxExpandedBytes) {
        throw LomRpcException('skill.expanded_too_large');
      }
    }
  }
}

/// Entries the doc says to ignore entirely (not counted, not installed).
bool _isIgnored(String name) =>
    name.startsWith('__MACOSX/') ||
    name == '.DS_Store' ||
    name.endsWith('/.DS_Store');

/// Rejects absolute paths, `..` / `.` segments, backslashes, colons,
/// NUL characters and empty names.
void _validatePath(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.contains('\x00')) {
    throw LomRpcException('skill.unsafe_path');
  }
  final segments = name.split('/');
  for (final segment in segments) {
    if (segment == '..' || segment == '.') {
      throw LomRpcException('skill.unsafe_path');
    }
  }
  if (segments.any((s) => s.isEmpty && s != segments.last)) {
    throw LomRpcException('skill.unsafe_path');
  }
}

String _normalized(String name) =>
    name.endsWith('/') ? name.substring(0, name.length - 1) : name;

String _decodeName(List<int> bytes, bool utf8Flag) {
  if (utf8Flag) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw LomRpcException('skill.invalid_zip');
    }
  }
  // No UTF-8 flag: the spec says CP437; latin-1 matches its low half
  // and is only used for validation, never for a written path.
  return latin1.decode(bytes);
}

/// Finds `SKILL.md` at the root, or under the single common top-level
/// directory when every file shares one.
List<int>? _manifestBytes(Map<String, List<int>> files) {
  if (files.containsKey('SKILL.md')) return files['SKILL.md'];
  final firstSegments = {
    for (final name in files.keys) name.split('/').first,
  };
  if (firstSegments.length == 1) {
    final top = firstSegments.single;
    final key = '$top/SKILL.md';
    if (files.containsKey(key)) return files[key];
  }
  return null;
}

LomParsedSkill _parseSkillMd(List<int> bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    throw LomRpcException('skill.invalid_manifest');
  }
  final lines = text.split('\n');
  var i = 0;
  // Skip leading comment / blank lines (DSH skills start with a
  // `# dsh-go:managed …` comment).
  while (i < lines.length &&
      (lines[i].trim().isEmpty || lines[i].startsWith('#'))) {
    i++;
  }
  final fields = <String, String>{};
  var bodyStart = i;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim() == '---') {
      bodyStart = i + 1;
      break;
    }
    final match = RegExp(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')
        .firstMatch(line);
    if (match == null) {
      bodyStart = i;
      break;
    }
    fields[match.group(1)!] = match.group(2)!.trim();
    i++;
    bodyStart = i;
  }
  final name = fields['name'] ?? '';
  final description = fields['description'] ?? '';
  if (name.isEmpty || description.isEmpty) {
    throw LomRpcException('skill.invalid_manifest');
  }
  if (!RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(name)) {
    throw LomRpcException('skill.already_exists_or_invalid_name');
  }
  final version = fields['version'] ?? '1.0.0';
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,49}$').hasMatch(version)) {
    throw LomRpcException('skill.invalid_manifest');
  }
  final body = lines.sublist(bodyStart).join('\n').trim();
  if (body.isEmpty || utf8.encode(body).length > _maxBodyBytes) {
    throw LomRpcException('skill.invalid_manifest');
  }
  return LomParsedSkill(
    name: name,
    description: description,
    version: version,
    body: body,
  );
}
