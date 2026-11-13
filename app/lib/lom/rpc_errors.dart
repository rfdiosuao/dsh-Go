/// Lom RPC error codes (doc §06 §7, §07 §2.9).
///
/// A reply's `error` field must match `^[a-z_]+\.[a-z_]+$` and must never
/// carry exception text, paths, stack traces or secrets. [LomRpcException]
/// carries only a code; [lomErrorCode] maps anything else to
/// `remote.operation_failed`.
library;

/// One RPC failure, carrying only an error code — never a message.
class LomRpcException implements Exception {
  LomRpcException(this.code);
  final String code;
  @override
  String toString() => 'LomRpcException($code)';
}

final _errorCodePattern = RegExp(r'^[a-z_]+\.[a-z_]+$');

/// Extracts the reply-safe error code from [error]: a well-formed code
/// from [LomRpcException] or [LomEngineException], anything else (including
/// DSH codes such as `gateway/...`, which contain `/`) becomes
/// `remote.operation_failed`.
String lomErrorCode(Object error) {
  final String? code;
  if (error is LomRpcException) {
    code = error.code;
  } else if (error is LomEngineException) {
    code = error.code;
  } else {
    code = null;
  }
  if (code != null && _errorCodePattern.hasMatch(code)) return code;
  return 'remote.operation_failed';
}

/// Thrown by the engine adapter when the DSH engine answers with a known
/// failure. [code] is already a reply-safe Lom error code.
class LomEngineException implements Exception {
  LomEngineException(this.code);
  final String code;
  @override
  String toString() => 'LomEngineException($code)';
}
