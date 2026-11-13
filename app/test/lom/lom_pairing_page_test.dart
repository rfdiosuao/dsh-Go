// Lom pairing, Phase 1: the controller state machine and the pairing page.
//
// The crypto / envelope / API / flow vectors live in the unit tests next
// to this file; these tests drive the Riverpod controller the page uses,
// with a scripted HTTP transport and an in-memory secret store, and pump
// the page itself with a fake scanner (no camera, no network, no native
// side).

import 'dart:convert';

import 'package:dsh_app/lom/base64url.dart';
import 'package:dsh_app/lom/credentials.dart';
import 'package:dsh_app/lom/identity.dart';
import 'package:dsh_app/lom/identity_store.dart';
import 'package:dsh_app/lom/lom_pairing_state.dart';
import 'package:dsh_app/lom/lom_providers.dart';
import 'package:dsh_app/lom/lom_relay_service.dart';
import 'package:dsh_app/lom/pairing_api.dart';
import 'package:dsh_app/ui/lom/lom_pairing_page.dart';
import 'package:dsh_app/ui/remote/pairing_page.dart' show pairingScannerProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

const _desktopK =
    '32jqJTBThIbGnEQca3yRNAUe9-fqOW8Rkj1fHjMPej2E1bsA0518osSsj3Rp8dx4MXI6mu0t9VQ30chWisbnbA';
const _qr =
    'lom://pair?v=1&h=bG9tLmVudGVybW9kZXR3by5jb20&p=OgX7dsvX6Pp6hNZsT6w8Sw&t=FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE&k=3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o&f=rp1mfT5Bdyg1iFGecQecVQ';

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

/// The pairing half of the Lom cloud, scripted by the test. Same shape as
/// the flow test's fake; the claim handler recomputes key_proof from the
/// submitted device_keys, so any generated identity works.
class _FakeTransport implements LomHttpTransport {
  final requests = <String>[];
  var claimCalls = 0;
  var confirmCalls = 0;
  var cancelCalls = 0;

  LomHttpResponse _ok(Map<String, dynamic> data) =>
      LomHttpResponse(200, jsonEncode({'success': true, 'data': data}));

  @override
  Future<LomHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  }) async {
    requests.add(uri.path);
    if (uri.path.endsWith('/inspect')) {
      return _ok({
        'pairing_id': 'OgX7dsvX6Pp6hNZsT6w8Sw',
        'desktop_name': 'My PC',
        'desktop_keys': _desktopK,
        'masked_account': 'a***@example.com',
        'expires_at': 1763000000,
      });
    }
    if (uri.path.endsWith('/claim')) {
      claimCalls++;
      final req = jsonDecode(body!) as Map<String, dynamic>;
      final expected = keyProof(
        psk: b64urlDecodeStrict(
          '3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o',
        )!,
        pairingId: 'OgX7dsvX6Pp6hNZsT6w8Sw',
        desktopKeys: _desktopK,
        phoneKeys: req['device_keys'] as String,
      );
      expect(req['key_proof'], expected);
      return _ok({'claim_secret': 'secret-1', 'expires_at': 1763000000});
    }
    if (uri.path.endsWith('/confirm')) {
      confirmCalls++;
      return _ok({
        'device_id': 'dev_0123456789abcdef0123456789abcdef',
        'device_token': 't' * 43,
        'token_expires_at': 1763000000,
        'desktop_name': 'My PC',
      });
    }
    if (uri.path.endsWith('/cancel')) {
      cancelCalls++;
      return _ok({});
    }
    if (uri.path.endsWith('/claim-by-code')) {
      final req = jsonDecode(body!) as Map<String, dynamic>;
      expect(req['manual_code'], 'AB3D-9XK2');
      return _ok({
        'pairing_id': 'mntD9iGtAxNFEDb-v4rUSg',
        'desktop_name': 'My PC',
        'desktop_keys': _desktopK,
        'masked_account': 'a***@example.com',
        'expires_at': 1763000000,
        'claim_secret': 'secret-2',
      });
    }
    throw StateError('unexpected ${uri.path}');
  }

  @override
  Future<LomHttpResponse> delete(
    Uri uri, {
    Map<String, String>? headers,
  }) async =>
      throw UnimplementedError();
}

/// The relay provider, stubbed: the page's done-state calls `refresh()`,
/// and the real controller would touch connectivity / sockets.
class _StubRelay extends LomRelayController {
  @override
  LomRelayState build() => const LomRelayState();

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> unpair() async => true;
}

ProviderContainer _container(_FakeTransport transport, _MapStore store) {
  final container = ProviderContainer(
    overrides: [
      lomIdentityStoreProvider.overrideWithValue(
        LomIdentityStore(
          secrets: store,
          protector: MemoryLomKeyProtector(),
        ),
      ),
      lomCredentialStoreProvider.overrideWithValue(LomCredentialStore(store)),
      lomDeviceInfoProvider.overrideWithValue(
        const AsyncValue.data(LomDeviceInfo(name: 'Test')),
      ),
      lomHttpTransportProvider.overrideWithValue(transport),
    ],
  );
  addTearDown(container.dispose);
  container.listen(lomPairingProvider, (_, _) {}, fireImmediately: true);
  return container;
}

void main() {
  group('controller', () {
    test('invalid link fails before any network request', () async {
      final transport = _FakeTransport();
      final container = _container(transport, _MapStore());
      final flow = container.read(lomPairingProvider.notifier);

      await flow.scanned('lom://pair?v=1&h=bad');
      final state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.failed);
      expect(state.errorCode, 'pairing.qr_invalid');
      expect(transport.requests, isEmpty);
    });

    test('QR: scan → confirm page → user confirms → done + saved', () async {
      final transport = _FakeTransport();
      final store = _MapStore();
      final container = _container(transport, store);
      final flow = container.read(lomPairingProvider.notifier);

      await flow.scanned(_qr);
      var state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.confirming);
      expect(state.offer?.desktopName, 'My PC');
      expect(state.offer?.maskedAccount, 'a***@example.com');
      expect(state.offer?.sas, isEmpty);
      expect(transport.confirmCalls, 0,
          reason: 'nothing is claimed before the person confirms');

      await flow.userConfirmed();
      state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.done);
      expect(transport.confirmCalls, 1);
      final saved = await LomCredentialStore(store).load();
      expect(saved?.deviceId, 'dev_0123456789abcdef0123456789abcdef');
      expect(saved?.desktopKeys, {_desktopK});
      expect(saved?.host, 'lom.entermodetwo.com');
    });

    test('already paired: a second scan is refused locally', () async {
      final transport = _FakeTransport();
      final store = _MapStore();
      final container = _container(transport, store);
      final flow = container.read(lomPairingProvider.notifier);

      await flow.scanned(_qr);
      await flow.userConfirmed();
      expect(container.read(lomPairingProvider).step, LomPairingUiStep.done);

      await flow.scanned(_qr);
      final state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.failed);
      expect(state.errorCode, 'pairing.already_paired');
    });

    test('bad code never reaches the network', () async {
      final transport = _FakeTransport();
      final container = _container(transport, _MapStore());
      final flow = container.read(lomPairingProvider.notifier);

      await flow.submittedCode('zzzz');
      final state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.failed);
      expect(state.errorCode, 'pairing.code_invalid');
      expect(transport.requests, isEmpty);
    });

    test('code path: SAS shown, confirm completes', () async {
      final transport = _FakeTransport();
      final container = _container(transport, _MapStore());
      final flow = container.read(lomPairingProvider.notifier);

      await flow.submittedCode('ab3d-9xk2');
      var state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.confirming);
      expect(state.offer?.sas, hasLength(6),
          reason: 'the code path shows the 6-digit SAS for visual compare');

      await flow.userConfirmed();
      state = container.read(lomPairingProvider);
      expect(state.step, LomPairingUiStep.done);
    });

    test('cancel on the confirm page goes back to scanning', () async {
      final transport = _FakeTransport();
      final container = _container(transport, _MapStore());
      final flow = container.read(lomPairingProvider.notifier);

      await flow.scanned(_qr);
      expect(container.read(lomPairingProvider).step,
          LomPairingUiStep.confirming);
      await flow.userCancelled();
      expect(container.read(lomPairingProvider).step,
          LomPairingUiStep.scanning);
      expect(transport.cancelCalls, 1);
    });
  });

  group('page', () {
    testWidgets('scan → confirm → connected', (tester) async {
      final transport = _FakeTransport();
      final store = _MapStore();
      await tester.pumpWidget(
        testApp(
          const LomPairingPage(),
          overrides: [
            lomIdentityStoreProvider.overrideWithValue(
              LomIdentityStore(
                secrets: store,
                protector: MemoryLomKeyProtector(),
              ),
            ),
            lomCredentialStoreProvider
                .overrideWithValue(LomCredentialStore(store)),
            lomDeviceInfoProvider.overrideWithValue(
              const AsyncValue.data(LomDeviceInfo(name: 'Test')),
            ),
            lomHttpTransportProvider.overrideWithValue(transport),
            pairingScannerProvider.overrideWithValue(
              (context, onCode) => FilledButton(
                onPressed: () => onCode(_qr),
                child: const Text('fake-scan'),
              ),
            ),
            lomRelayProvider.overrideWith(_StubRelay.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('fake-scan'));
      await tester.pumpAndSettle();
      expect(find.text('My PC'), findsOneWidget);
      expect(find.text('a***@example.com'), findsOneWidget);

      await tester.tap(find.text('确认连接'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已连接'), findsOneWidget);
      expect(transport.confirmCalls, 1);
    });

    testWidgets('invalid pasted link shows the failure page', (tester) async {
      final transport = _FakeTransport();
      final store = _MapStore();
      await tester.pumpWidget(
        testApp(
          const LomPairingPage(),
          overrides: [
            lomIdentityStoreProvider.overrideWithValue(
              LomIdentityStore(
                secrets: store,
                protector: MemoryLomKeyProtector(),
              ),
            ),
            lomCredentialStoreProvider
                .overrideWithValue(LomCredentialStore(store)),
            lomDeviceInfoProvider.overrideWithValue(
              const AsyncValue.data(LomDeviceInfo(name: 'Test')),
            ),
            lomHttpTransportProvider.overrideWithValue(transport),
            pairingScannerProvider.overrideWithValue(
              (context, onCode) => FilledButton(
                onPressed: () => onCode('not a lom link'),
                child: const Text('fake-scan'),
              ),
            ),
            lomRelayProvider.overrideWith(_StubRelay.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('fake-scan'));
      await tester.pumpAndSettle();
      expect(find.text('这不是有效的 Lom 配对码'), findsOneWidget);
      expect(transport.requests, isEmpty);
    });
  });
}
