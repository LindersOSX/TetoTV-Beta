import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/auth/application/auth_broker_config.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/data/anilist_pairing_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

export 'auth_broker_config.dart';

typedef PairingSessionClientFactory =
    TrackingPairingClient Function(
      TrackingProvider provider, {
      required String baseUrl,
    });

typedef TrackingPairingDiagnosticRecorder =
    Future<void> Function(Map<String, Object?> details);

TrackingPairingClient _createPairingSessionClient(
  TrackingProvider provider, {
  required String baseUrl,
}) => TrackingPairingClient(provider, baseUrl: baseUrl);

final pairingControllerProvider = StateNotifierProvider.autoDispose
    .family<PairingController, AsyncValue<PairingSession?>, TrackingProvider>((
      ref,
      provider,
    ) {
      return PairingController(
        provider,
        ref.watch(secureStorageProvider),
        tokenService: ref.watch(trackingTokenServiceProvider),
        diagnosticRecorder: (details) =>
            TetoTvDatabase.instance.recordDiagnosticEvent(
              category: 'tracker-pairing',
              severity: 'warning',
              message: 'Tracker pairing request deferred or failed',
              details: details,
            ),
      );
    });

class PairingController extends StateNotifier<AsyncValue<PairingSession?>> {
  PairingController(
    this._provider,
    this._storage, {
    TrackingTokenService? tokenService,
    this.clientFactory = _createPairingSessionClient,
    DateTime Function()? now,
    this.diagnosticRecorder,
  }) : _tokenService = tokenService ?? TrackingTokenService(_storage, now: now),
       _now = now ?? DateTime.now,
       super(const AsyncData(null));

  final TrackingProvider _provider;
  final FlutterSecureStorage _storage;
  final TrackingTokenService _tokenService;
  final PairingSessionClientFactory clientFactory;
  final DateTime Function() _now;
  final TrackingPairingDiagnosticRecorder? diagnosticRecorder;
  TrackingPairingClient? _activeClient;
  Timer? _pollTimer;
  bool _starting = false;
  bool _polling = false;
  int _consecutivePollFailures = 0;
  int _generation = 0;
  DateTime? _retryNotBefore;

  Future<void> start() async {
    if (_starting) return;
    final now = _now().toUtc();
    if (_retryNotBefore?.isAfter(now) == true) {
      final remaining = _retryNotBefore!.difference(now);
      state = AsyncError(
        TrackingPairingServiceException(
          reasonCode: 'rate_limited',
          message:
              'The pairing service is temporarily rate-limited. Wait before trying again.',
          httpStatus: 429,
          retryAfter: remaining,
        ),
        StackTrace.current,
      );
      return;
    }
    _starting = true;
    final generation = ++_generation;
    _pollTimer?.cancel();
    _activeClient = null;
    _consecutivePollFailures = 0;
    state = const AsyncLoading();
    var stage = 'configuration';
    try {
      final configuredUrl = await effectiveAuthBrokerBaseUrl(_storage);
      if (!mounted || generation != _generation) return;
      if (configuredUrl == null) {
        throw const AuthBrokerNotConfigured();
      }
      final client = clientFactory(_provider, baseUrl: configuredUrl);
      _activeClient = client;
      stage = 'health';
      await client.ensureReady();
      if (!mounted || generation != _generation) return;
      stage = 'session_create';
      final session = await client.createSession();
      if (!mounted || generation != _generation) return;
      _retryNotBefore = null;
      state = AsyncData(session);
      _schedulePoll(generation, session, session.pollInterval);
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      if (error is TrackingPairingServiceException &&
          error.reasonCode == 'rate_limited') {
        _retryNotBefore = _now().toUtc().add(
          error.retryAfter ?? const Duration(seconds: 60),
        );
      }
      _recordFailure(stage, error);
      state = AsyncError(error, stackTrace);
    } finally {
      _starting = false;
    }
  }

  Future<void> _poll(int generation) async {
    if (!mounted || generation != _generation) return;
    final client = _activeClient;
    if (_polling || client == null) return;
    final session = state.valueOrNull;
    if (session == null || session.status != PairingStatus.pending) return;
    if (_now().isAfter(session.expiresAt)) {
      _pollTimer?.cancel();
      state = AsyncData(session.copyWith(status: PairingStatus.expired));
      return;
    }

    _polling = true;
    try {
      final result = await client.poll(session);
      if (!mounted || generation != _generation) return;
      _consecutivePollFailures = 0;
      if (result.status == PairingStatus.authorized) {
        final token = result.accessToken?.trim();
        if (token == null || token.isEmpty) {
          throw const FormatException(
            'Pairing completed without an access token.',
          );
        }
        final refreshToken = result.refreshToken?.trim();
        final expiresAt = result.expiresAt;
        if (_provider == TrackingProvider.kitsu &&
            (refreshToken == null ||
                refreshToken.isEmpty ||
                expiresAt == null ||
                !expiresAt.toUtc().isAfter(_now().toUtc()))) {
          throw const FormatException(
            'Kitsu pairing completed without a refreshable session.',
          );
        }
        await _tokenService.saveTokenSet(
          _provider,
          accessToken: token,
          refreshToken: refreshToken,
          expiresAt: expiresAt,
        );
        if (!mounted || generation != _generation) return;
        _pollTimer?.cancel();
        state = AsyncData(session.copyWith(status: result.status));
        unawaited(_acknowledgeStoredToken(client, session));
        return;
      } else if (result.status == PairingStatus.expired) {
        _pollTimer?.cancel();
        state = AsyncData(session.copyWith(status: result.status));
        return;
      }
      state = AsyncData(session.copyWith(status: result.status));
      if (result.diagnosticReason case final reason?) {
        _recordReason(
          stage: 'poll',
          reasonCode: reason,
          httpStatus: reason == 'rate_limited' ? 429 : null,
          retryAfter: result.retryAfter,
        );
      }
      _schedulePoll(
        generation,
        session,
        result.retryAfter ?? session.pollInterval,
      );
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      _consecutivePollFailures++;
      _recordFailure('poll', error);
      if (_now().toUtc().isAfter(session.expiresAt.toUtc())) {
        state = AsyncData(session.copyWith(status: PairingStatus.expired));
        _pollTimer?.cancel();
      } else if (_consecutivePollFailures >= 3) {
        state = AsyncError(error, stackTrace);
        _pollTimer?.cancel();
      } else {
        _schedulePoll(
          generation,
          session,
          Duration(seconds: _consecutivePollFailures == 1 ? 8 : 15),
        );
      }
    } finally {
      _polling = false;
    }
  }

  /// Performs one immediate poll without waiting for the periodic timer.
  ///
  /// This also keeps credential-validation tests deterministic.
  Future<void> pollNow() {
    _pollTimer?.cancel();
    _pollTimer = null;
    return _poll(_generation);
  }

  void _schedulePoll(
    int generation,
    PairingSession session,
    Duration requestedDelay,
  ) {
    if (!mounted || generation != _generation) return;
    _pollTimer?.cancel();
    final remaining = session.expiresAt.toUtc().difference(_now().toUtc());
    if (remaining <= Duration.zero) {
      state = AsyncData(session.copyWith(status: PairingStatus.expired));
      return;
    }
    final delay = requestedDelay < remaining ? requestedDelay : remaining;
    _pollTimer = Timer(delay, () {
      _pollTimer = null;
      unawaited(_poll(generation));
    });
  }

  void _recordFailure(String stage, Object error) {
    final service = error is TrackingPairingServiceException ? error : null;
    _recordReason(
      stage: stage,
      reasonCode: switch (error) {
        TrackingPairingServiceException() => error.reasonCode,
        FormatException() => 'invalid_response',
        _ => 'application_failure',
      },
      httpStatus: service?.httpStatus,
      retryAfter: service?.retryAfter,
    );
  }

  Future<void> _acknowledgeStoredToken(
    TrackingPairingClient client,
    PairingSession session,
  ) async {
    try {
      await client.acknowledge(session);
    } catch (error) {
      // The credential is already safely stored. A failed acknowledgement
      // only leaves the companion's bounded recovery copy until expiry.
      _recordFailure('acknowledge', error);
    }
  }

  void _recordReason({
    required String stage,
    required String reasonCode,
    int? httpStatus,
    Duration? retryAfter,
  }) {
    final recorder = diagnosticRecorder;
    if (recorder == null) return;
    final details = <String, Object?>{
      'provider': _provider.slug,
      'stage': stage,
      'reason_code': reasonCode,
      'code': ?httpStatus,
      if (retryAfter != null)
        'retry_after_seconds': retryAfter.inSeconds.clamp(1, 3600),
    };
    unawaited(Future<void>.sync(() => recorder(details)).catchError((_) {}));
  }

  @override
  void dispose() {
    _generation++;
    _pollTimer?.cancel();
    _activeClient = null;
    super.dispose();
  }
}
