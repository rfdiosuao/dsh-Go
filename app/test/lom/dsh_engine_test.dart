import 'package:dsh_app/lom/dsh_engine.dart';
import 'package:dsh_app/lom/schedule_mapping.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

Message _userMessage(String id, String text, {String sourceKind = 'user'}) =>
    Message(
      id: id,
      role: MessageRole.user,
      parts: [TextPart(text)],
      source: MessageSource(sourceKind, const {}),
    );

Message _assistantMessage(String id, List<Part> parts) => Message(
      id: id,
      role: MessageRole.assistant,
      parts: parts,
      source: const MessageSource('model', {}),
    );

DateTime _t(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

void main() {
  group('lomMessagesFromEvents', () {
    test('human messages in order, injected context skipped', () {
      final result = lomMessagesFromEvents([
        UserMessageEvent(1, _t(1000), const {}, message: _userMessage('u1', 'hi')),
        UserMessageEvent(
          2,
          _t(1001),
          const {},
          message: _userMessage('u2', 'reminder text', sourceKind: 'reminder'),
        ),
        AssistantMessageEvent(
          3,
          _t(1002),
          const {},
          turn: 1,
          step: 1,
          message: _assistantMessage('a1', [const TextPart('hello')]),
        ),
      ]);
      expect(result.messages.map((m) => m.id), ['u1', 'a1']);
      expect(result.messages[1].role, 'assistant');
      expect(result.messages[1].text, 'hello');
      expect(result.turnStatus, isNull);
    });

    test('reasoning parts are never emitted', () {
      final result = lomMessagesFromEvents([
        AssistantMessageEvent(
          1,
          _t(1000),
          const {},
          turn: 1,
          step: 1,
          message: _assistantMessage('a1', [
            const ReasoningPart('secret thinking'),
            const TextPart('answer'),
          ]),
        ),
      ]);
      expect(result.messages.single.text, 'answer');
      expect(result.messages.single.blocks.length, 1);
      expect(result.messages.single.blocks.single.kind, 'text');
    });

    test('tool calls attach as tool_use blocks and results resolve them',
        () async {
      final result = lomMessagesFromEvents([
        AssistantMessageEvent(
          1,
          _t(1000),
          const {},
          turn: 1,
          step: 1,
          message: _assistantMessage('a1', [const TextPart('working')]),
        ),
        ToolCallEvent(
          2,
          _t(1001),
          const {},
          turn: 1,
          step: 1,
          callId: 'call-1',
          name: 'read_file',
          arguments: '{"path":"x"}',
        ),
        ToolResultEvent(
          3,
          _t(1002),
          const {},
          turn: 1,
          step: 1,
          message: Message(
            id: 't1',
            role: MessageRole.tool,
            parts: const [TextPart('file contents')],
            source: const MessageSource('tool', {}),
            toolCallId: 'call-1',
          ),
        ),
        TurnEndedEvent(
          4,
          _t(1003),
          const {},
          turn: 1,
          reason: const TurnEndReason('completed'),
        ),
      ]);
      final blocks = result.messages.single.blocks;
      expect(blocks.length, 2);
      expect(blocks[1].kind, 'tool_use');
      expect(blocks[1].title, 'read_file');
      expect(blocks[1].status, 'SUCCESS');
      expect(blocks[1].text, 'file contents');
      expect(result.turnStatus, 'completed');
      expect(result.turnSeq, 4);
    });

    test('turn outcomes map to chat.read statuses', () {
      String? statusFor(String kind) => lomMessagesFromEvents([
            TurnEndedEvent(
              1,
              _t(1000),
              const {},
              turn: 1,
              reason: TurnEndReason(kind),
            ),
          ]).turnStatus;
      expect(statusFor('completed'), 'completed');
      expect(statusFor('aborted'), 'cancelled');
      expect(statusFor('error'), 'failed');
      expect(statusFor('interrupted'), 'interrupted');
      expect(statusFor('max-tokens'), 'failed');
      expect(statusFor('forked'), isNull);
    });

    test('image/file parts become attachments with refs, not blocks', () {
      final result = lomMessagesFromEvents([
        AssistantMessageEvent(
          1,
          _t(1000),
          const {},
          turn: 1,
          step: 1,
          message: _assistantMessage('a1', [
            const TextPart('see this'),
            ImagePart(
              const ImageAttachment(
                attachmentId: 'img-1',
                mediaType: 'image/png',
                name: 'shot.png',
              ),
            ),
            const FilePart(
              FileAttachment(attachmentId: 'file-1', name: 'doc.pdf'),
            ),
            // No id: named nowhere, fetchable nowhere — dropped.
            const FilePart(FileAttachment(name: 'orphan.txt')),
          ]),
        ),
      ]);
      expect(result.messages.length, 1);
      final message = result.messages.single;
      expect(message.attachments, ['shot.png', 'doc.pdf']);
      expect(message.attachmentRefs.length, 2);
      expect(message.attachmentRefs[0].id, 'img-1');
      expect(message.attachmentRefs[0].kind, 'image');
      expect(message.attachmentRefs[1].id, 'file-1');
      expect(message.attachmentRefs[1].kind, 'file');
      expect(message.blocks.length, 1);
      expect(message.blocks.single.kind, 'text');
    });

    test('empty message ids fall back to seq ids', () {
      final result = lomMessagesFromEvents([
        UserMessageEvent(
          7,
          _t(1000),
          const {},
          message: _userMessage('', 'hi'),
        ),
      ]);
      expect(result.messages.single.id, 'seq-7');
    });
  });

  group('lomScheduleFromTask + lomPhoneScheduleJson', () {
    test('daily / weekly / interval / once / custom mapping', () {
      final daily = lomScheduleFromTask(
        ScheduleTask.fromJson({
          'id': 'task-daily',
          'sessionId': 's1',
          'kind': 'daily',
          'title': '晨报',
          'prompt': '汇报',
          'status': 'active',
          'time': '08:30',
          'timeZone': 'Asia/Shanghai',
          'weekdays': [],
        })!,
      );
      final dailyJson = lomPhoneScheduleJson(daily);
      expect(dailyJson['freq'], 'daily');
      expect(dailyJson['time'], '08:30');
      expect(dailyJson['enabled'], 'true');
      expect(dailyJson['session_id'], 's1');
      expect(dailyJson['editable'], 'false');

      final weekly = lomPhoneScheduleJson(
        lomScheduleFromTask(
          ScheduleTask.fromJson({
            'id': 'task-weekly',
            'sessionId': 's1',
            'kind': 'weekly',
            'title': '周报',
            'prompt': '总结',
            'status': 'active',
            'time': '09:00',
            'timeZone': 'Asia/Shanghai',
            'weekdays': [1, 3, 5],
          })!,
        ),
      );
      expect(weekly['freq'], 'weekly');
      expect(weekly['days'], '[1,3,5]');

      final interval = lomPhoneScheduleJson(
        lomScheduleFromTask(
          ScheduleTask.fromJson({
            'id': 'task-interval',
            'sessionId': 's1',
            'kind': 'every',
            'title': '巡检',
            'prompt': '检查',
            'status': 'inactive',
            'everySeconds': 5400,
          })!,
        ),
      );
      expect(interval['freq'], 'interval');
      expect(interval['every'], '90');
      expect(interval['enabled'], 'false');

      final once = lomPhoneScheduleJson(
        lomScheduleFromTask(
          ScheduleTask.fromJson({
            'id': 'task-once',
            'sessionId': 's1',
            'kind': 'at',
            'title': '提醒',
            'prompt': '开会',
            'status': 'active',
            'scheduledAt': '2030-01-02T03:04:05.000Z',
          })!,
        ),
      );
      expect(once['freq'], 'once');
      expect(once['time'], startsWith('2030-01-02T'));

      final cron = lomPhoneScheduleJson(
        lomScheduleFromTask(
          ScheduleTask.fromJson({
            'id': 'task-cron',
            'sessionId': 's1',
            'kind': 'cron',
            'title': '复杂',
            'prompt': '跑',
            'status': 'active',
            'expression': '0 9 * * 1',
          })!,
        ),
      );
      expect(cron['freq'], 'custom');
    });

    test('revision is the SHA-256 of the stored record', () {
      final task = lomScheduleFromTask(
        ScheduleTask.fromJson({
          'id': 'task-1',
          'sessionId': 's1',
          'kind': 'daily',
          'title': 't',
          'prompt': 'p',
          'status': 'active',
          'time': '08:30',
        })!,
      );
      final json = lomPhoneScheduleJson(task);
      expect(json['revision'], isNotEmpty);
      expect(
        lomPhoneScheduleJson(task)['revision'],
        json['revision'],
        reason: 'same record, same revision',
      );
    });
  });
}
