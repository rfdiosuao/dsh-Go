/// Lom relay manager: keeps the phone online on `wss://<host>/v1/relay`
/// while paired, and tears everything down on revocation / unpair.
///
/// Ownership:
/// - The [LomRelayClient] owns the token exchange, socket, heartbeat and
///   backoff. This controller owns its lifecycle: start when credentials
///   exist, stop when they don't, `reconnectNow()` on `networkKicks()`
///   (network change / app foreground).
/// - The Android foreground service (`dsh/lom_relay` channel →
///   `LomRelayService`) only keeps the process alive; Dart owns the
///   connection. It starts with the client and stops with it.
/// - Revocation is terminal: credentials are cleared and the client never
///   reconnects. A dropped socket is not a revocation — it backs off and
///   retries.
library;

import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path_provider/path_provider.dart';

import '../remote/network_watch.dart';
import '../state/connection_state.dart' show localConnectionProvider;
import 'credentials.dart';
import 'dsh_engine.dart';
import 'file_store.dart';
import 'identity.dart';
import 'io_adapters.dart';
import 'lom_providers.dart';
import 'optional_methods.dart';
import 'pairing_api.dart';
import 'phase4_store.dart';
import 'platform_adapters.dart';
import 'relay_client.dart';
import 'rpc_dispatcher.dart';
import 'rpc_store.dart';
import 'schedule_write.dart';
import 'skills.dart';

class LomRelayState {
  const LomRelayState({
    this.credentials,
    this.connection = LomConnectionState.unpaired,
    this.nextAttemptIn,
    this.serverTime,
    this.revoked = false,
  });

  /// Null when unpaired.
  final LomCredentials? credentials;
  final LomConnectionState connection;
  final Duration? nextAttemptIn;
  final int? serverTime;
  final bool revoked;

  bool get paired => credentials != null;
  bool get online => connection == LomConnectionState.connected;

  LomRelayState copyWith({
    LomCredentials? credentials,
    bool clearCredentials = false,
    LomConnectionState? connection,
    Duration? nextAttemptIn,
    bool clearNextAttempt = false,
    int? serverTime,
    bool? revoked,
  }) =>
      LomRelayState(
        credentials: clearCredentials ? null : (credentials ?? this.credentials),
        connection: connection ?? this.connection,
        nextAttemptIn:
            clearNextAttempt ? null : (nextAttemptIn ?? this.nextAttemptIn),
        serverTime: serverTime ?? this.serverTime,
        revoked: revoked ?? this.revoked,
      );
}

final lomRelayProvider =
    NotifierProvider<LomRelayController, LomRelayState>(
  LomRelayController.new,
);

/// MethodChannel `dsh/lom_relay`: `start` / `stop` the Android foreground
/// service that keeps the relay process alive. No-ops without the native
/// side (tests, desktop).
class LomForegroundService {
  LomForegroundService([
    this.channel = const MethodChannel('dsh/lom_relay'),
  ]);

  final MethodChannel channel;

  Future<void> start() async {
    try {
      await channel.invokeMethod<void>('start');
    } on MissingPluginException {
      // No native side: the Dart loop still runs while the app lives.
    } on PlatformException {
      // A vendor policy refused the start: same fallback.
    }
  }

  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No native side: nothing was started.
    } on PlatformException {
      // The service is already gone; the Dart client is stopped anyway.
    }
  }
}

class LomRelayController extends Notifier<LomRelayState> {
  LomRelayClient? _client;
  StreamSubscription<void>? _kicks;
  final _foreground = LomForegroundService();

  @override
  LomRelayState build() {
    ref.onDispose(() {
      unawaited(_kicks?.cancel());
      unawaited(_client?.stop());
    });
    // Network restored / app foregrounded: reconnect immediately instead
    // of waiting out the backoff.
    _kicks = networkKicks().listen((_) => _client?.reconnectNow());
    unawaited(_loadAndStart());
    return const LomRelayState();
  }

  Future<void> _loadAndStart() async {
    final creds = await ref.read(lomCredentialStoreProvider).load();
    if (!ref.mounted) return;
    if (creds == null) {
      state = const LomRelayState();
      return;
    }
    final identity =
        await ref.read(lomIdentityStoreProvider).loadOrCreate();
    if (!ref.mounted) return;
    await _start(creds, identity);
  }

  /// Re-reads credentials (e.g. after pairing finished) and starts or
  /// stops the client to match.
  Future<void> refresh() async {
    final creds = await ref.read(lomCredentialStoreProvider).load();
    if (!ref.mounted) return;
    if (creds == null) {
      await _stopClient();
      state = const LomRelayState();
      return;
    }
    if (_client != null && state.credentials?.deviceId == creds.deviceId) {
      state = state.copyWith(credentials: creds);
      return;
    }
    final identity =
        await ref.read(lomIdentityStoreProvider).loadOrCreate();
    if (!ref.mounted) return;
    await _start(creds, identity);
  }

  Future<void> _start(LomCredentials creds, LomIdentity identity) async {
    final transport = ref.read(lomHttpTransportProvider);
    final api = LomPairingApi(baseUrl: 'https://${creds.host}', transport: transport);
    // Phase 2/3: the dispatcher owns envelope opening, replay protection
    // and the required RPC methods, backed by the local DSH engine.
    // Phase 4: the optional handlers add chat management + device info.
    final secrets = ref.read(lomSecretStoreProvider);
    final engine = DshLomEngine(
      resolveClient: () async {
        final connection = await ref.read(localConnectionProvider.future);
        return connection?.client;
      },
    );
    // Phase 4 file transfer: bytes live under the app documents dir
    // (`lom_files/<senderHash>/<id>.bin`), metadata in the secret store.
    final docsDir = await getApplicationDocumentsDirectory();
    final fileStore = LomFileStore(
      secrets,
      storage: IoLomFileStorage(
        Directory('${docsDir.path}/lom_files'),
      ),
      gallerySaver: MethodChannelLomGallerySaver(),
    );
    final dispatcher = LomRpcDispatcher(
      identity: identity,
      trustedSenders: () => creds.desktopKeys,
      replay: LomReplayStore(secrets),
      modelConfigs: LomModelConfigStore(secrets),
      receipts: LomChatReceiptStore(secrets),
      engine: engine,
      optional: LomOptionalMethods(
        engine: engine,
        pins: LomPinStore(secrets),
        deviceNames: LomDeviceNameStore(secrets),
        files: fileStore,
        scheduleWrite: LomScheduleWriteHandler(
          engine: engine,
          receipts: LomOperationReceiptStore(secrets),
        ),
        skills: LomSkillRegistry(
          secrets,
          files: fileStore,
        ),
      ),
    );
    // A restart must never re-run an accepted-but-unfinished task: mark
    // it `interrupted` instead. A failure here must not block going online.
    try {
      await dispatcher.recoverInterrupted();
    } catch (_) {
      // The relay still starts; `chat.read` derives status from history.
    }
    late final LomRelayClient client;
    client = LomRelayClient(
      credentials: creds,
      api: api,
      webSocketFactory: ref.read(lomWebSocketFactoryProvider),
      credentialStore: ref.read(lomCredentialStoreProvider),
      onTaskRpc: (envelope) async {
        final reply = await dispatcher.handleEnvelope(envelope);
        if (reply != null) await client.sendReply(reply);
      },
      onStateChange: (connection, nextAttemptIn) {
        if (!ref.mounted) return;
        if (connection == LomConnectionState.revoked) {
          unawaited(_foreground.stop());
          state = state.copyWith(
            clearCredentials: true,
            connection: connection,
            clearNextAttempt: true,
            revoked: true,
          );
          return;
        }
        state = state.copyWith(
          connection: connection,
          nextAttemptIn: nextAttemptIn,
          clearNextAttempt: nextAttemptIn == null,
        );
      },
      onServerTime: (t) {
        if (ref.mounted) state = state.copyWith(serverTime: t);
      },
    );
    _client = client;
    state = state.copyWith(credentials: creds, revoked: false);
    unawaited(_foreground.start());
    client.start();
  }

  Future<void> _stopClient() async {
    final client = _client;
    _client = null;
    await client?.stop();
    await _foreground.stop();
  }

  /// The user tapped "解除配对": tell the cloud, then clear local
  /// credentials either way (the user asked to unpair; a failed server
  /// call is reported by the returned bool, not by keeping stale creds).
  Future<bool> unpair() async {
    final creds = state.credentials;
    if (creds == null) return true;
    var serverOk = true;
    try {
      final transport = ref.read(lomHttpTransportProvider);
      final api = LomPairingApi(
        baseUrl: 'https://${creds.host}',
        transport: transport,
      );
      await api.deleteDevice(
        deviceId: creds.deviceId,
        deviceToken: creds.deviceToken,
      );
    } catch (_) {
      serverOk = false;
    }
    await _stopClient();
    await ref.read(lomCredentialStoreProvider).clear();
    if (ref.mounted) state = const LomRelayState();
    return serverOk;
  }
}
