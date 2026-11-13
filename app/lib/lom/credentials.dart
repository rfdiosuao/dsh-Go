/// Lom credential storage (doc §03 2.4, §05 §1, §05 §6).
///
/// Device credentials (`device_id` + `device_token`, 90-day rolling),
/// the approved desktop public keys (a set, so the store can grow beyond
/// the one desktop the official phone keeps), the desktop name, and the
/// cloud hostname live in a Keystore-backed [SecretStore] under a dedicated
/// `lom.` namespace — never SharedPreferences, never logs, never URLs.
///
/// Rule: credentials are persisted **before** the UI shows "已连接".
/// Revocation clears credentials + approved keys but keeps user data
/// (sessions, skills, persona, memory) — that data is not stored here.
library;

import 'dart:convert';

import 'pairing_api.dart';

/// The secret-store abstraction (identical shape to the app's
/// `SecretStore` in `app/lib/remote/secret_store.dart`; the app wires its
/// own implementation in).
abstract class LomSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Persisted Lom pairing state.
class LomCredentials {
  const LomCredentials({
    required this.deviceId,
    required this.deviceToken,
    required this.tokenExpiresAt,
    required this.host,
    required this.desktopKeys,
    required this.desktopName,
  });

  final String deviceId;
  final String deviceToken;

  /// Unix seconds; renewed on every relay-token exchange.
  final int tokenExpiresAt;

  /// Cloud hostname saved at pairing time (from the QR `h`).
  final String host;

  /// Approved desktop public keys (`K` strings). Only envelopes from
  /// these senders are accepted.
  final Set<String> desktopKeys;

  /// Display name of the approved desktop.
  final String desktopName;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= tokenExpiresAt;
}

class LomCredentialStore {
  LomCredentialStore(this._store);

  final LomSecretStore _store;

  static const _kDeviceId = 'lom.device_id';
  static const _kDeviceToken = 'lom.device_token';
  static const _kTokenExpiresAt = 'lom.token_expires_at';
  static const _kHost = 'lom.host';
  static const _kDesktopKeys = 'lom.desktop_keys';
  static const _kDesktopName = 'lom.desktop_name';

  /// Loads persisted credentials, or `null` when unpaired.
  Future<LomCredentials?> load() async {
    final deviceId = await _store.read(_kDeviceId);
    final deviceToken = await _store.read(_kDeviceToken);
    final expiresRaw = await _store.read(_kTokenExpiresAt);
    final host = await _store.read(_kHost);
    final keysRaw = await _store.read(_kDesktopKeys);
    final desktopName = await _store.read(_kDesktopName);
    if (deviceId == null ||
        deviceId.isEmpty ||
        deviceToken == null ||
        deviceToken.isEmpty ||
        expiresRaw == null ||
        host == null ||
        host.isEmpty) {
      return null;
    }
    final expiresAt = int.tryParse(expiresRaw);
    if (expiresAt == null) return null;
    Set<String> keys = {};
    if (keysRaw != null && keysRaw.isNotEmpty) {
      final decoded = jsonDecode(keysRaw);
      if (decoded is List) {
        keys = decoded.whereType<String>().toSet();
      }
    }
    return LomCredentials(
      deviceId: deviceId,
      deviceToken: deviceToken,
      tokenExpiresAt: expiresAt,
      host: host,
      desktopKeys: keys,
      desktopName: desktopName ?? '',
    );
  }

  /// Persists [credentials] (from a `confirm` response) and reads the
  /// device id back to prove the write landed. Throws on failure — the
  /// caller must not show "已连接" until this returns.
  Future<void> save(LomDeviceCredentials credentials, {
    required String host,
    required String desktopKeys,
    required String desktopName,
  }) async {
    await _store.write(_kDeviceId, credentials.deviceId);
    await _store.write(_kDeviceToken, credentials.deviceToken);
    await _store.write(
      _kTokenExpiresAt,
      credentials.tokenExpiresAt.toString(),
    );
    await _store.write(_kHost, host);
    await _store.write(_kDesktopKeys, jsonEncode([desktopKeys]));
    await _store.write(_kDesktopName, desktopName);
    final back = await _store.read(_kDeviceId);
    if (back != credentials.deviceId) {
      throw StateError('lom credential store failed');
    }
  }

  /// Clears device credentials and approved desktop keys (revocation /
  /// unpair). Identity keys are kept (they are a different store).
  Future<void> clear() async {
    await _store.delete(_kDeviceId);
    await _store.delete(_kDeviceToken);
    await _store.delete(_kTokenExpiresAt);
    await _store.delete(_kHost);
    await _store.delete(_kDesktopKeys);
    await _store.delete(_kDesktopName);
  }
}
