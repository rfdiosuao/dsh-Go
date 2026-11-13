/// Lom wiring: Riverpod providers for the Lom phone-access client.
///
/// Everything Lom needs is built here from the app's existing pieces:
/// the Keystore-backed [SecretStore] (`secretStoreProvider`), the
/// diagnostics channel (device model / OS / app version for `device_info`),
/// and `networkKicks()` (network-change / foreground events that trigger
/// an immediate reconnect).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/diagnostics_channel.dart';
import '../remote/secret_store.dart';
import '../state/hosts_state.dart' show secretStoreProvider;
import 'credentials.dart';
import 'identity_store.dart';
import 'io_adapters.dart';
import 'keystore_protector.dart';
import 'pairing_api.dart';
import 'relay_client.dart';

/// Adapts the app's [SecretStore] to the Lom library's [LomSecretStore].
/// Keys keep their `lom.` prefix; the app's secure store adds its own
/// `remote.` prefix on top.
class LomSecretStoreAdapter implements LomSecretStore {
  LomSecretStoreAdapter(this._inner);
  final SecretStore _inner;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) =>
      _inner.write(key, value);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}

final lomSecretStoreProvider = Provider<LomSecretStore>(
  (ref) => LomSecretStoreAdapter(ref.watch(secretStoreProvider)),
);

final lomIdentityStoreProvider = Provider<LomIdentityStore>(
  (ref) => LomIdentityStore(
    secrets: ref.watch(lomSecretStoreProvider),
    protector: MethodChannelLomKeyProtector(),
  ),
);

final lomCredentialStoreProvider = Provider<LomCredentialStore>(
  (ref) => LomCredentialStore(ref.watch(lomSecretStoreProvider)),
);

/// `device_info` for pairing: model / OS / app version from the
/// diagnostics channel; empty strings when the native side is absent
/// (tests, desktop) — the cloud accepts empty fields.
final lomDeviceInfoProvider = FutureProvider<LomDeviceInfo>((ref) async {
  final diag = await const DiagnosticsChannel().info();
  final device = diag.device;
  final model = device['model'] is String ? device['model'] as String : '';
  final android = device['android'] is String
      ? device['android'] as String
      : '';
  final version = diag.app['versionName'] is String
      ? diag.app['versionName'] as String
      : '';
  return LomDeviceInfo(
    name: model,
    model: model,
    os: android.isEmpty ? '' : 'Android $android',
    appVersion: version,
  );
});

/// The HTTP transport for pairing / token exchange (package:http over
/// dart:io, 10s connect / 20s total timeouts).
final lomHttpTransportProvider = Provider<LomHttpTransport>(
  (ref) => HttpLomTransport(),
);

/// The WebSocket factory for the relay (dart:io, auto-Pong, 20s Ping).
final lomWebSocketFactoryProvider = Provider<LomWebSocketFactory>(
  (ref) => IoLomWebSocketFactory(),
);
