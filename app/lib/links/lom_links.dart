// The Lom deep link, registered for as long as the home shell is up (so a
// scan that returns after Android killed the app still lands):
//
//   lom://pair?v=1&h=…&p=…&t=…&k=…&f=…   the Lom desktop pairing QR code
//
// The link is handed to the Lom pairing page untouched; the page validates
// it (host whitelist, field lengths, fingerprint) before any network
// request, and never auto-confirms — the user still taps "确认连接".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../links/app_links.dart';
import '../ui/lom/lom_pairing_page.dart';

/// Draws nothing. Put it once in the home shell's stack, next to `LinkHost`.
class LomLinkHost extends ConsumerStatefulWidget {
  const LomLinkHost({super.key});

  @override
  ConsumerState<LomLinkHost> createState() => _LomLinkHostState();
}

class _LomLinkHostState extends ConsumerState<LomLinkHost> {
  VoidCallback? _off;

  @override
  void initState() {
    super.initState();
    _off = ref.read(linkRouterProvider).registerLinkHandler('pair', _open);
  }

  @override
  void dispose() {
    _off?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  Future<bool> _open(Uri uri) async {
    final router = ref.read(linkRouterProvider);
    final context = router.context;
    if (context == null || !context.mounted) return false;
    if (uri.scheme.toLowerCase() != 'lom') return false;
    unawaited(
      Navigator.of(context).push(LomPairingPage.route(initialLink: uri.toString())),
    );
    return true;
  }
}
