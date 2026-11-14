/// `apps.list` (doc §07 `apps.list`).
///
/// Lists the user's launchable apps plus the accessibility state the
/// commander needs before it can look at the screen or operate it.
/// Only launchable apps are listed; no other app's data is read.
///
/// The enumeration itself is a new native method, `lomListApps` on the
/// `dsh/phone` channel (`PhonePlugin.kt` → `PhoneControl.
/// listLaunchableApps`, `PackageManager.queryIntentActivities` with
/// `ACTION_MAIN` / `CATEGORY_LAUNCHER`); the accessibility state comes
/// from the existing `PhoneChannel.status()`.
library;

import '../phone/phone_channel.dart';

class LomAppInfo {
  const LomAppInfo({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

/// The native apps bridge. `listApps` returns launchable apps only.
abstract class LomAppsAdapter {
  Future<List<LomAppInfo>> listApps();

  /// Whether the accessibility service is on and answering.
  Future<bool> accessibilityOk();
}

/// `apps.list` over a [LomAppsAdapter].
class LomAppsHandler {
  LomAppsHandler({required this.adapter, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final LomAppsAdapter adapter;
  final DateTime Function() _now;

  /// Note the shape: unlike `skills.list` / `schedule.list`, `items`
  /// here is a real array, not JSON text (doc §07 `apps.list`).
  Future<Map<String, Object?>> list() async {
    final apps = await adapter.listApps();
    final accessibility = await adapter.accessibilityOk();
    return {
      'items': [
        for (final app in apps)
          {'package': app.packageName, 'label': app.label},
      ],
      'accessibility': accessibility ? 'true' : 'false',
      'sampled_at': '${_now().millisecondsSinceEpoch}',
    };
  }
}

/// The real adapter: app enumeration from the native plugin, a11y state
/// from the existing phone channel.
class PhoneChannelLomAppsAdapter implements LomAppsAdapter {
  PhoneChannelLomAppsAdapter(this.channel);

  final PhoneChannel channel;

  @override
  Future<List<LomAppInfo>> listApps() async {
    final apps = await channel.listApps();
    return [
      for (final app in apps)
        LomAppInfo(packageName: app.packageName, label: app.label),
    ];
  }

  @override
  Future<bool> accessibilityOk() async {
    final status = await channel.status();
    return status.a11y.ok;
  }
}
