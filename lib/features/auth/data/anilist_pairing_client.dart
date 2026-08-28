import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:dio/dio.dart';

class TrackingPairingClient {
  TrackingPairingClient(this._provider, {required String baseUrl})
    : _brokerOrigin = _normalizedBrokerOrigin(baseUrl),
      _dio = Dio(
        BaseOptions(
          baseUrl: '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/',
          // Keep the initial QR flow tolerant of a companion service restart,
          // while retaining finite deadlines on every request.
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 45),
          followRedirects: false,
          maxRedirects: 0,
          headers: const {'Accept': 'application/json'},
        ),
      );

  final Dio _dio;
  final TrackingProvider _provider;
  final Uri _brokerOrigin;

  Future<void> ensureReady() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('health');
      final data = response.data ?? const <String, dynamic>{};
      final providers = data['providers'];
      final ready = providers is Map<String, dynamic>
          ? providers[_provider.slug] == true
          : false;
      if (data['status'] != 'ok' || !ready) {
        throw StateError(
          '${_provider.displayName} is not configured on the TetoTV broker. '
          'Add its OAuth client credentials to the broker environment.',
        );
      }
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
  }

  Future<PairingSession> createSession() async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        'v1/${_provider.slug}/pairings',
      );
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
    final data = response.data!;
    final verificationUri = _trustedBrokerVerificationUri(
      data['verification_uri'],
      _brokerOrigin,
    );
    final verificationUriComplete = _trustedBrokerVerificationUri(
      data['verification_uri_complete'],
      _brokerOrigin,
    );
    return PairingSession(
      pairingId: data['pairing_id'] as String,
      deviceCode: data['device_code'] as String,
      userCode: data['user_code'] as String,
      verificationUri: verificationUri.toString(),
      verificationUriComplete: verificationUriComplete.toString(),
      expiresAt: DateTime.parse(data['expires_at'] as String),
      pollInterval: Duration(seconds: data['interval'] as int? ?? 5),
    );
  }

  String _connectionMessage(DioException error) {
    final status = error.response?.statusCode;
    if (status == 404) {
      return 'The address responded, but it is not a TetoTV broker. Confirm '
          'the URL and deploy the included broker service.';
    }
    if (status == 429) {
      return 'The pairing service is temporarily rate-limited. Wait one '
          'minute, then retry.';
    }
    return 'The TetoTV broker could not be reached over HTTPS. Confirm DNS, '
        'the TLS certificate, and the /health endpoint, then retry.';
  }

  Future<PairingPollResult> poll(PairingSession session) async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        'v1/${_provider.slug}/pairings/${session.pairingId}',
        options: Options(
          headers: {'Authorization': 'Pairing ${session.deviceCode}'},
        ),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const PairingPollResult(status: PairingStatus.expired);
      }
      if (error.response?.statusCode == 429) {
        return const PairingPollResult(status: PairingStatus.pending);
      }
      rethrow;
    }
    final data = response.data!;
    final status = switch (data['status']) {
      'authorized' => PairingStatus.authorized,
      'expired' => PairingStatus.expired,
      _ => PairingStatus.pending,
    };
    return PairingPollResult(
      status: status,
      accessToken: data['access_token'] as String?,
      refreshToken: data['refresh_token'] as String?,
      expiresAt: switch (data['expires_at']) {
        final String value => DateTime.tryParse(value),
        _ => null,
      },
    );
  }

  Future<TrackingTokenSet> refresh(String refreshToken) async {
    if (_provider != TrackingProvider.myAnimeList) {
      throw UnsupportedError('Only MAL uses refresh tokens.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      'v1/myanimelist/token/refresh',
      data: {'refresh_token': refreshToken},
    );
    final data = response.data!;
    return TrackingTokenSet(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
      expiresAt: switch (data['expires_at']) {
        final String value => DateTime.tryParse(value),
        _ => null,
      },
    );
  }
}

Uri _normalizedBrokerOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw ArgumentError.value(value, 'baseUrl', 'Use one HTTPS broker origin.');
  }
  return Uri(scheme: 'https', host: uri.host, port: uri.port);
}

Uri _trustedBrokerVerificationUri(Object? value, Uri brokerOrigin) {
  final uri = Uri.tryParse(value?.toString().trim() ?? '');
  if (uri == null ||
      uri.scheme != brokerOrigin.scheme ||
      uri.host.toLowerCase() != brokerOrigin.host.toLowerCase() ||
      uri.port != brokerOrigin.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException(
      'The pairing service returned an untrusted verification address.',
    );
  }
  return uri;
}
