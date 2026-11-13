/// dart:io / package:http adapters for the Lom pairing + relay clients.
///
/// Kept separate from the pure logic so tests can substitute fakes.
/// Timeouts follow doc §03 §0: connect 10s, total 20s per request.
/// Secrets in headers/bodies only — never in the URL.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;

import 'pairing_api.dart';
import 'relay_client.dart';

/// [LomHttpTransport] backed by `package:http` over a dart:io client with
/// a 10s connection timeout; every call additionally has a 20s total cap.
class HttpLomTransport implements LomHttpTransport {
  HttpLomTransport([http.Client? client])
      : _client = client ??
            IOClient(io.HttpClient()
              ..connectionTimeout = const Duration(seconds: 10));

  final http.Client _client;

  @override
  Future<LomHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  }) async {
    final res = await _client
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 20));
    return LomHttpResponse(res.statusCode, res.body);
  }

  @override
  Future<LomHttpResponse> delete(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final res = await _client
        .delete(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    return LomHttpResponse(res.statusCode, res.body);
  }

  void close() => _client.close();
}

/// [LomWebSocket] backed by `dart:io`'s `WebSocket`: incoming Ping frames
/// are answered with Pong automatically, and [pingInterval] makes the
/// client send its own Ping every 20s (doc §05 §5).
class IoLomWebSocket implements LomWebSocket {
  IoLomWebSocket(this._socket);
  final io.WebSocket _socket;

  @override
  Stream<String> get messages => _socket
      .where((event) => event is String)
      .cast<String>();

  @override
  Future<void> sendText(String text) async => _socket.add(text);

  @override
  Future<void> close() async => _socket.close();
}

class IoLomWebSocketFactory implements LomWebSocketFactory {
  @override
  Future<LomWebSocket> connect(
    Uri uri, {
    Map<String, String>? headers,
    Duration pingInterval = const Duration(seconds: 20),
  }) async {
    final socket = await io.WebSocket.connect(uri.toString(), headers: headers);
    // `WebSocket.connect` takes no ping interval; the live socket does.
    socket.pingInterval = pingInterval;
    return IoLomWebSocket(socket);
  }
}
