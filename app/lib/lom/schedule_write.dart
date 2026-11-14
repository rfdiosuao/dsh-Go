/// `schedule.save` / `schedule.delete` / `schedule.run` (doc §07 §10).
///
/// What the DSH engine actually offers, verified against
/// `packages/dsh_client`:
/// * edit an existing task — `editSchedule` (`schedule/update` with the
///   stored record as `expected`, i.e. compare-and-set);
/// * delete a task — `deleteSchedule`;
/// * run a task now — `runScheduledTask`.
///
/// What it does **not** offer, and this file does not fake:
/// * create a task — there is no create RPC; a task is made by the
///   model's `schedule_create` tool inside a conversation, which takes
///   up to 2 minutes and cannot fit the 15-second reply budget. A save
///   for an unknown id with an empty revision is therefore refused with
///   `schedule.invalid_request`, not answered with a made-up task.
/// * enable/disable a task — there is no toggle RPC and the app UI has
///   no toggle either (`active` is a derived status: a one-shot task
///   ends after firing). `schedule.toggle` stays `remote.method_unknown`.
/// * `schedule.save` flipping `enabled` — same reason: a save whose
///   `enabled` differs from the task's current state is refused with
///   `schedule.edit_on_phone`.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'engine.dart';
import 'phase4_store.dart';
import 'rpc_errors.dart';
import 'schedule_mapping.dart';

class LomScheduleWriteHandler {
  LomScheduleWriteHandler({
    required this.engine,
    required this.receipts,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LomEngine engine;
  final LomOperationReceiptStore receipts;
  final DateTime Function() _now;

  Future<Map<String, Object?>> handle(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'schedule.save':
        return _save(payload);
      case 'schedule.delete':
        return _delete(payload);
      case 'schedule.run':
        return _run(payload);
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  /// `schedule.save`: edit an existing task (compare-and-set on
  /// `revision`), or — for an existing id with an empty revision — a
  /// replay when the content is identical, `schedule.id_reused` when it
  /// is not.
  Future<Map<String, Object?>> _save(
    Map<String, dynamic> payload,
  ) async {
    final id = _string(payload, 'id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,80}$').hasMatch(id)) {
      throw LomRpcException('schedule.invalid_id');
    }
    final revision = _string(payload, 'revision');
    final name = _string(payload, 'name');
    final prompt = _string(payload, 'prompt');
    final freq = _string(payload, 'freq');
    final time = _string(payload, 'time');
    final days = _days(payload);
    final every = int.tryParse(_string(payload, 'every'));
    final enabled = _string(payload, 'enabled');
    final sessionId = _string(payload, 'session_id');
    if (name.isEmpty ||
        name.length > 200 ||
        utf8.encode(prompt).length > 60000 ||
        (enabled != 'true' && enabled != 'false')) {
      throw LomRpcException('schedule.invalid_content');
    }
    if (freq == 'custom') throw LomRpcException('schedule.edit_on_phone');
    if (!const {'once', 'daily', 'weekly', 'interval'}.contains(freq)) {
      throw LomRpcException('schedule.unsupported_frequency');
    }
    _validateTiming(freq, time, days, every, enabled);
    if (sessionId.isNotEmpty && !await engine.sessionExists(sessionId)) {
      throw LomRpcException('chat.session_missing');
    }
    final task = await _findTask(id);
    if (task == null) {
      // No create RPC exists: a save for a new id cannot be honoured.
      if (revision.isEmpty) {
        throw LomRpcException('schedule.invalid_request');
      }
      throw LomRpcException('schedule.missing');
    }
    final current = lomPhoneScheduleJson(task);
    if (revision.isEmpty) {
      // Replay rule (doc §07 §10): identical content returns the
      // existing task; different content under the same id is a reuse.
      if (_sameContent(current, name, prompt, freq, time, days, every,
          enabled, sessionId)) {
        return current;
      }
      throw LomRpcException('schedule.id_reused');
    }
    if (revision != current['revision']) {
      throw LomRpcException('sync.conflict');
    }
    if (current['editable'] != 'true') {
      throw LomRpcException('schedule.edit_on_phone');
    }
    if (enabled != current['enabled']) {
      // No toggle API: the enabled state cannot be changed from here.
      throw LomRpcException('schedule.edit_on_phone');
    }
    final timingChanged = freq != current['freq'] ||
        time != current['time'] ||
        jsonEncode(days) != current['days'] ||
        '${every ?? ''}' != current['every'];
    if (name == current['name'] &&
        prompt == current['prompt'] &&
        !timingChanged &&
        sessionId == current['session_id']) {
      return current;
    }
    final updated = await engine.updateScheduleTask(
      task,
      title: name == current['name'] ? null : name,
      prompt: prompt == current['prompt'] ? null : prompt,
      freq: timingChanged ? freq : null,
      time: timingChanged ? time : null,
      days: timingChanged ? days : null,
      everyMinutes: timingChanged ? every : null,
    );
    return lomPhoneScheduleJson(updated);
  }

  /// `schedule.delete`: a missing task still answers `deleted`; a
  /// revision mismatch is `sync.conflict`.
  Future<Map<String, Object?>> _delete(
    Map<String, dynamic> payload,
  ) async {
    final id = _string(payload, 'id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,80}$').hasMatch(id)) {
      throw LomRpcException('schedule.invalid_id');
    }
    final revision = _string(payload, 'revision');
    final task = await _findTask(id);
    if (task == null) return {'status': 'deleted'};
    if (revision.isNotEmpty &&
        revision != lomPhoneScheduleJson(task)['revision']) {
      throw LomRpcException('sync.conflict');
    }
    await engine.deleteScheduleTask(task);
    return {'status': 'deleted'};
  }

  /// `schedule.run`: the dispatching receipt is persisted **before** the
  /// task starts; the same `request_id` replays the stored receipt and
  /// never starts the task twice. A failure after the receipt was
  /// written leaves it `dispatching` and answers an error code outside
  /// the "definitely not executed" whitelist, so the desktop treats the
  /// outcome as unknown instead of assuming the task did not run.
  Future<Map<String, Object?>> _run(
    Map<String, dynamic> payload,
  ) async {
    final id = _string(payload, 'id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,80}$').hasMatch(id)) {
      throw LomRpcException('schedule.invalid_id');
    }
    final requestId = _string(payload, 'request_id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,64}$').hasMatch(requestId)) {
      throw LomRpcException('schedule.invalid_request');
    }
    final key = 'schedule.run:$requestId';
    final contentHash =
        crypto.sha256.convert(utf8.encode(id)).toString();
    final existing = await receipts.receiptFor(key);
    if (existing != null) {
      if (existing.contentHash != contentHash) {
        throw LomRpcException('schedule.id_reused');
      }
      // A `failed` receipt means the run definitely never started, so a
      // retry may execute; anything else replays the stored outcome.
      if (existing.status != 'failed') {
        return {
          'id': id,
          'status': existing.status,
          'session_id': existing.sessionId,
        };
      }
    }
    final task = await _findTask(id);
    if (task == null) throw LomRpcException('schedule.missing');
    if (!task.usesTargetProtocol && task.sessionId == null) {
      // Nowhere to run it: definitely not executed.
      throw LomRpcException('schedule.dispatch_failed');
    }
    await receipts.saveReceipt(
      LomOperationReceipt(
        key: key,
        contentHash: contentHash,
        status: 'dispatching',
        sessionId: task.sessionId ?? '',
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
    try {
      await engine.runScheduleTask(task);
    } catch (_) {
      throw LomRpcException('remote.operation_failed');
    }
    await receipts.saveReceipt(
      LomOperationReceipt(
        key: key,
        contentHash: contentHash,
        status: 'accepted',
        sessionId: task.sessionId ?? '',
        updatedAtMs: _now().millisecondsSinceEpoch,
      ),
    );
    return {
      'id': id,
      'status': 'accepted',
      'session_id': task.sessionId ?? '',
    };
  }

  Future<LomSchedule?> _findTask(String id) async {
    final tasks = await engine.scheduleCatalog();
    for (final task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  bool _sameContent(
    Map<String, Object?> current,
    String name,
    String prompt,
    String freq,
    String time,
    List<int> days,
    int? every,
    String enabled,
    String sessionId,
  ) =>
      name == current['name'] &&
      prompt == current['prompt'] &&
      freq == current['freq'] &&
      time == current['time'] &&
      jsonEncode(days) == current['days'] &&
      '${every ?? ''}' == current['every'] &&
      enabled == current['enabled'] &&
      sessionId == current['session_id'];

  void _validateTiming(
    String freq,
    String time,
    List<int> days,
    int? every,
    String enabled,
  ) {
    switch (freq) {
      case 'once':
        final match =
            RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$')
                .firstMatch(time);
        final at = match == null ? null : DateTime.tryParse(time);
        if (at == null) throw LomRpcException('schedule.invalid_time');
        if (enabled != 'false' && at.isBefore(_now())) {
          throw LomRpcException('schedule.time_in_past');
        }
      case 'daily':
      case 'weekly':
        if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
          throw LomRpcException('schedule.invalid_time');
        }
        if (freq == 'weekly' &&
            (days.isEmpty || days.any((d) => d < 1 || d > 7))) {
          throw LomRpcException('schedule.invalid_days');
        }
      case 'interval':
        if (every == null || every < 1 || every > 525600) {
          throw LomRpcException('schedule.invalid_interval');
        }
    }
  }

  List<int> _days(Map<String, dynamic> payload) {
    final raw = _string(payload, 'days');
    if (raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('days');
      return [
        for (final d in decoded)
          if (d is int) d else throw const FormatException('days'),
      ];
    } on FormatException {
      throw LomRpcException('schedule.invalid_days');
    }
  }

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }
}
