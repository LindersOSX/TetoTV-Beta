import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:dio/dio.dart';

/// Large enough to retain the complete bounded on-device diagnostics ring in
/// normal operation, while still protecting the public support endpoint from
/// unbounded uploads.
const maximumExplicitDiagnosticsCharacters = 480000;
const maximumRecentCrashSummaries = 12;

Map<String, Object?> attachRecentCrashSummaries(
  Map<String, Object?> diagnostics,
  List<Map<String, Object?>> summaries, {
  DateTime? now,
  int sourceDroppedOutsideWindow = 0,
  int sourceDroppedForCapacity = 0,
}) {
  final end = (now ?? DateTime.now()).toUtc();
  final start = end.subtract(diagnosticHistoryWindow);
  final retained = <Map<String, Object?>>[];
  var outsideWindow = 0;
  final ordered = [...summaries]
    ..sort((left, right) {
      final a = _crashTimestamp(left)?.millisecondsSinceEpoch ?? 0;
      final b = _crashTimestamp(right)?.millisecondsSinceEpoch ?? 0;
      return a.compareTo(b);
    });
  for (final summary in ordered) {
    final timestamp = _crashTimestamp(summary);
    if (timestamp == null ||
        timestamp.isBefore(start) ||
        timestamp.isAfter(end)) {
      outsideWindow++;
      continue;
    }
    retained.add({
      'timestamp': timestamp.toIso8601String(),
      'component': 'native-crash',
      'severity': 'fatal',
      'kind': switch (summary['kind']?.toString()) {
        'java' => 'java',
        'native' => 'native',
        'anr' => 'anr',
        'flutter' => 'flutter',
        _ => 'platform',
      },
      'message': redactDiagnosticValue(
        summary['message']?.toString() ?? 'TetoTV stopped unexpectedly.',
        maximum: 500,
      ),
      if (summary['stack'] case final Object stack)
        'context': {
          'stack': redactDiagnosticValue(stack.toString(), maximum: 1800),
        },
    });
  }
  final capacityDrop = retained.length > maximumRecentCrashSummaries
      ? retained.length - maximumRecentCrashSummaries
      : 0;
  final bounded = retained.length > maximumRecentCrashSummaries
      ? retained.sublist(retained.length - maximumRecentCrashSummaries)
      : retained;
  return {
    ...diagnostics,
    'recentCrashSummaryWindow': {
      'schema': 'tetotv-local-crash-summaries-v1',
      'hours': diagnosticHistoryWindow.inHours,
      'startsAt': start.toIso8601String(),
      'endsAt': end.toIso8601String(),
      'ordering': 'oldest-first',
      'capacity': maximumRecentCrashSummaries,
      'retainedCount': bounded.length,
      'droppedOutsideWindow':
          sourceDroppedOutsideWindow.clamp(0, 0x7fffffff) + outsideWindow,
      'droppedForCapacity':
          sourceDroppedForCapacity.clamp(0, 0x7fffffff) + capacityDrop,
    },
    'recentCrashSummaries': bounded,
  };
}

DateTime? _crashTimestamp(Map<String, Object?> value) {
  if (value['occurred_at_ms'] case final num milliseconds) {
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds.toInt(),
      isUtc: true,
    );
  }
  if (value['timestamp'] case final String iso) {
    return DateTime.tryParse(iso)?.toUtc();
  }
  if (value['occurred_at'] case final String iso) {
    return DateTime.tryParse(iso)?.toUtc();
  }
  return null;
}

class ExplicitDiagnosticsReport {
  const ExplicitDiagnosticsReport({
    required this.eventId,
    required this.submittedAt,
    required this.appVersion,
    required this.buildNumber,
    required this.androidSdk,
    required this.abi,
    required this.deviceClass,
    required this.report,
  });

  final String eventId;
  final DateTime submittedAt;
  final String appVersion;
  final int buildNumber;
  final int androidSdk;
  final String abi;
  final String deviceClass;
  final String report;

  factory ExplicitDiagnosticsReport.fromSnapshot({
    required AppVersionInfo version,
    required TvDeviceProfile profile,
    required bool isTelevision,
    required Map<String, Object?> diagnostics,
    DateTime? submittedAt,
    Random? random,
  }) {
    final timestamp = (submittedAt ?? DateTime.now()).toUtc();
    return ExplicitDiagnosticsReport(
      eventId: _newEventId(random ?? Random.secure()),
      submittedAt: timestamp,
      appVersion: _safeVersion(version.name),
      buildNumber: version.code.clamp(1, 999999999),
      androidSdk: profile.sdk.clamp(24, 99),
      abi: _safeAbi(profile.abis.firstOrNull ?? 'unknown'),
      deviceClass: isTelevision ? 'tv' : 'phone',
      report: buildRedactedDiagnosticsText(
        version: version,
        profile: profile,
        isTelevision: isTelevision,
        diagnostics: diagnostics,
        generatedAt: timestamp,
      ),
    );
  }

  Map<String, Object?> toWireJson() => {
    'schema_version': 1,
    // This random value belongs to this button press only. It is neither an
    // installation ID nor a device ID and exists only to make retries safe.
    'event_id': eventId,
    'submitted_at': submittedAt.toIso8601String(),
    'app_version': appVersion,
    'build_number': buildNumber,
    'android_sdk': androidSdk,
    'abi': abi,
    'device_class': deviceClass,
    'report': report,
  };
}

class ExplicitDiagnosticsAcknowledgement {
  const ExplicitDiagnosticsAcknowledgement({
    required this.reference,
    required this.duplicate,
  });

  final String reference;
  final bool duplicate;
}

class DiagnosticsShareException implements Exception {
  const DiagnosticsShareException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef DiagnosticsRetryDelay = Future<void> Function(Duration duration);

abstract interface class ExplicitDiagnosticsReportApi {
  Future<ExplicitDiagnosticsAcknowledgement> send(
    ExplicitDiagnosticsReport report,
  );
}

class ExplicitDiagnosticsReportClient implements ExplicitDiagnosticsReportApi {
  ExplicitDiagnosticsReportClient({
    Dio? dio,
    String? baseUrl,
    DiagnosticsRetryDelay? retryDelay,
  }) : _origin = _validatedOrigin(
         (baseUrl ?? AppConfig.diagnosticReportBaseUrl).trim(),
       ),
       _retryDelay = retryDelay ?? Future<void>.delayed,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 6),
               sendTimeout: const Duration(seconds: 6),
               receiveTimeout: const Duration(seconds: 10),
             ),
           );

  final String _origin;
  final Dio _dio;
  final DiagnosticsRetryDelay _retryDelay;

  @override
  Future<ExplicitDiagnosticsAcknowledgement> send(
    ExplicitDiagnosticsReport report,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      late final Response<Object?> response;
      try {
        response = await _dio.post<Object?>(
          '$_origin/v1/diagnostic-reports',
          data: report.toWireJson(),
          options: Options(
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            sendTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 10),
            followRedirects: false,
            maxRedirects: 0,
            responseType: ResponseType.json,
            validateStatus: (_) => true,
          ),
        );
      } on DioException catch (error) {
        if (attempt < 2 && _retryableDioFailure(error)) {
          await _retryDelay(Duration(milliseconds: 350 * (attempt + 1)));
          continue;
        }
        throw const DiagnosticsShareException(
          'The diagnostic service could not be reached. Check the connection and try again.',
        );
      }

      final status = response.statusCode ?? 0;
      if (status == 202) {
        final data = response.data;
        if (data is Map) {
          final delivery = data['status'];
          final reference = data['incident_id'];
          if ((delivery == 'posted' || delivery == 'duplicate') &&
              reference is String &&
              RegExp(r'^[A-Za-z0-9_-]{16,40}$').hasMatch(reference)) {
            return ExplicitDiagnosticsAcknowledgement(
              reference: reference,
              duplicate: delivery == 'duplicate',
            );
          }
        }
        throw const DiagnosticsShareException(
          'The diagnostic service returned an invalid confirmation. Try again.',
        );
      }
      if (status == 503 && attempt < 2) {
        await _retryDelay(Duration(milliseconds: 350 * (attempt + 1)));
        continue;
      }
      if (status == 429) {
        throw const DiagnosticsShareException(
          'Too many diagnostic reports were sent. Wait one minute and try again.',
        );
      }
      if (status == 413) {
        throw const DiagnosticsShareException(
          'The diagnostic report was too large to send. Refresh Diagnostics and try again.',
        );
      }
      if (status == 400 || status == 415) {
        throw const DiagnosticsShareException(
          'The diagnostic service rejected this report. Refresh Diagnostics and try again.',
        );
      }
      throw const DiagnosticsShareException(
        'The Discord diagnostic channel is temporarily unavailable. Try again shortly.',
      );
    }
    throw const DiagnosticsShareException(
      'The Discord diagnostic channel is temporarily unavailable. Try again shortly.',
    );
  }

  static String _validatedOrigin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const DiagnosticsShareException(
        'The diagnostic service is not configured safely.',
      );
    }
    return uri.origin;
  }
}

bool _retryableDioFailure(DioException error) => switch (error.type) {
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout ||
  DioExceptionType.connectionError ||
  DioExceptionType.unknown => true,
  _ => false,
};

String buildRedactedDiagnosticsText({
  required AppVersionInfo version,
  required TvDeviceProfile profile,
  required bool isTelevision,
  required Map<String, Object?> diagnostics,
  required DateTime generatedAt,
}) {
  final payload = <String, Object?>{
    'schema': 'tetotv-explicit-diagnostics-v3',
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'app': {
      'name': 'TetoTV',
      'version': _safeVersion(version.name),
      'build': version.code.clamp(1, 999999999),
    },
    'deviceClass': isTelevision ? 'tv' : 'phone',
    'deviceCapabilities': profile.toDiagnosticsJson(),
    'serviceConfiguration': {
      'oauthPairingConfigured': AppConfig.hasAuthBroker,
      'sourcePairingConfigured': AppConfig.hasSourcePairingBroker,
      'crashReportingEndpointConfigured': AppConfig.hasCrashReportEndpoint,
      'diagnosticEndpointConfigured': AppConfig.hasDiagnosticReportEndpoint,
      'watchTogetherConfigured': AppConfig.hasWatchTogether,
      'optionalReleaseResolverConfigured': AppConfig.hasReleaseResolver,
      'oauthAndSupportShareOrigin': _sameOrigin(
        AppConfig.authBrokerBaseUrl,
        AppConfig.diagnosticReportBaseUrl,
      ),
    },
    'diagnostics': diagnostics,
    'privacy':
        'Explicit user share only. Account and tracker identity, credentials, room codes and capabilities, display names and avatars, direct media source data, URLs, magnets, torrent hashes, local file paths, email addresses, network addresses, and media bytes are redacted.',
  };
  final fullTruncation = _SnapshotTruncation();
  final safe = _sanitizeSnapshot(
    payload,
    depth: 0,
    stringMaximum: 4000,
    listMaximum: 300,
    truncation: fullTruncation,
  );
  final fullPayload = _snapshotWithCompleteness(
    safe,
    truncation: fullTruncation,
    reducedForSize: false,
  );
  final text = const JsonEncoder.withIndent('  ').convert(fullPayload);
  if (text.length <= maximumExplicitDiagnosticsCharacters) return text;

  // Preserve valid, parseable JSON if an unusual device produces an enormous
  // capability list. The normal path above retains all 100 database events.
  // This fallback keeps representative data from every section and declares
  // the reduction instead of cutting through a JSON value.
  final compactTruncation = _SnapshotTruncation();
  final compact = _sanitizeSnapshot(
    payload,
    depth: 0,
    stringMaximum: 1000,
    listMaximum: 50,
    truncation: compactTruncation,
  );
  final compactPayload = _snapshotWithCompleteness(
    compact,
    truncation: compactTruncation,
    reducedForSize: true,
    fullSanitizedCharacters: text.length,
    preReductionTruncation: fullTruncation,
  );
  final compactText = const JsonEncoder.withIndent(' ').convert(compactPayload);
  if (compactText.length <= maximumExplicitDiagnosticsCharacters) {
    return compactText;
  }
  throw const DiagnosticsShareException(
    'The redacted diagnostic snapshot is unexpectedly large. Refresh Diagnostics and try again.',
  );
}

Object? _sanitizeSnapshot(
  Object? value, {
  required int depth,
  required int stringMaximum,
  required int listMaximum,
  required _SnapshotTruncation truncation,
}) {
  if (depth > 8) {
    truncation.depthLimitedValues++;
    return '[DEPTH LIMITED]';
  }
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    return _redactExplicitValue(
      value,
      maximum: stringMaximum,
      truncation: truncation,
    );
  }
  if (value is List) {
    final dropped = (value.length - listMaximum).clamp(0, 0x7fffffff);
    if (dropped > 0) {
      truncation.truncatedLists++;
      truncation.droppedListItems += dropped;
    }
    return [
      for (final item in value.take(listMaximum))
        _sanitizeSnapshot(
          item,
          depth: depth + 1,
          stringMaximum: stringMaximum,
          listMaximum: listMaximum,
          truncation: truncation,
        ),
    ];
  }
  if (value is Map) {
    const mapMaximum = 300;
    final dropped = (value.length - mapMaximum).clamp(0, 0x7fffffff);
    if (dropped > 0) {
      truncation.truncatedMaps++;
      truncation.droppedMapFields += dropped;
    }
    final result = <String, Object?>{};
    for (final entry in value.entries.take(mapMaximum)) {
      final rawKey = entry.key.toString();
      final key = _redactExplicitValue(
        rawKey,
        maximum: 80,
        truncation: truncation,
      );
      result[key] = _isSensitiveDiagnosticKey(rawKey)
          ? '[REDACTED]'
          : _sanitizeSnapshot(
              entry.value,
              depth: depth + 1,
              stringMaximum: stringMaximum,
              listMaximum: listMaximum,
              truncation: truncation,
            );
    }
    return result;
  }
  return _redactExplicitValue(
    value.toString(),
    maximum: 500,
    truncation: truncation,
  );
}

Map<String, Object?> _snapshotWithCompleteness(
  Object? value, {
  required _SnapshotTruncation truncation,
  required bool reducedForSize,
  int? fullSanitizedCharacters,
  _SnapshotTruncation? preReductionTruncation,
}) {
  final snapshot = value is Map<String, Object?>
      ? value
      : <String, Object?>{'snapshot': value};
  final reduced = reducedForSize || truncation.hasTruncation;
  final preReduction = preReductionTruncation?.toJson();
  return {
    ...snapshot,
    'reportCompleteness': {
      'reduced': reduced,
      'maximumReportCharacters': maximumExplicitDiagnosticsCharacters,
      'fullSanitizedCharacters': ?fullSanitizedCharacters,
      'reason': reducedForSize
          ? 'Device diagnostics exceeded the bounded share limit.'
          : truncation.hasTruncation
          ? 'One or more bounded fields were reduced.'
          : 'Complete within all configured bounds.',
      'truncation': truncation.toJson(),
      'preSizeReductionTruncation': ?preReduction,
    },
  };
}

class _SnapshotTruncation {
  int truncatedLists = 0;
  int droppedListItems = 0;
  int truncatedMaps = 0;
  int droppedMapFields = 0;
  int truncatedStrings = 0;
  int droppedStringCharacters = 0;
  int depthLimitedValues = 0;

  bool get hasTruncation =>
      truncatedLists > 0 ||
      truncatedMaps > 0 ||
      truncatedStrings > 0 ||
      depthLimitedValues > 0;

  Map<String, int> toJson() => {
    'truncatedLists': truncatedLists,
    'droppedListItems': droppedListItems,
    'truncatedMaps': truncatedMaps,
    'droppedMapFields': droppedMapFields,
    'truncatedStrings': truncatedStrings,
    'droppedStringCharacters': droppedStringCharacters,
    'depthLimitedValues': depthLimitedValues,
  };
}

bool _isSensitiveDiagnosticKey(String key) {
  final normalized = key
      .trim()
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]}_${match[2]}',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  if (RegExp(
    r'(?:^|_)(?:authorization|cookie|credential|password|passcode|secret|token|api_key|client_secret|headers?|http_headers?|request_headers?|response_headers?|query|query_parameters?|endpoint|origin|base_url|room_code|capability|tracker_id|anilist_(?:media_)?id|mal_(?:media_)?id|username|user_name|display_name|member|guest|host|participant|owner|email|avatar|account_id|user_id|device_id|installation_id|advertising_id|android_id|serial|file_name|filename|path|uri|url|hostname|server_name|server_id|library_id|item_id|media_id|magnet|info_hash|torrent_hash|source_id|stream_id|media_bytes|payload_bytes|media_title|anime_title|episode_title|title|episode)(?:$|_)',
  ).hasMatch(normalized)) {
    return true;
  }

  // Third-party providers frequently emit camelCase or delimiter-free keys.
  // Compare a compact form as well so accessToken, refreshtoken, apiKey,
  // deviceId, and streamUrl receive the same treatment as snake_case fields.
  final compact = normalized.replaceAll('_', '');
  if (const [
    'authorization',
    'cookie',
    'header',
    'headers',
    'httpheader',
    'httpheaders',
    'requestheader',
    'requestheaders',
    'responseheader',
    'responseheaders',
    'query',
    'queryparameters',
    'endpoint',
    'origin',
    'baseurl',
    'credential',
    'credentials',
    'password',
    'passcode',
    'apikey',
    'clientsecret',
    'roomcode',
    'capability',
    'trackerid',
    'anilistid',
    'anilistmediaid',
    'malid',
    'malmediaid',
    'displayname',
    'member',
    'guest',
    'host',
    'participant',
    'owner',
    'avatar',
    'hostname',
    'servername',
    'serverid',
    'libraryid',
    'itemid',
    'mediaid',
    'torrenthash',
    'sourceid',
    'streamid',
    'mediabytes',
    'payloadbytes',
  ].any(compact.contains)) {
    return true;
  }
  if (compact == 'token' ||
      compact.startsWith('token') ||
      compact.endsWith('token') ||
      compact.contains('accesstoken') ||
      compact.contains('refreshtoken') ||
      compact.contains('authtoken') ||
      compact.contains('bearertoken') ||
      compact.contains('secret')) {
    return true;
  }
  if (compact.endsWith('url') ||
      compact.endsWith('uri') ||
      compact.endsWith('path')) {
    return true;
  }
  return const {
        'username',
        'displayname',
        'email',
        'avatar',
        'accountid',
        'userid',
        'deviceid',
        'installationid',
        'advertisingid',
        'androidid',
        'serial',
        'filename',
        'magnet',
        'infohash',
        'torrenthash',
        'sourceid',
        'streamid',
        'mediabytes',
        'payloadbytes',
        'bytes',
        'binary',
        'buffer',
        'body',
        'payload',
        'source',
        'rawsource',
        'stream',
        'rawstream',
        'torrent',
        'release',
        'mediatitle',
        'animetitle',
        'episodetitle',
        'title',
        'episode',
      }.contains(compact) ||
      compact.endsWith('accountid') ||
      compact.endsWith('userid') ||
      compact.endsWith('deviceid') ||
      compact.endsWith('filename');
}

String _redactExplicitValue(
  String value, {
  required int maximum,
  required _SnapshotTruncation truncation,
}) {
  var safe = redactDiagnosticValue(
    value,
    maximum: (value.length * 2 + 64).clamp(maximum, 0x7fffffff),
  );
  if (safe.length > maximum) {
    truncation.truncatedStrings++;
    truncation.droppedStringCharacters += safe.length - maximum;
    safe = safe.substring(0, maximum);
  }
  return safe;
}

bool _sameOrigin(String left, String right) {
  final a = Uri.tryParse(left.trim());
  final b = Uri.tryParse(right.trim());
  return a != null &&
      b != null &&
      a.scheme == b.scheme &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;
}

String _newEventId(Random random) {
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return 'diag-${base64Url.encode(bytes).replaceAll('=', '')}';
}

String _safeVersion(String value) {
  final normalized = value.trim();
  return RegExp(r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(normalized)
      ? normalized
      : '0.0.0';
}

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
