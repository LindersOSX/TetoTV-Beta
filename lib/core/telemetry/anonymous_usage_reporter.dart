import 'dart:async';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AnonymousUsageState { active, streaming }

class AnonymousUsageSession {
  const AnonymousUsageSession({
    required this.token,
    required this.heartbeatInterval,
  });

  final String token;
  final Duration heartbeatInterval;
}

abstract interface class AnonymousUsageClient {
  Future<AnonymousUsageSession> createSession(AnonymousUsageState state);

  Future<void> heartbeat(String token, AnonymousUsageState state);

  Future<void> closeSession(String token);
}

/// First-party client for an aggregate Beta activity count.
///
/// The request body has exactly one field: `state`. The returned bearer token
/// is a short-lived capability held only in process memory.
class BrokerAnonymousUsageClient implements AnonymousUsageClient {
  BrokerAnonymousUsageClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: validatedAnonymousPresenceOrigin(),
              connectTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
              responseType: ResponseType.json,
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 300,
              headers: const {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                // Keep transport metadata generic; do not expose an app
                // version, Android build, model, or device identifier.
                'User-Agent': 'TetoTV-Beta-Presence/1',
              },
            ),
          );

  final Dio _dio;

  @override
  Future<AnonymousUsageSession> createSession(AnonymousUsageState state) async {
    final response = await _dio.post<Object?>(
      '/v1/app-presence/sessions',
      data: {'state': state.name},
    );
    final body = response.data;
    if (body is! Map) throw const FormatException('Invalid presence response.');
    final token = body['session_token'];
    final interval = body['heartbeat_interval'];
    if (token is! String ||
        token.length < 32 ||
        token.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token) ||
        interval is! num ||
        interval < 15 ||
        interval > 120) {
      throw const FormatException('Invalid presence response.');
    }
    return AnonymousUsageSession(
      token: token,
      heartbeatInterval: Duration(seconds: interval.round()),
    );
  }

  @override
  Future<void> heartbeat(String token, AnonymousUsageState state) =>
      _dio.put<void>(
        '/v1/app-presence/sessions/current',
        data: {'state': state.name},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );

  @override
  Future<void> closeSession(String token) => _dio.delete<void>(
    '/v1/app-presence/sessions/current',
    options: Options(headers: {'Authorization': 'Bearer $token'}),
  );
}

String validatedAnonymousPresenceOrigin() {
  final uri = Uri.tryParse(AppConfig.anonymousPresenceBaseUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'tetotv-bot.wisp.uno' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw StateError('Anonymous presence endpoint is not configured safely.');
  }
  return uri.origin;
}

/// Public releases and debug/test builds never send aggregate presence.
bool anonymousUsageEnabledForInstalledVersion(
  String version, {
  required bool isDebugBuild,
}) => installedBetaRuntimeFeaturesEnabled(version, isDebugBuild: isDebugBuild);

/// Prevents a fresh install from contacting the presence service before the
/// user has reached and completed the setup page which discloses this option.
/// Existing installations are migrated to a completed setup state by
/// [SetupProgressController]. Storage failures therefore fail closed.
bool anonymousUsageConsentReady({
  required bool preferencesLoaded,
  required bool enabled,
  required bool setupLoaded,
  required bool setupCompleted,
}) => preferencesLoaded && enabled && setupLoaded && setupCompleted;

/// Maintains one anonymous, expiring process session.
///
/// Playback owners are reference-counted so replacing one MPV route with the
/// next cannot briefly report the app as merely active when the old route
/// disposes after the new route initializes. Network failures stay silent and
/// can never interrupt startup or playback.
class AnonymousUsageReporter with WidgetsBindingObserver {
  AnonymousUsageReporter(
    this._client, {
    bool observeLifecycle = true,
    AppLifecycleState? initialLifecycleState,
  }) : _observeLifecycle = observeLifecycle {
    if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
    final lifecycle =
        initialLifecycleState ??
        (observeLifecycle ? WidgetsBinding.instance.lifecycleState : null);
    _resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  final AnonymousUsageClient _client;
  final bool _observeLifecycle;
  final Set<Object> _streamingOwners = <Object>{};
  bool _consented = false;
  bool _buildEligible = false;
  bool _resumed = true;
  bool _syncRequested = false;
  bool _draining = false;
  bool _disposed = false;
  String? _token;
  Timer? _timer;
  Duration _interval = const Duration(seconds: 45);

  bool get isStreaming => _streamingOwners.isNotEmpty;

  AnonymousUsageState get desiredState =>
      isStreaming ? AnonymousUsageState.streaming : AnonymousUsageState.active;

  void setConsent(bool value) {
    if (_disposed || value == _consented) return;
    _consented = value;
    _requestSynchronization();
  }

  void setBuildEligible(bool value) {
    if (_disposed || value == _buildEligible) return;
    _buildEligible = value;
    _requestSynchronization();
  }

  void beginStreaming(Object owner) {
    if (_disposed || !_streamingOwners.add(owner)) return;
    _requestSynchronization();
  }

  void endStreaming(Object owner) {
    if (_disposed || !_streamingOwners.remove(owner)) return;
    _requestSynchronization();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_resumed == resumed) return;
    _resumed = resumed;
    _requestSynchronization();
  }

  bool get _shouldReport =>
      _consented && _buildEligible && (_resumed || isStreaming);

  void _requestSynchronization() {
    if (_disposed) return;
    _syncRequested = true;
    if (!_draining) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_syncRequested && !_disposed) {
        _syncRequested = false;
        if (!_shouldReport) {
          await _endSession();
          continue;
        }
        final attemptedToken = _token;
        try {
          final token = attemptedToken;
          if (token == null) {
            final session = await _client.createSession(desiredState);
            if (_disposed || !_shouldReport) {
              await _bestEffortClose(session.token);
              continue;
            }
            _token = session.token;
            _interval = session.heartbeatInterval;
          } else {
            await _client.heartbeat(token, desiredState);
          }
          _scheduleNext(_interval);
        } on DioException catch (error) {
          if (error.response?.statusCode == 401 && attemptedToken != null) {
            // Android may suspend Dart timers long enough for the volatile
            // server capability to expire. Renew immediately after that
            // definitive response instead of leaving the live count stale for
            // another heartbeat interval.
            if (_token == attemptedToken) _token = null;
            _syncRequested = true;
            continue;
          }
          _scheduleNext(const Duration(seconds: 45));
        } catch (_) {
          _scheduleNext(const Duration(seconds: 45));
        }
      }
    } finally {
      _draining = false;
      if (_syncRequested && !_disposed) unawaited(_drain());
    }
  }

  void _scheduleNext(Duration delay) {
    if (_disposed || !_shouldReport) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      _requestSynchronization();
    });
  }

  Future<void> _endSession() async {
    _timer?.cancel();
    _timer = null;
    final token = _token;
    _token = null;
    if (token != null) await _bestEffortClose(token);
  }

  Future<void> _bestEffortClose(String token) async {
    try {
      await _client.closeSession(token);
    } catch (_) {
      // Abandoned capabilities expire server-side in at most three minutes.
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    final token = _token;
    _token = null;
    if (token != null) unawaited(_bestEffortClose(token));
    _streamingOwners.clear();
  }
}

final anonymousUsageClientProvider = Provider<AnonymousUsageClient>(
  (ref) => BrokerAnonymousUsageClient(),
);

final _anonymousUsageConsentProvider = Provider<bool>((ref) {
  final preferences = ref.watch(settingsPreferencesProvider);
  final setup = ref.watch(setupProgressProvider);
  return anonymousUsageConsentReady(
    preferencesLoaded: preferences.loaded,
    enabled: preferences.anonymousUsageCountEnabled,
    setupLoaded: setup.loaded,
    setupCompleted: setup.completed,
  );
});

final anonymousUsageReporterProvider = Provider<AnonymousUsageReporter>((ref) {
  final reporter = AnonymousUsageReporter(
    ref.watch(anonymousUsageClientProvider),
  );
  ref.listen<bool>(
    _anonymousUsageConsentProvider,
    (_, consented) => reporter.setConsent(consented),
    fireImmediately: true,
  );
  // Debug/test builds fail closed without even initializing update storage or
  // the platform version bridge. Signed builds use the installed version
  // family, never the user's selected update channel, as the eligibility gate.
  if (kDebugMode) {
    reporter.setBuildEligible(false);
  } else {
    ref.listen<bool>(
      isInstalledBetaBuildProvider,
      (_, eligible) => reporter.setBuildEligible(eligible),
      fireImmediately: true,
    );
  }
  ref.onDispose(reporter.dispose);
  return reporter;
});
