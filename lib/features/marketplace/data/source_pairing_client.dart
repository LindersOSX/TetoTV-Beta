import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:dio/dio.dart';

abstract interface class SourcePairingApi {
  Future<void> ensureReady();

  Future<SourcePairingSession> createSession();

  Future<SourcePairingPollResult> poll(SourcePairingSession session);

  Future<void> acknowledge(
    SourcePairingSession session,
    SourceImportSummary summary,
  );

  Future<void> cancel(SourcePairingSession session);
}

class SourcePairingClient implements SourcePairingApi {
  SourcePairingClient({required String baseUrl, Dio? dio})
    : _origin = Uri.parse(baseUrl.replaceFirst(RegExp(r'/+$'), '')),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/',
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {'Accept': 'application/json'},
            ),
          ) {
    if (_origin.scheme != 'https' ||
        _origin.host.isEmpty ||
        _origin.userInfo.isNotEmpty ||
        (_origin.path.isNotEmpty && _origin.path != '/') ||
        _origin.hasQuery ||
        _origin.hasFragment) {
      throw const FormatException(
        'Source pairing requires a public HTTPS broker origin.',
      );
    }
  }

  final Uri _origin;
  final Dio _dio;

  @override
  Future<void> ensureReady() async {
    try {
      late final Response<Map<String, dynamic>> response;
      try {
        // The Wispbyte bot keeps source pairing independent from Discord's
        // gateway status. Older brokers expose only the root health route, so
        // retain a strict 404-only fallback for compatibility.
        response = await _dio.get<Map<String, dynamic>>(
          'v1/source-pairings/health',
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
        response = await _dio.get<Map<String, dynamic>>('health');
      }
      final data = response.data ?? const <String, dynamic>{};
      final protocolVersion = switch (data['source_pairing_version']) {
        final int value => value,
        final num value => value.toInt(),
        _ => 0,
      };
      if (data['status'] != 'ok' ||
          data['source_pairing'] != true ||
          protocolVersion < 2) {
        throw StateError(
          'The TetoTV pairing service must be updated before sources can be saved with confirmation.',
        );
      }
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
  }

  @override
  Future<SourcePairingSession> createSession() async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        'v1/source-pairings',
        data: const <String, dynamic>{},
      );
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
    final data = response.data ?? const <String, dynamic>{};
    final pairingId = _boundedString(data['pairing_id'], 16, 80);
    final deviceCode = _boundedString(data['device_code'], 40, 128);
    final userCode = _boundedString(data['user_code'], 9, 9);
    final verification = Uri.tryParse('${data['verification_uri'] ?? ''}');
    final complete = Uri.tryParse('${data['verification_uri_complete'] ?? ''}');
    final expiresAt = DateTime.tryParse('${data['expires_at'] ?? ''}');
    final interval = switch (data['interval']) {
      final int value => value,
      final num value => value.toInt(),
      _ => 3,
    };
    if (pairingId == null ||
        deviceCode == null ||
        userCode == null ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(pairingId) ||
        !RegExp(r'^[A-Za-z0-9_-]{40,128}$').hasMatch(deviceCode) ||
        !RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$').hasMatch(userCode) ||
        !_validVerificationUri(verification, complete: false) ||
        !_validVerificationUri(
          complete,
          complete: true,
          expectedCode: userCode,
        ) ||
        expiresAt == null ||
        !expiresAt.isAfter(DateTime.now()) ||
        expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 15))) ||
        interval < 2 ||
        interval > 15) {
      throw const FormatException(
        'The TetoTV broker returned an invalid source-pairing session.',
      );
    }
    return SourcePairingSession(
      pairingId: pairingId,
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verification!,
      verificationUriComplete: complete!,
      expiresAt: expiresAt,
      pollInterval: Duration(seconds: interval),
    );
  }

  @override
  Future<SourcePairingPollResult> poll(SourcePairingSession session) async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        'v1/source-pairings/${session.pairingId}',
        options: Options(
          headers: {'Authorization': 'Pairing ${session.deviceCode}'},
        ),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const SourcePairingPollResult(
          status: SourcePairingPollStatus.expired,
        );
      }
      if (error.response?.statusCode == 429) {
        return const SourcePairingPollResult(
          status: SourcePairingPollStatus.pending,
        );
      }
      throw StateError(_connectionMessage(error));
    }
    final data = response.data ?? const <String, dynamic>{};
    switch (data['status']) {
      case 'pending':
        return const SourcePairingPollResult(
          status: SourcePairingPollStatus.pending,
        );
      case 'expired':
        return const SourcePairingPollResult(
          status: SourcePairingPollStatus.expired,
        );
      case 'submitted':
        break;
      default:
        throw const FormatException(
          'The source-pairing response has an invalid status.',
        );
    }
    final repositories = _urlList(data['repository_urls']);
    final manifests = _urlList(data['manifest_urls']);
    if (repositories.isEmpty && manifests.isEmpty) {
      throw const FormatException(
        'The source-pairing submission did not contain any URLs.',
      );
    }
    return SourcePairingPollResult(
      status: SourcePairingPollStatus.submitted,
      payload: SourcePairingPayload(
        repositoryUrls: repositories,
        manifestUrls: manifests,
      ),
    );
  }

  @override
  Future<void> acknowledge(
    SourcePairingSession session,
    SourceImportSummary summary,
  ) async {
    try {
      await _dio.post<void>(
        'v1/source-pairings/${session.pairingId}/complete',
        data: <String, int>{
          'repositories_saved': summary.repositoriesAdded,
          'manifests_saved': summary.manifestsAdded,
          // Only bounded counts leave the device. Rejection messages may
          // contain provider details and are deliberately kept local.
          'rejected_count': summary.errors.length.clamp(0, 16),
        },
        options: Options(
          headers: {'Authorization': 'Pairing ${session.deviceCode}'},
        ),
      );
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
  }

  @override
  Future<void> cancel(SourcePairingSession session) async {
    try {
      await _dio.delete<void>(
        'v1/source-pairings/${session.pairingId}',
        options: Options(
          headers: {'Authorization': 'Pairing ${session.deviceCode}'},
        ),
      );
    } on DioException catch (error) {
      // Cancellation is best effort. A missing session was already consumed
      // or expired, and other failures remain bounded by the broker TTL.
      if (error.response?.statusCode == 404) return;
    }
  }

  bool _validVerificationUri(
    Uri? uri, {
    required bool complete,
    String? expectedCode,
  }) {
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host != _origin.host ||
        uri.port != _origin.port ||
        uri.path != '/source-pair' ||
        uri.hasFragment) {
      return false;
    }
    if (!complete) return !uri.hasQuery;
    return uri.queryParameters.length == 1 &&
        uri.queryParameters['code'] == expectedCode;
  }

  String _connectionMessage(DioException error) {
    final status = error.response?.statusCode;
    if (status == 404) {
      return 'The configured broker has not been updated for source pairing.';
    }
    if (status == 429) {
      return 'Source pairing is temporarily rate-limited. Wait one minute and retry.';
    }
    if (status == 503) {
      return 'The source-pairing service is temporarily at capacity. Try again shortly.';
    }
    return 'The TetoTV pairing service could not be reached over HTTPS.';
  }
}

String? _boundedString(Object? value, int minimum, int maximum) {
  if (value is! String || value.length < minimum || value.length > maximum) {
    return null;
  }
  return value;
}

List<String> _urlList(Object? value) {
  if (value is! List || value.length > 8) {
    throw const FormatException('The source-pairing URL list is invalid.');
  }
  final result = <String>[];
  final seen = <String>{};
  for (final item in value) {
    if (item is! String || item.isEmpty || item.length > 2048) {
      throw const FormatException('A source-pairing URL is invalid.');
    }
    if (seen.add(item)) result.add(item);
  }
  return List<String>.unmodifiable(result);
}
