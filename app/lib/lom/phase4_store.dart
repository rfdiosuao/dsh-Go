/// Persistent Lom Phase 4 state: chat pins and the Lom device name.
///
/// Both live in the Keystore-backed [LomSecretStore] (`lom.` namespace),
/// next to the Phase 2/3 documents — never SharedPreferences, never logs.
library;

import 'credentials.dart';
import 'json_doc.dart';

/// Pinned sessions (doc §07 `chat.pin`).
///
/// DSH sessions have no pin concept, so pinning is a Lom-side overlay:
/// `chat.list` reports `pinned` from here, and `chat.pin` only flips this
/// set — it never archives or hides a session (archiving would remove it
/// from `chat.list`, which is not what pinning means).
class LomPinStore {
  LomPinStore(this._store);

  final LomSecretStore _store;
  static const _key = 'lom.chat_pins';

  late final _doc = LomJsonDoc(_store, _key);

  Future<Set<String>> pinnedIds() async {
    final doc = await _doc.load();
    return {for (final k in doc.keys) if (doc[k] == true) k};
  }

  Future<void> setPinned(String sessionId, bool pinned) =>
      _doc.mutate((doc) {
        if (pinned) {
          doc[sessionId] = true;
        } else {
          doc.remove(sessionId);
        }
      });
}

/// The Lom device name (doc §07 `device.rename`).
///
/// Stored independently of the DSH Remote device/host name: renaming the
/// phone for Lom must not rename it anywhere else. The reply echoes the
/// requested name verbatim, so the stored value is exactly what was asked.
class LomDeviceNameStore {
  LomDeviceNameStore(this._store);

  final LomSecretStore _store;
  static const _key = 'lom.device_name';

  late final _doc = LomJsonDoc(_store, _key);

  Future<String> load() async {
    final doc = await _doc.load();
    final name = doc['name'];
    return name is String ? name : '';
  }

  Future<void> save(String name, int updatedAtMs) => _doc.mutate((doc) {
        doc['name'] = name;
        doc['updated_at_ms'] = updatedAtMs;
      });
}

/// One persisted idempotency receipt for an operation whose outcome the
/// desktop may need to re-ask about (doc §07 §2): `schedule.run`
/// (`dispatching` → `accepted` / `failed`) and, later, `screen.control`
/// (`unknown` → `completed`). The receipt is written **before** the
/// operation starts, so a retry with the same key never double-executes.
class LomOperationReceipt {
  const LomOperationReceipt({
    required this.key,
    required this.contentHash,
    required this.status,
    required this.sessionId,
    required this.updatedAtMs,
    this.detail = '',
  });

  factory LomOperationReceipt.fromJson(Map<String, Object?> json) =>
      LomOperationReceipt(
        key: json['key'] as String? ?? '',
        contentHash: json['content_hash'] as String? ?? '',
        status: json['status'] as String? ?? 'dispatching',
        sessionId: json['session_id'] as String? ?? '',
        updatedAtMs: json['updated_at_ms'] as int? ?? 0,
        detail: json['detail'] as String? ?? '',
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'content_hash': contentHash,
        'status': status,
        'session_id': sessionId,
        'updated_at_ms': updatedAtMs,
        'detail': detail,
      };

  /// The idempotency key (`schedule.run:<request_id>`,
  /// `screen.control:<request_id>`).
  final String key;

  /// SHA-256 of the operation's content: the same key with different
  /// content is an id-reuse error, not a replay.
  final String contentHash;

  /// Caller-defined status (`dispatching` / `accepted` / `failed`,
  /// `unknown` / `completed`).
  final String status;

  /// Session the operation ran in, when known.
  final String sessionId;
  final int updatedAtMs;

  /// The stored reply for a completed operation, as JSON text
  /// (`screen.control` replays the original `{status, action, at,
  /// confirmation}` from it; other operations leave it empty).
  final String detail;
}

/// Persistent operation receipts, keyed by idempotency key.
class LomOperationReceiptStore {
  LomOperationReceiptStore(this._store);

  final LomSecretStore _store;
  static const _key = 'lom.op_receipts';

  late final _doc = LomJsonDoc(_store, _key);

  Future<LomOperationReceipt?> receiptFor(String key) async {
    final doc = await _doc.load();
    final raw = doc[key];
    if (raw is! Map<String, dynamic>) return null;
    return LomOperationReceipt.fromJson(Map<String, Object?>.from(raw));
  }

  Future<void> saveReceipt(LomOperationReceipt receipt) =>
      _doc.mutate((doc) {
        doc[receipt.key] = receipt.toJson();
      });
}
