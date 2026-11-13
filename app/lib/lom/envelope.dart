/// Lom RPC envelope (doc §06): one-shot X25519 + HKDF-SHA256 +
/// ChaCha20-Poly1305 + Ed25519 signature. No Noise, no session state.
///
/// Wire format — exactly six string fields, no more, no fewer:
/// `id` (32 hex chars), `sender` (K), `recipient` (K), `ephemeral`
/// (one-shot X25519 public key, 43 chars b64url), `ciphertext`
/// (`nonce(12) ‖ sealed ‖ tag(16)`, b64url, 28–400,000 bytes decoded),
/// `signature` (Ed25519 over `AAD ‖ body`, 86 chars b64url).
///
/// AAD = "LOM-REMOTE-V1\n" + id + "\n" + sender + "\n" + recipient +
///       "\n" + ephemeral (raw envelope text values).
/// Key = HKDF-SHA256(ikm = X25519 shared secret, salt = 32 zero bytes,
///       info = AAD, L = 32).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64url.dart';
import 'identity.dart';

/// Maximum plaintext size (UTF-8 bytes) for a sealed message.
const int lomEnvelopeMaxPlaintextBytes = 350000;

/// Maximum decoded `ciphertext` body size.
const int lomEnvelopeMaxCiphertextBytes = 400000;

/// Minimum decoded `ciphertext` body size (12 nonce + 0 cipher + 16 tag).
const int lomEnvelopeMinCiphertextBytes = 28;

/// Thrown when an envelope cannot be opened. [code] is one of the
/// internal-only codes `remote.invalid_key` / `remote.payload_invalid`,
/// or a descriptive reason; these codes never go into a reply.
class LomEnvelopeException implements Exception {
  LomEnvelopeException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => 'LomEnvelopeException($code${detail == null ? '' : ': $detail'})';
}

/// An envelope: exactly six string fields.
class LomEnvelope {
  const LomEnvelope({
    required this.id,
    required this.sender,
    required this.recipient,
    required this.ephemeral,
    required this.ciphertext,
    required this.signature,
  });

  factory LomEnvelope.fromJson(Map<String, dynamic> json) {
    if (json.length != 6) {
      throw LomEnvelopeException(
        'remote.payload_invalid',
        'envelope must have exactly 6 fields',
      );
    }
    String field(String name) {
      final v = json[name];
      if (v is! String) {
        throw LomEnvelopeException(
          'remote.payload_invalid',
          'envelope field $name is not a string',
        );
      }
      return v;
    }

    return LomEnvelope(
      id: field('id'),
      sender: field('sender'),
      recipient: field('recipient'),
      ephemeral: field('ephemeral'),
      ciphertext: field('ciphertext'),
      signature: field('signature'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender': sender,
        'recipient': recipient,
        'ephemeral': ephemeral,
        'ciphertext': ciphertext,
        'signature': signature,
      };

  final String id;
  final String sender;
  final String recipient;
  final String ephemeral;
  final String ciphertext;
  final String signature;

  /// AAD bytes for this envelope (raw field text, `\n` = 0x0A).
  List<int> get aad => utf8.encode(
        'LOM-REMOTE-V1\n$id\n$sender\n$recipient\n$ephemeral',
      );

  @override
  String toString() => 'LomEnvelope(id=$id, sender=$sender)';
}

final _random = Random.secure();

List<int> _randomBytes(int n) =>
    List<int>.generate(n, (_) => _random.nextInt(256));

Future<List<int>> _deriveKey({
  required List<int> shared,
  required List<int> aad,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(shared),
    nonce: List<int>.filled(32, 0),
    info: aad,
  );
  return key.extractBytes();
}

bool _isAllZero(List<int> bytes) => bytes.every((b) => b == 0);

/// Seals [plaintext] into an envelope from [sender] to [recipient].
///
/// [senderIdentity] supplies the Ed25519 signing key; a fresh ephemeral
/// X25519 key pair is generated per envelope and discarded afterwards.
/// [id] must be 32 hex characters (the caller owns ID generation).
Future<LomEnvelope> sealEnvelope({
  required List<int> plaintext,
  required String id,
  required LomIdentity senderIdentity,
  required String recipientKeys,
}) async {
  if (plaintext.length > lomEnvelopeMaxPlaintextBytes) {
    throw LomEnvelopeException(
      'remote.payload_invalid',
      'plaintext exceeds $lomEnvelopeMaxPlaintextBytes bytes',
    );
  }
  final recipient = splitPublicKeyString(recipientKeys);
  if (recipient == null) {
    throw LomEnvelopeException('remote.invalid_key', 'bad recipient K');
  }
  final ephemeralPair = await X25519().newKeyPair();
  final ephemeralPub =
      (await ephemeralPair.extractPublicKey()).bytes;
  final envelope = LomEnvelope(
    id: id,
    sender: senderIdentity.keys,
    recipient: recipientKeys,
    ephemeral: b64urlEncode(ephemeralPub),
    ciphertext: '', // filled below
    signature: '', // filled below
  );
  final shared = await X25519().sharedSecretKey(
    keyPair: ephemeralPair,
    remotePublicKey: SimplePublicKey(
      recipient.x25519,
      type: KeyPairType.x25519,
    ),
  );
  final sharedBytes = await shared.extractBytes();
  if (_isAllZero(sharedBytes)) {
    throw LomEnvelopeException('remote.invalid_key', 'zero shared secret');
  }
  final key = await _deriveKey(shared: sharedBytes, aad: envelope.aad);
  final nonce = _randomBytes(12);
  final sealed = await Chacha20.poly1305Aead().encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: envelope.aad,
  );
  final body = Uint8List.fromList([
    ...nonce,
    ...sealed.cipherText,
    ...sealed.mac.bytes,
  ]);
  final signature = await Ed25519().sign(
    [...envelope.aad, ...body],
    keyPair: senderIdentity.ed25519KeyPair,
  );
  return LomEnvelope(
    id: id,
    sender: senderIdentity.keys,
    recipient: recipientKeys,
    ephemeral: b64urlEncode(ephemeralPub),
    ciphertext: b64urlEncode(body),
    signature: b64urlEncode(signature.bytes),
  );
}

/// Opens a received envelope, following doc §06 4.5 in order:
/// recipient == own K, sender in [trustedSenders], field lengths,
/// Ed25519 verification over `AAD ‖ body`, X25519 + HKDF, ChaCha20-Poly1305
/// decryption. Any failure throws [LomEnvelopeException] and the caller
/// must send **no** reply.
Future<List<int>> openEnvelope({
  required LomEnvelope envelope,
  required LomIdentity ownIdentity,
  required Set<String> trustedSenders,
}) async {
  if (envelope.recipient != ownIdentity.keys) {
    throw LomEnvelopeException('remote.invalid_key', 'wrong recipient');
  }
  if (!trustedSenders.contains(envelope.sender)) {
    throw LomEnvelopeException('remote.invalid_key', 'untrusted sender');
  }
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(envelope.id)) {
    throw LomEnvelopeException('remote.payload_invalid', 'bad id');
  }
  final senderKeys = splitPublicKeyString(envelope.sender);
  if (senderKeys == null) {
    throw LomEnvelopeException('remote.invalid_key', 'bad sender K');
  }
  final ephemeralBytes =
      b64urlDecodeStrictLength(envelope.ephemeral, 32);
  if (ephemeralBytes == null) {
    throw LomEnvelopeException('remote.invalid_key', 'bad ephemeral');
  }
  final body = b64urlDecodeStrict(envelope.ciphertext);
  if (body == null ||
      body.length < lomEnvelopeMinCiphertextBytes ||
      body.length > lomEnvelopeMaxCiphertextBytes) {
    throw LomEnvelopeException('remote.payload_invalid', 'bad ciphertext');
  }
  final signatureBytes =
      b64urlDecodeStrictLength(envelope.signature, 64);
  if (signatureBytes == null) {
    throw LomEnvelopeException('remote.payload_invalid', 'bad signature');
  }
  final verified = await Ed25519().verify(
    [...envelope.aad, ...body],
    signature: Signature(
      signatureBytes,
      publicKey: SimplePublicKey(
        senderKeys.ed25519,
        type: KeyPairType.ed25519,
      ),
    ),
  );
  if (!verified) {
    throw LomEnvelopeException('remote.invalid_key', 'bad signature');
  }
  final shared = await X25519().sharedSecretKey(
    keyPair: ownIdentity.x25519KeyPair,
    remotePublicKey: SimplePublicKey(
      ephemeralBytes,
      type: KeyPairType.x25519,
    ),
  );
  final sharedBytes = await shared.extractBytes();
  if (_isAllZero(sharedBytes)) {
    throw LomEnvelopeException('remote.invalid_key', 'zero shared secret');
  }
  final key = await _deriveKey(shared: sharedBytes, aad: envelope.aad);
  final nonce = body.sublist(0, 12);
  final cipherAndTag = body.sublist(12);
  if (cipherAndTag.length < 16) {
    throw LomEnvelopeException('remote.payload_invalid', 'short body');
  }
  final cipherText = cipherAndTag.sublist(0, cipherAndTag.length - 16);
  final tag = cipherAndTag.sublist(cipherAndTag.length - 16);
  try {
    final opened = await Chacha20.poly1305Aead().decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
      secretKey: SecretKey(key),
      aad: envelope.aad,
    );
    return opened;
  } on SecretBoxAuthenticationError {
    throw LomEnvelopeException('remote.invalid_key', 'decrypt failed');
  }
}

/// Generates a fresh envelope id: 32 lowercase hex characters.
String newEnvelopeId() =>
    _randomBytes(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
