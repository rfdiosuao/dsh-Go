/// Lom RPC dispatcher — Phase 2 (envelope + dispatch) and Phase 3
/// (required methods), doc §06 §5 and §07.
///
/// Processing order per §06 §5 (the order matters):
/// 1. open the envelope (recipient / trusted sender / lengths / Ed25519
///    verify / decrypt / JSON parse) — any failure here gets **no reply**;
/// 2. `issued_at` window (±300,000 ms) → `remote.expired`, and an expired
///    request is **not** registered in the replay table;
/// 3. sender still approved → else `remote.revoked`;
/// 4. replay claim (`sender:id`, persisted, before executing) → else
///    `remote.replayed`;
/// 5. engine ready → else `remote.not_ready`;
/// 6. dispatch; unknown method → `remote.method_unknown`;
/// 7. method errors carry only their code, never exception text.
///
/// Replies reuse the request envelope `id`, carry a fresh ephemeral key,
/// and are sealed to the request sender. A reply that cannot be sealed
/// (plaintext over the limit) is not sent — the desktop times out.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import 'engine.dart';
import 'envelope.dart';
import 'identity.dart';
import 'rpc_errors.dart';
import 'rpc_store.dart';
import 'schedule_mapping.dart';

/// `issued_at` must be within this window of the phone's clock.
const int lomRpcWindowMs = 300000;

/// `chat.read` page size (doc §07: at most 50, oldest first).
const int lomChatReadPageSize = 50;

/// `chat.list` page size (doc §07: at most 100, newest first).
const int lomChatListPageSize = 100;

/// `chat.cancel` must confirm the turn really stopped; this is how long
/// the dispatcher waits for it (inside the 15-second reply budget).
const Duration lomChatCancelWait = Duration(seconds: 10);

/// SHA-256 of the empty document — the `revision` of a missing document
/// (doc §07 §5: a missing file counts as empty text).
const String lomEmptyDocumentRevision =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

class LomRpcDispatcher {
  LomRpcDispatcher({
    required this.identity,
    required this.trustedSenders,
    required this.replay,
    required this.modelConfigs,
    required this.receipts,
    required this.engine,
    DateTime Function()? now,
    this.cancelWait = lomChatCancelWait,
  }) : _now = now ?? DateTime.now;

  final LomIdentity identity;

  /// Re-read on every request: a sender revoked mid-flight must fail
  /// step 3 (`remote.revoked`), not execute.
  final Set<String> Function() trustedSenders;
  final LomReplayStore replay;
  final LomModelConfigStore modelConfigs;
  final LomChatReceiptStore receipts;
  final LomEngine engine;
  final DateTime Function() _now;

  /// How long `chat.cancel` waits for the turn to really stop.
  final Duration cancelWait;

  /// Methods this phone actually implements. `device.capabilities` is
  /// generated from this set, so the two can never drift apart.
  static const implementedMethods = <String>{
    'device.capabilities',
    'model.sync',
    'chat.send',
    'chat.read',
    'chat.list',
    'chat.cancel',
    'document.list',
    'document.read',
    'schedule.list',
  };

  /// In-memory history cache per session (message id → message, plus the
  /// newest observed turn outcome). Rebuilt from the engine after a
  /// restart; the dispatcher never trusts it for execution, only for reads.
  final Map<String, _SessionHistoryCache> _historyCache = {};

  /// Sessions with a `chat.send` currently between receipt and prompt
  /// return — a second send to one of them is `chat.busy` without an
  /// extra engine round-trip.
  final Set<String> _sending = {};

  /// Handles one `task.rpc` envelope. Returns the sealed reply envelope,
  /// or `null` when the request must get no reply (step 1 failure, or a
  /// reply that cannot be sealed).
  Future<Map<String, dynamic>?> handleEnvelope(
    Map<String, dynamic> json,
  ) async {
    late final LomEnvelope envelope;
    late final List<int> plain;
    try {
      envelope = LomEnvelope.fromJson(json);
      plain = await openEnvelope(
        envelope: envelope,
        ownIdentity: identity,
        trustedSenders: trustedSenders(),
      );
    } on LomEnvelopeException {
      return null;
    }
    late final Map<String, dynamic> request;
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map<String, dynamic>) return null;
      request = decoded;
    } on FormatException {
      return null;
    }
    final issuedAt = _issuedAt(request['issued_at']);
    if (issuedAt == null) {
      return _errorReply(envelope, 'remote.operation_failed');
    }
    if ((_now().millisecondsSinceEpoch - issuedAt).abs() > lomRpcWindowMs) {
      return _errorReply(envelope, 'remote.expired');
    }
    if (!trustedSenders().contains(envelope.sender)) {
      return _errorReply(envelope, 'remote.revoked');
    }
    if (!await replay.claim('${envelope.sender}:${envelope.id}')) {
      return _errorReply(envelope, 'remote.replayed');
    }
    if (!await engine.isReady()) {
      return _errorReply(envelope, 'remote.not_ready');
    }
    try {
      final method = request['method'];
      if (method is! String || !implementedMethods.contains(method)) {
        return await _errorReply(envelope, 'remote.method_unknown');
      }
      final payload = _parsePayload(request['payload']);
      if (payload == null) {
        return await _errorReply(envelope, 'remote.operation_failed');
      }
      final result = await _dispatch(method, payload, envelope.sender);
      return await _okReply(envelope, result);
    } on LomRpcException catch (e) {
      return _errorReply(envelope, lomErrorCode(e));
    } on LomEngineException catch (e) {
      return _errorReply(envelope, lomErrorCode(e));
    } catch (_) {
      return _errorReply(envelope, 'remote.operation_failed');
    }
  }

  /// Startup recovery: sessions still marked `running` were cut off by a
  /// restart. Mark them `interrupted` — never re-run them (doc §07 §2).
  Future<List<String>> recoverInterrupted() =>
      receipts.markRunningInterrupted();

  int? _issuedAt(Object? raw) {
    if (raw is String) return int.tryParse(raw);
    if (raw is int) return raw;
    return null;
  }

  Map<String, dynamic>? _parsePayload(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _okReply(
    LomEnvelope request,
    Map<String, Object?> result,
  ) async =>
      _sealReply(request, status: 'ok', payload: result, error: '');

  Future<Map<String, dynamic>?> _errorReply(
    LomEnvelope request,
    String code,
  ) async =>
      _sealReply(request, status: 'error', payload: {}, error: code);

  Future<Map<String, dynamic>?> _sealReply(
    LomEnvelope request, {
    required String status,
    required Map<String, Object?> payload,
    required String error,
  }) async {
    final text = jsonEncode({
      'status': status,
      'payload': jsonEncode(payload),
      'error': error,
    });
    try {
      final sealed = await sealEnvelope(
        plaintext: utf8.encode(text),
        id: request.id,
        senderIdentity: identity,
        recipientKeys: request.sender,
      );
      return sealed.toJson();
    } on LomEnvelopeException {
      return null;
    }
  }

  Future<Map<String, Object?>> _dispatch(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'device.capabilities':
        return _capabilities();
      case 'model.sync':
        return _modelSync(payload, sender);
      case 'chat.send':
        return _chatSend(payload, sender);
      case 'chat.read':
        return _chatRead(payload);
      case 'chat.list':
        return _chatList(payload);
      case 'chat.cancel':
        return _chatCancel(payload);
      case 'document.list':
        return {'items': <Object?>[]};
      case 'document.read':
        return _documentRead(payload);
      case 'schedule.list':
        return _scheduleList();
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  Map<String, Object?> _capabilities() => {
        'version': 1,
        'methods': [...implementedMethods]..sort(),
        'limits': {'chat.send.max_text_chars': 20000},
      };

  // ---------------------------------------------------------------- model

  /// `model.sync` (doc §07 §3). The `api_key` is passed to the engine's
  /// credential store only; the persisted config holds metadata alone.
  Future<Map<String, Object?>> _modelSync(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final baseUrl = _cleanBaseUrl(_string(payload, 'base_url'));
    if (baseUrl == null) throw LomRpcException('model.invalid_url');
    final apiKey = _string(payload, 'api_key');
    final model = _string(payload, 'model');
    if (apiKey.isEmpty ||
        apiKey.length > 16384 ||
        model.isEmpty ||
        model.length > 256) {
      throw LomRpcException('model.invalid_config');
    }
    final api = _piAiApi(_string(payload, 'platform'));
    if (api == null) throw LomRpcException('model.unsupported_protocol');
    final revision = int.tryParse(_string(payload, 'revision'));
    if (revision == null) throw LomRpcException('model.invalid_config');
    final existing = await modelConfigs.loadFor(sender);
    if (existing != null && revision < existing.revision) {
      throw LomRpcException('model.stale_revision');
    }
    final route = _routeFor(sender);
    final keyRef = _keyRefFor(route);
    await engine.applyModelConfig(
      route: route,
      api: api,
      baseUrl: baseUrl,
      keyRef: keyRef,
      apiKey: apiKey,
      model: model,
    );
    await modelConfigs.save(
      sender,
      LomModelConfig(
        baseUrl: baseUrl,
        model: model,
        platform: _string(payload, 'platform'),
        revision: revision,
        route: route,
        keyRef: keyRef,
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
    return {
      'status': 'saved',
      'model': model,
      'revision': _string(payload, 'revision'),
    };
  }

  /// Lom platform → pi-ai wire protocol. `gemini` has no pi-ai route:
  /// the dispatcher answers `model.unsupported_protocol` instead of
  /// pretending to support it.
  String? _piAiApi(String platform) => switch (platform) {
        'openai' => 'openai-completions',
        'openai-responses' => 'openai-responses',
        'anthropic' => 'anthropic-messages',
        _ => null,
      };

  /// `https://` only, no userinfo / query / fragment, trailing `/`s off.
  String? _cleanBaseUrl(String raw) {
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    var out = raw;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out.isEmpty ? null : out;
  }

  /// One pi-ai route per desktop (`lom-<12 hex>`), so two desktops' model
  /// configs can never contaminate each other.
  String _routeFor(String desktopKey) {
    final hash = crypto.sha256.convert(utf8.encode(desktopKey)).toString();
    return 'lom-${hash.substring(0, 12)}';
  }

  /// The credential reference the official Models page derives for a route
  /// (`custom-my-gw` → `CUSTOM_MY_GW_API_KEY`).
  String _keyRefFor(String route) =>
      '${route.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}_API_KEY';

  // ----------------------------------------------------------------- chat

  /// `chat.send` (doc §07 §4): validate → persist receipt → start task →
  /// return `accepted`. The receipt is written before `promptSession`, so
  /// a retry with the same `client_id` never double-executes.
  Future<Map<String, Object?>> _chatSend(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final clientId = _string(payload, 'client_id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,64}$').hasMatch(clientId)) {
      throw LomRpcException('chat.invalid_id');
    }
    final sessionId = _string(payload, 'session_id');
    var text = _string(payload, 'text');
    final files = _parseFiles(payload);
    if (text.trim().isEmpty && files.isEmpty) {
      throw LomRpcException('chat.invalid_text');
    }
    if (utf8.encode(text).length > 60000) {
      throw LomRpcException('chat.invalid_text');
    }
    if (text.trim().isEmpty) text = '请查看附件。';
    if (files.isNotEmpty) {
      // `file.*` lands in Phase 4: no attachment id can be verified yet.
      throw LomRpcException('file.missing');
    }
    final contentHash = crypto.sha256
        .convert(utf8.encode('$sessionId\n$text\n${jsonEncode(files)}'))
        .toString();
    final existing = await _findExistingReceipt(clientId, contentHash);
    if (existing != null) {
      return {
        'session_id': existing.sessionId,
        'client_id': clientId,
        'status': 'accepted',
      };
    }
    final (sid, config) = await _resolveSendSession(sessionId, sender);
    await _startTask(clientId, sid, contentHash, text, config);
    return {'session_id': sid, 'client_id': clientId, 'status': 'accepted'};
  }

  /// Idempotency lookup: the same `client_id` + content returns the
  /// original receipt; the same key + different content is `chat.id_reused`;
  /// a `failed` receipt (or none) returns null so the send proceeds.
  Future<LomChatReceipt?> _findExistingReceipt(
    String clientId,
    String contentHash,
  ) async {
    final existing = await receipts.receiptFor(clientId);
    if (existing == null) return null;
    if (existing.contentHash != contentHash) {
      throw LomRpcException('chat.id_reused');
    }
    if (existing.status == 'failed') return null;
    return existing;
  }

  /// Resolves the target session and checks it can take a task. The model
  /// check comes before session creation: a `model_missing` failure must
  /// not leave an empty session behind.
  Future<(String, LomModelConfig)> _resolveSendSession(
    String sessionId,
    String sender,
  ) async {
    final config = await modelConfigs.loadFor(sender);
    if (config == null) throw LomRpcException('chat.model_missing');
    var sid = sessionId;
    if (sid.isEmpty) {
      sid = await engine.createSession();
    } else if (!await engine.sessionExists(sid)) {
      throw LomRpcException('chat.session_missing');
    }
    if (_sending.contains(sid) || await engine.sessionRunning(sid)) {
      throw LomRpcException('chat.busy');
    }
    return (sid, config);
  }

  /// Persists the receipt, then starts the task. A failed start marks the
  /// receipt `failed` so a retry with the same `client_id` may re-execute.
  Future<void> _startTask(
    String clientId,
    String sid,
    String contentHash,
    String text,
    LomModelConfig config,
  ) async {
    await receipts.saveReceipt(
      LomChatReceipt(
        clientId: clientId,
        sessionId: sid,
        contentHash: contentHash,
        status: 'pending',
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
    _sending.add(sid);
    try {
      await engine.selectModel(
        sid,
        provider: config.route,
        model: config.model,
      );
      await engine.promptSession(sid, text, requestId: clientId);
    } catch (_) {
      await receipts.saveReceipt(
        LomChatReceipt(
          clientId: clientId,
          sessionId: sid,
          contentHash: contentHash,
          status: 'failed',
          updatedAtMs: _now().millisecondsSinceEpoch,
        ),
      );
      rethrow;
    } finally {
      _sending.remove(sid);
    }
    await receipts.saveReceipt(
      LomChatReceipt(
        clientId: clientId,
        sessionId: sid,
        contentHash: contentHash,
        status: 'accepted',
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
    await receipts.saveSessionState(
      LomChatSessionState(
        sessionId: sid,
        status: 'running',
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
  }

  List<String> _parseFiles(Map<String, dynamic> payload) {
    if (!payload.containsKey('files')) return [];
    final raw = _string(payload, 'files');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.any((e) => e is! String)) {
        throw const FormatException('files');
      }
      final files = decoded.cast<String>();
      if (files.length > 10) throw LomRpcException('file.too_many');
      return files;
    } on FormatException {
      throw LomRpcException('file.invalid_id');
    }
  }

  /// `chat.read` (doc §07 §4): `offset` pages of at most 50 messages,
  /// oldest first. `next` always advances while `offset < total`.
  Future<Map<String, Object?>> _chatRead(
    Map<String, dynamic> payload,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    final offset = _offset(payload);
    if (offset < 0) throw LomRpcException('remote.operation_failed');
    if (!await engine.sessionExists(sessionId)) {
      throw LomRpcException('chat.session_missing');
    }
    final cache = _historyCache.putIfAbsent(
      sessionId,
      () => _SessionHistoryCache(),
    );
    await _refreshHistory(sessionId, cache);
    final running = await engine.sessionRunning(sessionId);
    final stored = await receipts.sessionState(sessionId);
    final messages = cache.messages;
    final total = messages.length;
    final page = offset < total
        ? messages.sublist(offset, min(offset + lomChatReadPageSize, total))
        : <LomChatMessage>[];
    final status = _readStatus(running, cache, stored, messages.isEmpty);
    final error = status == 'failed' || status == 'timeout'
        ? (cache.lastError.isNotEmpty ? cache.lastError : stored?.error ?? '')
        : '';
    if (cache.lastStatus != null && cache.lastStatus != stored?.status) {
      await receipts.saveSessionState(
        LomChatSessionState(
          sessionId: sessionId,
          status: running ? 'running' : cache.lastStatus!,
          error: error,
          updatedAtMs: _now().millisecondsSinceEpoch,
        ),
      );
    }
    return {
      'items': [for (final m in page) m.toJson()],
      'total': total,
      'next': offset + page.length,
      'running': running,
      'status': status,
      'error': error,
    };
  }

  String _readStatus(
    bool running,
    _SessionHistoryCache cache,
    LomChatSessionState? stored,
    bool noMessages,
  ) {
    if (running) return 'running';
    if (cache.lastStatus != null) return cache.lastStatus!;
    final s = stored?.status;
    if (s != null && s != 'running' && s != 'idle') return s;
    if (noMessages) return 'idle';
    // Messages exist but no turn outcome was ever observed (e.g. the
    // session predates this phone's Lom install): best-effort `completed`.
    return 'completed';
  }

  /// Refreshes [cache] from the engine: a tail read at the current cursor,
  /// then older pages until the cached range is reached (or the log ends).
  Future<void> _refreshHistory(
    String sessionId,
    _SessionHistoryCache cache,
  ) async {
    final cursor = await engine.sessionCursor(sessionId);
    if (cache.complete && cache.cursor == cursor) return;
    var page = await engine.readHistory(
      sessionId,
      throughSeq: cursor,
      maxMessages: 500,
    );
    _mergeHistory(cache, page);
    while (page.hasMore &&
        (cache.minSeq == null || page.oldestSeq > cache.minSeq!)) {
      if (page.oldestSeq <= 0) break;
      page = await engine.readHistory(
        sessionId,
        throughSeq: page.cursor,
        beforeSeq: page.oldestSeq,
        maxMessages: 500,
      );
      _mergeHistory(cache, page);
    }
    cache.cursor = cursor;
    cache.complete = true;
    _trimHistoryCache(cache);
  }

  void _mergeHistory(_SessionHistoryCache cache, LomHistoryPage page) {
    for (final message in page.messages) {
      cache.byId[message.id] = message;
      if (cache.minSeq == null || message.seq < cache.minSeq!) {
        cache.minSeq = message.seq;
      }
    }
    if (page.turnStatus != null && page.turnSeq > cache.lastTurnSeq) {
      cache.lastStatus = page.turnStatus;
      cache.lastError = page.turnError;
      cache.lastTurnSeq = page.turnSeq;
    }
  }

  /// The cache is a read cache, not an archive: keep the newest 10,000
  /// messages so a very long session cannot grow it without bound.
  void _trimHistoryCache(_SessionHistoryCache cache) {
    const cap = 10000;
    if (cache.byId.length <= cap) return;
    final ordered = cache.messages;
    final drop = ordered.length - cap;
    for (var i = 0; i < drop; i++) {
      cache.byId.remove(ordered[i].id);
    }
    cache.minSeq = ordered[drop].seq;
  }

  /// `chat.list` (doc §07 §4): at most 100 sessions, newest first.
  Future<Map<String, Object?>> _chatList(
    Map<String, dynamic> payload,
  ) async {
    final offset = _offset(payload);
    if (offset < 0) throw LomRpcException('remote.operation_failed');
    final sessions = await engine.listSessions();
    final total = sessions.length;
    final page = offset < total
        ? sessions.sublist(offset, min(offset + lomChatListPageSize, total))
        : <LomSessionSummary>[];
    return {
      'items': [
        for (final s in page)
          {
            'id': s.id,
            'title': s.title.isEmpty ? '新的会话' : s.title,
            'updated': s.updatedMs,
            'pinned': s.pinned,
            'running': s.running,
            'model': s.model,
          },
      ],
      'total': total,
      'next': offset + page.length,
    };
  }

  /// `chat.cancel` (doc §07 §4): only answers once the turn has really
  /// stopped. A session that is not running answers success immediately.
  Future<Map<String, Object?>> _chatCancel(
    Map<String, dynamic> payload,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    if (!await engine.sessionExists(sessionId)) {
      throw LomRpcException('chat.session_missing');
    }
    if (!await engine.sessionRunning(sessionId)) {
      final stored = await receipts.sessionState(sessionId);
      if (stored?.status == 'running') {
        await receipts.saveSessionState(
          LomChatSessionState(
            sessionId: sessionId,
            status: 'cancelled',
            updatedAtMs: _now().millisecondsSinceEpoch,
          ),
        );
      }
      return {'status': 'cancelled', 'session_id': sessionId};
    }
    await engine.cancelSession(sessionId);
    final deadline = DateTime.now().add(cancelWait);
    while (await engine.sessionRunning(sessionId)) {
      if (DateTime.now().isAfter(deadline)) {
        // Never pretend it stopped: the desktop shows "尚未确认停止".
        throw LomRpcException('remote.operation_failed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await receipts.saveSessionState(
      LomChatSessionState(
        sessionId: sessionId,
        status: 'cancelled',
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
    return {'status': 'cancelled', 'session_id': sessionId};
  }

  // ------------------------------------------------------------- documents

  /// `document.read` (doc §07 §5). dsh-Go has no SOUL.md / GLOBAL.md /
  /// daily-memory document store, so every valid name reads as an empty
  /// (missing) document — never `remote.method_unknown`.
  Map<String, Object?> _documentRead(Map<String, dynamic> payload) {
    final name = _string(payload, 'name');
    if (!_isDocumentName(name)) throw LomRpcException('sync.invalid_name');
    return {
      'name': name,
      'text': '',
      'revision': lomEmptyDocumentRevision,
      'modified': 0,
    };
  }

  bool _isDocumentName(String name) {
    if (name == 'SOUL.md' || name == 'GLOBAL.md') return true;
    final match =
        RegExp(r'^(\d{4})-(\d{2})-(\d{2})\.md$').firstMatch(name);
    if (match == null) return false;
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    return month >= 1 && month <= 12 && day >= 1 && day <= 31;
  }

  // ------------------------------------------------------------- schedules

  /// `schedule.list` (doc §07 §10): read-only mapping of the DSH schedule
  /// catalog. `exact` is `"false"`: precise-alarm capability of this
  /// phone's DSH schedules has not been verified, so it is not claimed.
  Future<Map<String, Object?>> _scheduleList() async {
    final tasks = await engine.scheduleCatalog();
    final timezone = await engine.systemTimeZone();
    return {
      'items': jsonEncode([
        for (final task in tasks) lomPhoneScheduleJson(task),
      ]),
      'timezone': timezone,
      'exact': 'false',
    };
  }

  // ---------------------------------------------------------------- helpers

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }

  /// `offset` is a JSON number (doc §07); missing means 0, anything else
  /// is a protocol failure (-1).
  int _offset(Map<String, dynamic> payload) {
    final value = payload['offset'];
    if (value == null) return 0;
    if (value is int) return value;
    return -1;
  }
}

/// Cached history of one session, in message-id order by engine `seq`.
class _SessionHistoryCache {
  final Map<String, LomChatMessage> byId = {};
  int? minSeq;
  int cursor = -1;
  bool complete = false;
  String? lastStatus;
  String lastError = '';
  int lastTurnSeq = -1;

  List<LomChatMessage> get messages {
    final list = byId.values.toList(growable: false);
    list.sort((a, b) => a.seq.compareTo(b.seq));
    return list;
  }
}
