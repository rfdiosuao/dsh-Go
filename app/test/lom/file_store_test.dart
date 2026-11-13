import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart' as crypto;
import 'package:dsh_app/lom/lom_phone.dart';
import 'package:flutter_test/flutter_test.dart';

class _MapStore implements LomSecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeGallerySaver implements LomGallerySaver {
  String? lastPath;
  String uri = 'content://media/external/images/media/42';
  @override
  Future<String> saveToGallery({
    required String path,
    required String name,
    required String mime,
  }) async {
    lastPath = path;
    return uri;
  }
}

const _sender = 'desktop-key-K';
const _id = '0123456789abcdef';
final _bytes = utf8.encode('hello lom file transfer');
final _sha = crypto.sha256.convert(_bytes).toString();

Map<String, Object?> _beginPayload({int? size, String? sha}) => {
      'id': _id,
      'name': 'hello.txt',
      'mime': 'text/plain',
      'size': '${size ?? _bytes.length}',
      'sha256': sha ?? _sha,
    };

void main() {
  group('LomFileStore (Phase 4 file.*)', () {
    test('begin → chunk → finish → read round-trips, resumable', () async {
      final store = LomFileStore(
        _MapStore(),
        storage: MemoryLomFileStorage(),
      );
      var state = await store.handle('file.begin', _beginPayload(), _sender);
      expect(state['status'], 'uploading');
      expect(state['offset'], '0');
      // Same begin again returns the current progress (resume).
      state = await store.handle('file.begin', _beginPayload(), _sender);
      expect(state['offset'], '0');
      final first = _bytes.sublist(0, 5);
      final rest = _bytes.sublist(5);
      state = await store.handle('file.chunk', {
        'id': _id,
        'offset': '0',
        'data': base64Encode(first),
      }, _sender);
      expect(state['offset'], '5');
      // Re-sending the same slice is idempotent.
      state = await store.handle('file.chunk', {
        'id': _id,
        'offset': '0',
        'data': base64Encode(first),
      }, _sender);
      expect(state['offset'], '5');
      // Re-sending different bytes at the same offset conflicts.
      await expectLater(
        store.handle('file.chunk', {
          'id': _id,
          'offset': '0',
          'data': base64Encode(utf8.encode('HELLO')),
        }, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.chunk_conflict',
        )),
      );
      // A gap is an offset mismatch.
      await expectLater(
        store.handle('file.chunk', {
          'id': _id,
          'offset': '9',
          'data': base64Encode(rest),
        }, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.offset_mismatch',
        )),
      );
      state = await store.handle('file.chunk', {
        'id': _id,
        'offset': '5',
        'data': base64Encode(rest),
      }, _sender);
      expect(state['offset'], '${_bytes.length}');
      state = await store.handle('file.finish', {'id': _id}, _sender);
      expect(state['status'], 'complete');
      final read = await store.handle('file.read', {
        'id': _id,
        'offset': '0',
      }, _sender);
      expect(base64Decode(read['data'] as String), _bytes);
      expect(read['next'], '${_bytes.length}');
    });

    test('finish fails integrity on a wrong hash, read needs complete',
        () async {
      final store = LomFileStore(
        _MapStore(),
        storage: MemoryLomFileStorage(),
      );
      await store.handle(
        'file.begin',
        _beginPayload(sha: '0' * 64),
        _sender,
      );
      await store.handle('file.chunk', {
        'id': _id,
        'offset': '0',
        'data': base64Encode(_bytes),
      }, _sender);
      await expectLater(
        store.handle('file.finish', {'id': _id}, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.integrity_failed',
        )),
      );
      await expectLater(
        store.handle('file.read', {'id': _id, 'offset': '0'}, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.incomplete',
        )),
      );
    });

    test('begin validates id/name/size/hash and reuses ids', () async {
      final store = LomFileStore(
        _MapStore(),
        storage: MemoryLomFileStorage(),
      );
      for (final bad in [
        {'id': 'short', 'name': 'a.txt', 'mime': 'text/plain', 'size': '1', 'sha256': _sha},
        {'id': _id, 'name': '../evil', 'mime': 'text/plain', 'size': '1', 'sha256': _sha},
        {'id': _id, 'name': 'a.txt', 'mime': 'text/plain', 'size': '-1', 'sha256': _sha},
        {'id': _id, 'name': 'a.txt', 'mime': 'text/plain', 'size': '1', 'sha256': 'zz'},
      ]) {
        await expectLater(
          store.handle('file.begin', bad, _sender),
          throwsA(isA<LomRpcException>()),
        );
      }
      await store.handle('file.begin', _beginPayload(), _sender);
      await expectLater(
        store.handle(
          'file.begin',
          _beginPayload(size: _bytes.length + 1),
          _sender,
        ),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.id_reused',
        )),
      );
    });

    test('list is per-desktop, delete removes bytes and metadata',
        () async {
      final store = LomFileStore(
        _MapStore(),
        storage: MemoryLomFileStorage(),
      );
      await store.handle('file.begin', _beginPayload(), _sender);
      await store.handle('file.begin', _beginPayload(), 'other-desktop');
      final list = await store.handle('file.list', {}, _sender);
      final items =
          jsonDecode(list['items'] as String) as List;
      expect(items.length, 1);
      expect(items.first['id'], _id);
      final deleted =
          await store.handle('file.delete', {'id': _id}, _sender);
      expect(deleted, {'status': 'deleted'});
      await expectLater(
        store.handle('file.delete', {'id': _id}, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.missing',
        )),
      );
      // The other desktop's file is untouched.
      expect(await store.isComplete(_id, 'other-desktop'), false);
      expect(await store.lookup(_id, 'other-desktop'), isNotNull);
    });

    test('registerComplete is content-addressed and verifiable', () async {
      final store = LomFileStore(
        _MapStore(),
        storage: MemoryLomFileStorage(),
      );
      final first = await store.registerComplete(
        sender: _sender,
        name: 'pic.png',
        mime: 'image/png',
        bytes: _bytes,
      );
      final second = await store.registerComplete(
        sender: _sender,
        name: 'pic.png',
        mime: 'image/png',
        bytes: _bytes,
      );
      expect(first.id, second.id);
      expect(first.status, 'complete');
      expect(await store.isComplete(first.id, _sender), true);
    });

    test('save_gallery needs a complete file and a media URI', () async {
      final saver = _FakeGallerySaver();
      final store = LomFileStore(
        _MapStore(),
        storage: MemoryLomFileStorage(),
        gallerySaver: saver,
      );
      await store.handle('file.begin', _beginPayload(), _sender);
      await expectLater(
        store.handle('file.save_gallery', {'id': _id}, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.incomplete_or_corrupt',
        )),
      );
      // Memory storage has no real path, so the gallery bridge cannot run.
      await store.handle('file.chunk', {
        'id': _id,
        'offset': '0',
        'data': base64Encode(_bytes),
      }, _sender);
      await store.handle('file.finish', {'id': _id}, _sender);
      await expectLater(
        store.handle('file.save_gallery', {'id': _id}, _sender),
        throwsA(isA<LomRpcException>().having(
          (e) => e.code,
          'code',
          'file.storage_failed',
        )),
      );
    });

    test('IoLomFileStorage round-trips bytes on disk', () async {
      final dir = await io.Directory.systemTemp.createTemp('lom-file-test');
      try {
        final storage = IoLomFileStorage(dir);
        await storage.create('abc/0123456789abcdef');
        await storage.writeAt(
          'abc/0123456789abcdef',
          0,
          utf8.encode('hello '),
        );
        await storage.writeAt(
          'abc/0123456789abcdef',
          6,
          utf8.encode('world'),
        );
        expect(
          await storage.readAt('abc/0123456789abcdef', 0, 100),
          utf8.encode('hello world'),
        );
        expect(
          await storage.localPath('abc/0123456789abcdef'),
          isNotNull,
        );
        await storage.delete('abc/0123456789abcdef');
        expect(
          await storage.localPath('abc/0123456789abcdef'),
          isNull,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
