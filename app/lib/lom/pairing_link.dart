/// `lom://pair` deep-link parsing and validation (doc §02), plus the
/// manual pairing-code path (§02 §5).
///
/// A pairing link is `lom://pair?v=1&h=<h>&p=<p>&t=<t>&k=<k>&f=<f>` with
/// exactly the six fields, each once, in any order. All binary values are
/// strict unpadded base64url. The host is base64url of the UTF-8 hostname
/// and must be in the app's hardcoded whitelist — currently only
/// `lom.entermodetwo.com`. Any validation failure aborts with
/// `pairing.qr_invalid` and **no network request may be made**.
library;

import 'dart:convert';

import 'base64url.dart';

/// The only cloud host a Lom pairing link may point at. Hardcoded in the
/// app; never taken from the QR code or the network.
const Set<String> lomPairingHostWhitelist = {'lom.entermodetwo.com'};

/// Default cloud host for the manual-code path (no QR code to take it from).
const String lomDefaultHost = 'lom.entermodetwo.com';

/// The 31-character manual-code alphabet (no `0 O 1 I L`).
const String lomManualCodeAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

/// Thrown for any pairing-link validation failure. [code] is always
/// `pairing.qr_invalid` for QR links or `pairing.code_invalid` for manual
/// codes; callers must not issue network requests after this.
class LomPairingLinkException implements Exception {
  LomPairingLinkException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => 'LomPairingLinkException($code${detail == null ? '' : ': $detail'})';
}

/// A validated `lom://pair` link.
class LomPairLink {
  const LomPairLink({
    required this.raw,
    required this.host,
    required this.pairingId,
    required this.claimToken,
    required this.psk,
    required this.fingerprint,
  });

  /// The original link string, kept for debugging only (never logged:
  /// it contains the psk and claim token).
  final String raw;

  /// Decoded cloud hostname (whitelisted).
  final String host;

  /// `pairing_id` as it appears in the link (22 chars, used verbatim in
  /// HTTP requests and in the key_proof formula).
  final String pairingId;

  /// `claim_token` as it appears in the link (43 chars, used verbatim).
  final String claimToken;

  /// `psk` decoded to its 32 raw bytes (HMAC key for key_proof).
  final List<int> psk;

  /// Fingerprint `f` decoded to 16 raw bytes.
  final List<int> fingerprint;

  /// Parses and fully validates [input] per doc §02 §3.
  static LomPairLink parse(String input) {
    LomPairingLinkException fail(String detail) =>
        LomPairingLinkException('pairing.qr_invalid', detail);

    if (input.length > 2048) throw fail('link too long');
    // Scheme + authority + empty path + no fragment, parsed manually so
    // no URI normalisation can silently change a field value.
    if (!input.startsWith('lom://pair?')) throw fail('bad scheme/host');
    final query = input.substring('lom://pair?'.length);
    if (query.isEmpty || query.contains('#')) throw fail('bad query');
    final fields = <String, String>{};
    for (final part in query.split('&')) {
      final eq = part.indexOf('=');
      if (eq <= 0 || eq == part.length - 1) throw fail('bad field: $part');
      final key = part.substring(0, eq);
      final value = part.substring(eq + 1);
      if (fields.containsKey(key)) throw fail('duplicate field: $key');
      fields[key] = value;
    }
    if (fields.length != 6 ||
        !fields.keys.toSet().containsAll(const {'v', 'h', 'p', 't', 'k', 'f'})) {
      throw fail('fields must be exactly v h p t k f');
    }
    if (fields['v'] != '1') throw fail('unsupported version');
    final hostBytes = b64urlDecodeStrict(fields['h']!);
    if (hostBytes == null) throw fail('bad host encoding');
    String host;
    try {
      host = utf8.decode(hostBytes);
    } on FormatException {
      throw fail('host is not UTF-8');
    }
    if (!RegExp(r'^[a-z0-9]+([.-][a-z0-9]+)*$').hasMatch(host)) {
      throw fail('bad host format');
    }
    if (!lomPairingHostWhitelist.contains(host)) {
      throw fail('host not whitelisted');
    }
    final pairingIdBytes = b64urlDecodeStrictLength(fields['p']!, 16);
    if (pairingIdBytes == null) throw fail('bad pairing_id');
    final claimTokenBytes = b64urlDecodeStrictLength(fields['t']!, 32);
    if (claimTokenBytes == null) throw fail('bad claim_token');
    final psk = b64urlDecodeStrictLength(fields['k']!, 32);
    if (psk == null) throw fail('bad psk');
    final fingerprint = b64urlDecodeStrictLength(fields['f']!, 16);
    if (fingerprint == null) throw fail('bad fingerprint');
    return LomPairLink(
      raw: input,
      host: host,
      pairingId: fields['p']!,
      claimToken: fields['t']!,
      psk: psk,
      fingerprint: fingerprint,
    );
  }

  /// The base URL for pairing HTTP calls, e.g. `https://lom.entermodetwo.com`.
  String get baseUrl => 'https://$host';
}

/// Normalises a user-typed manual pairing code: strips `-` and spaces,
/// upper-cases, and requires exactly 8 characters from the 31-char
/// alphabet. Returns the canonical `XXXX-XXXX` form, or `null` when the
/// input is invalid (local error `pairing.code_invalid`, no network call).
String? normalizeManualCode(String input) {
  final cleaned = input
      .replaceAll('-', '')
      .replaceAll(' ', '')
      .toUpperCase();
  if (cleaned.length != 8) return null;
  for (var i = 0; i < cleaned.length; i++) {
    if (!lomManualCodeAlphabet.contains(cleaned[i])) return null;
  }
  return '${cleaned.substring(0, 4)}-${cleaned.substring(4)}';
}
