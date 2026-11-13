/// Maps a DSH schedule to a Lom `PhoneSchedule` (doc §07 §10).
///
/// All fields are strings; `items` itself is JSON text. `editable` is
/// `"false"`: the write side (`schedule.save` / `toggle` / `delete` /
/// `run`) is Phase 4, so the desktop must not offer editing.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import 'engine.dart';

/// Maps one DSH schedule to a `PhoneSchedule` JSON object.
Map<String, Object?> lomPhoneScheduleJson(LomSchedule task) {
  final freq = switch (task.kind) {
    'at' => 'once',
    'daily' => 'daily',
    'weekly' => 'weekly',
    'every' => 'interval',
    _ => 'custom',
  };
  final time = switch (task.kind) {
    'at' => task.scheduledAtMs == null
        ? ''
        : _formatOnceTime(task.scheduledAtMs!),
    'daily' || 'weekly' => _hhmm(task.time),
    _ => '',
  };
  final every = task.kind == 'every' && task.everySeconds != null
      ? '${max(1, task.everySeconds! ~/ 60)}'
      : '';
  final next = task.scheduledAtMs != null &&
          task.scheduledAtMs! >
              DateTime.now().millisecondsSinceEpoch
      ? '${task.scheduledAtMs!}'
      : '';
  return {
    'id': task.id,
    'revision': crypto.sha256.convert(utf8.encode(task.recordJson)).toString(),
    'name': task.title,
    'prompt': task.prompt,
    'freq': freq,
    'time': time,
    'days': task.kind == 'weekly' ? jsonEncode(task.weekdays) : '[]',
    'every': every,
    'enabled': task.active ? 'true' : 'false',
    'session_id': task.sessionId ?? '',
    'next': next,
    'last': task.lastDeliveredAtMs == null
        ? ''
        : '${task.lastDeliveredAtMs!}',
    'runs': '[]',
    'editable': 'false',
  };
}

String _hhmm(String? time) {
  if (time == null) return '';
  final match = RegExp(r'^(\d{2}):(\d{2})').firstMatch(time);
  return match == null ? '' : '${match.group(1)}:${match.group(2)}';
}

/// One-shot wall time in the phone's local zone: `yyyy-MM-ddTHH:mm`.
String _formatOnceTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}';
}
