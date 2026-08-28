import 'dart:async';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AnonymousCrashReport {
  const AnonymousCrashReport({
    required this.reportId,
    required this.kind,
    required this.message,
    required this.stack,
    required this.occurredAt,
    required this.appVersion,
    required this.buildNumber,
    required this.androidSdk,
    required this.abi,
    required this.deviceClass,
  });

  final String reportId;
  final String kind;
  final String message;
  final String stack;
  final DateTime occurredAt;
  final String appVersion;
  final int buildNumber;
  final int androidSdk;
  final String abi;
  final String deviceClass;

  Map<String, Object?> toLocalJson() => {
    'report_id': reportId,
    ...toWireJson(),
  };

  Map<String, Object?> toWireJson() => {
    'schema_version': 1,
    // Unique to this crash only. This is not an installation or device ID; it
    // makes a broker retry idempotent if the first response is lost.
    'event_id': reportId,
    'kind': kind,
    'message': message,
    'stack': stack,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'app_version': appVersion,
    'build_number': buildNumber,
    'android_sdk': androidSdk,
    'abi': abi,
    'device_class': deviceClass,
  };
}

abstract interface class AnonymousCrashReportClient {
  Future<void> send(AnonymousCrashReport report);
}

class BrokerAnonymousCrashReportClient implements AnonymousCrashReportClient {
  BrokerAnonymousCrashReportClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _validatedBrokerOrigin(),
              connectTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
              responseType: ResponseType.json,
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (status) => status == 202,
              headers: const {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
            ),
          );

  final Dio _dio;

  static String _validatedBrokerOrigin() {
    final uri = Uri.tryParse(AppConfig.crashReportBaseUrl.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw StateError(
        'Anonymous crash-report endpoint is not configured safely.',
      );
    }
    return uri.origin;
  }

  @override
  Future<void> send(AnonymousCrashReport report) async {
    await _dio.post<void>('/v1/crash-reports', data: report.toWireJson());
  }
}

abstract interface class AnonymousCrashPlatform {
  Future<void> setEnabled(bool enabled);

  Future<bool> store(Map<String, Object?> report);

  Future<Map<String, Object?>?> pending();

  Future<void> acknowledge(String reportId);

  Future<void> clear();

  Future<AppVersionInfo> appVersion();

  Future<TvDeviceProfile> deviceProfile();

  Future<bool> isTelevision();
}

class AndroidAnonymousCrashPlatform implements AnonymousCrashPlatform {
  const AndroidAnonymousCrashPlatform(this._bridge);

  final AndroidTvBridge _bridge;

  @override
  Future<void> setEnabled(bool enabled) =>
      _bridge.setAnonymousCrashReportingEnabled(enabled);

  @override
  Future<bool> store(Map<String, Object?> report) =>
      _bridge.storePendingAnonymousCrashReport(report);

  @override
  Future<Map<String, Object?>?> pending() =>
      _bridge.getPendingAnonymousCrashReport();

  @override
  Future<void> acknowledge(String reportId) =>
      _bridge.acknowledgeAnonymousCrashReport(reportId);

  @override
  Future<void> clear() => _bridge.clearPendingAnonymousCrashReports();

  @override
  Future<AppVersionInfo> appVersion() => _bridge.getAppVersion();

  @override
  Future<TvDeviceProfile> deviceProfile() => _bridge.getDeviceProfile();

  @override
  Future<bool> isTelevision() => _bridge.isTelevision();
}

class AnonymousCrashReporter {
  AnonymousCrashReporter(this._client, this._platform);

  final AnonymousCrashReportClient _client;
  final AnonymousCrashPlatform _platform;
  bool _enabled = false;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();
  String? _lastSignature;
  DateTime? _lastSignatureAt;
  final Map<String, DateTime> _handledSignatures = {};
  final List<DateTime> _handledReportTimes = [];

  void setEnabled(bool value) {
    if (_disposed || value == _enabled) return;
    _enabled = value;
    _enqueue(() async {
      try {
        await _platform.setEnabled(value);
        if (value) {
          await _flushPending();
        } else {
          await _platform.clear();
        }
      } catch (_) {
        // Reporting can never block startup or settings changes.
      }
    });
  }

  Future<void> record({
    required String kind,
    required Object error,
    StackTrace? stack,
  }) {
    if (_disposed ||
        !_enabled ||
        _isExpectedArtworkNetworkFailure(error, stack)) {
      return Future<void>.value();
    }
    final message = redactDiagnosticValue(error.toString(), maximum: 500);
    final safeStack = _redactStack(stack?.toString() ?? '', maximum: 4000);
    final signature =
        '$kind|$message|${safeStack.split('\n').firstOrNull ?? ''}';
    final now = DateTime.now();
    if (_lastSignature == signature &&
        _lastSignatureAt != null &&
        now.difference(_lastSignatureAt!) < const Duration(seconds: 30)) {
      return Future<void>.value();
    }
    _lastSignature = signature;
    _lastSignatureAt = now;
    return _enqueue(() async {
      try {
        if (!_enabled || !await _flushPending()) return;
        final report = await _createReport(
          reportId: 'dart-${now.microsecondsSinceEpoch}',
          kind: kind,
          message: message,
          stack: safeStack,
          occurredAt: now,
        );
        if (!_enabled) return;
        final stored = await _platform.store(report.toLocalJson());
        if (!stored) return;
        await _sendStored(report);
      } catch (_) {
        // Crash reporting must never create a second unhandled error.
      }
    });
  }

  /// Reports an unexpected error that the app caught and presented without
  /// terminating. Expected control-flow failures are intentionally excluded,
  /// and a small rolling quota prevents a broken endpoint or rebuild loop from
  /// flooding the private Discord diagnostics channel.
  Future<void> recordHandled({
    required AnonymousErrorArea area,
    required Object error,
    StackTrace? stack,
  }) {
    if (_disposed ||
        !_enabled ||
        _isExpectedArtworkNetworkFailure(error, stack) ||
        !_isUnexpectedHandledError(error)) {
      return Future<void>.value();
    }
    final now = DateTime.now();
    _pruneHandledReports(now);
    final safeError = redactDiagnosticValue(error.toString(), maximum: 360);
    final firstFrame = _redactStack(
      stack?.toString() ?? '',
      maximum: 300,
    ).split('\n').firstOrNull;
    final signature =
        '${area.name}|${error.runtimeType}|$safeError|$firstFrame';
    final previous = _handledSignatures[signature];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 10)) {
      return Future<void>.value();
    }
    if (_handledReportTimes.length >= 6) return Future<void>.value();
    _handledSignatures[signature] = now;
    _handledReportTimes.add(now);
    return record(
      // The existing broker schema calls non-framework Dart errors
      // "platform". Reusing it keeps the deployed broker/bot compatible while
      // the message clearly distinguishes a handled application failure.
      kind: 'platform',
      error: 'Handled ${area.label} error (${error.runtimeType}): $safeError',
      stack: stack,
    );
  }

  void _pruneHandledReports(DateTime now) {
    const window = Duration(minutes: 10);
    _handledReportTimes.removeWhere((time) => now.difference(time) >= window);
    _handledSignatures.removeWhere((_, time) => now.difference(time) >= window);
  }

  Future<bool> _flushPending() async {
    if (!_enabled) return false;
    final pending = await _platform.pending();
    if (pending == null) return true;
    final report = await _reportFromPending(pending);
    if (report == null) {
      await _platform.clear();
      return true;
    }
    return _sendStored(report);
  }

  Future<bool> _sendStored(AnonymousCrashReport report) async {
    try {
      await _client.send(report);
      await _platform.acknowledge(report.reportId);
      return true;
    } catch (_) {
      // Keep the bounded local report for the next launch. Never log report
      // contents or surface a crash-reporting failure to the user.
      return false;
    }
  }

  Future<AnonymousCrashReport> _createReport({
    required String reportId,
    required String kind,
    required String message,
    required String stack,
    required DateTime occurredAt,
    int? androidSdk,
    String? abi,
    String? deviceClass,
  }) async {
    final values = await Future.wait<Object>([
      _platform.appVersion().catchError((_) => const AppVersionInfo.unknown()),
      _platform.deviceProfile().catchError(
        (_) => const TvDeviceProfile.unknown(),
      ),
      _platform.isTelevision().catchError((_) => false),
    ]);
    final version = values[0] as AppVersionInfo;
    final profile = values[1] as TvDeviceProfile;
    final television = values[2] as bool;
    return AnonymousCrashReport(
      reportId: reportId,
      kind: _safeKind(kind),
      message: redactDiagnosticValue(message, maximum: 500),
      stack: _redactStack(stack, maximum: 4000),
      occurredAt: occurredAt,
      appVersion: _safeVersion(version.name),
      buildNumber: version.code.clamp(1, 999999999),
      androidSdk: (androidSdk ?? profile.sdk).clamp(24, 99),
      abi: _safeAbi(abi ?? profile.abis.firstOrNull ?? 'unknown'),
      deviceClass: switch (deviceClass) {
        'tv' => 'tv',
        'phone' => 'phone',
        _ => television ? 'tv' : 'phone',
      },
    );
  }

  Future<AnonymousCrashReport?> _reportFromPending(
    Map<String, Object?> value,
  ) async {
    final reportId = value['report_id'];
    final kind = value['kind'];
    final message = value['message'];
    final occurredAt = _occurredAt(value);
    if (reportId is! String ||
        reportId.isEmpty ||
        reportId.length > 100 ||
        kind is! String ||
        message is! String ||
        occurredAt == null) {
      return null;
    }
    return _createReport(
      reportId: reportId,
      kind: kind,
      message: message,
      stack: value['stack'] as String? ?? '',
      occurredAt: occurredAt,
      androidSdk: (value['android_sdk'] as num?)?.toInt(),
      abi: value['abi'] as String?,
      deviceClass: value['device_class'] as String?,
    );
  }

  DateTime? _occurredAt(Map<String, Object?> value) {
    if (value['occurred_at'] case final String iso) {
      return DateTime.tryParse(iso)?.toUtc();
    }
    if (value['occurred_at_ms'] case final num milliseconds) {
      final value = milliseconds.toInt();
      if (value > 0) {
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      }
    }
    return null;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((_) {});
    return result;
  }

  void dispose() {
    _disposed = true;
    _enabled = false;
  }
}

enum AnonymousErrorArea {
  applicationState('application state'),
  catalog('catalog'),
  playback('playback');

  const AnonymousErrorArea(this.label);

  final String label;
}

bool _isUnexpectedHandledError(Object error) {
  if (error is DioException && error.type == DioExceptionType.cancel) {
    return false;
  }
  final type = error.runtimeType.toString().toLowerCase();
  if (type == 'debridcachemissexception' ||
      type == 'webprovidersearchcancelled' ||
      type == '_discordauthenticationabandoned') {
    return false;
  }
  final message = error.toString().toLowerCase();
  return !const [
    'authorization_pending',
    'slow_down',
    'expired_token',
    'access_denied',
    'authorization was denied',
    'authentication was cancelled',
    'authentication was canceled',
    'login was cancelled',
    'login was canceled',
    'connection attempt was cancelled',
    'operation was cancelled',
    'operation was canceled',
    'request was cancelled',
    'request was canceled',
    'search cancelled',
    'search canceled',
    'not instantly cached',
    'no results',
  ].any(message.contains);
}

/// Image loading is deliberately best-effort: Flutter's image pipeline can
/// surface an artwork CDN DNS outage through the global error hooks even
/// though the screen has already rendered its placeholder. Keep that bounded
/// network context in the local explicit diagnostics ring (recorded by the
/// global hook), but do not post it as an anonymous application crash.
///
/// API failures remain reportable. The predicate requires either an image
/// pipeline stack frame or one of the narrowly scoped public artwork hosts;
/// a generic DNS/connection failure is never discarded.
bool _isExpectedArtworkNetworkFailure(Object error, StackTrace? stack) {
  final message = error.toString().toLowerCase();
  final isResolutionFailure =
      message.contains('failed host lookup') ||
      message.contains('connection closed before full header') ||
      message.contains('connection reset by peer');
  if (!isResolutionFailure) return false;
  final stackText = stack?.toString().toLowerCase() ?? '';
  final imagePipeline =
      stackText.contains('network_image') ||
      stackText.contains('image_provider') ||
      stackText.contains('image_stream');
  final artworkHost = const [
    's4.anilist.co',
    's.anilist.co',
    'media.kitsu.io',
    'cdn.myanimelist.net',
    'cdn.discordapp.com',
    // Transparent title logos use a dedicated, bounded downloader. Its
    // transport errors can reach Flutter's image pipeline without a useful
    // stack even though AnimeTitleLogoView has already shown the text
    // fallback. Keep those expected CDN resets out of the crash channel.
    'artworks.thetvdb.com',
    'assets.fanart.tv',
  ].any(message.contains);
  return imagePipeline || artworkHost;
}

/// Captures Riverpod failures that would otherwise be converted into an error
/// panel and never reach FlutterError/PlatformDispatcher.
class AnonymousHandledErrorObserver extends ProviderObserver {
  AnonymousHandledErrorObserver({
    Future<void> Function({
      required AnonymousErrorArea area,
      required Object error,
      StackTrace? stack,
    })?
    report,
  }) : _report = report ?? recordAnonymousHandledError;

  final Future<void> Function({
    required AnonymousErrorArea area,
    required Object error,
    StackTrace? stack,
  })
  _report;
  final Map<ProviderBase<Object?>, Object> _lastErrors = {};

  void _capture(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stack,
  ) {
    if (identical(_lastErrors[provider], error)) return;
    _lastErrors[provider] = error;
    unawaited(
      _report(
        area: AnonymousErrorArea.applicationState,
        error: error,
        stack: stack,
      ),
    );
  }

  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) => _capture(provider, error, stackTrace);

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (newValue case AsyncError(:final error, :final stackTrace)) {
      _capture(provider, error, stackTrace);
    } else {
      _lastErrors.remove(provider);
    }
  }

  @override
  void didDisposeProvider(
    ProviderBase<Object?> provider,
    ProviderContainer container,
  ) {
    _lastErrors.remove(provider);
  }
}

String _safeKind(String value) => switch (value) {
  'flutter' || 'platform' || 'native' || 'java' || 'anr' => value,
  _ => 'platform',
};

String _safeAbi(String value) {
  final normalized = value.trim().toLowerCase();
  return const {
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
        'x86',
      }.contains(normalized)
      ? normalized
      : 'unknown';
}

String _safeVersion(String value) {
  final normalized = value.trim();
  return RegExp(r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(normalized)
      ? normalized
      : '0.0.0';
}

String _redactStack(String value, {required int maximum}) {
  final lines = value
      .split(RegExp(r'[\r\n]+'))
      .take(50)
      .map((line) => redactDiagnosticValue(line, maximum: 300))
      .where((line) => line.isNotEmpty);
  final output = lines.join('\n');
  return output.length <= maximum ? output : output.substring(0, maximum);
}

final anonymousCrashReportClientProvider = Provider<AnonymousCrashReportClient>(
  (ref) => BrokerAnonymousCrashReportClient(),
);

final anonymousCrashPlatformProvider = Provider<AnonymousCrashPlatform>(
  (ref) => AndroidAnonymousCrashPlatform(AndroidTvBridge.instance),
);

AnonymousCrashReporter? _activeAnonymousCrashReporter;

Future<void> recordAnonymousCrash({
  required String kind,
  required Object error,
  StackTrace? stack,
}) =>
    _activeAnonymousCrashReporter?.record(
      kind: kind,
      error: error,
      stack: stack,
    ) ??
    Future<void>.value();

Future<void> recordAnonymousHandledError({
  required AnonymousErrorArea area,
  required Object error,
  StackTrace? stack,
}) =>
    _activeAnonymousCrashReporter?.recordHandled(
      area: area,
      error: error,
      stack: stack,
    ) ??
    Future<void>.value();

final anonymousCrashReporterProvider = Provider<AnonymousCrashReporter>((ref) {
  final reporter = AnonymousCrashReporter(
    ref.watch(anonymousCrashReportClientProvider),
    ref.watch(anonymousCrashPlatformProvider),
  );
  _activeAnonymousCrashReporter = reporter;
  ref.listen<(bool, bool)>(
    settingsPreferencesProvider.select(
      (preferences) =>
          (preferences.loaded, preferences.anonymousCrashReportingEnabled),
    ),
    (_, state) {
      final (loaded, enabled) = state;
      if (loaded || enabled) reporter.setEnabled(enabled);
    },
    fireImmediately: true,
  );
  ref.onDispose(() {
    if (identical(_activeAnonymousCrashReporter, reporter)) {
      _activeAnonymousCrashReporter = null;
    }
    reporter.dispose();
  });
  return reporter;
});
