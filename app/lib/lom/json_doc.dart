/// One JSON object document in a [LomSecretStore], with serialized writes.
///
/// Extracted from `rpc_store.dart` so the Phase 4 stores (pins, device
/// name, operation receipts, skills, file metadata) share the same
/// load–update–save discipline: writes to one document are serialized
/// through a future chain, so two concurrent mutations cannot both read
/// a stale document.
library;

import 'dart:async';
import 'dart:convert';

import 'credentials.dart';

/// A single JSON document (`Map<String, Object?>`) persisted under one
/// secret-store key.
class LomJsonDoc {
  LomJsonDoc(this._store, this._key);

  final LomSecretStore _store;
  final String _key;
  Future<void> _tail = Future.value();

  Future<Map<String, Object?>> _load() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return Map<String, Object?>.from(decoded);
    }
    return {};
  }

  /// Runs [update] against the freshly loaded document, then persists it.
  /// Calls are serialized: a later [mutate] only starts after the earlier
  /// one's load–update–save has finished.
  Future<T> mutate<T>(
    FutureOr<T> Function(Map<String, Object?> doc) update,
  ) {
    final run = _tail.then((_) async {
      final doc = await _load();
      final result = await update(doc);
      await _store.write(_key, jsonEncode(doc));
      return result;
    });
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Map<String, Object?>> load() => _tail.then((_) => _load());
}
