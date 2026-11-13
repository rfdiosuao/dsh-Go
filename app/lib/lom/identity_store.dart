/// Lom identity persistence (doc §04 "私钥保护（建议）").
///
/// The long-lived identity (X25519 + Ed25519 private keys) is generated
/// once at first launch and never replaced. Private bytes are protected by
/// a [LomKeyProtector]: on Android the real implementation wraps them with
/// an AES-256-GCM key held in the Android Keystore and stores the wrapped
/// bytes in `noBackupFilesDir` (via the `dsh/lom_keystore` channel); the
/// public key string `K` lives in the Keystore-backed [LomSecretStore]
/// (same store as the device credentials).
///
/// Private key bytes are never logged, never uploaded, and only exist in
/// memory while an operation needs them.
library;

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64url.dart';
import 'credentials.dart';
import 'identity.dart';

/// Wraps / unwraps raw key bytes with a device Keystore key.
/// Implemented on Android by `LomKeystorePlugin` (AES-256-GCM, key alias
/// `lom_identity_wrap`); tests use an in-memory stand-in.
abstract class LomKeyProtector {
  /// Encrypts [plaintext] bytes; returns the wrapped bytes (IV included).
  Future<List<int>> wrap(List<int> plaintext);

  /// Decrypts bytes previously returned by [wrap].
  Future<List<int>> unwrap(List<int> wrapped);
}

/// Owns the Lom identity: load-or-create, public `K`, private bytes.
class LomIdentityStore {
  LomIdentityStore({
    required this.secrets,
    required this.protector,
  });

  final LomSecretStore secrets;

  /// The protector also owns persistence of the wrapped bytes (Android:
  /// `noBackupFilesDir/lom_identity.bin`).
  final LomKeyProtectorWithStorage protector;

  static const _kPublicKeys = 'lom.identity.public_keys';

  /// The wrapped private bytes are kept by the protector implementation
  /// itself (Android: `noBackupFilesDir/lom_identity.bin`); the secret
  /// store only holds the public key string. This keeps the private
  /// material out of every backup and out of SharedPreferences.
  static const _kWrappedMarker = 'lom.identity.wrapped';

  /// Loads the identity, or generates + persists a fresh one on first run.
  Future<LomIdentity> loadOrCreate() async {
    final existing = await load();
    if (existing != null) return existing;
    final fresh = await LomIdentity.generate();
    await _save(fresh);
    return fresh;
  }

  /// Loads the identity, or `null` when none was ever stored.
  Future<LomIdentity?> load() async {
    final keys = await secrets.read(_kPublicKeys);
    final marker = await secrets.read(_kWrappedMarker);
    if (keys == null || marker != '1') return null;
    final split = splitPublicKeyString(keys);
    if (split == null) return null;
    final wrapped = await protector.loadWrapped();
    if (wrapped == null) return null;
    List<int> privateBytes;
    try {
      privateBytes = await protector.unwrap(wrapped);
    } catch (_) {
      return null;
    }
    if (privateBytes.length != 64) return null;
    final identity = await LomIdentity.fromPrivateBytes(
      x25519PrivateKey: privateBytes.sublist(0, 32),
      ed25519Seed: privateBytes.sublist(32, 64),
    );
    // The stored public keys must match the unwrapped private keys;
    // otherwise the store is corrupt — fail closed.
    if (identity.keys != keys) return null;
    return identity;
  }

  Future<void> _save(LomIdentity identity) async {
    final private = await identity.extractPrivateBytes();
    final wrapped = await protector.wrap(private);
    await protector.saveWrapped(wrapped);
    await secrets.write(_kPublicKeys, identity.keys);
    await secrets.write(_kWrappedMarker, '1');
    // Prove the write landed before the caller proceeds.
    final back = await secrets.read(_kPublicKeys);
    if (back != identity.keys) {
      throw StateError('lom identity store failed');
    }
  }

  /// Deletes the identity (only used when the user explicitly resets Lom
  /// pairing; re-pairing afterwards is treated as a new device).
  Future<void> delete() async {
    await secrets.delete(_kPublicKeys);
    await secrets.delete(_kWrappedMarker);
    await protector.deleteWrapped();
  }
}

/// Extended protector contract: the wrapped bytes themselves are persisted
/// by the platform implementation (Android `noBackupFilesDir`), not by Dart.
abstract class LomKeyProtectorWithStorage extends LomKeyProtector {
  Future<List<int>?> loadWrapped();
  Future<void> saveWrapped(List<int> wrapped);
  Future<void> deleteWrapped();
}

/// Base64 helpers for the platform channel payload (the channel carries
/// wrapped bytes as unpadded base64url strings; the channel never sees
/// plaintext private keys).
String lomWrapEncode(List<int> bytes) => b64urlEncode(bytes);
List<int>? lomWrapDecode(String s) => b64urlDecodeStrict(s);

/// In-memory protector for tests and previews (NOT for production: the
/// wrapping key lives in memory). Uses AES-256-GCM from `cryptography`
/// with a fresh random key per instance.
class MemoryLomKeyProtector implements LomKeyProtectorWithStorage {
  MemoryLomKeyProtector();

  List<int>? _wrapped;
  Uint8List? _key;
  static final _random = Random.secure();

  @override
  Future<List<int>> wrap(List<int> plaintext) async {
    _key ??= Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(_key!),
      nonce: nonce,
    );
    return [...nonce, ...box.cipherText, ...box.mac.bytes];
  }

  @override
  Future<List<int>> unwrap(List<int> wrapped) async {
    final key = _key;
    if (key == null) throw StateError('no key');
    final nonce = wrapped.sublist(0, 12);
    final cipherAndTag = wrapped.sublist(12);
    final cipherText = cipherAndTag.sublist(0, cipherAndTag.length - 16);
    final tag = cipherAndTag.sublist(cipherAndTag.length - 16);
    return _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
      secretKey: SecretKey(key),
    );
  }

  @override
  Future<List<int>?> loadWrapped() async => _wrapped;

  @override
  Future<void> saveWrapped(List<int> wrapped) async {
    _wrapped = List<int>.from(wrapped);
  }

  @override
  Future<void> deleteWrapped() async {
    _wrapped = null;
    _key = null;
  }

  static final _aead = Chacha20.poly1305Aead();
}
