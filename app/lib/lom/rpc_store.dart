/// Persistent Lom RPC state (doc §06 §6, §07 §2 "幂等与结果未知").
///
/// Three JSON documents in the Keystore-backed [LomSecretStore] (the same
/// `lom.` namespace as the pairing credentials — never SharedPreferences,
/// never logs):
///
/// * `lom.rpc_replay` — envelope dedup keys `sender:id` → expiry (ms).
///   Retained 10 minutes; **must** survive restarts, so it is not memory-only.
/// * `lom.model_configs` — per-desktop model metadata (base URL, model,
///   platform, revision, route, key reference). The `api_key` itself is
///   **never** stored here; it only goes to the DSH credential store.
/// * `lom.chat_receipts` / `lom.chat_sessions` — `chat.send` idempotency
///   receipts (persisted **before** the task starts) and the last known
///   outcome of each session, so a restart can mark an unfinished task
///   `interrupted` instead of re-running it.
///
/// Writes to one document are serialized through a future chain, so two
/// concurrent claims of the same key cannot both succeed inside one isolate.
library;

import 'dart:async';
import 'dart:convert';

import 'credentials.dart';

/// One JSON object document in a [LomSecretStore], with serialized writes.
class _JsonDoc {
  _JsonDoc(this._store, this._key);

  final LomSecretStore _store;
  final String _key;
  Future<void> _tail = Future.value();

  Future<Map<String, Object?>> _load() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return Map<String, Object?>.from(decoded);
    }
    return {};
  }

  /// Runs [update] against the freshly loaded document, then persists it.
  /// Calls are serialized: a later [mutate] only starts after the earlier
  /// one's load–update–save has finished.
  Future<T> mutate<T>(
    FutureOr<T> Function(Map<String, Object?> doc) update,
  ) {
    final run = _tail.then((_) async {
      final doc = await _load();
      final result = await update(doc);
      await _store.write(_key, jsonEncode(doc));
      return result;
    });
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Map<String, Object?>> load() => _tail.then((_) => _load());
}

/// Envelope replay protection (doc §06 §6): dedup key `sender:id`,
/// retained at least 10 minutes, persisted, concurrency-safe.
class LomReplayStore {
  LomReplayStore(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final LomSecretStore _store;
  final DateTime Function() _now;
  static const _key = 'lom.rpc_replay';

  /// How long a dedup key is kept (10 minutes: 5-minute window each way).
  static const retention = Duration(minutes: 10);

  late final _doc = _JsonDoc(_store, _key);

  /// Claims [dedupKey]. Returns `true` when newly claimed, `false` when
  /// the key was already claimed and has not expired.
  Future<bool> claim(String dedupKey) => _doc.mutate((doc) {
        final nowMs = _now().millisecondsSinceEpoch;
        doc.removeWhere((_, v) => v is! int || v <= nowMs);
        if (doc.containsKey(dedupKey)) return false;
        doc[dedupKey] = nowMs + retention.inMilliseconds;
        return true;
      });
}

/// A desktop's synced model configuration — metadata only, no `api_key`.
class LomModelConfig {
  const LomModelConfig({
    required this.baseUrl,
    required this.model,
    required this.platform,
    required this.revision,
    required this.route,
    required this.keyRef,
    required this.updatedAtMs,
  });

  factory LomModelConfig.fromJson(Map<String, Object?> json) =>
      LomModelConfig(
        baseUrl: json['base_url'] as String? ?? '',
        model: json['model'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        revision: json['revision'] as int? ?? 0,
        route: json['route'] as String? ?? '',
        keyRef: json['key_ref'] as String? ?? '',
        updatedAtMs: json['updated_at_ms'] as int? ?? 0,
      );

  Map<String, Object?> toJson() => {
        'base_url': baseUrl,
        'model': model,
        'platform': platform,
        'revision': revision,
        'route': route,
        'key_ref': keyRef,
        'updated_at_ms': updatedAtMs,
      };

  final String baseUrl;
  final String model;

  /// Lom platform name: `openai` / `openai-responses` / `anthropic`.
  final String platform;

  /// Monotonically non-decreasing per desktop (doc §07 §3).
  final int revision;

  /// DSH pi-ai route this desktop's config was written to.
  final String route;

  /// Credential reference the `api_key` was stored under (a name, not a key).
  final String keyRef;
  final int updatedAtMs;
}

/// Per-desktop model configs, keyed by the sender desktop's public key `K`.
class LomModelConfigStore {
  LomModelConfigStore(this._store);

  final LomSecretStore _store;
  static const _key = 'lom.model_configs';

  late final _doc = _JsonDoc(_store, _key);

  Future<LomModelConfig?> loadFor(String desktopKey) async {
    final doc = await _doc.load();
    final raw = doc[desktopKey];
    if (raw is! Map<String, dynamic>) return null;
    return LomModelConfig.fromJson(Map<String, Object?>.from(raw));
  }

  Future<void> save(String desktopKey, LomModelConfig config) =>
      _doc.mutate((doc) {
        doc[desktopKey] = config.toJson();
      });
}

/// A persisted `chat.send` receipt (doc §07 §2).
class LomChatReceipt {
  const LomChatReceipt({
    required this.clientId,
    required this.sessionId,
    required this.contentHash,
    required this.status,
    required this.updatedAtMs,
  });

  factory LomChatReceipt.fromJson(Map<String, Object?> json) =>
      LomChatReceipt(
        clientId: json['client_id'] as String? ?? '',
        sessionId: json['session_id'] as String? ?? '',
        contentHash: json['content_hash'] as String? ?? '',
        status: json['status'] as String? ?? 'pending',
        updatedAtMs: json['updated_at_ms'] as int? ?? 0,
      );

  Map<String, Object?> toJson() => {
        'client_id': clientId,
        'session_id': sessionId,
        'content_hash': contentHash,
        'status': status,
        'updated_at_ms': updatedAtMs,
      };

  final String clientId;
  final String sessionId;

  /// SHA-256 of `session_id + "\n" + text + "\n" + filesJson`: the same
  /// `client_id` with different content is `chat.id_reused`.
  final String contentHash;

  /// `pending` (receipt written, task start unconfirmed), `accepted`
  /// (prompt entered the engine inbox), `failed` (start failed; a retry
  /// with the same `client_id` may re-execute).
  final String status;
  final int updatedAtMs;
}

/// Last known outcome of one session, for `chat.read`'s `status` field.
class LomChatSessionState {
  const LomChatSessionState({
    required this.sessionId,
    required this.status,
    this.error = '',
    required this.updatedAtMs,
  });

  factory LomChatSessionState.fromJson(Map<String, Object?> json) =>
      LomChatSessionState(
        sessionId: json['session_id'] as String? ?? '',
        status: json['status'] as String? ?? 'idle',
        error: json['error'] as String? ?? '',
        updatedAtMs: json['updated_at_ms'] as int? ?? 0,
      );

  Map<String, Object?> toJson() => {
        'session_id': sessionId,
        'status': status,
        'error': error,
        'updated_at_ms': updatedAtMs,
      };

  final String sessionId;

  /// `running` / `completed` / `failed` / `timeout` / `cancelled` /
  /// `interrupted` / `idle` (doc §07 `chat.read`).
  final String status;

  /// Short human-readable failure note (no secrets, no internals).
  final String error;
  final int updatedAtMs;
}

/// `chat.send` receipts + per-session outcomes.
class LomChatReceiptStore {
  LomChatReceiptStore(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final LomSecretStore _store;
  final DateTime Function() _now;
  static const _receiptsKey = 'lom.chat_receipts';
  static const _sessionsKey = 'lom.chat_sessions';

  late final _receipts = _JsonDoc(_store, _receiptsKey);
  late final _sessions = _JsonDoc(_store, _sessionsKey);

  Future<LomChatReceipt?> receiptFor(String clientId) async {
    final doc = await _receipts.load();
    final raw = doc[clientId];
    if (raw is! Map<String, dynamic>) return null;
    return LomChatReceipt.fromJson(Map<String, Object?>.from(raw));
  }

  Future<void> saveReceipt(LomChatReceipt receipt) =>
      _receipts.mutate((doc) {
        doc[receipt.clientId] = receipt.toJson();
      });

  Future<LomChatSessionState?> sessionState(String sessionId) async {
    final doc = await _sessions.load();
    final raw = doc[sessionId];
    if (raw is! Map<String, dynamic>) return null;
    return LomChatSessionState.fromJson(Map<String, Object?>.from(raw));
  }

  Future<void> saveSessionState(LomChatSessionState state) =>
      _sessions.mutate((doc) {
        doc[state.sessionId] = state.toJson();
      });

  /// Startup recovery (doc §07 §2): every session still marked `running`
  /// was cut off by a restart — mark it `interrupted` and never re-run it.
  /// Returns the affected session ids. `pending` receipts are left as-is:
  /// a desktop retry with the same `client_id` gets the original receipt
  /// back instead of a second execution.
  Future<List<String>> markRunningInterrupted() => _sessions.mutate((doc) {
        final nowMs = _now().millisecondsSinceEpoch;
        final interrupted = <String>[];
        for (final entry in doc.entries) {
          final raw = entry.value;
          if (raw is! Map<String, dynamic>) continue;
          final state =
              LomChatSessionState.fromJson(Map<String, Object?>.from(raw));
          if (state.status == 'running') {
            interrupted.add(entry.key);
            doc[entry.key] = LomChatSessionState(
              sessionId: state.sessionId,
              status: 'interrupted',
              updatedAtMs: nowMs,
            ).toJson();
          }
        }
        return interrupted;
      });
}
