/// The DSH engine surface the Lom RPC dispatcher needs, as plain Dart
/// data — no `package:dsh_client` types leak into the dispatcher, so it
/// stays unit-testable with a fake engine. `dsh_engine.dart` adapts the
/// real [DshClient] to this interface; `lom_relay_service.dart` wires it
/// to the local engine connection.
library;

import 'dart:convert';

/// One content block of an assistant message (doc §07 `chat.read`).
class LomChatBlock {
  const LomChatBlock({
    required this.id,
    required this.kind,
    this.title = '',
    this.text = '',
    this.status = '',
    this.command = '',
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        if (title.isNotEmpty) 'title': title,
        'text': text,
        if (status.isNotEmpty) 'status': status,
        if (command.isNotEmpty) 'command': command,
      };

  /// Block id, stable across polls.
  final String id;

  /// `text` or `tool_use` (thinking blocks are never emitted).
  final String kind;

  /// Tool name for `tool_use`.
  final String title;
  final String text;

  /// `tool_use` execution state: `PENDING` / `STREAMING` / `RUNNING` /
  /// `SUCCESS` / `FAILED` / `TIMEOUT` / `CANCELLED`.
  final String status;
  final String command;
}

/// `chat.image` size cap (doc §07 §4): 15 MiB.
const int lomChatImageMaxBytes = 15728640;

/// One attachment of a chat message, retained so `chat.file` can fetch
/// it by index (doc §07 `chat.file`). The desktop only sees the file
/// names (`attachments`); the reference stays on the phone.
class LomAttachmentRef {
  const LomAttachmentRef({
    required this.id,
    required this.mediaType,
    required this.name,
    required this.kind,
  });

  /// Engine attachment id (`session/attachment` key).
  final String id;
  final String mediaType;
  final String name;

  /// `image` (an `ImagePart`) or `file` (a `FilePart`).
  final String kind;
}

/// Fetched attachment bytes, for `chat.file` / `chat.image`.
class LomAttachmentData {
  const LomAttachmentData({
    required this.bytes,
    required this.mime,
    required this.name,
  });

  final List<int> bytes;
  final String mime;
  final String name;
}

/// One chat message (doc §07 `chat.read`).
class LomChatMessage {
  const LomChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.at,
    this.seq = -1,
    this.blocks = const [],
    this.attachments = const [],
    this.attachmentRefs = const [],
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role,
        'text': text,
        'at': at,
        'attachments': attachments,
        if (blocks.isNotEmpty)
          'blocks': [for (final b in blocks) b.toJson()],
      };

  /// Message id, stable across polls (falls back to `seq-<seq>`).
  final String id;

  /// `user` or `assistant`.
  final String role;
  final String text;

  /// Milliseconds since epoch.
  final int at;

  /// Engine log sequence, for ordering and incremental refresh.
  final int seq;
  final List<LomChatBlock> blocks;
  final List<String> attachments;

  /// Fetchable references for [attachments], in the same order — the
  /// `chat.file` index addresses both lists at once.
  final List<LomAttachmentRef> attachmentRefs;
}

/// One page of a session's history, newest events first in the raw log but
/// returned as messages in chronological order.
class LomHistoryPage {
  const LomHistoryPage({
    required this.messages,
    this.turnStatus,
    this.turnError = '',
    this.turnSeq = -1,
    required this.cursor,
    required this.hasMore,
    required this.oldestSeq,
  });

  final List<LomChatMessage> messages;

  /// Outcome of the newest `turn/end` in this page, if any:
  /// `completed` / `failed` / `timeout` / `cancelled` / `interrupted`.
  final String? turnStatus;
  final String turnError;

  /// Sequence of that newest `turn/end` event (-1 when none).
  final int turnSeq;

  /// The `asOfSeq` cursor this page was read at.
  final int cursor;

  /// Older events exist before [oldestSeq].
  final bool hasMore;

  /// Smallest sequence in this page (-1 when the page is empty).
  final int oldestSeq;
}

/// One row of `chat.list` (doc §07).
class LomSessionSummary {
  const LomSessionSummary({
    required this.id,
    required this.title,
    required this.updatedMs,
    required this.pinned,
    required this.running,
    required this.model,
  });

  final String id;
  final String title;
  final int updatedMs;

  /// DSH sessions have no pin concept; always `false` (see dsh_engine).
  final bool pinned;
  final bool running;

  /// Model id of the session's last/next selection, or `""`.
  final String model;
}

/// One DSH scheduled task, before the `PhoneSchedule` mapping
/// (doc §07 §10). Field meanings follow `ScheduleTask` in
/// `package:dsh_client`: `scheduledAt` is the next target time (UTC),
/// `weekdays` are ISO 1 = Monday, `kind` is one of
/// `after` / `at` / `every` / `daily` / `weekly` / `cron` / `rrule`.
class LomSchedule {
  const LomSchedule({
    required this.id,
    required this.title,
    required this.prompt,
    required this.kind,
    required this.active,
    this.sessionId,
    this.scheduledAtMs,
    this.afterSeconds,
    this.everySeconds,
    this.time,
    this.timeZone,
    this.weekdays = const [],
    this.expression,
    this.lastDeliveredAtMs,
    required this.recordJson,
  });

  final String id;
  final String title;
  final String prompt;
  final String kind;
  final bool active;
  final String? sessionId;
  final int? scheduledAtMs;
  final int? afterSeconds;
  final int? everySeconds;

  /// `HH:MM[:SS]` in [timeZone] (daily / weekly).
  final String? time;
  final String? timeZone;
  final List<int> weekdays;
  final String? expression;
  final int? lastDeliveredAtMs;

  /// The stored record as JSON text; its SHA-256 is the `revision`.
  final String recordJson;

  /// Whether this task uses the 0.2.2 target protocol (its record has a
  /// `target` object) rather than a plain session id. Target tasks run
  /// through the Host's `schedule/*` RPCs; legacy tasks run by prompting
  /// their session.
  bool get usesTargetProtocol {
    try {
      final decoded = jsonDecode(recordJson);
      return decoded is Map<String, dynamic> &&
          decoded['target'] is Map<String, dynamic>;
    } catch (_) {
      return false;
    }
  }
}

/// The DSH engine surface the dispatcher needs. Every method throws
/// [LomEngineException] with a reply-safe Lom error code on a known
/// failure (e.g. `chat.session_missing`); transport failures surface as
/// [LomEngineException] with `remote.operation_failed`.
abstract class LomEngine {
  /// Whether the local engine client is currently reachable. The
  /// dispatcher answers `remote.not_ready` when this is false.
  Future<bool> isReady();

  /// Writes a desktop's model config into the engine: stores the key under
  /// [keyRef] (`credentials/set`) and declares the pi-ai route ([route],
  /// [api] is the pi-ai wire protocol, e.g. `openai-completions`).
  /// `gemini` has no pi-ai route and is rejected by the dispatcher before
  /// this is called.
  Future<void> applyModelConfig({
    required String route,
    required String api,
    required String baseUrl,
    required String keyRef,
    required String apiKey,
    required String model,
  });

  /// Creates a session and returns its id.
  Future<String> createSession();

  /// Whether the session exists (`projections` answers non-null).
  Future<bool> sessionExists(String sessionId);

  /// Whether the session currently has a running turn.
  Future<bool> sessionRunning(String sessionId);

  /// The session's `asOfSeq` cursor, for incremental history refresh.
  Future<int> sessionCursor(String sessionId);

  /// Reads one history page: the tail ending at [throughSeq] (or the
  /// current cursor when null), or the events strictly before [beforeSeq].
  Future<LomHistoryPage> readHistory(
    String sessionId, {
    int? throughSeq,
    int? beforeSeq,
    int maxMessages = 500,
  });

  /// All sessions, newest first.
  Future<List<LomSessionSummary>> listSessions();

  /// Selects [provider]/[model] for one session.
  Future<void> selectModel(
    String sessionId, {
    required String provider,
    required String model,
  });

  /// Sends [text] into the session's inbox. [requestId] is the Lom
  /// `client_id` (the engine treats a repeated id as idempotent).
  /// Returns once the prompt entered the inbox.
  Future<void> promptSession(
    String sessionId,
    String text, {
    required String requestId,
  });

  /// Interrupts the running turn. Answers even when idle.
  Future<void> cancelSession(String sessionId);

  /// Renames a session (`session/rename`); returns the title the engine
  /// confirmed. Throws [LomEngineException] with `chat.session_missing`
  /// when the session does not exist.
  Future<String> renameSession(String sessionId, String title);

  /// Permanently deletes a session. Throws [LomEngineException] with
  /// `remote.operation_failed` when this host cannot delete sessions
  /// (the bridge route is absent) or the outcome is unknown — the caller
  /// must never treat that as "deleted".
  Future<void> deleteSession(String sessionId);

  /// The current network transport, one of `wifi` / `cellular` /
  /// `ethernet` / `offline` / `unknown` (doc §07 `device.status`). Never
  /// throws: anything unknowable answers `unknown`.
  Future<String> deviceNetwork();

  /// Fetches one message attachment by its retained reference
  /// (`session/attachment`). Throws [LomEngineException] with
  /// `file.attachment_missing` when the host has no such attachment.
  /// File-kind parts go through the same endpoint; a host that only
  /// serves images answers the same missing code.
  Future<LomAttachmentData> attachmentBytes({
    required String sessionId,
    required LomAttachmentRef ref,
  });

  /// Reads one file from a session's sandbox (`session` workspace,
  /// engine-enforced). Throws [LomEngineException] with
  /// `file.attachment_missing` when the path does not resolve there.
  /// The caller enforces the image type/size limits.
  Future<List<int>> readSessionFile(String sessionId, String path);

  /// The engine's schedule catalog (read-only).
  Future<List<LomSchedule>> scheduleCatalog();

  /// Edits an existing schedule (`schedule/update` with the stored
  /// record as `expected`). Only the non-null fields change; [freq] (with
  /// [time] / [days] / [everyMinutes]) replaces the timing rule.
  /// Returns the updated task. Throws [LomEngineException] with
  /// `sync.conflict` (record changed), `schedule.missing`,
  /// `schedule.time_in_past`, `schedule.edit_on_phone`,
  /// `schedule.unsupported_frequency` or `schedule.invalid_content`.
  Future<LomSchedule> updateScheduleTask(
    LomSchedule task, {
    String? title,
    String? prompt,
    String? freq,
    String? time,
    List<int>? days,
    int? everyMinutes,
  });

  /// Deletes a schedule (hard delete, history included). Returns false
  /// when the task was already gone.
  Future<bool> deleteScheduleTask(LomSchedule task);

  /// Runs a schedule now, through the Host's run semantics. The caller
  /// (schedule.run) persists the dispatching receipt first.
  Future<void> runScheduleTask(LomSchedule task);

  /// The phone's IANA time zone (Android system zone, offset fallback).
  Future<String> systemTimeZone();
}
