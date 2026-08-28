import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/settings/application/phone_setup_bundle_importer.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/data/phone_setup_crypto.dart';
import 'package:anime_tv/features/settings/data/phone_setup_pairing_client.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const phoneSetupSessionStorageKey = 'phone_setup_pairing_session_v1';

enum PhoneSetupViewStage {
  idle,
  starting,
  waiting,
  bound,
  review,
  applying,
  completed,
  expired,
  failed,
}

class PhoneSetupViewState {
  const PhoneSetupViewState({
    this.stage = PhoneSetupViewStage.idle,
    this.session,
    this.bundle,
    this.revision,
    this.result,
    this.linkDiscordRequested = false,
    this.message,
  });

  final PhoneSetupViewStage stage;
  final PhoneSetupPairingSession? session;
  final PhoneSetupBundle? bundle;
  final int? revision;
  final PhoneSetupApplyResult? result;
  final bool linkDiscordRequested;
  final String? message;

  bool get isBusy =>
      stage == PhoneSetupViewStage.starting ||
      stage == PhoneSetupViewStage.applying;

  bool get canRetry =>
      stage == PhoneSetupViewStage.failed ||
      stage == PhoneSetupViewStage.expired;
}

final phoneSetupPairingApiProvider = Provider<PhoneSetupPairingApi>((ref) {
  return PhoneSetupPairingClient(baseUrl: AppConfig.setupPairingBrokerBaseUrl);
});

final phoneSetupCryptographyProvider = Provider<PhoneSetupCryptography>((ref) {
  return SecurePhoneSetupCryptography();
});

final phoneSetupPairingControllerProvider =
    StateNotifierProvider<PhoneSetupPairingController, PhoneSetupViewState>((
      ref,
    ) {
      return PhoneSetupPairingController(
        ref.watch(secureStorageProvider),
        ref.watch(phoneSetupPairingApiProvider),
        ref.watch(phoneSetupCryptographyProvider),
        ref.watch(phoneSetupBundleImporterProvider),
        ref.read(setupProgressProvider.notifier).complete,
      );
    });

typedef PhoneSetupCompleteCallback = Future<void> Function();

class PhoneSetupPairingController extends StateNotifier<PhoneSetupViewState> {
  PhoneSetupPairingController(
    this._storage,
    this._api,
    this._cryptography,
    this._importer,
    this._markSetupComplete, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(const PhoneSetupViewState());

  final FlutterSecureStorage _storage;
  final PhoneSetupPairingApi _api;
  final PhoneSetupCryptography _cryptography;
  final PhoneSetupBundleImporter _importer;
  final PhoneSetupCompleteCallback _markSetupComplete;
  final DateTime Function() _now;

  Timer? _pollTimer;
  bool _operationInProgress = false;
  bool _regenerationInProgress = false;
  int _lastObservedRevision = -1;
  int? _locallyAppliedRevision;
  bool _locallyRequestedDiscordLink = false;

  Future<void> startOrResume() async {
    if (_operationInProgress ||
        _regenerationInProgress ||
        state.stage == PhoneSetupViewStage.completed) {
      return;
    }
    _operationInProgress = true;
    _pollTimer?.cancel();
    state = PhoneSetupViewState(
      stage: PhoneSetupViewStage.starting,
      session: state.session,
      message: 'Preparing secure phone setup…',
    );
    try {
      await _api.ensureReady();
      final saved = await _restoreSavedSession();
      if (!mounted) return;
      if (saved != null && saved.session.expiresAt.isAfter(_now().toUtc())) {
        _locallyAppliedRevision = saved.appliedRevision;
        _locallyRequestedDiscordLink = saved.linkDiscordRequested;
        state = PhoneSetupViewState(
          stage: PhoneSetupViewStage.waiting,
          session: saved.session,
          message: saved.appliedRevision == null
              ? 'Secure setup resumed.'
              : 'Finishing the setup already applied on this device…',
        );
        if (saved.appliedRevision case final revision?) {
          await _finishPendingAcknowledgement(
            saved.session,
            revision,
            linkDiscordRequested: saved.linkDiscordRequested,
          );
        } else {
          _schedulePoll(Duration.zero);
        }
        return;
      }
      if (saved != null) await _clearSavedSession();
      final key = await _cryptography.generateKeyMaterial();
      final session = await _api.createSession(key);
      await _saveSession(session);
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.waiting,
        session: session,
        message: 'Scan the QR code or enter the code on your phone.',
      );
      _schedulePoll(Duration.zero);
    } catch (_) {
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.failed,
        session: state.session,
        message:
            'Secure phone setup could not start. Check the connection and try again.',
      );
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> pollNow() async {
    final session = state.session;
    if (_operationInProgress ||
        _regenerationInProgress ||
        session == null ||
        state.stage == PhoneSetupViewStage.review ||
        state.stage == PhoneSetupViewStage.applying ||
        state.stage == PhoneSetupViewStage.completed) {
      return;
    }
    if (!session.expiresAt.isAfter(_now().toUtc())) {
      await _expire();
      return;
    }
    if (_locallyAppliedRevision case final revision?) {
      _operationInProgress = true;
      _pollTimer?.cancel();
      try {
        await _finishPendingAcknowledgement(
          session,
          revision,
          linkDiscordRequested: _locallyRequestedDiscordLink,
        );
      } finally {
        _operationInProgress = false;
      }
      return;
    }
    _operationInProgress = true;
    _pollTimer?.cancel();
    try {
      final result = await _api.poll(session);
      if (!mounted) return;
      if (result.revision < _lastObservedRevision) {
        throw const FormatException('The setup response was replayed.');
      }
      _lastObservedRevision = result.revision;
      switch (result.status) {
        case PhoneSetupPairingStatus.pending:
          state = PhoneSetupViewState(
            stage: PhoneSetupViewStage.waiting,
            session: session,
            message: 'Waiting for your phone to connect…',
          );
        case PhoneSetupPairingStatus.bound:
          state = PhoneSetupViewState(
            stage: PhoneSetupViewStage.bound,
            session: session,
            message:
                'Phone connected. Your progress is saved while you finish setup.',
          );
        case PhoneSetupPairingStatus.submitted:
          final envelope = result.envelope;
          if (envelope == null || result.revision <= 0) {
            throw const FormatException('The encrypted setup is incomplete.');
          }
          late final PhoneSetupBundle bundle;
          try {
            bundle = await _cryptography.decrypt(
              pairingId: session.pairingId,
              deviceKey: session.keyMaterial,
              envelope: envelope,
            );
          } catch (_) {
            await _api.acknowledge(
              session,
              revision: result.revision,
              applied: false,
            );
            if (!mounted) return;
            state = PhoneSetupViewState(
              stage: PhoneSetupViewStage.bound,
              session: session,
              message:
                  'The encrypted setup did not pass validation. Review it on your phone and send it again.',
            );
            _schedulePoll(session.pollInterval);
            return;
          }
          if (!mounted) return;
          state = PhoneSetupViewState(
            stage: PhoneSetupViewStage.review,
            session: session,
            bundle: bundle,
            revision: result.revision,
            message:
                'Review what will be added. Account secrets remain hidden.',
          );
          return;
        case PhoneSetupPairingStatus.completed:
          final linkDiscordRequested = _locallyRequestedDiscordLink;
          await _clearSavedSession();
          await _markSetupComplete();
          if (!mounted) return;
          state = PhoneSetupViewState(
            stage: PhoneSetupViewStage.completed,
            session: session,
            linkDiscordRequested: linkDiscordRequested,
            message: 'Phone setup is complete.',
          );
          return;
        case PhoneSetupPairingStatus.failed:
          state = PhoneSetupViewState(
            stage: PhoneSetupViewStage.failed,
            session: session,
            message:
                'The phone rejected or could not finish this setup. Try again.',
          );
          return;
        case PhoneSetupPairingStatus.expired:
          await _expire();
          return;
      }
      _schedulePoll(session.pollInterval);
    } catch (_) {
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: state.stage == PhoneSetupViewStage.bound
            ? PhoneSetupViewStage.bound
            : PhoneSetupViewStage.waiting,
        session: session,
        message:
            'Connection interrupted. TetoTV will keep trying securely in the background.',
      );
      _schedulePoll(const Duration(seconds: 8));
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> applyReviewedSetup() async {
    final session = state.session;
    final bundle = state.bundle;
    final revision = state.revision;
    if (_operationInProgress ||
        session == null ||
        bundle == null ||
        revision == null) {
      return;
    }
    _operationInProgress = true;
    state = PhoneSetupViewState(
      stage: PhoneSetupViewStage.applying,
      session: session,
      bundle: bundle,
      revision: revision,
      message: 'Verifying accounts and applying your choices…',
    );
    try {
      final result = await _importer.apply(bundle);
      if (!mounted) return;
      if (!result.applied) {
        await _api.acknowledge(session, revision: revision, applied: false);
        if (!mounted) return;
        state = PhoneSetupViewState(
          stage: PhoneSetupViewStage.bound,
          session: session,
          result: result,
          message: result.message,
        );
        _schedulePoll(session.pollInterval);
        return;
      }

      // Persist the non-secret revision before acknowledgement. If Android
      // terminates the app here, the next launch acknowledges instead of
      // applying the same account/source payload a second time.
      _locallyAppliedRevision = revision;
      final linkDiscordRequested =
          bundle.preferences.linkDiscord == true && !result.discordConnected;
      _locallyRequestedDiscordLink = linkDiscordRequested;
      await _saveSession(
        session,
        appliedRevision: revision,
        linkDiscordRequested: linkDiscordRequested,
      );
      await _api.acknowledge(session, revision: revision, applied: true);
      await _clearSavedSession();
      await _markSetupComplete();
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.completed,
        session: session,
        result: result,
        linkDiscordRequested: linkDiscordRequested,
        message: result.message ?? 'Phone setup is complete.',
      );
    } catch (_) {
      if (!mounted) return;
      final alreadyApplied = _locallyAppliedRevision == revision;
      state = PhoneSetupViewState(
        stage: alreadyApplied
            ? PhoneSetupViewStage.waiting
            : PhoneSetupViewStage.review,
        session: session,
        bundle: alreadyApplied ? null : bundle,
        revision: alreadyApplied ? null : revision,
        message: alreadyApplied
            ? 'Your choices are saved. Reconnecting to confirm completion…'
            : 'Setup could not be applied. Nothing was sent back; try again.',
      );
      if (alreadyApplied) _schedulePoll(const Duration(seconds: 5));
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> rejectReviewedSetup() async {
    final session = state.session;
    final revision = state.revision;
    if (_operationInProgress || session == null || revision == null) return;
    _operationInProgress = true;
    state = PhoneSetupViewState(
      stage: PhoneSetupViewStage.applying,
      session: session,
      message: 'Returning this setup to your phone for changes…',
    );
    try {
      await _api.acknowledge(session, revision: revision, applied: false);
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.bound,
        session: session,
        message: 'Make your changes on the phone, then send them again.',
      );
      _schedulePoll(session.pollInterval);
    } catch (_) {
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.review,
        session: session,
        bundle: state.bundle,
        revision: revision,
        message: 'Could not return the setup yet. Try again.',
      );
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> cancel() async {
    final session = state.session;
    _pollTimer?.cancel();
    if (session != null) {
      try {
        await _api.cancel(session);
      } catch (_) {
        // Local cancellation always wins. The remote session still expires
        // without ever having the locally held decryption key.
      }
    }
    await _clearSavedSession();
    if (mounted) state = const PhoneSetupViewState();
  }

  Future<void> restart() async {
    await regenerate();
  }

  /// Invalidates the active broker session before creating a fresh key/code.
  ///
  /// A poll that is already in flight is allowed to finish first. Its timer is
  /// then cancelled again before the old server-side session is revoked. This
  /// prevents the old response from racing with, or overwriting, the newly
  /// created session.
  Future<void> regenerate() async {
    if (_regenerationInProgress ||
        state.stage == PhoneSetupViewStage.applying ||
        state.stage == PhoneSetupViewStage.review ||
        state.stage == PhoneSetupViewStage.completed) {
      return;
    }
    _regenerationInProgress = true;
    _pollTimer?.cancel();
    var scheduleFreshPoll = false;
    try {
      while (_operationInProgress && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!mounted) return;

      _operationInProgress = true;
      _pollTimer?.cancel();
      final previousSession = state.session;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.starting,
        session: previousSession,
        message: previousSession == null
            ? 'Creating a fresh secure setup code…'
            : 'Invalidating the old code before creating a new one…',
      );

      try {
        if (previousSession != null) {
          // Do not issue a second live code unless the broker confirms that
          // the previous pairing is gone (404/410 also count as gone).
          await _api.cancel(previousSession);
        }
        await _clearSavedSession();
        _lastObservedRevision = -1;
        await _api.ensureReady();
        final key = await _cryptography.generateKeyMaterial();
        final freshSession = await _api.createSession(key);
        await _saveSession(freshSession);
        if (!mounted) return;
        state = PhoneSetupViewState(
          stage: PhoneSetupViewStage.waiting,
          session: freshSession,
          message: 'A new secure setup code is ready.',
        );
        scheduleFreshPoll = true;
      } catch (_) {
        if (!mounted) return;
        state = PhoneSetupViewState(
          stage: PhoneSetupViewStage.failed,
          session: previousSession,
          message:
              'The old code could not be replaced securely. Check the connection and try again.',
        );
      } finally {
        _operationInProgress = false;
      }
    } finally {
      _regenerationInProgress = false;
      if (scheduleFreshPoll && mounted) _schedulePoll(Duration.zero);
    }
  }

  Future<void> _finishPendingAcknowledgement(
    PhoneSetupPairingSession session,
    int revision, {
    required bool linkDiscordRequested,
  }) async {
    try {
      await _api.acknowledge(session, revision: revision, applied: true);
      await _clearSavedSession();
      await _markSetupComplete();
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.completed,
        session: session,
        linkDiscordRequested: linkDiscordRequested,
        message: 'Phone setup is complete.',
      );
    } catch (_) {
      if (!mounted) return;
      state = PhoneSetupViewState(
        stage: PhoneSetupViewStage.waiting,
        session: session,
        message: 'Your choices are saved. Reconnecting to confirm completion…',
      );
      _schedulePoll(const Duration(seconds: 5));
    }
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () => unawaited(pollNow()));
  }

  Future<_SavedPhoneSetup?> _restoreSavedSession() async {
    final raw = await _storage.read(key: phoneSetupSessionStorageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 1) {
        throw const FormatException();
      }
      final appliedRevision = decoded['applied_revision'];
      if (appliedRevision != null &&
          (appliedRevision is! int ||
              appliedRevision <= 0 ||
              appliedRevision > 1000000)) {
        throw const FormatException();
      }
      final linkDiscordRequested = decoded['link_discord_requested'];
      if (linkDiscordRequested != null && linkDiscordRequested is! bool) {
        throw const FormatException();
      }
      return _SavedPhoneSetup(
        session: _api.restoreSession(decoded['session']),
        appliedRevision: appliedRevision as int?,
        linkDiscordRequested: linkDiscordRequested == true,
      );
    } catch (_) {
      await _clearSavedSession();
      return null;
    }
  }

  Future<void> _saveSession(
    PhoneSetupPairingSession session, {
    int? appliedRevision,
    bool linkDiscordRequested = false,
  }) {
    return _storage.write(
      key: phoneSetupSessionStorageKey,
      value: jsonEncode(<String, Object?>{
        'version': 1,
        'session': session.toJson(),
        'applied_revision': appliedRevision,
        'link_discord_requested': linkDiscordRequested,
      }),
    );
  }

  Future<void> _clearSavedSession() async {
    _locallyAppliedRevision = null;
    _locallyRequestedDiscordLink = false;
    await _storage.delete(key: phoneSetupSessionStorageKey);
  }

  Future<void> _expire() async {
    _pollTimer?.cancel();
    await _clearSavedSession();
    if (!mounted) return;
    state = PhoneSetupViewState(
      stage: PhoneSetupViewStage.expired,
      session: state.session,
      message: 'This setup session expired. Create a new secure code.',
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

class _SavedPhoneSetup {
  const _SavedPhoneSetup({
    required this.session,
    this.appliedRevision,
    this.linkDiscordRequested = false,
  });

  final PhoneSetupPairingSession session;
  final int? appliedRevision;
  final bool linkDiscordRequested;
}
