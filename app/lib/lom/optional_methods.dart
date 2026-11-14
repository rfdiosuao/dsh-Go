/// Lom RPC Phase 4 (optional methods), doc §07.
///
/// The required methods live in `rpc_dispatcher.dart`; the optional ones
/// live here so the dispatcher (already ~770 lines) does not keep growing.
/// Each method is only dispatched — and only listed by
/// `device.capabilities` — when this object actually provides it, via
/// [availableMethods]. A method with no honest implementation behind it
/// stays `remote.method_unknown` instead of faking a result.
///
/// Phase 4 groups, in value order (see `dsh-go-gap-20261114.md` §3):
/// 1. `chat.rename` / `chat.pin` / `chat.delete` — this file.
/// 2. `device.status` / `device.rename` — this file.
/// 3. `file.*` — `file_store.dart` (later PR).
/// 4. `screen.*` — `screen_adapter.dart` (later PR; native bridge pending).
/// 5. `schedule.*` write side — `schedule_write.dart` (later PR).
/// 6. `skills.*` — `skills_store.dart` (later PR).
/// 7. `subagent.*` — verified unmappable (see report); stays unknown.
/// 8. `chat.file` / `chat.image` — `file_handlers.dart` (later PR).
/// 9. `apps.list` — `apps_adapter.dart` (later PR; native bridge pending).
library;

import 'engine.dart';
import 'file_store.dart';
import 'phase4_store.dart';
import 'rpc_errors.dart';
import 'schedule_write.dart';
import 'skills.dart';

/// Optional-method handlers. Constructed once per relay session in
/// `lom_relay_service.dart` and passed to [LomRpcDispatcher].
class LomOptionalMethods {
  LomOptionalMethods({
    required this.engine,
    required this.pins,
    required this.deviceNames,
    this.files,
    this.scheduleWrite,
    this.skills,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LomEngine engine;
  final LomPinStore pins;
  final LomDeviceNameStore deviceNames;

  /// `file.*` store, or null when file transfer is not wired (then the
  /// `file.*` methods stay `remote.method_unknown` and `chat.send` keeps
  /// refusing attachments).
  final LomFileStore? files;

  /// Schedule write side, or null when it is not wired.
  /// `schedule.toggle` is never listed: there is no toggle API to back
  /// it (see `schedule_write.dart`).
  final LomScheduleWriteHandler? scheduleWrite;

  /// Skill registry, or null when it is not wired.
  final LomSkillRegistry? skills;

  final DateTime Function() _now;

  /// Methods this phone actually implements, beyond the Phase 2/3 base
  /// set. `device.capabilities` is generated from this set, so the two
  /// can never drift apart.
  Set<String> get availableMethods => {
        'chat.rename',
        'chat.pin',
        'chat.delete',
        'device.status',
        'device.rename',
        if (files != null) ...[
          'file.begin',
          'file.chunk',
          'file.finish',
          'file.read',
          'file.list',
          'file.delete',
          'file.save_gallery',
          'chat.file',
          'chat.image',
        ],
        if (scheduleWrite != null) ...[
          'schedule.save',
          'schedule.delete',
          'schedule.run',
        ],
        if (skills != null) ...[
          'skills.list',
          'skills.read',
          'skills.install',
          'skills.toggle',
          'skills.delete',
        ],
      };

  /// Pinned session ids, for the `chat.list` overlay (the engine has no
  /// pin concept, so `pinned` comes from here).
  Future<Set<String>> pinnedIds() => pins.pinnedIds();

  /// Handles one optional method. [sender] is the requesting desktop's
  /// public key `K` (per-desktop isolation for file/skill state; unused
  /// by the chat/device methods).
  Future<Map<String, Object?>> handle(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'chat.rename':
        return _chatRename(payload);
      case 'chat.pin':
        return _chatPin(payload);
      case 'chat.delete':
        return _chatDelete(payload);
      case 'device.status':
        return _deviceStatus();
      case 'device.rename':
        return _deviceRename(payload);
      case 'file.begin':
      case 'file.chunk':
      case 'file.finish':
      case 'file.read':
      case 'file.list':
      case 'file.delete':
      case 'file.save_gallery':
        final store = files;
        if (store == null) throw LomRpcException('remote.method_unknown');
        return store.handle(method, payload, sender);
      case 'schedule.save':
      case 'schedule.delete':
      case 'schedule.run':
        final writer = scheduleWrite;
        if (writer == null) throw LomRpcException('remote.method_unknown');
        return writer.handle(method, payload, sender);
      case 'skills.list':
      case 'skills.read':
      case 'skills.install':
      case 'skills.toggle':
      case 'skills.delete':
        final registry = skills;
        if (registry == null) throw LomRpcException('remote.method_unknown');
        return registry.handle(method, payload, sender);
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  // ------------------------------------------------------------------ chat

  /// `chat.rename` (doc §07 §4): `title` trimmed to 1–200 chars.
  Future<Map<String, Object?>> _chatRename(
    Map<String, dynamic> payload,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    final title = _string(payload, 'title').trim();
    if (title.isEmpty || title.length > 200) {
      throw LomRpcException('chat.invalid_title');
    }
    if (!await engine.sessionExists(sessionId)) {
      throw LomRpcException('chat.session_missing');
    }
    await engine.renameSession(sessionId, title);
    return {'status': 'saved', 'session_id': sessionId};
  }

  /// `chat.pin` (doc §07 §4): `pinned` is a JSON boolean. Pinning is a
  /// Lom-side overlay only — it never archives the session.
  Future<Map<String, Object?>> _chatPin(
    Map<String, dynamic> payload,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    final pinned = payload['pinned'];
    if (pinned is! bool) throw LomRpcException('remote.operation_failed');
    if (!await engine.sessionExists(sessionId)) {
      throw LomRpcException('chat.session_missing');
    }
    await pins.setPinned(sessionId, pinned);
    return {'status': 'saved', 'session_id': sessionId};
  }

  /// `chat.delete` (doc §07 §4): a missing session still answers
  /// `deleted`; a running session is refused with `chat.busy`. The
  /// dispatcher drops the deleted session from its history cache.
  Future<Map<String, Object?>> _chatDelete(
    Map<String, dynamic> payload,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    if (!await engine.sessionExists(sessionId)) {
      return {'status': 'deleted'};
    }
    if (await engine.sessionRunning(sessionId)) {
      throw LomRpcException('chat.busy');
    }
    await engine.deleteSession(sessionId);
    await pins.setPinned(sessionId, false);
    return {'status': 'deleted'};
  }

  // ---------------------------------------------------------------- device

  /// `device.status` (doc §07 §6): `battery` is `""` — no battery-level
  /// source exists in this app (verified: no battery API in `app/lib`,
  /// `DiagnosticsPlugin`, or `pubspec.yaml`), and the doc forbids
  /// inventing a number. `network` comes from the engine.
  Future<Map<String, Object?>> _deviceStatus() async => {
        'battery': '',
        'network': await engine.deviceNetwork(),
        'sampled_at': '${_now().millisecondsSinceEpoch}',
      };

  /// `device.rename` (doc §07 §6): the reply echoes the requested name
  /// verbatim, so an unacceptable name errors instead of being silently
  /// rewritten. Empty or over-200-char names are rejected.
  Future<Map<String, Object?>> _deviceRename(
    Map<String, dynamic> payload,
  ) async {
    final name = _string(payload, 'name');
    if (name.isEmpty || name.length > 200) {
      throw LomRpcException('remote.operation_failed');
    }
    await deviceNames.save(name, _now().millisecondsSinceEpoch);
    return {'name': name};
  }

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }
}
