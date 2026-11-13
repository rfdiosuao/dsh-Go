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
