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

const _desktopK =
    '32jqJTBThIbGnEQca3yRNAUe9-fqOW8Rkj1fHjMPej2E1bsA0518osSsj3Rp8dx4MXI6mu0t9VQ30chWisbnbA';
const _qr =
    'lom://pair?v=1&h=bG9tLmVudGVybW9kZXR3by5jb20&p=OgX7dsvX6Pp6hNZsT6w8Sw&t=FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE&k=3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o&f=rp1mfT5Bdyg1iFGecQecVQ';

class _FakeTransport implements LomHttpTransport {
  _FakeTransport();
  var confirmCalls = 0;
  var claimCalls = 0;
  var cancelCalls = 0;
  final requests = <String>[];

  LomHttpResponse _ok(Map<String, dynamic> data) =>
      LomHttpResponse(200, jsonEncode({'success': true, 'data': data}));

  @override
  Future<LomHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  }) async {
    requests.add('${uri.path} $body');
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
      // The flow must compute key_proof from its own identity: recompute
      // it independently from the submitted device_keys.
      final expected = keyProof(
        psk: b64urlDecodeStrict(
          '3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o',
        )!,
        pairingId: 'OgX7dsvX6Pp6hNZsT6w8Sw',
        desktopKeys: _desktopK,
        phoneKeys: req['device_keys'] as String,
      );
      expect(req['key_proof'], expected);
      expect(req['device_keys'], isNotEmpty);
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

Future<LomIdentity> _phoneIdentity() => LomIdentity.fromPrivateBytes(
      x25519PrivateKey: List<int>.generate(32, (i) => i + 1),
      ed25519Seed: List<int>.generate(32, (i) => 100 + i),
    );

void main() {
  group('LomPairingFlow QR path', () {
    test('inspect → claim → user confirm → credentials persisted', () async {
      final identity = await _phoneIdentity();
      final transport = _FakeTransport();
      final store = LomCredentialStore(_MapStore());
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) =>
            LomPairingApi(baseUrl: baseUrl, transport: transport),
      );
      await flow.startFromLink(_qr);
      expect(flow.step, LomPairingStep.awaitingUser);
      expect(flow.offer?.desktopName, 'My PC');
      expect(flow.offer?.method, 'qr');
      expect(flow.offer?.sas, isEmpty);
      // confirm is NOT sent before the user confirms.
      expect(transport.confirmCalls, 0);
      await flow.userConfirmed(sleep: (_) async {});
      expect(flow.step, LomPairingStep.done);
      expect(transport.confirmCalls, 1);
      final saved = await store.load();
      expect(saved?.deviceId, 'dev_0123456789abcdef0123456789abcdef');
      expect(saved?.desktopKeys, {_desktopK});
      expect(saved?.host, 'lom.entermodetwo.com');
    });

    test('fingerprint mismatch aborts before claim', () async {
      final identity = await _phoneIdentity();
      final transport = _FakeTransport();
      final store = LomCredentialStore(_MapStore());
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) =>
            LomPairingApi(baseUrl: baseUrl, transport: transport),
      );
      // Tamper the fingerprint in the QR link (last char Q->R breaks
      // canonicality, so use a different valid 16-byte fingerprint).
      final badQr = _qr.replaceFirst(
        'f=rp1mfT5Bdyg1iFGecQecVQ',
        'f=AAAAAAAAAAAAAAAAAAAAAA',
      );
      await expectLater(
        flow.startFromLink(badQr),
        throwsA(
          isA<LomPairingException>().having(
            (e) => e.code,
            'code',
            'pairing.key_mismatch',
          ),
        ),
      );
      expect(flow.step, LomPairingStep.failed);
      expect(transport.claimCalls, 0); // never claimed
    });

    test('invalid QR link makes no network request', () async {
      final identity = await _phoneIdentity();
      final transport = _FakeTransport();
      final store = LomCredentialStore(_MapStore());
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) =>
            LomPairingApi(baseUrl: baseUrl, transport: transport),
      );
      await expectLater(
        flow.startFromLink('lom://pair?v=1&h=AAAA'),
        throwsA(isA<LomPairingLinkException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('already paired refuses to start', () async {
      final identity = await _phoneIdentity();
      final store = LomCredentialStore(_MapStore());
      await store.save(
        const LomDeviceCredentials(
          deviceId: 'dev_abc',
          deviceToken: 'tok',
          tokenExpiresAt: 1999999999,
          desktopName: 'My PC',
        ),
        host: 'lom.entermodetwo.com',
        desktopKeys: _desktopK,
        desktopName: 'My PC',
      );
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) => throw StateError('must not be called'),
      );
      await expectLater(
        flow.startFromLink(_qr),
        throwsA(
          isA<LomPairingException>().having(
            (e) => e.code,
            'code',
            'pairing.already_paired',
          ),
        ),
      );
    });

    test('cancel calls cancel and resets', () async {
      final identity = await _phoneIdentity();
      final transport = _FakeTransport();
      final store = LomCredentialStore(_MapStore());
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) =>
            LomPairingApi(baseUrl: baseUrl, transport: transport),
      );
      await flow.startFromLink(_qr);
      await flow.userCancelled();
      expect(transport.cancelCalls, 1);
      expect(flow.step, LomPairingStep.idle);
    });
  });

  group('LomPairingFlow manual-code path', () {
    test('claim-by-code computes the vector SAS', () async {
      final identity = await _phoneIdentity();
      final transport = _FakeTransport();
      final store = LomCredentialStore(_MapStore());
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) =>
            LomPairingApi(baseUrl: baseUrl, transport: transport),
      );
      final offer = await flow.startFromCode('ab3d-9xk2');
      expect(offer.method, 'code');
      // SAS depends on the flow's own phone K; recompute independently.
      expect(
        offer.sas,
        sasCode(
          pairingId: 'mntD9iGtAxNFEDb-v4rUSg',
          desktopKeys: _desktopK,
          phoneKeys: identity.keys,
        ),
      );
      expect(offer.sas.length, 6);
      await flow.userConfirmed(sleep: (_) async {});
      expect(flow.step, LomPairingStep.done);
    });

    test('bad code never reaches the network', () async {
      final identity = await _phoneIdentity();
      final transport = _FakeTransport();
      final store = LomCredentialStore(_MapStore());
      final flow = LomPairingFlow(
        identity: identity,
        credentialStore: store,
        deviceInfo: const LomDeviceInfo(name: 'Test'),
        apiFactory: (baseUrl) =>
            LomPairingApi(baseUrl: baseUrl, transport: transport),
      );
      await expectLater(
        flow.startFromCode('AB0D-9XK2'),
        throwsA(
          isA<LomPairingException>().having(
            (e) => e.code,
            'code',
            'pairing.code_invalid',
          ),
        ),
      );
      expect(transport.requests, isEmpty);
    });
  });

  group('LomIdentityStore', () {
    test('loadOrCreate persists and reloads the same identity', () async {
      final secrets = _MapStore();
      final protector = MemoryLomKeyProtector();
      final store = LomIdentityStore(secrets: secrets, protector: protector);
      final first = await store.loadOrCreate();
      final second = await store.loadOrCreate();
      expect(second.keys, first.keys);
      // A new store object over the same backing maps loads the same keys.
      final store2 = LomIdentityStore(secrets: secrets, protector: protector);
      final third = await store2.load();
      expect(third?.keys, first.keys);
    });

    test('delete removes the identity', () async {
      final secrets = _MapStore();
      final protector = MemoryLomKeyProtector();
      final store = LomIdentityStore(secrets: secrets, protector: protector);
      await store.loadOrCreate();
      await store.delete();
      expect(await store.load(), isNull);
    });
  });
}
