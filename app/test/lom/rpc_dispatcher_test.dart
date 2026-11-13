import 'dart:convert';

import 'package:dsh_app/lom/lom_phone.dart';
import 'package:flutter_test/flutter_test.dart';

class _MapStore implements LomSecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeSession {
  bool running = false;
  bool neverStops = false;
  List<LomChatMessage> messages = [];
  String? turnStatus;
  String turnError = '';
  int cursor = 0;
}

class _FakeEngine implements LomEngine {
  bool ready = true;
  int createCount = 0;
  int promptCount = 0;
  int cancelCount = 0;
  bool throwOnList = false;
  LomChatReceiptStore? receipts;
  ({String route, String api, String baseUrl, String keyRef, String model})?
      appliedModel;
  final sessions = <String, _FakeSession>{};
  List<LomSessionSummary> summaries = [];
  List<LomSchedule> schedules = [];
  String timezone = 'Asia/Shanghai';

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<void> applyModelConfig({
    required String route,
    required String api,
    required String baseUrl,
    required String keyRef,
    required String apiKey,
    required String model,
  }) async {
    appliedModel = (
      route: route,
      api: api,
      baseUrl: baseUrl,
      keyRef: keyRef,
      model: model,
    );
  }

  @override
  Future<String> createSession() async {
    createCount++;
    final id = 's-new-$createCount';
    sessions[id] = _FakeSession();
    return id;
  }

  @override
  Future<bool> sessionExists(String sessionId) async =>
      sessions.containsKey(sessionId);

  @override
  Future<bool> sessionRunning(String sessionId) async {
    final s = sessions[sessionId];
    if (s == null) throw LomEngineException('chat.session_missing');
    return s.running;
  }

  @override
  Future<int> sessionCursor(String sessionId) async {
    final s = sessions[sessionId];
    if (s == null) throw LomEngineException('chat.session_missing');
    return s.cursor;
  }

  @override
  Future<LomHistoryPage> readHistory(
    String sessionId, {
    int? throughSeq,
    int? beforeSeq,
    int maxMessages = 500,
  }) async {
    final s = sessions[sessionId];
    if (s == null) throw LomEngineException('chat.session_missing');
    return LomHistoryPage(
      messages: s.messages,
      turnStatus: s.turnStatus,
      turnError: s.turnError,
      turnSeq: s.turnStatus == null ? -1 : 1,
      cursor: s.cursor,
      hasMore: false,
      oldestSeq: s.messages.isEmpty ? -1 : s.messages.first.seq,
    );
  }

  @override
  Future<List<LomSessionSummary>> listSessions() async {
    if (throwOnList) throw StateError('boom /etc/passwd secret');
    return summaries;
  }

  @override
  Future<void> selectModel(
    String sessionId, {
    required String provider,
    required String model,
  }) async {}

  @override
  Future<void> promptSession(
    String sessionId,
    String text, {
    required String requestId,
  }) async {
    promptCount++;
    // The receipt must already be persisted when the engine is invoked.
    final receipt = await receipts?.receiptFor(requestId);
    assert(receipt != null, 'receipt must be persisted before prompt');
    sessions[sessionId]?.running = true;
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    cancelCount++;
    final s = sessions[sessionId];
    if (s != null && !s.neverStops) s.running = false;
  }

  @override
  Future<List<LomSchedule>> scheduleCatalog() async => schedules;

  @override
  Future<String> systemTimeZone() async => timezone;
}

class _Harness {
  static const nowMs = 1767222000000;

  late final LomIdentity phone;
  late final LomIdentity desktop;
  late final _MapStore store;
  late final _FakeEngine engine;
  late final LomRpcDispatcher dispatcher;
  late final LomChatReceiptStore receipts;
  final trusted = <String>{};
  var _ids = 0;

  Future<void> init() async {
    phone = await LomIdentity.generate();
    desktop = await LomIdentity.generate();
    trusted.add(desktop.keys);
    store = _MapStore();
    engine = _FakeEngine();
    receipts = LomChatReceiptStore(store);
    engine.receipts = receipts;
    dispatcher = LomRpcDispatcher(
      identity: phone,
      trustedSenders: () => trusted,
      replay: LomReplayStore(store),
      modelConfigs: LomModelConfigStore(store),
      receipts: receipts,
      engine: engine,
      now: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      cancelWait: const Duration(milliseconds: 100),
    );
  }

  String _nextId() => (++_ids).toRadixString(16).padLeft(32, '0');

  Future<Map<String, dynamic>?> call(
    String method,
    Map<String, Object?> payload, {
    String? id,
    int? issuedAt,
    LomIdentity? sender,
  }) async {
    final env = await sealEnvelope(
      plaintext: utf8.encode(
        jsonEncode({
          'method': method,
          'payload': jsonEncode(payload),
          'issued_at': (issuedAt ?? nowMs).toString(),
        }),
      ),
      id: id ?? _nextId(),
      senderIdentity: sender ?? desktop,
      recipientKeys: phone.keys,
    );
    return dispatcher.handleEnvelope(env.toJson());
  }

  /// Opens a reply envelope and returns (status, payload, error).
  Future<(String, Map<String, dynamic>, String)> reply(
    Map<String, dynamic>? envJson,
  ) async {
    expect(envJson, isNotNull, reason: 'expected a reply envelope');
    final env = LomEnvelope.fromJson(envJson!);
    final plain = await openEnvelope(
      envelope: env,
      ownIdentity: desktop,
      trustedSenders: {phone.keys},
    );
    final decoded = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return (
      decoded['status'] as String,
      jsonDecode(decoded['payload'] as String) as Map<String, dynamic>,
      decoded['error'] as String,
    );
  }

  Future<(String, Map<String, dynamic>, String)> syncModel({
    String platform = 'openai',
    String revision = '100',
    String baseUrl = 'https://api.example.com/',
    String apiKey = 'sk-test-key',
    String model = 'gpt-5',
  }) async {
    final env = await call('model.sync', {
      'base_url': baseUrl,
      'api_key': apiKey,
      'model': model,
      'platform': platform,
      'revision': revision,
    });
    return reply(env);
  }
}

void main() {
  group('envelope + dispatch (Phase 2)', () {
    test('unknown method returns remote.method_unknown', () async {
      final h = _Harness();
      await h.init();
      final (status, payload, error) =
          await h.reply(await h.call('screen.capture', {}));
      expect(status, 'error');
      expect(payload, {});
      expect(error, 'remote.method_unknown');
    });

    test('tampered signature gets no reply', () async {
      final h = _Harness();
      await h.init();
      final env = await sealEnvelope(
        plaintext: utf8.encode(
          jsonEncode({
            'method': 'device.capabilities',
            'payload': '{}',
            'issued_at': _Harness.nowMs.toString(),
          }),
        ),
        id: 'b' * 32,
        senderIdentity: h.desktop,
        recipientKeys: h.phone.keys,
      );
      final json = env.toJson();
      final sig = json['signature'] as String;
      json['signature'] = (sig[0] == 'A' ? 'B' : 'A') + sig.substring(1);
      expect(await h.dispatcher.handleEnvelope(json), isNull);
    });

    test('expired request is rejected and NOT registered for replay',
        () async {
      final h = _Harness();
      await h.init();
      final id = 'c' * 32;
      final (_, _, error) = await h.reply(
        await h.call(
          'device.capabilities',
          {},
          id: id,
          issuedAt: _Harness.nowMs - 300001,
        ),
      );
      expect(error, 'remote.expired');
      // Same id with a fresh timestamp must not be treated as a replay.
      final (status, _, err2) = await h.reply(
        await h.call('device.capabilities', {}, id: id),
      );
      expect(status, 'ok');
      expect(err2, '');
    });

    test('replayed envelope id returns remote.replayed', () async {
      final h = _Harness();
      await h.init();
      final id = 'd' * 32;
      final (status, _, _) =
          await h.reply(await h.call('device.capabilities', {}, id: id));
      expect(status, 'ok');
      final (_, _, error) = await h.reply(
        await h.call('device.capabilities', {}, id: id),
      );
      expect(error, 'remote.replayed');
    });

    test('engine not ready returns remote.not_ready', () async {
      final h = _Harness();
      await h.init();
      h.engine.ready = false;
      final (_, _, error) =
          await h.reply(await h.call('device.capabilities', {}));
      expect(error, 'remote.not_ready');
    });

    test('sender revoked between open and dispatch returns remote.revoked',
        () async {
      final h = _Harness();
      await h.init();
      var calls = 0;
      final dispatcher = LomRpcDispatcher(
        identity: h.phone,
        trustedSenders: () => (++calls == 1) ? {h.desktop.keys} : <String>{},
        replay: LomReplayStore(h.store),
        modelConfigs: LomModelConfigStore(h.store),
        receipts: LomChatReceiptStore(h.store),
        engine: h.engine,
        now: () => DateTime.fromMillisecondsSinceEpoch(_Harness.nowMs),
      );
      final env = await sealEnvelope(
        plaintext: utf8.encode(
          jsonEncode({
            'method': 'device.capabilities',
            'payload': '{}',
            'issued_at': _Harness.nowMs.toString(),
          }),
        ),
        id: 'e' * 32,
        senderIdentity: h.desktop,
        recipientKeys: h.phone.keys,
      );
      final (_, _, error) =
          await h.reply(await dispatcher.handleEnvelope(env.toJson()));
      expect(error, 'remote.revoked');
    });

    test('device.capabilities is generated from the dispatch table',
        () async {
      final h = _Harness();
      await h.init();
      final (status, payload, _) =
          await h.reply(await h.call('device.capabilities', {}));
      expect(status, 'ok');
      expect(payload['version'], 1);
      final methods = (payload['methods'] as List).cast<String>();
      expect(
        methods,
        containsAll([
          'device.capabilities',
          'model.sync',
          'chat.send',
          'chat.read',
          'chat.list',
          'chat.cancel',
          'document.list',
          'document.read',
          'schedule.list',
        ]),
      );
    });

    test('engine exceptions never leak text into the error code', () async {
      final h = _Harness();
      await h.init();
      h.engine.throwOnList = true;
      final (status, _, error) =
          await h.reply(await h.call('chat.list', {'offset': 0}));
      expect(status, 'error');
      expect(error, 'remote.operation_failed');
    });
  });

  group('model.sync (Phase 3)', () {
    test('openai config is applied and persisted without the api key',
        () async {
      final h = _Harness();
      await h.init();
      final (status, payload, error) = await h.syncModel();
      expect(status, 'ok');
      expect(error, '');
      expect(payload, {
        'status': 'saved',
        'model': 'gpt-5',
        'revision': '100',
      });
      expect(h.engine.appliedModel?.api, 'openai-completions');
      expect(h.engine.appliedModel?.baseUrl, 'https://api.example.com');
      expect(h.engine.appliedModel?.route, startsWith('lom-'));
      // The key itself must never land in the Lom store.
      expect(h.store.values.values.join(), isNot(contains('sk-test-key')));
    });

    test('gemini is honestly unsupported', () async {
      final h = _Harness();
      await h.init();
      final (_, _, error) = await h.syncModel(platform: 'gemini');
      expect(error, 'model.unsupported_protocol');
      expect(h.engine.appliedModel, isNull);
    });

    test('http base_url is rejected', () async {
      final h = _Harness();
      await h.init();
      final (_, _, error) = await h.syncModel(
        baseUrl: 'http://api.example.com/',
      );
      expect(error, 'model.invalid_url');
    });

    test('stale revision is rejected, equal revision accepted', () async {
      final h = _Harness();
      await h.init();
      await h.syncModel(revision: '100');
      final (_, _, error) = await h.syncModel(revision: '50');
      expect(error, 'model.stale_revision');
      final (status, _, _) = await h.syncModel(revision: '100');
      expect(status, 'ok');
    });
  });

  group('chat.send (Phase 3)', () {
    test('new session: receipt first, then prompt, returns accepted',
        () async {
      final h = _Harness();
      await h.init();
      await h.syncModel();
      final (status, payload, error) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000001',
          'session_id': '',
          'text': 'hello',
        }),
      );
      expect(status, 'ok');
      expect(error, '');
      expect(payload['status'], 'accepted');
      expect(payload['session_id'], 's-new-1');
      expect(h.engine.promptCount, 1);
      expect(
        (await h.receipts.receiptFor('client-00000000001'))?.status,
        'accepted',
      );
    });

    test('same client_id + content returns the original receipt', () async {
      final h = _Harness();
      await h.init();
      await h.syncModel();
      const payload = {
        'client_id': 'client-00000000002',
        'session_id': '',
        'text': 'hello',
      };
      await h.reply(await h.call('chat.send', payload));
      final (status, result, _) =
          await h.reply(await h.call('chat.send', payload));
      expect(status, 'ok');
      expect(result['session_id'], 's-new-1');
      expect(h.engine.promptCount, 1);
      expect(h.engine.createCount, 1);
    });

    test('same client_id + different content is chat.id_reused', () async {
      final h = _Harness();
      await h.init();
      await h.syncModel();
      await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000003',
          'session_id': '',
          'text': 'hello',
        }),
      );
      final (_, _, error) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000003',
          'session_id': '',
          'text': 'different',
        }),
      );
      expect(error, 'chat.id_reused');
      expect(h.engine.promptCount, 1);
    });

    test('busy session, missing model and missing session', () async {
      final h = _Harness();
      await h.init();
      await h.syncModel();
      h.engine.sessions['s1'] = _FakeSession()..running = true;
      final (_, _, busy) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000004',
          'session_id': 's1',
          'text': 'hi',
        }),
      );
      expect(busy, 'chat.busy');
      final (_, _, missing) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000005',
          'session_id': 'nope',
          'text': 'hi',
        }),
      );
      expect(missing, 'chat.session_missing');
    });

    test('model_missing leaves no session behind', () async {
      final h = _Harness();
      await h.init();
      final (_, _, error) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000006',
          'session_id': '',
          'text': 'hi',
        }),
      );
      expect(error, 'chat.model_missing');
      expect(h.engine.createCount, 0);
    });

    test('invalid client_id and empty text', () async {
      final h = _Harness();
      await h.init();
      await h.syncModel();
      final (_, _, e1) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'short',
          'session_id': '',
          'text': 'hi',
        }),
      );
      expect(e1, 'chat.invalid_id');
      final (_, _, e2) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'client-00000000007',
          'session_id': '',
          'text': '   ',
        }),
      );
      expect(e2, 'chat.invalid_text');
    });
  });

  group('chat.read / list / cancel (Phase 3)', () {
    _FakeSession seededMessages() {
      final s = _FakeSession()
        ..turnStatus = 'completed'
        ..cursor = 5;
      s.messages = [
        for (var i = 1; i <= 5; i++)
          LomChatMessage(
            id: 'm$i',
            role: i.isOdd ? 'user' : 'assistant',
            text: 'message $i',
            at: 1000 + i,
            seq: i,
          ),
      ];
      return s;
    }

    test('chat.read pages oldest-first with a progressing next', () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = seededMessages();
      final (_, page0, _) = await h.reply(
        await h.call('chat.read', {'session_id': 's1', 'offset': 0}),
      );
      expect(page0['total'], 5);
      expect(page0['next'], 5);
      expect(page0['running'], false);
      expect(page0['status'], 'completed');
      expect((page0['items'] as List).first['id'], 'm1');
      final (_, page4, _) = await h.reply(
        await h.call('chat.read', {'session_id': 's1', 'offset': 4}),
      );
      expect((page4['items'] as List).length, 1);
      expect(page4['next'], 5);
      final (_, page5, _) = await h.reply(
        await h.call('chat.read', {'session_id': 's1', 'offset': 5}),
      );
      expect((page5['items'] as List), isEmpty);
      expect(page5['next'], 5);
      // The observed outcome is persisted for later reads.
      expect((await h.receipts.sessionState('s1'))?.status, 'completed');
    });

    test('chat.read on a missing session', () async {
      final h = _Harness();
      await h.init();
      final (_, _, error) = await h.reply(
        await h.call('chat.read', {'session_id': 'nope', 'offset': 0}),
      );
      expect(error, 'chat.session_missing');
    });

    test('chat.list pages newest-first', () async {
      final h = _Harness();
      await h.init();
      h.engine.summaries = [
        const LomSessionSummary(
          id: 's2',
          title: 'Second',
          updatedMs: 2000,
          pinned: false,
          running: true,
          model: 'gpt-5',
        ),
        const LomSessionSummary(
          id: 's1',
          title: '',
          updatedMs: 1000,
          pinned: false,
          running: false,
          model: '',
        ),
      ];
      final (_, page0, _) = await h.reply(
        await h.call('chat.list', {'offset': 0}),
      );
      expect(page0['total'], 2);
      expect((page0['items'] as List).first['id'], 's2');
      expect((page0['items'] as List).last['title'], '新的会话');
      final (_, page1, _) = await h.reply(
        await h.call('chat.list', {'offset': 1}),
      );
      expect((page1['items'] as List).length, 1);
      expect(page1['next'], 2);
    });

    test('chat.cancel waits for the turn to really stop', () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = _FakeSession()..running = true;
      final (status, payload, _) = await h.reply(
        await h.call('chat.cancel', {'session_id': 's1'}),
      );
      expect(status, 'ok');
      expect(payload, {'status': 'cancelled', 'session_id': 's1'});
      expect(h.engine.cancelCount, 1);
      expect((await h.receipts.sessionState('s1'))?.status, 'cancelled');
    });

    test('chat.cancel on an idle session succeeds without cancelling',
        () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = _FakeSession();
      final (status, _, _) = await h.reply(
        await h.call('chat.cancel', {'session_id': 's1'}),
      );
      expect(status, 'ok');
      expect(h.engine.cancelCount, 0);
    });

    test('chat.cancel that never stops is not faked as stopped', () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = _FakeSession()
        ..running = true
        ..neverStops = true;
      final (_, _, error) = await h.reply(
        await h.call('chat.cancel', {'session_id': 's1'}),
      );
      expect(error, 'remote.operation_failed');
    });
  });

  group('document.* and schedule.list (Phase 3)', () {
    test('document.list is empty, document.read is an empty document',
        () async {
      final h = _Harness();
      await h.init();
      final (_, list, _) =
          await h.reply(await h.call('document.list', {}));
      expect(list, {'items': []});
      final (_, read, _) = await h.reply(
        await h.call('document.read', {'name': 'SOUL.md'}),
      );
      expect(read['text'], '');
      expect(read['revision'], lomEmptyDocumentRevision);
      expect(read['modified'], 0);
      final (_, _, error) = await h.reply(
        await h.call('document.read', {'name': 'notes.txt'}),
      );
      expect(error, 'sync.invalid_name');
      final (_, _, error2) = await h.reply(
        await h.call('document.read', {'name': '2026-13-01.md'}),
      );
      expect(error2, 'sync.invalid_name');
    });

    test('schedule.list maps the catalog and reports exact=false',
        () async {
      final h = _Harness();
      await h.init();
      final (_, empty, _) =
          await h.reply(await h.call('schedule.list', {}));
      expect(empty['items'], '[]');
      expect(empty['timezone'], 'Asia/Shanghai');
      expect(empty['exact'], 'false');
      h.engine.schedules = [
        const LomSchedule(
          id: 'task-1',
          title: '晨报',
          prompt: '汇报',
          kind: 'daily',
          active: true,
          time: '08:30:00',
          weekdays: [],
          recordJson: '{"a":1}',
        ),
        const LomSchedule(
          id: 'task-2',
          title: '巡检',
          prompt: '检查',
          kind: 'every',
          active: false,
          everySeconds: 3600,
          recordJson: '{"a":2}',
        ),
      ];
      final (_, list, _) =
          await h.reply(await h.call('schedule.list', {}));
      final items = jsonDecode(list['items'] as String) as List;
      expect(items.length, 2);
      expect(items[0]['freq'], 'daily');
      expect(items[0]['time'], '08:30');
      expect(items[0]['enabled'], 'true');
      expect(items[0]['editable'], 'false');
      expect(items[1]['freq'], 'interval');
      expect(items[1]['every'], '60');
      expect(items[1]['enabled'], 'false');
    });

    test('recoverInterrupted marks running sessions interrupted', () async {
      final h = _Harness();
      await h.init();
      await h.receipts.saveSessionState(
        const LomChatSessionState(
          sessionId: 's1',
          status: 'running',
          updatedAtMs: 1,
        ),
      );
      expect(await h.dispatcher.recoverInterrupted(), ['s1']);
      expect((await h.receipts.sessionState('s1'))?.status, 'interrupted');
    });
  });
}
