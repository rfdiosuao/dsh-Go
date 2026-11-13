import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/lom/lom_phone.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSocket implements LomWebSocket {
  _FakeSocket(this.incoming);
  final StreamController<String> incoming;
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get messages => incoming.stream;

  @override
  Future<void> sendText(String text) async => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

class _FakeFactory implements LomWebSocketFactory {
  _FakeFactory(this.makeSocket);
  final _FakeSocket Function(Uri uri, Map<String, String>? headers) makeSocket;
  final List<(Uri, Map<String, String>?)> connects = [];

  @override
  Future<LomWebSocket> connect(
    Uri uri, {
    Map<String, String>? headers,
    Duration pingInterval = const Duration(seconds: 20),
  }) async {
    connects.add((uri, headers));
    return makeSocket(uri, headers);
  }
}

LomCredentials _creds() => const LomCredentials(
      deviceId: 'dev_abc',
      deviceToken: 'tok',
      tokenExpiresAt: 1999999999,
      host: 'lom.entermodetwo.com',
      desktopKeys: {},
      desktopName: 'My PC',
    );

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

class _TokenTransport implements LomHttpTransport {
  _TokenTransport({this.relayTokenFailsWith});
  final String? relayTokenFailsWith;
  var tokenCalls = 0;

  @override
  Future<LomHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  }) async {
    if (uri.path == '/v1/relay/token') {
      tokenCalls++;
      if (relayTokenFailsWith != null) {
        return LomHttpResponse(
          401,
          jsonEncode({
            'success': false,
            'code': relayTokenFailsWith,
            'error': 'x',
          }),
        );
      }
      return LomHttpResponse(
        200,
        jsonEncode({
          'success': true,
          'data': {'relay_token': 'r' * 43, 'expires_at': 1763003600},
        }),
      );
    }
    throw StateError('unexpected POST ${uri.path}');
  }

  @override
  Future<LomHttpResponse> delete(
    Uri uri, {
    Map<String, String>? headers,
  }) async =>
      throw UnimplementedError();
}

void main() {
  group('LomRelayClient', () {
    test('connects with a fresh relay token and records hello server_time', () async {
      final transport = _TokenTransport();
      final store = _MapStore();
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final incoming = StreamController<String>();
      final factory = _FakeFactory((uri, headers) => _FakeSocket(incoming));
      final states = <LomConnectionState>[];
      int? serverTime;
      final client = LomRelayClient(
        credentials: _creds(),
        api: api,
        webSocketFactory: factory,
        credentialStore: LomCredentialStore(store),
        onStateChange: (s, _) => states.add(s),
        onServerTime: (t) => serverTime = t,
        sleep: (_) async {},
      );
      client.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(transport.tokenCalls, 1);
      expect(factory.connects.length, 1);
      expect(factory.connects[0].$1.toString(), 'wss://lom.entermodetwo.com/v1/relay');
      expect(factory.connects[0].$2?['Authorization'], 'Bearer ${'r' * 43}');
      expect(states, contains(LomConnectionState.connected));
      incoming.add(jsonEncode({
        'v': 1,
        'kind': 'ctrl',
        'type': 'hello',
        'device_id': 'dev_abc',
        'server_time': 1767222000,
      }));
      await Future<void>.delayed(Duration.zero);
      expect(serverTime, 1767222000);
      // Unknown types and unparsable frames are ignored, connection survives.
      incoming.add('not json');
      incoming.add(jsonEncode({'type': 'something.new'}));
      await Future<void>.delayed(Duration.zero);
      expect(client.state, LomConnectionState.connected);
      await client.stop();
    });

    test('device.revoked clears credentials and stops reconnecting', () async {
      final transport = _TokenTransport();
      final store = _MapStore();
      final credStore = LomCredentialStore(store);
      await credStore.save(
        const LomDeviceCredentials(
          deviceId: 'dev_abc',
          deviceToken: 'tok',
          tokenExpiresAt: 1999999999,
          desktopName: 'My PC',
        ),
        host: 'lom.entermodetwo.com',
        desktopKeys: 'K' * 86,
        desktopName: 'My PC',
      );
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final incoming = StreamController<String>();
      final factory = _FakeFactory((uri, headers) => _FakeSocket(incoming));
      final states = <LomConnectionState>[];
      final client = LomRelayClient(
        credentials: _creds(),
        api: api,
        webSocketFactory: factory,
        credentialStore: credStore,
        onStateChange: (s, _) => states.add(s),
        sleep: (_) async {},
      );
      client.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      incoming.add(jsonEncode({'v': 1, 'kind': 'ctrl', 'type': 'device.revoked'}));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(states, contains(LomConnectionState.revoked));
      expect(await credStore.load(), isNull);
      expect(transport.tokenCalls, 1); // no reconnect after revocation
      await client.stop();
    });

    test('relay.device_revoked on token exchange revokes without reconnect', () async {
      final transport = _TokenTransport(relayTokenFailsWith: 'relay.device_revoked');
      final store = _MapStore();
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      final factory = _FakeFactory((uri, headers) => _FakeSocket(StreamController<String>()));
      final states = <LomConnectionState>[];
      final client = LomRelayClient(
        credentials: _creds(),
        api: api,
        webSocketFactory: factory,
        credentialStore: LomCredentialStore(store),
        onStateChange: (s, _) => states.add(s),
        sleep: (_) async {},
      );
      client.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(states, contains(LomConnectionState.revoked));
      expect(factory.connects, isEmpty);
      await client.stop();
    });

    test('socket close triggers a reconnect with a fresh token', () async {
      final transport = _TokenTransport();
      final store = _MapStore();
      final api = LomPairingApi(
        baseUrl: 'https://lom.entermodetwo.com',
        transport: transport,
      );
      var sockets = 0;
      StreamController<String>? current;
      final factory = _FakeFactory((uri, headers) {
        sockets++;
        current = StreamController<String>();
        return _FakeSocket(current!);
      });
      final client = LomRelayClient(
        credentials: _creds(),
        api: api,
        webSocketFactory: factory,
        credentialStore: LomCredentialStore(store),
        sleep: (_) async {},
      );
      client.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sockets, 1);
      // Drop the socket: the client must reconnect and re-exchange the token.
      await current!.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await Future<void>.delayed(Duration.zero);
      expect(sockets, greaterThanOrEqualTo(2));
      expect(transport.tokenCalls, greaterThanOrEqualTo(2));
      await client.stop();
    });
  });
}
