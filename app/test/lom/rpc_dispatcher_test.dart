import 'dart:convert';
import 'dart:io' as io;

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

  // Phase 4 (optional methods).
  final titles = <String, String>{};
  final deletedIds = <String>{};
  bool deletionSupported = true;
  String network = 'wifi';

  @override
  Future<String> renameSession(String sessionId, String title) async {
    if (!sessions.containsKey(sessionId)) {
      throw LomEngineException('chat.session_missing');
    }
    titles[sessionId] = title;
    return title;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    if (!deletionSupported) {
      throw LomEngineException('remote.operation_failed');
    }
    if (!sessions.containsKey(sessionId)) {
      throw LomEngineException('chat.session_missing');
    }
    sessions.remove(sessionId);
    deletedIds.add(sessionId);
  }

  @override
  Future<String> deviceNetwork() async => network;

  // Phase 4 (chat.file / chat.image).
  final attachmentData = <String, LomAttachmentData>{};
  final sessionFiles = <String, List<int>>{};

  @override
  Future<LomAttachmentData> attachmentBytes({
    required String sessionId,
    required LomAttachmentRef ref,
  }) async {
    final data = attachmentData[ref.id];
    if (data == null) throw LomEngineException('file.attachment_missing');
    return data;
  }

  @override
  Future<List<int>> readSessionFile(String sessionId, String path) async {
    final bytes = sessionFiles['$sessionId:$path'];
    if (bytes == null) throw LomEngineException('file.attachment_missing');
    return bytes;
  }
}

class _FakeGallerySaver implements LomGallerySaver {
  String uri = 'content://media/external/images/media/42';
  @override
  Future<String> saveToGallery({
    required String path,
    required String name,
    required String mime,
  }) async =>
      uri;
}

class _Harness {
  static const nowMs = 1767222000000;

  late final LomIdentity phone;
  late final LomIdentity desktop;
  late final _MapStore store;
  late final _FakeEngine engine;
  late final LomRpcDispatcher dispatcher;
  late final LomChatReceiptStore receipts;
  late final LomFileStore fileStore;
  final trusted = <String>{};
  var _ids = 0;

  Future<void> init({LomFileStorage? fileStorage}) async {
    phone = await LomIdentity.generate();
    desktop = await LomIdentity.generate();
    trusted.add(desktop.keys);
    store = _MapStore();
    engine = _FakeEngine();
    receipts = LomChatReceiptStore(store);
    engine.receipts = receipts;
    fileStore = LomFileStore(
      store,
      storage: fileStorage ?? MemoryLomFileStorage(),
      gallerySaver: _FakeGallerySaver(),
    );
    dispatcher = LomRpcDispatcher(
      identity: phone,
      trustedSenders: () => trusted,
      replay: LomReplayStore(store),
      modelConfigs: LomModelConfigStore(store),
      receipts: receipts,
      engine: engine,
      optional: LomOptionalMethods(
        engine: engine,
        pins: LomPinStore(store),
        deviceNames: LomDeviceNameStore(store),
        files: fileStore,
        now: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      ),
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

  group('Phase 4: chat.rename / chat.pin / chat.delete', () {
    test('rename saves the trimmed title, rejects bad titles', () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = _FakeSession();
      final (status, payload, _) = await h.reply(
        await h.call('chat.rename', {
          'session_id': 's1',
          'title': '  新标题  ',
        }),
      );
      expect(status, 'ok');
      expect(payload, {'status': 'saved', 'session_id': 's1'});
      expect(h.engine.titles['s1'], '新标题');

      final (_, _, errorEmpty) = await h.reply(
        await h.call('chat.rename', {'session_id': 's1', 'title': '   '}),
      );
      expect(errorEmpty, 'chat.invalid_title');
      final (_, _, errorMissing) = await h.reply(
        await h.call('chat.rename', {
          'session_id': 'nope',
          'title': 'x',
        }),
      );
      expect(errorMissing, 'chat.session_missing');
    });

    test('pin is a Lom-side overlay shown by chat.list', () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = _FakeSession();
      h.engine.summaries = [
        const LomSessionSummary(
          id: 's1',
          title: 't',
          updatedMs: 1,
          pinned: false,
          running: false,
          model: '',
        ),
      ];
      final (_, listBefore, _) =
          await h.reply(await h.call('chat.list', {'offset': 0}));
      expect((listBefore['items'] as List).first['pinned'], false);
      final (status, _, _) = await h.reply(
        await h.call('chat.pin', {'session_id': 's1', 'pinned': true}),
      );
      expect(status, 'ok');
      final (_, listAfter, _) =
          await h.reply(await h.call('chat.list', {'offset': 0}));
      expect((listAfter['items'] as List).first['pinned'], true);
      // Unpin, and a non-boolean `pinned` is a protocol failure.
      await h.reply(
        await h.call('chat.pin', {'session_id': 's1', 'pinned': false}),
      );
      final (_, listUnpinned, _) =
          await h.reply(await h.call('chat.list', {'offset': 0}));
      expect((listUnpinned['items'] as List).first['pinned'], false);
      final (_, _, error) = await h.reply(
        await h.call('chat.pin', {'session_id': 's1', 'pinned': 'true'}),
      );
      expect(error, 'remote.operation_failed');
    });

    test('delete refuses a running session, deletes, missing is deleted',
        () async {
      final h = _Harness();
      await h.init();
      final running = _FakeSession()..running = true;
      h.engine.sessions['s-run'] = running;
      h.engine.sessions['s-idle'] = _FakeSession();
      final (_, _, busyError) = await h.reply(
        await h.call('chat.delete', {'session_id': 's-run'}),
      );
      expect(busyError, 'chat.busy');
      expect(h.engine.sessions.containsKey('s-run'), true);
      final (status, payload, _) = await h.reply(
        await h.call('chat.delete', {'session_id': 's-idle'}),
      );
      expect(status, 'ok');
      expect(payload, {'status': 'deleted'});
      expect(h.engine.deletedIds, contains('s-idle'));
      final (goneStatus, _, _) = await h.reply(
        await h.call('chat.delete', {'session_id': 's-gone'}),
      );
      expect(goneStatus, 'ok');
    });

    test('delete on a host without deletion support fails, not faked',
        () async {
      final h = _Harness();
      await h.init();
      h.engine.sessions['s1'] = _FakeSession();
      h.engine.deletionSupported = false;
      final (status, _, error) = await h.reply(
        await h.call('chat.delete', {'session_id': 's1'}),
      );
      expect(status, 'error');
      expect(error, 'remote.operation_failed');
      expect(h.engine.sessions.containsKey('s1'), true);
    });
  });

  group('Phase 4: device.status / device.rename', () {
    test('status reports network, battery is empty (no source)', () async {
      final h = _Harness();
      await h.init();
      h.engine.network = 'cellular';
      final (status, payload, _) =
          await h.reply(await h.call('device.status', {}));
      expect(status, 'ok');
      expect(payload['battery'], '');
      expect(payload['network'], 'cellular');
      expect(payload['sampled_at'], '1767222000000');
    });

    test('rename echoes the name verbatim, rejects empty names', () async {
      final h = _Harness();
      await h.init();
      const name = '我的手机';
      final (status, payload, _) = await h.reply(
        await h.call('device.rename', {'name': name}),
      );
      expect(status, 'ok');
      expect(payload, {'name': name});
      final (_, _, error) = await h.reply(
        await h.call('device.rename', {'name': ''}),
      );
      expect(error, 'remote.operation_failed');
    });

    test('capabilities lists the Phase 4 methods once wired', () async {
      final h = _Harness();
      await h.init();
      final (_, payload, _) =
          await h.reply(await h.call('device.capabilities', {}));
      final methods = (payload['methods'] as List).cast<String>();
      for (final m in [
        'chat.rename',
        'chat.pin',
        'chat.delete',
        'device.status',
        'device.rename',
      ]) {
        expect(methods, contains(m));
      }
      expect(methods, isNot(contains('screen.capture')));
      expect(methods, isNot(contains('subagent.list')));
    });
  });

  group('Phase 4: file.* over RPC', () {
    const fileId = '0123456789abcdef';
    final fileBytes = utf8.encode('hello');
    // SHA-256 of "hello".
    const fileSha =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

    Future<void> uploadViaRpc(_Harness h) async {
      await h.reply(await h.call('file.begin', {
        'id': fileId,
        'name': 'hello.txt',
        'mime': 'text/plain',
        'size': '5',
        'sha256': fileSha,
      }));
      await h.reply(await h.call('file.chunk', {
        'id': fileId,
        'offset': '0',
        'data': base64Encode(fileBytes),
      }));
      final (status, state, _) = await h.reply(
        await h.call('file.finish', {'id': fileId}),
      );
      expect(status, 'ok');
      expect(state['status'], 'complete');
    }

    test('begin/chunk/finish/read round-trips and lists in capabilities',
        () async {
      final h = _Harness();
      await h.init();
      await uploadViaRpc(h);
      final (status, read, _) = await h.reply(
        await h.call('file.read', {'id': fileId, 'offset': '0'}),
      );
      expect(status, 'ok');
      expect(base64Decode(read['data'] as String), fileBytes);
      expect(read['next'], '5');
      final (_, caps, _) =
          await h.reply(await h.call('device.capabilities', {}));
      final methods = (caps['methods'] as List).cast<String>();
      for (final m in [
        'file.begin',
        'file.chunk',
        'file.finish',
        'file.read',
        'file.list',
        'file.delete',
        'file.save_gallery',
      ]) {
        expect(methods, contains(m));
      }
      expect((caps['limits'] as Map)['file.max_bytes'], 104857600);
    });

    test('chat.send accepts verified attachments, refuses the rest',
        () async {
      final h = _Harness();
      await h.init();
      await h.syncModel();
      final (_, _, unknownError) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'aaaaaaaa-0000-0000-0000-000000000001',
          'session_id': '',
          'text': 'look',
          'files': '["$fileId"]',
        }),
      );
      expect(unknownError, 'file.missing');
      // Uploaded but not finished: incomplete.
      await h.reply(await h.call('file.begin', {
        'id': fileId,
        'name': 'hello.txt',
        'mime': 'text/plain',
        'size': '5',
        'sha256': fileSha,
      }));
      final (_, _, incompleteError) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'aaaaaaaa-0000-0000-0000-000000000002',
          'session_id': '',
          'text': 'look',
          'files': '["$fileId"]',
        }),
      );
      expect(incompleteError, 'file.incomplete');
      await uploadViaRpc(h);
      final (status, sent, _) = await h.reply(
        await h.call('chat.send', {
          'client_id': 'aaaaaaaa-0000-0000-0000-000000000003',
          'session_id': '',
          'text': 'look',
          'files': '["$fileId"]',
        }),
      );
      expect(status, 'ok');
      expect(sent['status'], 'accepted');
    });

    test('save_gallery returns the MediaStore URI for a finished file',
        () async {
      final dir = await io.Directory.systemTemp.createTemp('lom-rpc-file');
      try {
        final h = _Harness();
        await h.init(fileStorage: IoLomFileStorage(dir));
        await uploadViaRpc(h);
        final (status, saved, _) = await h.reply(
          await h.call('file.save_gallery', {'id': fileId}),
        );
        expect(status, 'ok');
        expect(saved['status'], 'saved');
        expect(
          saved['uri'],
          'content://media/external/images/media/42',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('Phase 4: chat.file / chat.image over RPC', () {
    Future<_Harness> harnessWithMessage() async {
      final h = _Harness();
      await h.init();
      final session = _FakeSession();
      session.messages = [
        const LomChatMessage(
          id: 'm1',
          role: 'assistant',
          text: 'see this',
          at: 1767222000000,
          seq: 1,
          attachments: ['pic.png'],
          attachmentRefs: [
            LomAttachmentRef(
              id: 'att-1',
              mediaType: 'image/png',
              name: 'pic.png',
              kind: 'image',
            ),
          ],
        ),
      ];
      h.engine.sessions['s1'] = session;
      h.engine.attachmentData['att-1'] = const LomAttachmentData(
        bytes: [1, 2, 3, 4],
        mime: 'image/png',
        name: 'pic.png',
      );
      return h;
    }

    test('chat.file registers the attachment and file.read serves it',
        () async {
      final h = await harnessWithMessage();
      final (status, state, _) = await h.reply(
        await h.call('chat.file', {
          'session_id': 's1',
          'message_id': 'm1',
          'index': '0',
        }),
      );
      expect(status, 'ok');
      expect(state['status'], 'complete');
      expect(state['name'], 'pic.png');
      expect(state['mime'], 'image/png');
      final (_, read, _) = await h.reply(
        await h.call('file.read', {
          'id': state['id'] as String,
          'offset': '0',
        }),
      );
      expect(base64Decode(read['data'] as String), [1, 2, 3, 4]);
    });

    test('chat.file errors: missing session/message/index/attachment',
        () async {
      final h = await harnessWithMessage();
      final (_, _, sessionError) = await h.reply(
        await h.call('chat.file', {
          'session_id': 'nope',
          'message_id': 'm1',
          'index': '0',
        }),
      );
      expect(sessionError, 'chat.session_missing');
      final (_, _, messageError) = await h.reply(
        await h.call('chat.file', {
          'session_id': 's1',
          'message_id': 'nope',
          'index': '0',
        }),
      );
      expect(messageError, 'file.message_missing');
      final (_, _, indexError) = await h.reply(
        await h.call('chat.file', {
          'session_id': 's1',
          'message_id': 'm1',
          'index': '1',
        }),
      );
      expect(indexError, 'file.attachment_missing');
      h.engine.attachmentData.clear();
      final (_, _, fetchError) = await h.reply(
        await h.call('chat.file', {
          'session_id': 's1',
          'message_id': 'm1',
          'index': '0',
        }),
      );
      expect(fetchError, 'file.attachment_missing');
    });

    test('chat.image reads only sandbox images', () async {
      final h = await harnessWithMessage();
      h.engine.sessionFiles['s1:shots/a.png'] = [9, 8, 7];
      final (status, state, _) = await h.reply(
        await h.call('chat.image', {
          'session_id': 's1',
          'source': 'shots/a.png',
        }),
      );
      expect(status, 'ok');
      expect(state['status'], 'complete');
      expect(state['mime'], 'image/png');
      for (final bad in ['/abs/a.png', '../a.png', 'a.txt', 'a.png/..']) {
        final (_, _, error) = await h.reply(
          await h.call('chat.image', {'session_id': 's1', 'source': bad}),
        );
        expect(error, 'file.invalid_source', reason: bad);
      }
      final (_, _, missingError) = await h.reply(
        await h.call('chat.image', {
          'session_id': 's1',
          'source': 'shots/gone.png',
        }),
      );
      expect(missingError, 'file.attachment_missing');
      final (_, _, sessionError) = await h.reply(
        await h.call('chat.image', {
          'session_id': 'nope',
          'source': 'shots/a.png',
        }),
      );
      expect(sessionError, 'chat.session_missing');
    });

    test('capabilities lists chat.file and chat.image', () async {
      final h = await harnessWithMessage();
      final (_, caps, _) =
          await h.reply(await h.call('device.capabilities', {}));
      final methods = (caps['methods'] as List).cast<String>();
      expect(methods, contains('chat.file'));
      expect(methods, contains('chat.image'));
    });
  });
}
