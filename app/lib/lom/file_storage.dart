/// File byte storage + transfer metadata (doc §07 §7 `FileState`).
///
/// Split out of `file_store.dart`: the store (RPC validation + state
/// machine) stays there; the bytes and the record shape live here.
library;
/// Byte storage for one transfer. [key] is opaque (`<senderHash>/<id>`);
/// implementations must never let it escape its root.
abstract class LomFileStorage {
  Future<void> create(String key);
  Future<void> writeAt(String key, int offset, List<int> bytes);
  Future<List<int>> readAt(String key, int offset, int length);
  Future<void> delete(String key);

  /// On-disk path of [key], or null when the bytes are not a real file
  /// (memory storage). `file.save_gallery` needs a real path to hand to
  /// the MediaStore bridge.
  Future<String?> localPath(String key);
}

/// In-memory [LomFileStorage] for tests.
class MemoryLomFileStorage implements LomFileStorage {
  final _files = <String, List<int>>{};

  @override
  Future<void> create(String key) async {
    _files.putIfAbsent(key, () => <int>[]);
  }

  @override
  Future<void> writeAt(String key, int offset, List<int> bytes) async {
    final cur = _files.putIfAbsent(key, () => <int>[]);
    final needed = offset + bytes.length;
    if (cur.length < needed) {
      // Growing a List<int> by assignment would fill with null; pad
      // with zeros explicitly.
      cur.addAll(List<int>.filled(needed - cur.length, 0));
    }
    cur.setRange(offset, offset + bytes.length, bytes);
  }

  @override
  Future<List<int>> readAt(String key, int offset, int length) async {
    final cur = _files[key];
    if (cur == null) return [];
    final end = (offset + length).clamp(0, cur.length);
    if (offset >= end) return [];
    return cur.sublist(offset, end);
  }

  @override
  Future<void> delete(String key) async {
    _files.remove(key);
  }

  @override
  Future<String?> localPath(String key) async => null;
}

/// Saves a finished file to the system gallery / MediaStore and returns
/// its `content://media/…` URI. Implemented by the `dsh/files` channel
/// (`platform_adapters.dart`); null in tests that do not cover it.
abstract class LomGallerySaver {
  Future<String> saveToGallery({
    required String path,
    required String name,
    required String mime,
  });
}

/// One transfer's metadata (doc §07 §7 `FileState`).
class LomFileRecord {
  const LomFileRecord({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
    required this.offset,
    required this.status,
  });

  factory LomFileRecord.fromJson(Map<String, Object?> json) => LomFileRecord(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        mime: json['mime'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        sha256: json['sha256'] as String? ?? '',
        offset: json['offset'] as int? ?? 0,
        status: json['status'] as String? ?? 'uploading',
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'mime': mime,
        'size': size,
        'sha256': sha256,
        'offset': offset,
        'status': status,
      };

  /// The wire `FileState`: `size` / `offset` are decimal strings.
  Map<String, Object?> toFileState() => {
        'id': id,
        'name': name,
        'mime': mime,
        'size': '$size',
        'sha256': sha256,
        'offset': '$offset',
        'status': status,
      };

  final String id;
  final String name;
  final String mime;
  final int size;
  final String sha256;
  final int offset;

  /// `uploading` (not yet received/verified) or `complete` (SHA-256 ok).
  final String status;

  LomFileRecord copyWith({int? offset, String? status}) => LomFileRecord(
        id: id,
        name: name,
        mime: mime,
        size: size,
        sha256: sha256,
        offset: offset ?? this.offset,
        status: status ?? this.status,
      );
}

