/// Flutter platform-channel adapters for the Lom Phase 4 methods that
/// need native code. Kept out of the pure-Dart files so those stay
/// unit-testable with `dart test`.
library;

import 'package:flutter/services.dart';

import 'file_storage.dart';
import 'rpc_errors.dart';

/// [LomGallerySaver] via the `dsh/files` channel: the native side inserts
/// the file into the MediaStore and returns its `content://media/…` URI.
/// A missing native method (older build, desktop tests) is a storage
/// failure, never a fabricated URI.
class MethodChannelLomGallerySaver implements LomGallerySaver {
  MethodChannelLomGallerySaver([
    this.channel = const MethodChannel('dsh/files'),
  ]);

  final MethodChannel channel;

  @override
  Future<String> saveToGallery({
    required String path,
    required String name,
    required String mime,
  }) async {
    try {
      final uri = await channel.invokeMethod<String>(
        'lomSaveToGallery',
        {'path': path, 'name': name, 'mime': mime},
      );
      if (uri == null || uri.isEmpty) {
        throw LomRpcException('file.storage_failed');
      }
      return uri;
    } on LomRpcException {
      rethrow;
    } catch (_) {
      throw LomRpcException('file.storage_failed');
    }
  }
}
