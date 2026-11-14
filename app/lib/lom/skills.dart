/// `skills.list` / `skills.read` / `skills.install` / `skills.toggle` /
/// `skills.delete` (doc §07 §9).
///
/// This phase keeps a **Lom-side registry** in the Lom store
/// (`lom.skills`): installing a skill registers its parsed `SKILL.md`
/// (name / description / version / body). The ZIP itself is validated
/// strictly and the package's other files are **not** persisted — wiring
/// installed skills into DSH engine skill loading needs an engine API
/// that was not found (`skills/list` is per-session and read-only; the
/// phone's native skills live under workspace `skills/phone-task-<hash>/`
/// and have no install RPC). That wiring is a documented follow-up; the
/// desktop must not assume an installed skill is already callable by the
/// phone's Agent.
///
/// `SKILL.md` format follows the DSH bundled skills (e.g.
/// `app/assets/skills/dsh-go-guide/SKILL.md`): `name:` / `description:` /
/// `whenToUse:` lines at the top, a `---` separator, then the body.
/// `version:` is optional and defaults to `1.0.0` — DSH skills carry no
/// version field, and refusing them all would make install useless.
/// The body is capped at 150,000 UTF-8 bytes (the same cap as a Lom
/// document): `skills.read` must fit the 350,000-byte reply limit, and
/// the Lom store is not a file store.
library;

import 'dart:convert';

import 'credentials.dart';
import 'file_store.dart';
import 'json_doc.dart';
import 'rpc_errors.dart';
import 'skill_zip.dart';


/// One installed skill. All fields are strings, per doc §07 §9.
class LomSkill {
  const LomSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.enabled,
    required this.body,
    required this.installedAtMs,
  });

  factory LomSkill.fromJson(Map<String, Object?> json) => LomSkill(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        version: json['version'] as String? ?? '1.0.0',
        enabled: json['enabled'] as String? ?? 'true',
        body: json['body'] as String? ?? '',
        installedAtMs: json['installed_at_ms'] as int? ?? 0,
      );

  Map<String, Object?> toJson({bool withBody = true}) => {
        'id': id,
        'name': name,
        'description': description,
        'version': version,
        'enabled': enabled,
        'body': withBody ? body : '',
        'installed_at_ms': installedAtMs,
      };

  final String id;
  final String name;
  final String description;
  final String version;
  final String enabled;
  final String body;
  final int installedAtMs;
}

class LomSkillRegistry {
  LomSkillRegistry(
    this._store, {
    required this.files,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LomSecretStore _store;
  final LomFileStore files;
  final DateTime Function() _now;
  static const _key = 'lom.skills';

  late final _doc = LomJsonDoc(_store, _key);

  Future<Map<String, Object?>> handle(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'skills.list':
        return _list();
      case 'skills.read':
        return _read(_id(payload));
      case 'skills.install':
        return _install(_id(payload), sender);
      case 'skills.toggle':
        return _toggle(_id(payload), _string(payload, 'enabled'));
      case 'skills.delete':
        return _delete(_id(payload));
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  Future<Map<String, Object?>> _list() async {
    final skills = await _all();
    return {
      'items': jsonEncode([
        for (final skill in skills) skill.toJson(withBody: false),
      ]),
    };
  }

  Future<Map<String, Object?>> _read(String id) async {
    final skill = await _find(id);
    if (skill == null) throw LomRpcException('skill.not_found');
    return skill.toJson();
  }

  Future<Map<String, Object?>> _install(
    String transferId,
    String sender,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9-]{16,64}$').hasMatch(transferId)) {
      throw LomRpcException('skill.invalid_transfer');
    }
    final bytes = await files.completeBytes(transferId, sender);
    if (bytes == null) throw LomRpcException('skill.invalid_transfer');
    if (bytes.length > skillMaxPackageBytes) {
      throw LomRpcException('skill.package_too_large');
    }
    // Validate everything before writing anything, so a rejected
    // package never leaves partial state behind.
    final parsed = validateSkillZip(bytes);
    final skill = LomSkill(
      id: parsed.name,
      name: parsed.name,
      description: parsed.description,
      version: parsed.version,
      enabled: 'true',
      body: parsed.body,
      installedAtMs: _now().millisecondsSinceEpoch,
    );
    final inserted = await _doc.mutate((doc) async {
      if (doc.containsKey(skill.id)) return null;
      doc[skill.id] = skill.toJson();
      return skill;
    });
    if (inserted == null) {
      throw LomRpcException('skill.already_exists_or_invalid_name');
    }
    return inserted.toJson();
  }

  Future<Map<String, Object?>> _toggle(String id, String enabled) async {
    if (enabled != 'true' && enabled != 'false') {
      throw LomRpcException('skill.invalid_toggle');
    }
    final updated = await _doc.mutate((doc) async {
      final raw = doc[id];
      if (raw is! Map<String, dynamic>) return null;
      final skill = LomSkill.fromJson(Map<String, Object?>.from(raw));
      final next = LomSkill(
        id: skill.id,
        name: skill.name,
        description: skill.description,
        version: skill.version,
        enabled: enabled,
        body: skill.body,
        installedAtMs: skill.installedAtMs,
      );
      doc[id] = next.toJson();
      return next;
    });
    if (updated == null) throw LomRpcException('skill.not_found');
    return updated.toJson();
  }

  Future<Map<String, Object?>> _delete(String id) async {
    final removed = await _doc.mutate((doc) async {
      if (!doc.containsKey(id)) return false;
      doc.remove(id);
      return true;
    });
    if (!removed) throw LomRpcException('skill.not_found');
    // Confirm the delete actually landed.
    if (await _find(id) != null) {
      throw LomRpcException('skill.delete_failed');
    }
    return {'status': 'deleted'};
  }

  Future<List<LomSkill>> _all() async {
    final doc = await _doc.load();
    final skills = [
      for (final raw in doc.values)
        if (raw is Map<String, dynamic>)
          LomSkill.fromJson(Map<String, Object?>.from(raw)),
    ];
    skills.sort((a, b) => a.installedAtMs.compareTo(b.installedAtMs));
    return skills;
  }

  Future<LomSkill?> _find(String id) async {
    final doc = await _doc.load();
    final raw = doc[id];
    if (raw is! Map<String, dynamic>) return null;
    return LomSkill.fromJson(Map<String, Object?>.from(raw));
  }

  String _id(Map<String, dynamic> payload) => _string(payload, 'id');

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }
}
