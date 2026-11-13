/// Android Keystore-backed protector for the Lom identity private keys.
///
/// The AES-256-GCM wrapping key lives in the Android Keystore (alias
/// `lom_identity_wrap`, never exportable) and the wrapped bytes live in
/// `noBackupFilesDir/lom_identity.bin` — both owned by the native
/// `LomKeystorePlugin` (`dsh/lom_keystore` channel). Plaintext private
/// keys cross the channel only as method arguments in memory, never in
/// storage, logs, or backups.
///
/// Without the native side (widget tests, desktop) every call throws
/// [UnsupportedError]; tests use [MemoryLomKeyProtector] instead.
library;

import 'package:flutter/services.dart';

import 'base64url.dart';
import 'identity_store.dart';

/// MethodChannel `dsh/lom_keystore` protector.
///
/// Channel methods (all take/return unpadded base64url strings):
/// - `wrap`: {plaintext} -> {wrapped}
/// - `unwrap`: {wrapped} -> {plaintext}
/// - `loadWrapped`: {} -> {wrapped} | null
/// - `saveWrapped`: {wrapped} -> {}
/// - `deleteWrapped`: {} -> {}
class MethodChannelLomKeyProtector implements LomKeyProtectorWithStorage {
  MethodChannelLomKeyProtector([
    this.channel = const MethodChannel('dsh/lom_keystore'),
  ]);

  final MethodChannel channel;

  @override
  Future<List<int>> wrap(List<int> plaintext) async {
    final wrapped = await channel.invokeMethod<String>(
      'wrap',
      {'plaintext': b64urlEncode(plaintext)},
    );
    final bytes = wrapped == null ? null : b64urlDecodeStrict(wrapped);
    if (bytes == null) throw StateError('lom keystore wrap failed');
    return bytes;
  }

  @override
  Future<List<int>> unwrap(List<int> wrapped) async {
    final plain = await channel.invokeMethod<String>(
      'unwrap',
      {'wrapped': b64urlEncode(wrapped)},
    );
    final bytes = plain == null ? null : b64urlDecodeStrict(plain);
    if (bytes == null) throw StateError('lom keystore unwrap failed');
    return bytes;
  }

  @override
  Future<List<int>?> loadWrapped() async {
    final wrapped = await channel.invokeMethod<String>('loadWrapped');
    if (wrapped == null || wrapped.isEmpty) return null;
    return b64urlDecodeStrict(wrapped);
  }

  @override
  Future<void> saveWrapped(List<int> wrapped) async {
    await channel.invokeMethod<void>(
      'saveWrapped',
      {'wrapped': b64urlEncode(wrapped)},
    );
  }

  @override
  Future<void> deleteWrapped() async {
    await channel.invokeMethod<void>('deleteWrapped');
  }
}
