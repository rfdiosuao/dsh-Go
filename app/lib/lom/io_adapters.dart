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
import 'file_storage.dart';

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

/// [LomFileStorage] backed by real files under [root] (`<root>/<key>.bin`,
/// one subdirectory per sending desktop). Writes use random access, so a
/// resumed chunk only rewrites its own slice; every write is flushed and
/// the file closed before the RPC returns.
class IoLomFileStorage implements LomFileStorage {
  IoLomFileStorage(this.root);

  final io.Directory root;

  io.File _file(String key) => io.File('${root.path}/$key.bin');

  @override
  Future<void> create(String key) async {
    final file = _file(key);
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.create();
  }

  @override
  Future<void> writeAt(String key, int offset, List<int> bytes) async {
    final file = _file(key);
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.create();
    // `write` / `writeOnly` truncate on open; `append` does not, and
    // `setPosition` still positions the write (verified by test).
    final raf = await file.open(mode: io.FileMode.append);
    try {
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  @override
  Future<List<int>> readAt(String key, int offset, int length) async {
    final file = _file(key);
    if (!await file.exists()) return [];
    final raf = await file.open(mode: io.FileMode.read);
    try {
      final size = await raf.length();
      if (offset >= size) return [];
      await raf.setPosition(offset);
      final want = length.clamp(0, size - offset);
      return await raf.read(want);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<String?> localPath(String key) async {
    final file = _file(key);
    return await file.exists() ? file.path : null;
  }
}
