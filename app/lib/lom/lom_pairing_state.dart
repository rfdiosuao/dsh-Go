/// Lom pairing UI state: a thin Riverpod wrapper around [LomPairingFlow].
///
/// The flow itself enforces the protocol rules (link validated before any
/// network request, fingerprint checked before claim, `confirm` only after
/// the user taps "确认连接"); this controller only mirrors its steps into
/// state the page can render, and owns the in-memory claim secret via the
/// flow (never persisted, never logged).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'credentials.dart';
import 'lom_providers.dart';
import 'pairing_api.dart';
import 'pairing_flow.dart';
import 'pairing_link.dart';

/// UI-facing pairing steps. `scanning` covers camera / photo / paste;
/// `confirming` is the "连接到这台电脑？" page; `waitingDesktop` is the
/// "正在等待电脑核对" state while `confirm` retries `awaiting_desktop`.
enum LomPairingUiStep {
  scanning,
  working,
  confirming,
  waitingDesktop,
  done,
  failed,
}

class LomPairingUiState {
  const LomPairingUiState({
    this.step = LomPairingUiStep.scanning,
    this.offer,
    this.errorCode,
    this.credentials,
  });

  final LomPairingUiStep step;

  /// Shown on the confirm page (desktop name, masked account, SAS on the
  /// code path).
  final LomPairingOffer? offer;

  /// A Lom error code (`pairing.qr_invalid`, `pairing.expired`,
  /// `pairing.desktop_timeout`, `net.unreachable`, …) or a local code.
  final String? errorCode;

  final LomDeviceCredentials? credentials;

  LomPairingUiState copyWith({
    LomPairingUiStep? step,
    LomPairingOffer? offer,
    String? errorCode,
    LomDeviceCredentials? credentials,
  }) =>
      LomPairingUiState(
        step: step ?? this.step,
        offer: offer ?? this.offer,
        errorCode: errorCode,
        credentials: credentials ?? this.credentials,
      );
}

final lomPairingProvider =
    NotifierProvider.autoDispose<LomPairingController, LomPairingUiState>(
  LomPairingController.new,
);

class LomPairingController extends Notifier<LomPairingUiState> {
  LomPairingFlow? _flow;
  int _epoch = 0;

  @override
  LomPairingUiState build() => const LomPairingUiState();

  Future<LomPairingFlow> _newFlow() async {
    final identity = await ref.read(lomIdentityStoreProvider).loadOrCreate();
    final deviceInfo = await ref.read(lomDeviceInfoProvider.future);
    final transport = ref.read(lomHttpTransportProvider);
    return LomPairingFlow(
      identity: identity,
      credentialStore: ref.read(lomCredentialStoreProvider),
      deviceInfo: deviceInfo,
      apiFactory: (baseUrl) =>
          LomPairingApi(baseUrl: baseUrl, transport: transport),
    );
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  /// A pairing link was scanned, pasted, or deep-linked in. Invalid links
  /// fail here with `pairing.qr_invalid` and no network request.
  Future<void> scanned(String text) async {
    final epoch = ++_epoch;
    state = state.copyWith(step: LomPairingUiStep.working, errorCode: null);
    try {
      final flow = await _newFlow();
      if (!_current(epoch)) return;
      _flow = flow;
      await flow.startFromLink(text);
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.confirming,
        offer: flow.offer,
      );
    } on LomPairingLinkException catch (e) {
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.failed,
        errorCode: e.code,
      );
    } on LomPairingException catch (e) {
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.failed,
        errorCode: e.code,
      );
    }
  }

  /// A manual pairing code was typed in (normalised + validated locally).
  Future<void> submittedCode(String rawCode) async {
    final epoch = ++_epoch;
    state = state.copyWith(step: LomPairingUiStep.working, errorCode: null);
    try {
      final flow = await _newFlow();
      if (!_current(epoch)) return;
      _flow = flow;
      final offer = await flow.startFromCode(rawCode);
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.confirming,
        offer: offer,
      );
    } on LomPairingException catch (e) {
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.failed,
        errorCode: e.code,
      );
    }
  }

  /// The user tapped "确认连接" on the confirm page.
  Future<void> userConfirmed() async {
    final flow = _flow;
    if (flow == null || state.step != LomPairingUiStep.confirming) return;
    final epoch = ++_epoch;
    state = state.copyWith(step: LomPairingUiStep.waitingDesktop);
    try {
      await flow.userConfirmed();
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.done,
        offer: flow.offer,
        credentials: flow.credentials,
      );
    } on LomPairingException catch (e) {
      if (!_current(epoch)) return;
      state = LomPairingUiState(
        step: LomPairingUiStep.failed,
        offer: flow.offer,
        errorCode: e.code,
      );
    }
  }

  /// The user tapped "取消" on the confirm page.
  Future<void> userCancelled() async {
    final flow = _flow;
    _flow = null;
    if (flow != null) await flow.userCancelled();
    if (ref.mounted) state = const LomPairingUiState();
  }

  /// Back to scanning after a failure.
  void retry() {
    _epoch++;
    _flow = null;
    state = const LomPairingUiState();
  }
}

/// The currently paired Lom desktop, if any (for the status row).
final lomPairedProvider = FutureProvider<LomCredentials?>(
  (ref) => ref.watch(lomCredentialStoreProvider).load(),
);
