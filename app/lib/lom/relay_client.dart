/// Lom relay client (doc §05): exchange device credentials for a 1-hour
/// relay token, hold one `wss://<host>/v1/relay` connection, heartbeats,
/// backoff reconnect, and revocation.
///
/// Wire rules:
/// - `POST /v1/relay/token` (Authorization: Device id.token) before **every**
///   (re)connect — never cache/reuse a token.
/// - WebSocket: `Authorization: Bearer <relay_token>`; cloud Pings every
///   20s (auto-Pong is enough) and we also send a Ping every 20s.
/// - Frames are JSON text: `hello` (records `server_time`), `task.rpc`
///   (handed to [onTaskRpc] — Phase 2; Phase 1 leaves it unhandled, which
///   means the desktop times out after 15s), `device.revoked` (stop, clear
///   credentials, never reconnect). Unknown types and unparsable frames are
///   ignored. `task.rpc` handling never blocks the read loop.
/// - Backoff after a failed attempt: 1/2/5/10/30s + ±20% jitter; reset on
///   a successful handshake. Network-available / screen-on / foreground
///   events call [reconnectNow] to skip the wait.
/// - Only an explicit revocation clears credentials: closes, timeouts,
///   5xx and `relay.unauthorized` are reconnect reasons, not revocation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'credentials.dart';
import 'pairing_api.dart';

/// Connection states surfaced to the UI (online = desktop shows a green dot).
enum LomConnectionState {
  /// No credentials: never connected / unpaired.
  unpaired,

  /// Trying to exchange a token / open the socket.
  connecting,

  /// WebSocket open; `hello` seen (or not yet — still online).
  connected,

  /// Between attempts; [nextAttemptIn] may be null when waiting on an event.
  backingOff,

  /// Credentials revoked by the desktop / expired: stopped, no reconnect.
  revoked,
}

/// A text WebSocket. The app implements this with `dart:io`'s `WebSocket`
/// (auto-Pong, `pingInterval`); tests substitute a fake.
abstract class LomWebSocket {
  Stream<String> get messages;
  Future<void> sendText(String text);
  Future<void> close();
}

/// Opens a WebSocket with the given headers and a 20s ping interval.
abstract class LomWebSocketFactory {
  Future<LomWebSocket> connect(
    Uri uri, {
    Map<String, String>? headers,
    Duration pingInterval = const Duration(seconds: 20),
  });
}

/// Backoff schedule (doc §05 §5): 1, 2, 5, 10, then 30s, each ±20% jitter.
Duration lomBackoffDelay(int consecutiveFailures, {Random? random}) {
  const schedule = [1, 2, 5, 10, 30];
  final base = schedule[consecutiveFailures < schedule.length
      ? consecutiveFailures
      : schedule.length - 1];
  final r = (random ?? Random()).nextDouble() * 2 - 1; // [-1, 1)
  final jittered = base * (1 + 0.2 * r);
  return Duration(milliseconds: (jittered * 1000).round());
}

typedef LomTaskRpcHandler = Future<void> Function(
  Map<String, dynamic> envelope,
);

class LomRelayClient {
  LomRelayClient({
    required this.credentials,
    required this.api,
    required this.webSocketFactory,
    required this.credentialStore,
    this.onTaskRpc,
    this.onStateChange,
    this.onServerTime,
    Future<void> Function(Duration d)? sleep,
    Random? random,
  })  : _sleep = sleep ?? Future.delayed,
        _random = random ?? Random();

  final LomCredentials credentials;
  final LomPairingApi api;
  final LomWebSocketFactory webSocketFactory;
  final LomCredentialStore credentialStore;

  /// Phase 2: handles a `task.rpc` envelope. Phase 1 leaves this null;
  /// the envelope is then ignored (no reply is sent).
  final LomTaskRpcHandler? onTaskRpc;

  final void Function(LomConnectionState state, Duration? nextAttemptIn)?
      onStateChange;

  /// Called with the cloud's Unix-seconds clock from `hello` (clock-skew
  /// hint; RPC has a 5-minute window).
  final void Function(int serverTime)? onServerTime;

  final Future<void> Function(Duration d) _sleep;
  final Random _random;

  LomConnectionState _state = LomConnectionState.unpaired;
  LomWebSocket? _socket;
  StreamSubscription<String>? _subscription;
  bool _stopped = false;
  bool _reconnectRequested = false;
  int _failures = 0;
  int? _serverTime;

  LomConnectionState get state => _state;
  int? get serverTime => _serverTime;

  void _setState(LomConnectionState state, [Duration? nextAttemptIn]) {
    _state = state;
    onStateChange?.call(state, nextAttemptIn);
  }

  /// Starts (or restarts) the connection loop. Returns immediately; the
  /// loop runs until [stop] or revocation.
  void start() {
    if (_stopped) _stopped = false;
    unawaited(_run());
  }

  /// Skips the current backoff wait and reconnects now.
  void reconnectNow() {
    _reconnectRequested = true;
  }

  /// Closes the socket and stops reconnecting. Does not clear credentials.
  Future<void> stop() async {
    _stopped = true;
    _reconnectRequested = false;
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    if (_state != LomConnectionState.revoked &&
        _state != LomConnectionState.unpaired) {
      _setState(LomConnectionState.unpaired);
    }
  }

  Future<void> _run() async {
    while (!_stopped) {
      _setState(LomConnectionState.connecting);
      try {
        final token = await api.relayToken(
          deviceId: credentials.deviceId,
          deviceToken: credentials.deviceToken,
        );
        final socket = await webSocketFactory.connect(
          Uri.parse('wss://${credentials.host}/v1/relay'),
          headers: {'Authorization': 'Bearer ${token.relayToken}'},
          pingInterval: const Duration(seconds: 20),
        );
        _socket = socket;
        _failures = 0; // handshake established
        _setState(LomConnectionState.connected);
        final done = Completer<void>();
        _subscription = socket.messages.listen(
          _onMessage,
          onError: (_) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        await _subscription?.cancel();
        _subscription = null;
        _socket = null;
        if (_stopped) break;
        // Socket closed without revocation: reconnect with backoff.
        await _backoff();
      } on LomPairingException catch (e) {
        if (e.code == 'relay.device_revoked') {
          await _revoke();
          break;
        }
        // relay.unauthorized / net.unreachable / 5xx: back off and retry.
        await _backoff();
      } catch (_) {
        await _backoff();
      }
    }
  }

  Future<void> _backoff() async {
    if (_stopped) return;
    final delay = lomBackoffDelay(_failures, random: _random);
    _failures++;
    _setState(LomConnectionState.backingOff, delay);
    _reconnectRequested = false;
    final deadline = DateTime.now().add(delay);
    while (!_stopped && !_reconnectRequested) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await _sleep(
        remaining < const Duration(milliseconds: 200)
            ? remaining
            : const Duration(milliseconds: 200),
      );
    }
    _reconnectRequested = false;
  }

  Future<void> _revoke() async {
    await credentialStore.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    _setState(LomConnectionState.revoked);
  }

  void _onMessage(String text) {
    if (text.length > 640 * 1024) return; // over the cloud's frame cap
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } on FormatException {
      return; // ignore unparsable frames
    }
    switch (msg['type']) {
      case 'hello':
        final t = msg['server_time'];
        if (t is int) {
          _serverTime = t;
          onServerTime?.call(t);
        }
      case 'device.revoked':
        unawaited(_revoke());
      case 'task.rpc':
        final envelope = msg['envelope'];
        if (envelope is Map<String, dynamic> && onTaskRpc != null) {
          // Never block the read loop on RPC handling.
          unawaited(onTaskRpc!(envelope));
        }
        // Phase 1: no handler yet — no reply is sent.
      default:
        // Unknown type: ignore (forward compatibility).
        return;
    }
  }

  /// Sends a `task.reply` frame. Phase 2 uses this after sealing a reply
  /// envelope; the envelope must have exactly the six fields and the same
  /// `id` as the request.
  Future<void> sendReply(Map<String, dynamic> envelope) async {
    final socket = _socket;
    if (socket == null) return;
    await socket.sendText(jsonEncode({
      'type': 'task.reply',
      'envelope': envelope,
    }));
  }
}
