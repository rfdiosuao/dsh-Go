/// Lom file transfer (`file.*`, doc §07 §7).
///
/// Files are isolated per sending desktop (the metadata key and the byte
/// storage key both include a hash of the sender's public key `K`), so one
/// desktop can never read another's uploads. Only ids registered through
/// this channel are addressable — arbitrary paths are never accepted.
///
/// Byte storage is an injected [LomFileStorage]: real files on disk in
/// production (`IoLomFileStorage` in `io_adapters.dart`), memory in tests.
/// Metadata lives in the Keystore-backed secret store (`lom.files`).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'credentials.dart';
import 'file_storage.dart';
import 'json_doc.dart';
import 'rpc_errors.dart';

/// Single-file cap (doc §07 §7): 100 MiB.
const int lomFileMaxBytes = 104857600;

/// Chunk cap: 128 KiB.
const int lomFileChunkBytes = 131072;

/// Suggested total quota per desktop: 500 MiB.
const int lomFileQuotaBytes = 524288000;

/// The `file.*` methods, per sending desktop.
class LomFileStore {
  LomFileStore(
    this._store, {
    required this.storage,
    this.gallerySaver,
  });

  final LomSecretStore _store;
  final LomFileStorage storage;
  final LomGallerySaver? gallerySaver;

  static const _key = 'lom.files';

  late final _doc = LomJsonDoc(_store, _key);

  String _senderHash(String sender) =>
      crypto.sha256.convert(utf8.encode(sender)).toString().substring(0, 16);

  String _docKey(String sender, String id) => '${_senderHash(sender)}:$id';
  String _storageKey(String sender, String id) =>
      '${_senderHash(sender)}/$id';

  /// The record for [id] from [sender], or null when never registered.
  Future<LomFileRecord?> lookup(String id, String sender) async {
    final doc = await _doc.load();
    final raw = doc[_docKey(sender, id)];
    if (raw is! Map<String, dynamic>) return null;
    return LomFileRecord.fromJson(Map<String, Object?>.from(raw));
  }

  /// Whether [id] from [sender] is a finished, verified upload. Used by
  /// `chat.send` to validate attachment ids.
  Future<bool> isComplete(String id, String sender) async =>
      (await lookup(id, sender))?.status == 'complete';

  /// The full bytes of a finished transfer, or null when it is missing
  /// or not complete. Used by `skills.install` to read the uploaded ZIP
  /// (the transfer was already SHA-256-verified by `file.finish`).
  Future<List<int>?> completeBytes(String id, String sender) async {
    final record = await lookup(id, sender);
    if (record == null || record.status != 'complete') return null;
    return storage.readAt(_storageKey(sender, id), 0, record.size);
  }

  /// Registers already-known bytes (e.g. a session attachment for
  /// `chat.file` / `chat.image`) as a finished transfer. The id is
  /// derived from the content, so registering the same bytes twice
  /// returns the same record instead of a duplicate.
  Future<LomFileRecord> registerComplete({
    required String sender,
    required String name,
    required String mime,
    required List<int> bytes,
  }) async {
    final sha = crypto.sha256.convert(bytes).toString();
    final id = 'reg-${sha.substring(0, 28)}';
    return _doc.mutate((doc) async {
      final existing = _record(doc, sender, id);
      if (existing != null && existing.status == 'complete') return existing;
      if (_totalFor(doc, sender) - (existing?.size ?? 0) + bytes.length >
          lomFileQuotaBytes) {
        throw LomRpcException('file.quota_exceeded');
      }
      await storage.create(_storageKey(sender, id));
      await storage.writeAt(_storageKey(sender, id), 0, bytes);
      final record = LomFileRecord(
        id: id,
        name: name,
        mime: mime,
        size: bytes.length,
        sha256: sha,
        offset: bytes.length,
        status: 'complete',
      );
      doc[_docKey(sender, id)] = record.toJson();
      return record;
    });
  }

  /// Handles one `file.*` method. [sender] is the requesting desktop's
  /// public key `K`.
  Future<Map<String, Object?>> handle(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'file.begin':
        return (await _begin(payload, sender)).toFileState();
      case 'file.chunk':
        return (await _chunk(payload, sender)).toFileState();
      case 'file.finish':
        return (await _finish(payload, sender)).toFileState();
      case 'file.read':
        return _read(payload, sender);
      case 'file.list':
        return _list(sender);
      case 'file.delete':
        return _delete(payload, sender);
      case 'file.save_gallery':
        return _saveGallery(payload, sender);
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  Future<LomFileRecord> _begin(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final id = _id(payload);
    final name = _string(payload, 'name');
    if (name.isEmpty ||
        name.length > 200 ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[/\\\x00-\x1f\x7f]'))) {
      throw LomRpcException('file.invalid_name');
    }
    final mime = _string(payload, 'mime');
    if (mime.length > 200) throw LomRpcException('file.invalid_mime');
    final size = int.tryParse(_string(payload, 'size'));
    final sha = _string(payload, 'sha256');
    if (size == null ||
        size < 0 ||
        size > lomFileMaxBytes ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw LomRpcException('file.invalid_size_or_hash');
    }
    return _doc.mutate((doc) async {
      final existing = _record(doc, sender, id);
      if (existing != null) {
        // Same metadata → resume at the current offset; different
        // metadata under the same id is a reuse error.
        if (existing.name == name &&
            existing.mime == mime &&
            existing.size == size &&
            existing.sha256 == sha) {
          return existing;
        }
        throw LomRpcException('file.id_reused');
      }
      if (_totalFor(doc, sender) + size > lomFileQuotaBytes) {
        throw LomRpcException('file.quota_exceeded');
      }
      await storage.create(_storageKey(sender, id));
      final record = LomFileRecord(
        id: id,
        name: name,
        mime: mime,
        size: size,
        sha256: sha,
        offset: 0,
        status: 'uploading',
      );
      doc[_docKey(sender, id)] = record.toJson();
      return record;
    });
  }

  Future<LomFileRecord> _chunk(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final id = _id(payload);
    final offset = int.tryParse(_string(payload, 'offset'));
    final bytes = _chunkBytes(_string(payload, 'data'));
    if (offset == null || offset < 0) {
      throw LomRpcException('file.invalid_chunk');
    }
    return _doc.mutate((doc) async {
      final record = _record(doc, sender, id);
      if (record == null) throw LomRpcException('file.missing');
      final key = _storageKey(sender, id);
      if (offset == record.offset) {
        if (record.status == 'complete') {
          throw LomRpcException('file.chunk_conflict');
        }
        await storage.writeAt(key, offset, bytes);
        final next = record.copyWith(offset: offset + bytes.length);
        doc[_docKey(sender, id)] = next.toJson();
        return next;
      }
      if (offset < record.offset) {
        // Re-sent slice: only an exact byte-for-byte repeat is ok.
        if (offset + bytes.length > record.offset) {
          throw LomRpcException('file.offset_mismatch');
        }
        final stored = await storage.readAt(key, offset, bytes.length);
        if (!_bytesEqual(stored, bytes)) {
          throw LomRpcException('file.chunk_conflict');
        }
        return record;
      }
      throw LomRpcException('file.offset_mismatch');
    });
  }

  Future<LomFileRecord> _finish(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final id = _id(payload);
    return _doc.mutate((doc) async {
      final record = _record(doc, sender, id);
      if (record == null) throw LomRpcException('file.missing');
      if (record.status == 'complete') return record;
      if (record.offset != record.size) {
        throw LomRpcException('file.integrity_failed');
      }
      final bytes = await storage.readAt(
        _storageKey(sender, id),
        0,
        record.size,
      );
      if (bytes.length != record.size ||
          crypto.sha256.convert(bytes).toString() != record.sha256) {
        throw LomRpcException('file.integrity_failed');
      }
      final done = record.copyWith(status: 'complete');
      doc[_docKey(sender, id)] = done.toJson();
      return done;
    });
  }

  Future<Map<String, Object?>> _read(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final id = _id(payload);
    final offset = int.tryParse(_string(payload, 'offset'));
    if (offset == null || offset < 0) {
      throw LomRpcException('file.invalid_chunk');
    }
    final record = await lookup(id, sender);
    if (record == null) throw LomRpcException('file.missing');
    if (record.status != 'complete') throw LomRpcException('file.incomplete');
    if (offset > record.size) throw LomRpcException('file.invalid_offset');
    if (offset == record.size) return {'data': '', 'next': '$offset'};
    final bytes = await storage.readAt(
      _storageKey(sender, id),
      offset,
      lomFileChunkBytes,
    );
    return {
      'data': base64Encode(bytes),
      'next': '${offset + bytes.length}',
    };
  }

  Future<Map<String, Object?>> _list(String sender) async {
    final doc = await _doc.load();
    final prefix = '${_senderHash(sender)}:';
    final items = [
      for (final entry in doc.entries)
        if (entry.key.startsWith(prefix) &&
            entry.value is Map<String, dynamic>)
          LomFileRecord.fromJson(
            Map<String, Object?>.from(entry.value as Map),
          ).toFileState(),
    ];
    return {'items': jsonEncode(items)};
  }

  Future<Map<String, Object?>> _delete(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final id = _id(payload);
    final deleted = await _doc.mutate((doc) async {
      final record = _record(doc, sender, id);
      if (record == null) return false;
      await storage.delete(_storageKey(sender, id));
      doc.remove(_docKey(sender, id));
      return true;
    });
    if (!deleted) throw LomRpcException('file.missing');
    return {'status': 'deleted'};
  }

  Future<Map<String, Object?>> _saveGallery(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final id = _id(payload);
    final record = await lookup(id, sender);
    if (record == null) throw LomRpcException('file.missing');
    if (record.status != 'complete') {
      throw LomRpcException('file.incomplete_or_corrupt');
    }
    final saver = gallerySaver;
    if (saver == null) throw LomRpcException('remote.method_unknown');
    final path = await storage.localPath(_storageKey(sender, id));
    if (path == null) throw LomRpcException('file.storage_failed');
    final uri = await saver.saveToGallery(
      path: path,
      name: record.name,
      mime: record.mime,
    );
    if (!uri.startsWith('content://media/')) {
      throw LomRpcException('file.storage_failed');
    }
    return {'id': id, 'status': 'saved', 'uri': uri};
  }

  LomFileRecord? _record(
    Map<String, Object?> doc,
    String sender,
    String id,
  ) {
    final raw = doc[_docKey(sender, id)];
    if (raw is! Map<String, dynamic>) return null;
    return LomFileRecord.fromJson(Map<String, Object?>.from(raw));
  }

  /// Total bytes held for [sender] (uploading + complete).
  int _totalFor(Map<String, Object?> doc, String sender) {
    final prefix = '${_senderHash(sender)}:';
    var total = 0;
    for (final entry in doc.entries) {
      final value = entry.value;
      if (entry.key.startsWith(prefix) &&
          value is Map<String, dynamic>) {
        total +=
            LomFileRecord.fromJson(Map<String, Object?>.from(value)).size;
      }
    }
    return total;
  }

  String _id(Map<String, dynamic> payload) {
    final id = _string(payload, 'id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,64}$').hasMatch(id)) {
      throw LomRpcException('file.invalid_id');
    }
    return id;
  }

  /// Standard base64 (with `=` padding), decoding to 1–128 KiB.
  List<int> _chunkBytes(String data) {
    if (data.isEmpty ||
        !RegExp(r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$')
            .hasMatch(data)) {
      throw LomRpcException('file.invalid_chunk');
    }
    List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw LomRpcException('file.invalid_chunk');
    }
    if (bytes.isEmpty || bytes.length > lomFileChunkBytes) {
      throw LomRpcException('file.invalid_chunk');
    }
    return bytes;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }
}
