/// Adapts the real [DshClient] (local `dsh web` engine) to [LomEngine].
///
/// The mapping rules live in the pure functions below so they are unit
/// testable without an engine:
///
/// * history events → [LomChatMessage]s: only human user messages and
///   assistant messages become items; injected context messages, thinking
///   (`reasoning`) parts and image/file parts are not sent to the desktop.
///   Tool calls become `tool_use` blocks on the assistant message they
///   belong to; a `turn/end` event sets the session outcome.
/// * [ScheduleTask] → [LomSchedule]: the raw catalog record, revision
///   derivation happens in the dispatcher.
/// * DSH sessions have no pin concept, so `chat.list` always reports
///   `pinned: false`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dsh_client/dsh_client.dart';

import '../state/time_zones.dart' show detectAndroidTimeZone;
import 'engine.dart';
import 'rpc_errors.dart';

/// Cap on one message's text in a `chat.read` reply (the whole reply
/// plaintext must stay under 350,000 bytes).
const int _maxMessageTextChars = 50000;

/// Cap on one block's text.
const int _maxBlockTextChars = 20000;

class DshLomEngine implements LomEngine {
  DshLomEngine({required this.resolveClient});

  /// Resolves the local engine client (null while the engine is down).
  /// The first non-null client is cached; a closed client is dropped and
  /// re-resolved once (see [_withClient]).
  final Future<DshClient?> Function() resolveClient;

  DshClient? _cached;

  Future<DshClient?> _client() async {
    final cached = _cached;
    if (cached != null) return cached;
    final DshClient? client;
    try {
      client = await resolveClient().timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    }
    if (client != null) _cached = client;
    return client;
  }

  Future<DshClient> _requireClient() async {
    final client = await _client();
    if (client == null) throw LomEngineException('remote.not_ready');
    return client;
  }

  /// Runs [run] against the engine client. A closed client is dropped,
  /// re-resolved once, and the call retried; anything else that is not
  /// already a [LomEngineException] becomes `remote.operation_failed`
  /// (never a DSH code or message — those must not leak into replies).
  Future<T> _guard<T>(Future<T> Function(DshClient client) run) async {
    try {
      return await run(await _requireClient());
    } on LomEngineException {
      rethrow;
    } on DshClosedException {
      _cached = null;
      try {
        return await run(await _requireClient());
      } on LomEngineException {
        rethrow;
      } catch (_) {
        throw LomEngineException('remote.operation_failed');
      }
    } catch (_) {
      throw LomEngineException('remote.operation_failed');
    }
  }

  @override
  Future<bool> isReady() async {
    try {
      return await _client() != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> applyModelConfig({
    required String route,
    required String api,
    required String baseUrl,
    required String keyRef,
    required String apiKey,
    required String model,
  }) =>
      _guard((client) async {
        await client.setProviderKey(apiKey, ref: keyRef);
        await client.saveProvider(
          ProviderProfile(
            route: route,
            api: api,
            baseUrl: baseUrl,
            apiKeyEnv: keyRef,
            models: [ProviderModelSpec(id: model)],
          ),
        );
      });

  @override
  Future<String> createSession() =>
      _guard((client) async => (await client.createSession()).sessionId);

  @override
  Future<bool> sessionExists(String sessionId) =>
      _guard((client) async => await client.projections(sessionId) != null);

  @override
  Future<bool> sessionRunning(String sessionId) => _guard((client) async {
        final sessions = await client.listSessions();
        for (final s in sessions) {
          if (s.sessionId == sessionId) return s.running;
        }
        throw LomEngineException('chat.session_missing');
      });

  @override
  Future<int> sessionCursor(String sessionId) =>
      _guard((client) async {
        final projections = await client.projections(sessionId);
        if (projections == null) {
          throw LomEngineException('chat.session_missing');
        }
        return projections.asOfSeq;
      });

  @override
  Future<LomHistoryPage> readHistory(
    String sessionId, {
    int? throughSeq,
    int? beforeSeq,
    int maxMessages = 500,
  }) =>
      _guard((client) async {
        final cursor = throughSeq ??
            (await client.projections(sessionId))?.asOfSeq;
        if (cursor == null) throw LomEngineException('chat.session_missing');
        final page = await client.history(
          sessionId,
          throughSeq: cursor,
          beforeSeq: beforeSeq,
          maxMessages: maxMessages,
        );
        final mapped = lomMessagesFromEvents(page.events);
        return LomHistoryPage(
          messages: mapped.messages,
          turnStatus: mapped.turnStatus,
          turnError: mapped.turnError,
          turnSeq: mapped.turnSeq,
          cursor: cursor,
          hasMore: page.hasMore,
          oldestSeq: page.events.isEmpty ? -1 : page.events.first.seq,
        );
      });

  @override
  Future<List<LomSessionSummary>> listSessions() =>
      _guard((client) async {
        final sessions = await client.listSessions();
        return [
          for (final s in sessions)
            LomSessionSummary(
              id: s.sessionId,
              title: s.title ?? '',
              updatedMs: s.updatedAt.millisecondsSinceEpoch,
              // DSH sessions have no pin concept.
              pinned: false,
              running: s.running,
              model: s.projections.nextModel?.model ??
                  s.projections.lastUsedModel?.model ??
                  '',
            ),
        ];
      });

  @override
  Future<void> selectModel(
    String sessionId, {
    required String provider,
    required String model,
  }) =>
      _guard((client) async {
        await client.setModel(sessionId, provider: provider, model: model);
      });

  @override
  Future<void> promptSession(
    String sessionId,
    String text, {
    required String requestId,
  }) =>
      _guard((client) async {
        // The dispatcher already refused a busy session, so `queue` can
        // only enqueue behind a turn that started in the meantime.
        await client.prompt(sessionId, text, requestId: requestId);
      });

  @override
  Future<void> cancelSession(String sessionId) =>
      _guard((client) async {
        await client.cancel(sessionId);
      });

  @override
  Future<String> renameSession(String sessionId, String title) =>
      _guard((client) async => client.renameSession(sessionId, title));

  @override
  Future<void> deleteSession(String sessionId) =>
      _guard((client) async {
        // Never fall back to archive: a host without the deletion route
        // must report the failure, not silently archive instead.
        if (!await client.supportsSessionDeletion()) {
          throw LomEngineException('remote.operation_failed');
        }
        await client.deleteSessionPermanently(sessionId);
      });

  @override
  Future<String> deviceNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.contains(ConnectivityResult.wifi)) return 'wifi';
      if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
      if (results.contains(ConnectivityResult.mobile)) return 'cellular';
      if (results.contains(ConnectivityResult.none)) return 'offline';
      return 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  @override
  Future<List<LomSchedule>> scheduleCatalog() =>
      _guard((client) async {
        final tasks = await client.scheduleCatalog();
        return [for (final t in tasks) lomScheduleFromTask(t)];
      });

  @override
  Future<String> systemTimeZone() => detectAndroidTimeZone();
}

// ------------------------------------------------------------------ history

/// Maps one session's log events to chat messages + the newest turn
/// outcome. Pure: unit-testable without an engine.
///
/// * `user/message` only counts when it is a human prompt — injected
///   context (reminders, skill catalogs, goal rounds) is not conversation.
/// * Assistant `reasoning` parts are never emitted (doc §07: do not send
///   thinking content); image/file parts are not emitted either.
/// * `tool/call` / `tool/result` attach to the most recent assistant
///   message as `tool_use` blocks, so the desktop sees one message with
///   its tool trace instead of stray tool rows.
({
  List<LomChatMessage> messages,
  String? turnStatus,
  String turnError,
  int turnSeq,
})
lomMessagesFromEvents(List<SessionLogEvent> events) {
  final ordered = [...events]..sort((a, b) => a.seq.compareTo(b.seq));
  final builders = <_MessageBuilder>[];
  String? turnStatus;
  var turnError = '';
  var turnSeq = -1;
  for (final event in ordered) {
    switch (event) {
      case UserMessageEvent(:final message) when message.source.isHuman:
        builders.add(
          _MessageBuilder(
            id: _messageId(message.id, event.seq),
            role: 'user',
            text: _cap(message.text, _maxMessageTextChars),
            at: event.time.millisecondsSinceEpoch,
            seq: event.seq,
          ),
        );
      case AssistantMessageEvent(:final message):
        builders.add(
          _MessageBuilder(
            id: _messageId(message.id, event.seq),
            role: 'assistant',
            text: _cap(message.text, _maxMessageTextChars),
            at: event.time.millisecondsSinceEpoch,
            seq: event.seq,
            blocks: _blocksFromParts(message),
          ),
        );
      case ToolCallEvent(:final callId, :final name, :final arguments):
        final target = _lastAssistant(builders);
        if (target != null) {
          target.blocks.add(
            LomChatBlock(
              id: callId.isEmpty ? 'seq-${event.seq}' : callId,
              kind: 'tool_use',
              title: name,
              text: _cap(arguments, _maxBlockTextChars),
              status: 'RUNNING',
            ),
          );
        }
      case ToolResultEvent(:final message, :final failure):
        final block = _findBlock(builders, message.toolCallId ?? '');
        if (block != null) {
          final index = _blockIndex(builders, block);
          if (index.$1 >= 0) {
            builders[index.$1].blocks[index.$2] = LomChatBlock(
              id: block.id,
              kind: 'tool_use',
              title: block.title,
              text: _cap(message.text, _maxBlockTextChars),
              status: failure == null ? 'SUCCESS' : 'FAILED',
            );
          }
        }
      case TurnEndedEvent(:final reason):
        final mapped = _turnOutcome(reason.kind);
        if (mapped != null) {
          turnStatus = mapped.$1;
          turnError = mapped.$2;
          turnSeq = event.seq;
        }
      default:
        break;
    }
  }
  return (
    messages: [for (final b in builders) b.build()],
    turnStatus: turnStatus,
    turnError: turnError,
    turnSeq: turnSeq,
  );
}

String _messageId(String id, int seq) =>
    id.isEmpty ? 'seq-$seq' : id;

String _cap(String text, int maxChars) =>
    text.length <= maxChars ? text : text.substring(0, maxChars);

List<LomChatBlock> _blocksFromParts(Message message) {
  final blocks = <LomChatBlock>[];
  for (var i = 0; i < message.parts.length; i++) {
    final part = message.parts[i];
    switch (part) {
      case TextPart(:final text):
        if (text.isNotEmpty) {
          blocks.add(
            LomChatBlock(
              id: '${message.id}:$i',
              kind: 'text',
              text: _cap(text, _maxBlockTextChars),
            ),
          );
        }
      case ToolCallPart(:final id, :final name, :final arguments):
        blocks.add(
          LomChatBlock(
            id: id.isEmpty ? '${message.id}:$i' : id,
            kind: 'tool_use',
            title: name,
            text: _cap(arguments, _maxBlockTextChars),
            status: 'RUNNING',
          ),
        );
      default:
        // ReasoningPart (thinking), ImagePart, FilePart, UnknownPart:
        // never sent to the desktop.
        break;
    }
  }
  return blocks;
}

_MessageBuilder? _lastAssistant(List<_MessageBuilder> builders) {
  for (var i = builders.length - 1; i >= 0; i--) {
    if (builders[i].role == 'assistant') return builders[i];
  }
  return null;
}

LomChatBlock? _findBlock(List<_MessageBuilder> builders, String callId) {
  if (callId.isEmpty) return null;
  for (var i = builders.length - 1; i >= 0; i--) {
    for (final block in builders[i].blocks) {
      if (block.id == callId) return block;
    }
  }
  return null;
}

(int, int) _blockIndex(List<_MessageBuilder> builders, LomChatBlock block) {
  for (var i = 0; i < builders.length; i++) {
    for (var j = 0; j < builders[i].blocks.length; j++) {
      if (identical(builders[i].blocks[j], block)) return (i, j);
    }
  }
  return (-1, -1);
}

/// DSH turn-end kind → Lom `chat.read` status + short error note.
(String, String)? _turnOutcome(String kind) => switch (kind) {
      'completed' => ('completed', ''),
      'aborted' => ('cancelled', ''),
      'error' => ('failed', '模型调用失败'),
      'max-tokens' => ('failed', '输出达到上限'),
      'blocked' => ('failed', '请求被拦截'),
      'interrupted' => ('interrupted', ''),
      _ => null, // 'forked' / unknown: not an outcome for the desktop.
    };

class _MessageBuilder {
  _MessageBuilder({
    required this.id,
    required this.role,
    required this.text,
    required this.at,
    required this.seq,
    List<LomChatBlock>? blocks,
  }) : blocks = blocks ?? [];

  final String id;
  final String role;
  final String text;
  final int at;
  final int seq;
  final List<LomChatBlock> blocks;

  LomChatMessage build() => LomChatMessage(
        id: id,
        role: role,
        text: text,
        at: at,
        seq: seq,
        blocks: List.unmodifiable(blocks),
      );
}

// --------------------------------------------------------------- schedules

/// Maps one catalog task to the dispatcher's [LomSchedule] DTO.
LomSchedule lomScheduleFromTask(ScheduleTask task) => LomSchedule(
      id: task.id,
      title: task.title,
      prompt: task.prompt,
      kind: task.kind,
      active: task.active,
      sessionId: task.sessionId,
      scheduledAtMs: task.scheduledAt?.millisecondsSinceEpoch,
      afterSeconds: task.afterSeconds,
      everySeconds: task.everySeconds,
      time: task.time,
      timeZone: task.timeZone,
      weekdays: task.weekdays,
      expression: task.expression,
      lastDeliveredAtMs: task.lastDeliveredAt?.millisecondsSinceEpoch,
      recordJson: jsonEncode(task.record),
    );
