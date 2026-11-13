/// Lom phone identity keys and pairing algorithms (doc §04).
///
/// Identity: one long-lived X25519 key pair (key agreement) + one long-lived
/// Ed25519 key pair (signing). The public key string is
/// `K = b64url(x25519_pub 32B ‖ ed25519_pub 32B)` — 86 characters.
/// Private keys are never replaced (a new key is a new device) and never
/// uploaded or logged.
///
/// Algorithms:
/// - fingerprint(K) = SHA-256("LOM-KEY-FP-V1\n" + K)[0..16]
/// - key_proof = b64url(HMAC-SHA256(psk, "LOM-PAIR-PROOF-V1\n" +
///   pairing_id + "\n" + K_desktop + "\n" + K_phone))
/// - SAS = (SHA-256("LOM-PAIR-SAS-V1\n" + pairing_id + "\n" + K_desktop +
///   "\n" + K_phone)[0..4] big-endian u32) mod 1_000_000, zero-padded to 6.
///   In every formula the K values and pairing_id enter as their ASCII text,
///   except `psk` which enters as its decoded 32 raw bytes (HMAC key).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'base64url.dart';

/// A Lom phone identity: the two long-lived key pairs plus their public
/// key string `K`.
class LomIdentity {
  LomIdentity._({
    required this.x25519KeyPair,
    required this.ed25519KeyPair,
    required this.x25519PublicKey,
    required this.ed25519PublicKey,
  }) : keys = b64urlEncode([...x25519PublicKey, ...ed25519PublicKey]);

  /// Generates a fresh identity. Call once at first launch, then persist.
  static Future<LomIdentity> generate() async {
    final x = await X25519().newKeyPair();
    final e = await Ed25519().newKeyPair();
    return LomIdentity._(
      x25519KeyPair: x,
      ed25519KeyPair: e,
      x25519PublicKey: (await x.extractPublicKey()).bytes,
      ed25519PublicKey: (await e.extractPublicKey()).bytes,
    );
  }

  /// Rebuilds an identity from raw private key material (32-byte X25519
  /// private key + 32-byte Ed25519 seed). Used when loading persisted keys
  /// and by the test vectors, whose keys are repeated-byte seeds.
  static Future<LomIdentity> fromPrivateBytes({
    required List<int> x25519PrivateKey,
    required List<int> ed25519Seed,
  }) async {
    final x = await X25519().newKeyPairFromSeed(x25519PrivateKey);
    final e = await Ed25519().newKeyPairFromSeed(ed25519Seed);
    return LomIdentity._(
      x25519KeyPair: x,
      ed25519KeyPair: e,
      x25519PublicKey: (await x.extractPublicKey()).bytes,
      ed25519PublicKey: (await e.extractPublicKey()).bytes,
    );
  }

  /// Extracts the raw private key bytes: 64 bytes =
  /// X25519 private (32) ‖ Ed25519 seed (32). The caller must protect these
  /// (Keystore AES-256-GCM wrapping, never log or upload).
  Future<Uint8List> extractPrivateBytes() async {
    final x = await x25519KeyPair.extractPrivateKeyBytes();
    final e = await ed25519KeyPair.extractPrivateKeyBytes();
    return Uint8List.fromList([...x, ...e]);
  }

  final SimpleKeyPair x25519KeyPair;
  final SimpleKeyPair ed25519KeyPair;

  /// Raw 32-byte X25519 public key (u-coordinate, little-endian).
  final List<int> x25519PublicKey;

  /// Raw 32-byte Ed25519 public key.
  final List<int> ed25519PublicKey;

  /// `K` — b64url(x25519_pub ‖ ed25519_pub), 86 characters.
  final String keys;
}

/// Validates a public key string `K`: 86 chars, canonical base64url,
/// decoding to exactly 64 bytes. Returns the decoded bytes or `null`.
List<int>? parsePublicKeyString(String k) {
  if (k.length != 86) return null;
  return b64urlDecodeStrictLength(k, 64);
}

/// Splits a valid `K` into its X25519 (first 32 bytes) and Ed25519
/// (last 32 bytes) public keys. Returns `null` when [k] is invalid.
({List<int> x25519, List<int> ed25519})? splitPublicKeyString(String k) {
  final bytes = parsePublicKeyString(k);
  if (bytes == null) return null;
  return (x25519: bytes.sublist(0, 32), ed25519: bytes.sublist(32, 64));
}

/// fingerprint(K) = first 16 bytes of SHA-256("LOM-KEY-FP-V1\n" + K),
/// returned as unpadded base64url (22 chars).
String fingerprint(String k) {
  final digest = crypto.sha256.convert(utf8.encode('LOM-KEY-FP-V1\n$k'));
  return b64urlEncode(digest.bytes.sublist(0, 16));
}

/// key_proof = b64url(HMAC-SHA256(psk,
///   "LOM-PAIR-PROOF-V1\n" + pairing_id + "\n" + desktopK + "\n" + phoneK)).
///
/// [psk] is the decoded 32 raw bytes from the QR code; the K values and
/// pairing_id enter as their ASCII text.
String keyProof({
  required List<int> psk,
  required String pairingId,
  required String desktopKeys,
  required String phoneKeys,
}) {
  final msg = utf8.encode(
    'LOM-PAIR-PROOF-V1\n$pairingId\n$desktopKeys\n$phoneKeys',
  );
  final mac = crypto.Hmac(crypto.sha256, psk).convert(msg);
  return b64urlEncode(mac.bytes);
}

/// SAS confirmation code: 6 decimal digits (zero-padded) from
/// SHA-256("LOM-PAIR-SAS-V1\n" + pairing_id + "\n" + desktopK + "\n" + phoneK),
/// first 4 bytes read big-endian as u32, mod 1_000_000.
String sasCode({
  required String pairingId,
  required String desktopKeys,
  required String phoneKeys,
}) {
  final digest = crypto.sha256.convert(
    utf8.encode('LOM-PAIR-SAS-V1\n$pairingId\n$desktopKeys\n$phoneKeys'),
  ).bytes;
  final n = ByteData.sublistView(Uint8List.fromList(digest)).getUint32(0);
  return (n % 1000000).toString().padLeft(6, '0');
}

/// Formats a 6-digit SAS for display, e.g. `643266` → `643 266`.
String formatSas(String sas) =>
    sas.length == 6 ? '${sas.substring(0, 3)} ${sas.substring(3)}' : sas;
