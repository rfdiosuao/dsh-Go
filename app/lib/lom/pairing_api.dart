/// Lom pairing HTTP client (doc §03): inspect → claim → confirm / cancel,
/// plus the manual-code path (claim-by-code) and unpairing.
///
/// Transport is injected ([LomHttpTransport]) so tests can fake the cloud.
/// Timeouts: connect 10s / read 15s / total 20s (enforced by the transport
/// implementation; the default dart:io one below does). Network failure maps
/// to local error `net.unreachable`; a non-JSON response maps to
/// `pairing.response_invalid`. Error bodies carry a `code` such as
/// `pairing.expired` — callers switch on it, never on the human `error` text.
///
/// Secrets (`claim_token`, `claim_secret`, `device_token`, `psk`) travel only
/// in request bodies/headers, never in URLs, and must never be logged.
library;

import 'dart:async';
import 'dart:convert';

/// A minimal HTTP response.
class LomHttpResponse {
  const LomHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// The transport the pairing client talks through. The app implements this
/// with `package:http` (or dart:io); tests substitute a fake.
abstract class LomHttpTransport {
  Future<LomHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  });
  Future<LomHttpResponse> delete(
    Uri uri, {
    Map<String, String>? headers,
  });
}

/// A pairing/cloud error: [code] is the server `code` (e.g.
/// `pairing.expired`, `pairing.awaiting_desktop`) or a local code
/// (`net.unreachable`, `pairing.response_invalid`).
class LomPairingException implements Exception {
  LomPairingException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => 'LomPairingException($code${detail == null ? '' : ': $detail'})';
}

/// Device info sent with `claim` / `claim-by-code` (doc §03 §0).
class LomDeviceInfo {
  const LomDeviceInfo({
    this.name = '',
    this.model = '',
    this.os = '',
    this.appVersion = '',
  });
  final String name;
  final String model;
  final String os;
  final String appVersion;

  Map<String, dynamic> toJson() => {
        'name': name,
        'model': model,
        'os': os,
        'app_version': appVersion,
      };
}

/// `inspect` result: the desktop that owns this pairing session.
class LomInspectResult {
  const LomInspectResult({
    required this.pairingId,
    required this.desktopName,
    required this.desktopKeys,
    required this.maskedAccount,
    required this.expiresAt,
  });
  final String pairingId;
  final String desktopName;
  final String desktopKeys;
  final String maskedAccount;
  final int expiresAt;
}

/// `claim` result: the one-time credential for `confirm` / `cancel`.
class LomClaimResult {
  const LomClaimResult({required this.claimSecret, required this.expiresAt});
  final String claimSecret;
  final int expiresAt;
}

/// `confirm` result: the device credentials.
class LomDeviceCredentials {
  const LomDeviceCredentials({
    required this.deviceId,
    required this.deviceToken,
    required this.tokenExpiresAt,
    required this.desktopName,
  });
  final String deviceId;
  final String deviceToken;
  final int tokenExpiresAt;
  final String desktopName;
}

/// `claim-by-code` result: session info plus the claim secret.
class LomClaimByCodeResult {
  const LomClaimByCodeResult({
    required this.pairingId,
    required this.desktopName,
    required this.desktopKeys,
    required this.maskedAccount,
    required this.expiresAt,
    required this.claimSecret,
  });
  final String pairingId;
  final String desktopName;
  final String desktopKeys;
  final String maskedAccount;
  final int expiresAt;
  final String claimSecret;
}

/// Maximum `confirm` retries while the desktop is still verifying
/// `key_proof` (doc §03 2.4): one attempt per second, at most 15.
const int lomConfirmAwaitingDesktopMaxAttempts = 15;

/// Extra retries for plain network failures during `confirm`.
const int lomConfirmNetworkMaxRetries = 3;

class LomPairingApi {
  LomPairingApi({required this.baseUrl, required this.transport});

  /// e.g. `https://lom.entermodetwo.com` (from the QR `h`, whitelisted).
  final String baseUrl;
  final LomHttpTransport transport;

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) async {
    LomHttpResponse res;
    try {
      res = await transport.post(
        _uri(path),
        headers: {..._jsonHeaders, ...?headers},
        body: jsonEncode(body),
      );
    } catch (_) {
      throw LomPairingException('net.unreachable');
    }
    return _decode(res);
  }

  Map<String, dynamic> _decode(LomHttpResponse res) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        throw LomPairingException('pairing.response_invalid');
      }
      json = decoded;
    } on FormatException {
      throw LomPairingException('pairing.response_invalid');
    }
    if (json['success'] == true) {
      final data = json['data'];
      if (data is Map<String, dynamic>) return data;
      return const {};
    }
    final code = json['code'];
    throw LomPairingException(
      code is String && code.isNotEmpty ? code : 'pairing.response_invalid',
      json['error'] is String ? json['error'] as String : null,
    );
  }

  static String _string(Map<String, dynamic> data, String key) {
    final v = data[key];
    if (v is! String) {
      throw LomPairingException('pairing.response_invalid', 'missing $key');
    }
    return v;
  }

  static int _int(Map<String, dynamic> data, String key) {
    final v = data[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw LomPairingException('pairing.response_invalid', 'missing $key');
  }

  /// `POST /v1/pairing/sessions/{pairing_id}/inspect`.
  Future<LomInspectResult> inspect({
    required String pairingId,
    required String claimToken,
  }) async {
    final data = await _postJson(
      '/v1/pairing/sessions/$pairingId/inspect',
      {'claim_token': claimToken},
    );
    return LomInspectResult(
      pairingId: _string(data, 'pairing_id'),
      desktopName: _string(data, 'desktop_name'),
      desktopKeys: _string(data, 'desktop_keys'),
      maskedAccount: _string(data, 'masked_account'),
      expiresAt: _int(data, 'expires_at'),
    );
  }

  /// `POST /v1/pairing/sessions/{pairing_id}/claim`.
  Future<LomClaimResult> claim({
    required String pairingId,
    required String claimToken,
    required String deviceKeys,
    required LomDeviceInfo deviceInfo,
    required String keyProof,
  }) async {
    final data = await _postJson(
      '/v1/pairing/sessions/$pairingId/claim',
      {
        'claim_token': claimToken,
        'device_keys': deviceKeys,
        'device_info': deviceInfo.toJson(),
        'key_proof': keyProof,
      },
    );
    return LomClaimResult(
      claimSecret: _string(data, 'claim_secret'),
      expiresAt: _int(data, 'expires_at'),
    );
  }

  /// One `POST /v1/pairing/sessions/{pairing_id}/confirm` attempt.
  Future<LomDeviceCredentials> confirm({
    required String pairingId,
    required String claimSecret,
  }) async {
    final data = await _postJson(
      '/v1/pairing/sessions/$pairingId/confirm',
      {'claim_secret': claimSecret},
    );
    return LomDeviceCredentials(
      deviceId: _string(data, 'device_id'),
      deviceToken: _string(data, 'device_token'),
      tokenExpiresAt: _int(data, 'token_expires_at'),
      desktopName: _string(data, 'desktop_name'),
    );
  }

  /// `confirm` with the doc's retry rules: while the cloud answers
  /// `pairing.awaiting_desktop`, retry once per second up to 15 times;
  /// plain network failures get up to 3 extra retries. After that the
  /// caller surfaces local error `pairing.desktop_timeout`.
  ///
  /// [sleep] is injectable so tests run instantly.
  Future<LomDeviceCredentials> confirmAwaitingDesktop({
    required String pairingId,
    required String claimSecret,
    Future<void> Function(Duration d)? sleep,
  }) async {
    final wait = sleep ?? Future.delayed;
    var networkRetries = 0;
    for (var attempt = 0; ; attempt++) {
      try {
        return await confirm(pairingId: pairingId, claimSecret: claimSecret);
      } on LomPairingException catch (e) {
        if (e.code == 'pairing.awaiting_desktop') {
          if (attempt >= lomConfirmAwaitingDesktopMaxAttempts - 1) {
            throw LomPairingException('pairing.desktop_timeout');
          }
          await wait(const Duration(seconds: 1));
          continue;
        }
        if (e.code == 'net.unreachable' &&
            networkRetries < lomConfirmNetworkMaxRetries) {
          networkRetries++;
          await wait(const Duration(seconds: 1));
          continue;
        }
        rethrow;
      }
    }
  }

  /// `POST /v1/pairing/sessions/{pairing_id}/cancel`.
  Future<void> cancel({
    required String pairingId,
    required String claimSecret,
  }) async {
    await _postJson(
      '/v1/pairing/sessions/$pairingId/cancel',
      {'claim_secret': claimSecret},
    );
  }

  /// `POST /v1/pairing/claim-by-code` (no QR code, no psk, no key_proof).
  Future<LomClaimByCodeResult> claimByCode({
    required String manualCode,
    required String deviceKeys,
    required LomDeviceInfo deviceInfo,
  }) async {
    final data = await _postJson('/v1/pairing/claim-by-code', {
      'manual_code': manualCode,
      'device_keys': deviceKeys,
      'device_info': deviceInfo.toJson(),
    });
    return LomClaimByCodeResult(
      pairingId: _string(data, 'pairing_id'),
      desktopName: _string(data, 'desktop_name'),
      desktopKeys: _string(data, 'desktop_keys'),
      maskedAccount: _string(data, 'masked_account'),
      expiresAt: _int(data, 'expires_at'),
      claimSecret: _string(data, 'claim_secret'),
    );
  }

  /// `DELETE /v1/devices/me` — unpair this device. The caller clears local
  /// credentials after this returns (success or local failure: the user
  /// asked to unpair; a failed server call is reported separately).
  Future<void> deleteDevice({
    required String deviceId,
    required String deviceToken,
  }) async {
    LomHttpResponse res;
    try {
      res = await transport.delete(
        _uri('/v1/devices/me'),
        headers: {
          'Authorization': 'Device $deviceId.$deviceToken',
        },
      );
    } catch (_) {
      throw LomPairingException('net.unreachable');
    }
    _decode(res);
  }

  /// `POST /v1/relay/token` — exchange device credentials for a 1-hour
  /// relay token. Returns `(relayToken, expiresAtSeconds)`.
  Future<({String relayToken, int expiresAt})> relayToken({
    required String deviceId,
    required String deviceToken,
  }) async {
    final data = await _postJson(
      '/v1/relay/token',
      {},
      headers: {'Authorization': 'Device $deviceId.$deviceToken'},
    );
    return (
      relayToken: _string(data, 'relay_token'),
      expiresAt: _int(data, 'expires_at'),
    );
  }
}
