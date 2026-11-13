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

void main() {
  group('LomReplayStore', () {
    test('first claim wins, second is a replay', () async {
      final store = LomReplayStore(_MapStore());
      expect(await store.claim('K1:aaaa'), isTrue);
      expect(await store.claim('K1:aaaa'), isFalse);
      expect(await store.claim('K1:aaab'), isTrue);
      expect(await store.claim('K2:aaaa'), isTrue);
    });

    test('claims expire after the 10-minute retention', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1_000_000);
      final store = LomReplayStore(
        _MapStore(),
        now: () => now,
      );
      expect(await store.claim('K1:aaaa'), isTrue);
      expect(await store.claim('K1:aaaa'), isFalse);
      now = DateTime.fromMillisecondsSinceEpoch(
        1_000_000 + LomReplayStore.retention.inMilliseconds + 1,
      );
      expect(await store.claim('K1:aaaa'), isTrue);
    });

    test('concurrent claims of the same key admit only one', () async {
      final store = LomReplayStore(_MapStore());
      final results = await Future.wait([
        store.claim('K1:aaaa'),
        store.claim('K1:aaaa'),
        store.claim('K1:aaaa'),
      ]);
      expect(results.where((r) => r).length, 1);
    });
  });

  group('LomModelConfigStore', () {
    test('round-trips per-desktop configs', () async {
      final store = LomModelConfigStore(_MapStore());
      expect(await store.loadFor('K1'), isNull);
      await store.save(
        'K1',
        const LomModelConfig(
          baseUrl: 'https://api.example.com',
          model: 'gpt-5',
          platform: 'openai',
          revision: 42,
          route: 'lom-abcdef012345',
          keyRef: 'LOM_ABCDEF012345_API_KEY',
          updatedAtMs: 123,
        ),
      );
      final loaded = await store.loadFor('K1');
      expect(loaded?.model, 'gpt-5');
      expect(loaded?.revision, 42);
      expect(loaded?.route, 'lom-abcdef012345');
      expect(await store.loadFor('K2'), isNull);
    });
  });

  group('LomChatReceiptStore', () {
    test('receipts round-trip and can be marked failed', () async {
      final store = LomChatReceiptStore(_MapStore());
      expect(await store.receiptFor('c1'), isNull);
      await store.saveReceipt(
        const LomChatReceipt(
          clientId: 'c1',
          sessionId: 's1',
          contentHash: 'h1',
          status: 'pending',
          updatedAtMs: 1,
        ),
      );
      expect((await store.receiptFor('c1'))?.status, 'pending');
      await store.saveReceipt(
        const LomChatReceipt(
          clientId: 'c1',
          sessionId: 's1',
          contentHash: 'h1',
          status: 'accepted',
          updatedAtMs: 2,
        ),
      );
      expect((await store.receiptFor('c1'))?.status, 'accepted');
    });

    test('markRunningInterrupted only touches running sessions', () async {
      final store = LomChatReceiptStore(_MapStore());
      await store.saveSessionState(
        const LomChatSessionState(
          sessionId: 's-running',
          status: 'running',
          updatedAtMs: 1,
        ),
      );
      await store.saveSessionState(
        const LomChatSessionState(
          sessionId: 's-done',
          status: 'completed',
          updatedAtMs: 1,
        ),
      );
      final interrupted = await store.markRunningInterrupted();
      expect(interrupted, ['s-running']);
      expect(
        (await store.sessionState('s-running'))?.status,
        'interrupted',
      );
      expect((await store.sessionState('s-done'))?.status, 'completed');
      expect(await store.markRunningInterrupted(), isEmpty);
    });
  });
}
