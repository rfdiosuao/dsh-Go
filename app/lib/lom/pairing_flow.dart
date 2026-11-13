/// Lom pairing flow orchestration (doc §03), framework-free so it can be
/// unit-tested with plain `dart test`. The Riverpod controller in the app
/// is a thin wrapper around this class.
///
/// Rules enforced here (not just in the UI):
/// - A QR link is fully validated before any network request.
/// - The desktop fingerprint from `inspect` is checked against the QR `f`
///   with a constant-time comparison before `claim`.
/// - `confirm` is only sent after the user explicitly confirms
///   ([userConfirmed]); the flow waits in [LomPairingStep.awaitingUser]
///   until then. Deep links get no exception.
/// - The manual-code path never auto-confirms: the SAS is computed locally
///   and shown to the user, who compares it with the desktop's number.
/// - Already paired → the flow refuses to start (`pairing.already_paired`);
///   unpair first.
library;

import 'base64url.dart';
import 'credentials.dart';
import 'identity.dart';
import 'pairing_api.dart';
import 'pairing_link.dart';

enum LomPairingStep {
  idle,
  inspecting,
  awaitingUser,
  claiming,
  waitingDesktop,
  done,
  failed,
}

/// What the confirm page shows the user.
class LomPairingOffer {
  const LomPairingOffer({
    required this.desktopName,
    required this.maskedAccount,
    required this.sas,
    required this.method,
  });

  /// Desktop name from `inspect` / `claim-by-code` (untrusted display text).
  final String desktopName;
  final String maskedAccount;

  /// 6-digit SAS for the manual-code path; empty for the QR path (the QR
  /// path shows no code — the fingerprint + key_proof do the checking).
  final String sas;

  /// `qr` or `code`.
  final String method;
}

class LomPairingFlow {
  LomPairingFlow({
    required this.identity,
    required this.credentialStore,
    required this.deviceInfo,
    LomPairingApi Function(String baseUrl)? apiFactory,
  }) : _apiFactory = apiFactory ??
            ((baseUrl) => throw UnimplementedError(
                  'pass an apiFactory (needs an HTTP transport)',
                ));

  final LomIdentity identity;
  final LomCredentialStore credentialStore;
  final LomDeviceInfo deviceInfo;
  final LomPairingApi Function(String baseUrl) _apiFactory;

  LomPairingStep step = LomPairingStep.idle;
  LomPairingOffer? offer;
  LomPairingException? error;
  LomDeviceCredentials? credentials;

  LomPairingApi? _api;
  String? _host;
  String? _pairingId;
  String? _claimSecret;
  String? _desktopKeys;
  String? _desktopName;

  /// Starts the QR path from a scanned / pasted / deep-linked string.
  /// Throws [LomPairingLinkException] (`pairing.qr_invalid`) before any
  /// network request when the link is invalid.
  Future<void> startFromLink(String rawLink) async {
    await _guardNotPaired();
    final link = LomPairLink.parse(rawLink); // throws before any network
    _host = link.host;
    _pairingId = link.pairingId;
    _api = _apiFactory(link.baseUrl);
    step = LomPairingStep.inspecting;
    try {
      final inspected = await _api!.inspect(
        pairingId: link.pairingId,
        claimToken: link.claimToken,
      );
      if (inspected.pairingId != link.pairingId) {
        throw LomPairingException('pairing.key_mismatch');
      }
      final desktopKeys = splitPublicKeyString(inspected.desktopKeys);
      if (desktopKeys == null) {
        throw LomPairingException('pairing.key_mismatch');
      }
      final fp = b64urlDecodeStrictLength(
        fingerprint(inspected.desktopKeys),
        16,
      )!;
      if (!constantTimeEquals(fp, link.fingerprint)) {
        throw LomPairingException('pairing.key_mismatch');
      }
      _desktopKeys = inspected.desktopKeys;
      _desktopName = inspected.desktopName;
      // Claim immediately (the user still has to confirm before `confirm`).
      step = LomPairingStep.claiming;
      final claimed = await _api!.claim(
        pairingId: link.pairingId,
        claimToken: link.claimToken,
        deviceKeys: identity.keys,
        deviceInfo: deviceInfo,
        keyProof: keyProof(
          psk: link.psk,
          pairingId: link.pairingId,
          desktopKeys: inspected.desktopKeys,
          phoneKeys: identity.keys,
        ),
      );
      _claimSecret = claimed.claimSecret;
      offer = LomPairingOffer(
        desktopName: inspected.desktopName,
        maskedAccount: inspected.maskedAccount,
        sas: '',
        method: 'qr',
      );
      step = LomPairingStep.awaitingUser;
    } on LomPairingException catch (e) {
      error = e;
      step = LomPairingStep.failed;
      rethrow;
    }
  }

  /// Starts the manual-code path from a user-typed code. Returns the offer
  /// (with the SAS for the user to compare with the desktop's number).
  /// The code is normalised locally first; an invalid code never reaches
  /// the network (`pairing.code_invalid`).
  Future<LomPairingOffer> startFromCode(String rawCode) async {
    await _guardNotPaired();
    final code = normalizeManualCode(rawCode);
    if (code == null) {
      error = LomPairingException('pairing.code_invalid');
      step = LomPairingStep.failed;
      throw error!;
    }
    _host = lomDefaultHost;
    _api = _apiFactory('https://$lomDefaultHost');
    step = LomPairingStep.claiming;
    try {
      final claimed = await _api!.claimByCode(
        manualCode: code,
        deviceKeys: identity.keys,
        deviceInfo: deviceInfo,
      );
      if (splitPublicKeyString(claimed.desktopKeys) == null) {
        throw LomPairingException('pairing.key_mismatch');
      }
      _pairingId = claimed.pairingId;
      _claimSecret = claimed.claimSecret;
      _desktopKeys = claimed.desktopKeys;
      _desktopName = claimed.desktopName;
      final sas = sasCode(
        pairingId: claimed.pairingId,
        desktopKeys: claimed.desktopKeys,
        phoneKeys: identity.keys,
      );
      offer = LomPairingOffer(
        desktopName: claimed.desktopName,
        maskedAccount: claimed.maskedAccount,
        sas: sas,
        method: 'code',
      );
      step = LomPairingStep.awaitingUser;
      return offer!;
    } on LomPairingException catch (e) {
      error = e;
      step = LomPairingStep.failed;
      rethrow;
    }
  }

  /// The user tapped "确认连接" after seeing the desktop name (and, on the
  /// code path, after comparing the SAS). Only now is `confirm` sent.
  /// On success the credentials are persisted **before** the step flips to
  /// `done` (the UI may only show "已连接" afterwards).
  Future<void> userConfirmed({
    Future<void> Function(Duration d)? sleep,
  }) async {
    if (step != LomPairingStep.awaitingUser ||
        _api == null ||
        _pairingId == null ||
        _claimSecret == null ||
        _desktopKeys == null ||
        _host == null) {
      throw StateError('confirm called outside awaitingUser');
    }
    step = LomPairingStep.waitingDesktop;
    try {
      final creds = await _api!.confirmAwaitingDesktop(
        pairingId: _pairingId!,
        claimSecret: _claimSecret!,
        sleep: sleep,
      );
      await credentialStore.save(
        creds,
        host: _host!,
        desktopKeys: _desktopKeys!,
        desktopName: _desktopName ?? creds.desktopName,
      );
      credentials = creds;
      step = LomPairingStep.done;
    } on LomPairingException catch (e) {
      error = e;
      step = LomPairingStep.failed;
      rethrow;
    }
  }

  /// The user tapped "取消" on the confirm page.
  Future<void> userCancelled() async {
    if (_api != null && _pairingId != null && _claimSecret != null) {
      try {
        await _api!.cancel(
          pairingId: _pairingId!,
          claimSecret: _claimSecret!,
        );
      } catch (_) {
        // Best effort: the session expires on its own in 5 minutes.
      }
    }
    step = LomPairingStep.idle;
    offer = null;
    _claimSecret = null;
  }

  Future<void> _guardNotPaired() async {
    final existing = await credentialStore.load();
    if (existing != null) {
      error = LomPairingException('pairing.already_paired');
      step = LomPairingStep.failed;
      throw error!;
    }
  }
}
