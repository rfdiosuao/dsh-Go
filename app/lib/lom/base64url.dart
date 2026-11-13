/// Strict unpadded base64url (RFC 4648 §5), per Lom phone-access doc §04.
library;

import 'dart:convert';

/// Encodes [bytes] as unpadded base64url.
String b64urlEncode(List<int> bytes) {
  // Dart's base64Url codec emits `=` padding; strip it.
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Strictly decodes [input] as unpadded base64url.
///
/// Returns `null` when the input is not a canonical unpadded base64url
/// string (illegal characters, padding, non-canonical trailing bits, or a
/// length whose remainder mod 4 is 1).
List<int>? b64urlDecodeStrict(String input) {
  if (input.contains('=')) return null;
  if (input.length % 4 == 1) return null;
  for (var i = 0; i < input.length; i++) {
    final c = input.codeUnitAt(i);
    final ok =
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2D || // -
        c == 0x5F; // _
    if (!ok) return null;
  }
  final padded = input + ('=' * ((4 - input.length % 4) % 4));
  List<int> decoded;
  try {
    decoded = base64Url.decode(padded);
  } on FormatException {
    return null;
  }
  // Canonical check: re-encoding must reproduce the input exactly.
  if (b64urlEncode(decoded) != input) return null;
  return decoded;
}

/// Strictly decodes [input] as unpadded base64url and requires exactly
/// [expectedBytes] bytes. Returns `null` on any failure.
List<int>? b64urlDecodeStrictLength(String input, int expectedBytes) {
  final decoded = b64urlDecodeStrict(input);
  if (decoded == null || decoded.length != expectedBytes) return null;
  return decoded;
}

/// Constant-time equality for secret comparisons (fingerprints, proofs).
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
