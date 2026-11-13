import 'dart:convert';

import 'package:dsh_app/lom/lom_phone.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTransport implements LomHttpTransport {
  FakeTransport(this.handler);
  final Future<LomHttpResponse> Function(
    String method,
    Uri uri,
    Map<String, String>? headers,
    String? body,
  ) handler;

  final List<(String, Uri, String?)> calls = [];

  @override
  Future<LomHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  }) async {
    calls.add(('POST', uri, body));
    return handler('POST', uri, headers, body);
  }

  @override
  Future<LomHttpResponse> delete(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    calls.add(('DELETE', uri, null));
    return handler('DELETE', uri, headers, null);
  }
}

LomHttpResponse ok(Map<String, dynamic> data) =>
    LomHttpResponse(200, jsonEncode({'success': true, 'data': data}));

LomHttpResponse err(int status, String code) => LomHttpResponse(
      status,
      jsonEncode({'success': false, 'code': code, 'error': 'x'}),
    );

const _deviceInfo = LomDeviceInfo(
  name: 'Test Phone',
  model: 'Pixel 8',
  os: 'Android 15',
  appVersion: '1.0.16',
);

void main() {
  group('LomPairingApi', () {
    test('inspect → claim → confirm happy path', () async {
      final transport = FakeTransport((method, uri, headers, body) async {
        if (uri.path.endsWith('/inspect')) {
          return ok({
            'pairing_id': 'OgX7dsvX6Pp6hNZsT6w8Sw',
            'desktop_name': 'My PC',
            'desktop_keys': 'K' * 86,
            'masked_account': 'a***@example.com',
            'expires_at': 1763000000,
          });
        }
        if (uri.path.endsWith('/claim')) {
          final req = jsonDecode(body!) as Map<String, dynamic>;
          expect(req['key_proof'], isNotEmpty);
          expect(req['device_keys'], isNotEmpty);
          return ok({'claim_secret': 'secret-1', 'expires_at': 1763000000});
        }
        if (uri.path.endsWith('/confirm')) {
          return ok({
            'device_id': 'dev_0123456789abcdef0123456789abcdef',
            'device_token': 't' * 43,
            'token_expires_at': 1763000000 + 90 * 86400,
            'desktop_name': 'My PC',
          });
        }
        return err(404, 'pairing.not_found');
      });
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final inspected = await api.inspect(
        pairingId: 'OgX7dsvX6Pp6hNZsT6w8Sw',
        claimToken: 't' * 43,
      );
      expect(inspected.desktopName, 'My PC');
      final claimed = await api.claim(
        pairingId: 'OgX7dsvX6Pp6hNZsT6w8Sw',
        claimToken: 't' * 43,
        deviceKeys: 'K' * 86,
        deviceInfo: _deviceInfo,
        keyProof: 'p' * 43,
      );
      expect(claimed.claimSecret, 'secret-1');
      final creds = await api.confirm(
        pairingId: 'OgX7dsvX6Pp6hNZsT6w8Sw',
        claimSecret: 'secret-1',
      );
      expect(creds.deviceId, startsWith('dev_'));
      // Tokens never travel in the URL.
      for (final (_, uri, _) in transport.calls) {
        expect(uri.toString(), isNot(contains('secret-1')));
        expect(uri.toString(), isNot(contains('t' * 43)));
      }
    });

    test('error codes surface from the body', () async {
      final transport = FakeTransport(
        (_, _, _, _) async => err(410, 'pairing.expired'),
      );
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      await expectLater(
        api.inspect(pairingId: 'x', claimToken: 'y'),
        throwsA(
          isA<LomPairingException>().having((e) => e.code, 'code', 'pairing.expired'),
        ),
      );
    });

    test('non-JSON response → pairing.response_invalid', () async {
      final transport = FakeTransport(
        (_, _, _, _) async => const LomHttpResponse(502, '<html>bad gateway</html>'),
      );
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      await expectLater(
        api.inspect(pairingId: 'x', claimToken: 'y'),
        throwsA(
          isA<LomPairingException>().having(
            (e) => e.code,
            'code',
            'pairing.response_invalid',
          ),
        ),
      );
    });

    test('transport throw → net.unreachable', () async {
      final transport = FakeTransport(
        (_, _, _, _) async => throw StateError('socket'),
      );
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      await expectLater(
        api.inspect(pairingId: 'x', claimToken: 'y'),
        throwsA(
          isA<LomPairingException>().having(
            (e) => e.code,
            'code',
            'net.unreachable',
          ),
        ),
      );
    });

    test('confirm retries awaiting_desktop then succeeds', () async {
      var attempts = 0;
      final transport = FakeTransport((method, uri, headers, body) async {
        attempts++;
        if (attempts <= 2) return err(409, 'pairing.awaiting_desktop');
        return ok({
          'device_id': 'dev_0123456789abcdef0123456789abcdef',
          'device_token': 't' * 43,
          'token_expires_at': 1763000000,
          'desktop_name': 'My PC',
        });
      });
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final waits = <Duration>[];
      final creds = await api.confirmAwaitingDesktop(
        pairingId: 'p',
        claimSecret: 's',
        sleep: (d) async => waits.add(d),
      );
      expect(creds.deviceId, startsWith('dev_'));
      expect(attempts, 3);
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    });

    test('confirm gives up after 15 awaiting_desktop → desktop_timeout', () async {
      var attempts = 0;
      final transport = FakeTransport((_, _, _, _) async {
        attempts++;
        return err(409, 'pairing.awaiting_desktop');
      });
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      await expectLater(
        api.confirmAwaitingDesktop(
          pairingId: 'p',
          claimSecret: 's',
          sleep: (_) async {},
        ),
        throwsA(
          isA<LomPairingException>().having(
            (e) => e.code,
            'code',
            'pairing.desktop_timeout',
          ),
        ),
      );
      expect(attempts, 15);
    });

    test('claim-by-code posts the normalised code', () async {
      Map<String, dynamic>? seen;
      final transport = FakeTransport((method, uri, headers, body) async {
        seen = jsonDecode(body!) as Map<String, dynamic>;
        return ok({
          'pairing_id': 'mntD9iGtAxNFEDb-v4rUSg',
          'desktop_name': 'My PC',
          'desktop_keys': 'K' * 86,
          'masked_account': 'a***@example.com',
          'expires_at': 1763000000,
          'claim_secret': 'secret-2',
        });
      });
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final res = await api.claimByCode(
        manualCode: 'AB3D-9XK2',
        deviceKeys: 'K' * 86,
        deviceInfo: _deviceInfo,
      );
      expect(res.claimSecret, 'secret-2');
      expect(seen?['manual_code'], 'AB3D-9XK2');
      expect(seen?.containsKey('key_proof'), isFalse);
    });

    test('relayToken returns the token', () async {
      final transport = FakeTransport((method, uri, headers, body) async {
        expect(headers?['Authorization'], startsWith('Device dev_'));
        return ok({'relay_token': 'r' * 43, 'expires_at': 1763003600});
      });
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final token = await api.relayToken(
        deviceId: 'dev_abc',
        deviceToken: 'tok',
      );
      expect(token.relayToken, 'r' * 43);
      expect(token.expiresAt, 1763003600);
    });
  });

  group('LomCredentialStore (in-memory stand-in)', () {
    test('save → load round-trip, then clear', () async {
      final values = <String, String>{};
      final store = _MapStore(values);
      final creds = LomCredentialStore(store);
      expect(await creds.load(), isNull);
      await creds.save(
        const LomDeviceCredentials(
          deviceId: 'dev_abc',
          deviceToken: 'tok',
          tokenExpiresAt: 1763000000,
          desktopName: 'My PC',
        ),
        host: 'lom.entermodetwo.com',
        desktopKeys: 'K' * 86,
        desktopName: 'My PC',
      );
      final loaded = await creds.load();
      expect(loaded?.deviceId, 'dev_abc');
      expect(loaded?.desktopKeys, {'K' * 86});
      expect(loaded?.host, 'lom.entermodetwo.com');
      await creds.clear();
      expect(await creds.load(), isNull);
    });
  });

  group('lomBackoffDelay', () {
    test('schedule 1/2/5/10/30 with ±20% jitter', () {
      for (final (failures, base) in [(0, 1), (1, 2), (2, 5), (3, 10), (4, 30), (9, 30)]) {
        for (var i = 0; i < 50; i++) {
          final d = lomBackoffDelay(failures);
          expect(d.inMilliseconds, greaterThanOrEqualTo((base * 800).round()));
          expect(d.inMilliseconds, lessThanOrEqualTo((base * 1200).round()));
        }
      }
    });
  });
}

class _MapStore implements LomSecretStore {
  _MapStore(this.values);
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}
