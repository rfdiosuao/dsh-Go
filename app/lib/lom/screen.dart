/// `screen.capture` / `screen.tree` / `screen.control` (doc §07 §8).
///
/// The Dart side of this group is complete: request validation, capture
/// throttling, tree capping / password masking, and receipt-first
/// idempotency for `screen.control`. What is **not** here is the native
/// bridge: the phone driver (`PhoneA11yService` / `MainScreenDriver` /
/// `ScreenShooter`, `PhoneControl`) is driven by its own internal task
/// engine with three-confirmation gates, and no Dart-callable method
/// exists for it. Wiring Lom control past those gates blind would be a
/// safety change, so the methods stay `remote.method_unknown` (not in
/// `device.capabilities`) until the bridge lands.
///
/// ## Native bridge spec (for the follow-up)
///
/// Add these methods to the `dsh/phone` MethodChannel (`PhonePlugin.kt`),
/// mirroring `lomListApps`:
/// * `lomScreenInfo` () → `{width, height, a11yEnabled,
///   serviceConnected, metered}` — original screen pixels; `metered`
///   is whether the current network is metered.
/// * `lomScreenCapture` ({quality: `low`/`balanced`/`high`,
///   cellularCap: bool}) → `{bytes: Uint8List, width, height,
///   capturedAtMs}` — JPEG, long edge ≈ 480 / 720 / 1080 px; the native
///   side lowers quality until the bytes fit the cap the Dart side
///   enforces (260,000, or 45,000 when capped).
/// * `lomScreenTree` () → `{package, nodes: [{text, description,
///   resource, bounds: [x1, y1, x2, y2], clickable, editable, focused,
///   isPassword}]}` — flattened, deepest-first order; password fields
///   flagged, never their content.
/// * `lomScreenControl` ({action, x, y, x2, y2, text, packageName}) →
///   `{atMs, confirmation}` — throws a `PlatformException` whose `code`
///   is the `screen.*` code when the system refuses the action
///   (`screen.app_missing`, `screen.no_focused_input`,
///   `screen.action_unconfirmed`, `screen.no_window`).
/// The Dart adapter for those methods (`MethodChannelLomScreenAdapter`)
/// is a thin translation of the shapes above; it does not exist yet
/// because the native methods do not exist yet.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'phase4_store.dart';
import 'screen_types.dart';
import 'rpc_errors.dart';

/// The dispatcher-side protocol layer for `screen.*`.
class LomScreenHandler {
  LomScreenHandler({
    required this.adapter,
    required this.receipts,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _now = now ?? DateTime.now,
        _sleep = sleep ?? Future.delayed;

  final LomScreenAdapter adapter;
  final LomOperationReceiptStore receipts;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  /// JPEG cap in bytes (260,000), and the capped value under
  /// `cellular_cap` on a metered network (45,000).
  static const maxJpegBytes = 260000;
  static const maxCappedJpegBytes = 45000;

  /// Minimum interval between captures (400 ms), and under
  /// `cellular_cap` on a metered network (2 s).
  static const minCaptureIntervalMs = 400;
  static const minCappedCaptureIntervalMs = 2000;

  static const maxNodes = 300;
  static const maxNodeTextChars = 160;

  int _lastCaptureMs = 0;

  Future<Map<String, Object?>> handle(
    String method,
    Map<String, dynamic> payload,
    String sender,
  ) async {
    switch (method) {
      case 'screen.capture':
        return _capture(payload);
      case 'screen.tree':
        return _tree();
      case 'screen.control':
        return _control(payload);
      default:
        throw LomRpcException('remote.method_unknown');
    }
  }

  Future<Map<String, Object?>> _capture(
    Map<String, dynamic> payload,
  ) async {
    final quality = _string(payload, 'quality');
    if (!const {'low', 'balanced', 'high'}.contains(quality)) {
      throw LomRpcException('screen.invalid_request');
    }
    final cellularCap = _string(payload, 'cellular_cap') == 'true';
    final info = await adapter.info();
    if (!info.permissionOk) {
      throw LomRpcException('screen.permission_required');
    }
    final capped = cellularCap && info.metered;
    final minInterval =
        capped ? minCappedCaptureIntervalMs : minCaptureIntervalMs;
    final nowMs = _now().millisecondsSinceEpoch;
    final elapsed = nowMs - _lastCaptureMs;
    if (elapsed < minInterval) {
      // Wait out the interval instead of failing: the doc requires
      // the gap, it does not define a throttle error code.
      await _sleep(Duration(milliseconds: minInterval - elapsed));
    }
    final shot = await adapter.capture(
      quality: capped ? 'low' : quality,
      cellularCap: cellularCap,
    );
    if (shot.width <= 0 || shot.height <= 0) {
      throw LomRpcException('screen.capture_failed');
    }
    final maxBytes = capped ? maxCappedJpegBytes : maxJpegBytes;
    if (shot.jpegBytes.length > maxBytes) {
      throw LomRpcException('screen.frame_too_large');
    }
    final image = base64Encode(shot.jpegBytes);
    if (image.length > 800000) {
      throw LomRpcException('screen.frame_too_large');
    }
    _lastCaptureMs = _now().millisecondsSinceEpoch;
    return {
      'image': image,
      'mime': 'image/jpeg',
      'width': '${shot.width}',
      'height': '${shot.height}',
      'captured_at': '${shot.capturedAtMs > 0 ? shot.capturedAtMs : nowMs}',
    };
  }

  Future<Map<String, Object?>> _tree() async {
    final info = await adapter.info();
    if (!info.permissionOk) {
      throw LomRpcException('screen.permission_required');
    }
    final tree = await adapter.tree();
    final nodes = tree.nodes.take(maxNodes).toList();
    return {
      'package': tree.package,
      'nodes': [
        for (final node in nodes)
          {
            'text': node.isPassword
                ? '[password]'
                : _truncate(node.text, maxNodeTextChars),
            'description': _truncate(node.description, maxNodeTextChars),
            'resource': node.resource,
            'bounds': node.bounds,
            'clickable': node.clickable,
            'editable': node.editable,
            'focused': node.focused,
          },
      ],
      'truncated': tree.truncated || tree.nodes.length > maxNodes,
    };
  }

  /// `screen.control`: validate, then write the "result unknown"
  /// receipt **before** executing, then update it to "completed".
  /// A re-send of the same `request_id` replays the stored result when
  /// completed, answers `screen.previous_result_unknown` while the
  /// receipt is still unknown (never re-execute a tap), and
  /// `screen.id_reused` when the content differs.
  Future<Map<String, Object?>> _control(
    Map<String, dynamic> payload,
  ) async {
    final action = await _parseAction(payload);
    final key = 'screen.control:${action.requestId}';
    final contentHash = crypto.sha256
        .convert(utf8.encode(jsonEncode(action.toContentJson())))
        .toString();
    final existing = await receipts.receiptFor(key);
    if (existing != null) {
      if (existing.contentHash != contentHash) {
        throw LomRpcException('screen.id_reused');
      }
      if (existing.status == 'completed') {
        final stored = jsonDecode(existing.detail) as Map<String, dynamic>;
        return {
          'status': 'completed',
          'action': stored['action'],
          'at': stored['at'],
          'confirmation': stored['confirmation'],
        };
      }
      throw LomRpcException('screen.previous_result_unknown');
    }
    try {
      await receipts.saveReceipt(
        LomOperationReceipt(
          key: key,
          contentHash: contentHash,
          status: 'unknown',
          sessionId: '',
          updatedAtMs: _now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {
      throw LomRpcException('screen.receipt_failed');
    }
    final result = await adapter.control(action);
    final response = {
      'status': 'completed',
      'action': action.action,
      'at': result.atMs,
      'confirmation': result.confirmation,
    };
    await receipts.saveReceipt(
      LomOperationReceipt(
        key: key,
        contentHash: contentHash,
        status: 'completed',
        sessionId: '',
        updatedAtMs: _now().millisecondsSinceEpoch,
        detail: jsonEncode(response),
      ),
    );
    return response;
  }

  Future<LomScreenAction> _parseAction(Map<String, dynamic> payload) async {
    final requestId = _string(payload, 'request_id');
    if (!RegExp(r'^[A-Za-z0-9-]{16,64}$').hasMatch(requestId)) {
      throw LomRpcException('screen.invalid_request');
    }
    final action = _string(payload, 'action');
    if (!const {'tap', 'swipe', 'type', 'back', 'home', 'open_app'}
        .contains(action)) {
      throw LomRpcException('screen.invalid_action');
    }
    final text = _string(payload, 'text');
    final packageName = _string(payload, 'package_name');
    switch (action) {
      case 'tap':
        final (x, y) = await _point(payload, 'x', 'y');
        return LomScreenAction(
          requestId: requestId,
          action: action,
          x: x,
          y: y,
        );
      case 'swipe':
        final (x, y) = await _point(payload, 'x', 'y');
        final (x2, y2) = await _point(payload, 'x2', 'y2');
        return LomScreenAction(
          requestId: requestId,
          action: action,
          x: x,
          y: y,
          x2: x2,
          y2: y2,
        );
      case 'type':
        if (text.isEmpty) throw LomRpcException('screen.invalid_request');
        if (text.length > 8000) {
          throw LomRpcException('screen.text_too_long');
        }
        return LomScreenAction(
          requestId: requestId,
          action: action,
          text: text,
        );
      case 'open_app':
        if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
            .hasMatch(packageName)) {
          throw LomRpcException('screen.invalid_package');
        }
        return LomScreenAction(
          requestId: requestId,
          action: action,
          packageName: packageName,
        );
      default:
        return LomScreenAction(requestId: requestId, action: action);
    }
  }

  /// Parses and bounds-checks one point against the current screen.
  /// The screen size is read fresh: the phone may have rotated since
  /// the last capture.
  Future<(int, int)> _point(
    Map<String, dynamic> payload,
    String xKey,
    String yKey,
  ) async {
    final x = int.tryParse(_string(payload, xKey));
    final y = int.tryParse(_string(payload, yKey));
    if (x == null || y == null) {
      throw LomRpcException('screen.invalid_coordinate');
    }
    final info = await adapter.info();
    if (x < 0 || y < 0 || x >= info.width || y >= info.height) {
      throw LomRpcException('screen.invalid_coordinate');
    }
    return (x, y);
  }

  String _truncate(String text, int maxChars) =>
      text.length <= maxChars ? text : text.substring(0, maxChars);

  String _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String ? value : '';
  }
}
