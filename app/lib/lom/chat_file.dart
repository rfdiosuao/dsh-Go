/// `chat.file` / `chat.image` (doc §07 §4).
///
/// Both register real bytes as finished `file.*` transfers (via
/// `LomFileStore.registerComplete`) and return the `FileState`, so the
/// desktop then reads them with `file.read`. Nothing here accepts a
/// caller-supplied path: `chat.file` only exports an attachment that
/// actually exists on the named message, and `chat.image` only reads
/// inside the session's sandbox through the engine.
library;

import 'engine.dart';
import 'file_storage.dart';
import 'file_store.dart';
import 'rpc_errors.dart';

const _imageMimes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

class LomChatFileHandler {
  LomChatFileHandler({
    required this.engine,
    required this.files,
    required this.findMessage,
  });

  final LomEngine engine;
  final LomFileStore files;

  /// Looks a message up in the dispatcher's history cache (refreshing it
  /// from the engine). Throws `chat.session_missing` when the session
  /// does not exist; returns null when the message is not there.
  final Future<LomChatMessage?> Function(String sessionId, String messageId)
      findMessage;

  Future<Map<String, Object?>> handle(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'chat.file':
        return (await _chatFile(payload, sender)).toFileState();
      case 'chat.image':
        return (await _chatImage(payload, sender)).toFileState();
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  /// `chat.file`: `{session_id, message_id, index}` — `index` is a
  /// decimal string into the message's `attachments`.
  Future<LomFileRecord> _chatFile(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    final messageId = _string(payload, 'message_id');
    final message = await findMessage(sessionId, messageId);
    if (message == null) throw LomRpcException('file.message_missing');
    final index = int.tryParse(_string(payload, 'index'));
    if (index == null ||
        index < 0 ||
        index >= message.attachments.length ||
        index >= message.attachmentRefs.length) {
      throw LomRpcException('file.attachment_missing');
    }
    final ref = message.attachmentRefs[index];
    final data = await engine.attachmentBytes(
      sessionId: sessionId,
      ref: ref,
    );
    return files.registerComplete(
      sender: sender,
      name: ref.name,
      mime: data.mime,
      bytes: data.bytes,
    );
  }

  /// `chat.image`: `{session_id, source}` — `source` is an image
  /// reference from the agent's reply text, resolved only inside the
  /// session's sandbox. Absolute paths, `..` segments, backslashes and
  /// non-image extensions are refused outright.
  Future<LomFileRecord> _chatImage(
    Map<String, dynamic> payload,
    String sender,
  ) async {
    final sessionId = _string(payload, 'session_id');
    if (sessionId.isEmpty) throw LomRpcException('chat.invalid_id');
    if (!await engine.sessionExists(sessionId)) {
      throw LomRpcException('chat.session_missing');
    }
    final source = _string(payload, 'source');
    final mime = _imageMime(source);
    if (mime == null) throw LomRpcException('file.invalid_source');
    final bytes = await engine.readSessionFile(sessionId, source);
    if (bytes.length > lomChatImageMaxBytes) {
      throw LomRpcException('file.invalid_source');
    }
    return files.registerComplete(
      sender: sender,
      name: source.split('/').last,
      mime: mime,
      bytes: bytes,
    );
  }

  /// Validates a sandbox-relative image path and returns its MIME, or
  /// null when the path is not an acceptable image reference.
  String? _imageMime(String source) {
    if (source.isEmpty ||
        source.startsWith('/') ||
        source.contains('\\') ||
        source.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    final segments = source.split('/');
    if (segments.any((s) => s == '..' || s == '.' || s.isEmpty)) {
      return null;
    }
    final ext = source.split('.').last.toLowerCase();
    if (source == ext) return null;
    return _imageMimes[ext];
  }

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }
}
