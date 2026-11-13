// Connect this phone to a Lom desktop: scan the QR code Lom shows on the
// computer (or type the 8-digit pairing code), check the computer, and tap
// "确认连接". Nothing confirms for the computer, and the pairing link is
// fully validated before any network request (see lib/lom/).
//
// After pairing, the phone stays online on the Lom relay so the desktop
// can send it tasks; the status row at the bottom shows that state, and
// "解除配对" removes it (sessions, skills and memory stay on the phone).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../lom/lom_pairing_state.dart';
import '../../lom/lom_relay_service.dart';
import '../../lom/pairing_flow.dart' show LomPairingOffer;
import '../../lom/identity.dart' show formatSas;
import '../../lom/relay_client.dart' show LomConnectionState;
import '../common/app_dialog.dart' show showAppDialog;
import '../remote/pairing_page.dart' show pairingScannerProvider;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class LomPairingPage extends ConsumerStatefulWidget {
  const LomPairingPage({super.key, this.initialLink});

  /// A pairing link that arrived before this page opened (deep link,
  /// in-app scan hand-off). Fed to the controller on first build; the
  /// user still has to confirm on the confirm page.
  final String? initialLink;

  static Route<void> route({String? initialLink}) => MaterialPageRoute<void>(
        builder: (_) => LomPairingPage(initialLink: initialLink),
      );

  @override
  ConsumerState<LomPairingPage> createState() => _LomPairingPageState();
}

class _LomPairingPageState extends ConsumerState<LomPairingPage> {
  bool _showCodeEntry = false;
  bool _initialLinkFed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A deep-linked pairing code: hand it to the controller once.
    final link = widget.initialLink;
    if (!_initialLinkFed && link != null && link.isNotEmpty) {
      _initialLinkFed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(ref.read(lomPairingProvider.notifier).scanned(link));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final flow = ref.watch(lomPairingProvider);
    final relay = ref.watch(lomRelayProvider);
    ref.listen(lomPairingProvider.select((s) => s.step), (_, step) {
      if (step == LomPairingUiStep.done) {
        unawaited(ref.read(lomRelayProvider.notifier).refresh());
      }
    });
    final Widget body = switch (flow.step) {
      LomPairingUiStep.scanning => _showCodeEntry
          ? _CodeEntry(onBack: () => setState(() => _showCodeEntry = false))
          : _ScanStep(
              onCode: ref.read(lomPairingProvider.notifier).scanned,
              onCodeEntry: () => setState(() => _showCodeEntry = true),
            ),
      LomPairingUiStep.working => _Busy(label: l10n.remotePairReading),
      LomPairingUiStep.confirming => _ConfirmStep(offer: flow.offer!),
      LomPairingUiStep.waitingDesktop =>
        _Busy(label: l10n.lomPairWaitingDesktop),
      LomPairingUiStep.done => _DoneStep(desktopName: relay.credentials?.desktopName ?? flow.offer?.desktopName ?? ''),
      LomPairingUiStep.failed => _FailedStep(errorCode: flow.errorCode),
    };
    return AppPage.list(
      title: l10n.lomPairTitle,
      subtitle: Text(l10n.lomPairSubtitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: body,
          ),
        ),
        _RelayStatusRow(),
      ],
    );
  }
}

/// Maps a Lom error code to user-facing text. Unknown codes fall back to
/// the generic failure line; secrets never appear here.
String lomPairErrorText(L10n l10n, String? code) => switch (code) {
      'pairing.qr_invalid' => l10n.lomPairErrInvalidLink,
      'pairing.code_invalid' => l10n.lomPairErrCodeInvalid,
      'pairing.key_mismatch' => l10n.lomPairErrKeyMismatch,
      'pairing.expired' => l10n.lomPairErrExpired,
      'pairing.desktop_timeout' => l10n.lomPairErrDesktopTimeout,
      'pairing.already_paired' => l10n.lomPairErrAlreadyPaired,
      'pairing.store_failed' => l10n.lomPairErrStoreFailed,
      'net.unreachable' => l10n.lomPairErrNetwork,
      _ => l10n.lomPairErrFailed,
    };

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: child,
        ),
      );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => _Card(
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
            ),
          ],
        ),
      );
}

class _ScanStep extends ConsumerWidget {
  const _ScanStep({required this.onCode, required this.onCodeEntry});

  final ValueChanged<String> onCode;
  final VoidCallback onCodeEntry;

  Future<void> _paste(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!context.mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.remotePairPasteEmpty)),
      );
      return;
    }
    onCode(text);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRSuperellipse(
            borderRadius: AppShape.radiusLg,
            child: ref.watch(pairingScannerProvider)(context, onCode),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          l10n.lomPairScanHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton.icon(
            onPressed: () => unawaited(_paste(context)),
            icon: const Icon(AppIcons.paste, size: 18),
            label: Text(l10n.remotePairPasteLink),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: onCodeEntry,
            child: Text(l10n.lomPairCodeEntry),
          ),
        ),
      ],
    );
  }
}

class _CodeEntry extends ConsumerStatefulWidget {
  const _CodeEntry({required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<_CodeEntry> createState() => _CodeEntryState();
}

class _CodeEntryState extends ConsumerState<_CodeEntry> {
  final _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.lomPairCodeTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'AB3D-9XK2',
                  helperText: l10n.lomPairCodeHint,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.lomPairConfirm),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: widget.onBack, child: Text(l10n.commonCancel)),
      ],
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await ref
          .read(lomPairingProvider.notifier)
          .submittedCode(_controller.text);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

/// "连接到这台电脑？" — desktop name, masked account, and (code path only)
/// the 6-digit confirmation code to compare with the desktop's number.
class _ConfirmStep extends ConsumerWidget {
  const _ConfirmStep({required this.offer});

  final LomPairingOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final notifier = ref.read(lomPairingProvider.notifier);
    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: colors.textTertiary),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.computer,
                      size: 22, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.lomPairConfirmTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              fact(l10n.lomPairDesktop, offer.desktopName),
              fact(l10n.lomPairAccount, offer.maskedAccount),
              if (offer.sas.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  l10n.lomPairSasTitle,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: colors.textTertiary),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    formatSas(offer.sas),
                    style: AppType.mono(
                      size: 28,
                      weight: FontWeight.w600,
                      color: colors.codeWellFg,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.lomPairSasHint,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.textTertiary, height: 1.5),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => unawaited(notifier.userConfirmed()),
          child: Text(l10n.lomPairConfirm),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => unawaited(notifier.userCancelled()),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }
}

class _DoneStep extends ConsumerWidget {
  const _DoneStep({required this.desktopName});

  final String desktopName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.done,
                      size: 22, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.lomPairConnected(desktopName),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(l10n.remotePairDone),
        ),
      ],
    );
  }
}

class _FailedStep extends ConsumerWidget {
  const _FailedStep({required this.errorCode});

  final String? errorCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final notifier = ref.read(lomPairingProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.warning, size: 20, color: colors.danger),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.lomPairFailedTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                lomPairErrorText(l10n, errorCode),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: notifier.retry,
          child: Text(l10n.lomPairScanAgain),
        ),
      ],
    );
  }
}

/// Online status of the paired Lom desktop, with unpair.
class _RelayStatusRow extends ConsumerWidget {
  const _RelayStatusRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final relay = ref.watch(lomRelayProvider);
    if (!relay.paired && !relay.revoked) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final status = relay.revoked
        ? l10n.lomPairRevoked
        : relay.online
            ? l10n.remoteOnline
            : relay.connection == LomConnectionState.backingOff
                ? l10n.lomPairReconnecting
                : l10n.remoteOffline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: _Card(
        child: Row(
          children: [
            Icon(
              relay.online ? AppIcons.done : AppIcons.warning,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                relay.revoked
                    ? status
                    : '${relay.credentials?.desktopName ?? ''} · $status',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (relay.paired)
              TextButton(
                onPressed: () => unawaited(_confirmUnpair(context, ref)),
                child: Text(l10n.lomPairUnpair),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUnpair(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.lomPairUnpairTitle),
        content: Text(l10n.lomPairUnpairBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.lomPairUnpair),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(lomRelayProvider.notifier).unpair();
      ref.read(lomPairingProvider.notifier).retry();
    }
  }
}
