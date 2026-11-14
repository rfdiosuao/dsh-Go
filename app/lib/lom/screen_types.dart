/// Screen data shapes and the native bridge interface for `screen.*`
/// (doc §07 §8). Split out of `screen.dart` so neither file passes the
/// 400-line limit. The handler lives in `screen.dart`.
library;

import 'rpc_errors.dart';

/// The phone's screen and permission state, as the adapter sees it.
class LomScreenInfo {
  const LomScreenInfo({
    required this.width,
    required this.height,
    required this.a11yEnabled,
    required this.serviceConnected,
    required this.metered,
  });

  /// Original screen pixels.
  final int width;
  final int height;

  /// The user turned the accessibility service on in system settings.
  final bool a11yEnabled;

  /// The service is bound and answering.
  final bool serviceConnected;

  /// The current network is metered.
  final bool metered;

  bool get permissionOk => a11yEnabled && serviceConnected;
}

class LomScreenCapture {
  const LomScreenCapture({
    required this.jpegBytes,
    required this.width,
    required this.height,
    required this.capturedAtMs,
  });

  final List<int> jpegBytes;
  final int width;
  final int height;
  final int capturedAtMs;
}

class LomScreenNode {
  const LomScreenNode({
    this.text = '',
    this.description = '',
    this.resource = '',
    this.bounds = const [0, 0, 0, 0],
    this.clickable = false,
    this.editable = false,
    this.focused = false,
    this.isPassword = false,
  });

  final String text;
  final String description;
  final String resource;

  /// `[x1, y1, x2, y2]` in original screen pixels.
  final List<int> bounds;
  final bool clickable;
  final bool editable;
  final bool focused;

  /// A password field: the text is never reported (see the handler).
  final bool isPassword;
}

class LomScreenTree {
  const LomScreenTree({
    required this.package,
    required this.nodes,
    this.truncated = false,
  });

  final String package;
  final List<LomScreenNode> nodes;
  final bool truncated;
}

/// One control action, already validated by the handler.
class LomScreenAction {
  const LomScreenAction({
    required this.requestId,
    required this.action,
    this.x,
    this.y,
    this.x2,
    this.y2,
    this.text = '',
    this.packageName = '',
  });

  final String requestId;
  final String action;
  final int? x;
  final int? y;
  final int? x2;
  final int? y2;
  final String text;
  final String packageName;

  /// The content the idempotency receipt hashes: everything that
  /// decides what the action does, in a fixed order.
  Map<String, Object?> toContentJson() => {
        'action': action,
        'x': x,
        'y': y,
        'x2': x2,
        'y2': y2,
        'text': text,
        'package_name': packageName,
      };
}

class LomScreenControlResult {
  const LomScreenControlResult({
    required this.atMs,
    required this.confirmation,
  });

  final int atMs;
  final String confirmation;
}

/// The native screen bridge. Implementations throw [LomRpcException]
/// with a `screen.*` code when the system refuses (`screen.app_missing`,
/// `screen.no_focused_input`, `screen.action_unconfirmed`,
/// `screen.no_window`); the handler turns those into the reply.
abstract class LomScreenAdapter {
  Future<LomScreenInfo> info();

  Future<LomScreenCapture> capture({
    required String quality,
    required bool cellularCap,
  });

  Future<LomScreenTree> tree();

  Future<LomScreenControlResult> control(LomScreenAction action);
}

