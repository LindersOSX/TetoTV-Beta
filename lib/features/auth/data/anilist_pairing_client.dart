import 'dart:io' show HttpDate;

import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:dio/dio.dart';

typedef TrackingPairingDelay = Future<void> Function(Duration duration);

/// Safe, app-authored transport metadata for the tracker pairing UI and local
/// diagnostics. Response bodies and arbitrary server messages are never kept.
class TrackingPairingServiceException extends StateError {
  TrackingPairingServiceException({
    required this.reasonCode,
    required String message,
    this.httpStatus,
    this.retryAfter,
  }) : super(message);

  final String reasonCode;
  final int? httpStatus;
  final Duration? retryAfter;
}

class TrackingPairingClient {
  TrackingPairingClient(
    this._provider, {
    required String baseUrl,
    Dio? dio,
    TrackingPairingDelay? delay,
  }) : _brokerOrigin = _normalizedBrokerOrigin(baseUrl),
       _dio = dio ?? _brokerDio(baseUrl),
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  static const _dnsRetryDelays = <Duration>[
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];
  final Dio _dio;
  final TrackingPairingDelay _delay;
  final TrackingProvider _provider;
  final Uri _brokerOrigin;

  Future<void> ensureReady() async {
    try {
      final response = await _withDnsRetry(
        () => _dio.get<Map<String, dynamic>>('health'),
      );
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
      throw _connectionFailure(error);
    }
  }

  Future<PairingSession> createSession() async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _withDnsRetry(
        () => _dio.post<Map<String, dynamic>>('v1/${_provider.slug}/pairings'),
      );
    } on DioException catch (error) {
      throw _connectionFailure(error);
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

  TrackingPairingServiceException _connectionFailure(DioException error) {
    final status = error.response?.statusCode;
    final dnsFailure = _isDnsLookupFailure(error);
    return TrackingPairingServiceException(
      reasonCode: switch (status) {
        404 => 'service_unavailable',
        429 => 'rate_limited',
        _ when dnsFailure => 'dns_lookup_failed',
        _ => switch (error.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.sendTimeout ||
          DioExceptionType.receiveTimeout => 'network_timeout',
          _ => 'network_failure',
        },
      },
      message: switch (status) {
        404 =>
          'The address responded, but it is not a TetoTV broker. Confirm the URL and deploy the included broker service.',
        429 =>
          'The pairing service is temporarily rate-limited. Wait before trying again.',
        _ when dnsFailure =>
          'This device could not resolve the TetoTV companion address. Check the network or Private DNS setting, then retry.',
        _ =>
          'The TetoTV broker could not be reached over HTTPS. Confirm DNS, the TLS certificate, and the /health endpoint, then retry.',
      },
      httpStatus: status,
      retryAfter: status == 429 ? _retryDelay(error.response?.headers) : null,
    );
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
        return PairingPollResult(
          status: PairingStatus.pending,
          retryAfter: _retryDelay(error.response?.headers),
          diagnosticReason: 'rate_limited',
        );
      }
      throw _connectionFailure(error);
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

  /// Confirms that an authorized token response reached secure storage.
  ///
  /// The companion keeps the response briefly retriable until this succeeds,
  /// so a dropped HTTPS response cannot consume the user's completed login.
  Future<void> acknowledge(PairingSession session) async {
    try {
      await _dio.delete<void>(
        'v1/${_provider.slug}/pairings/${session.pairingId}',
        options: Options(
          headers: {'Authorization': 'Pairing ${session.deviceCode}'},
        ),
      );
    } on DioException catch (error) {
      // Missing state is already acknowledged or expired and is therefore an
      // idempotent success from the device's perspective.
      if (error.response?.statusCode == 404) return;
      throw _connectionFailure(error);
    }
  }

  Future<TrackingTokenSet> refresh(String refreshToken) async {
    if (_provider != TrackingProvider.myAnimeList &&
        _provider != TrackingProvider.kitsu) {
      throw UnsupportedError(
        '${_provider.displayName} does not use brokered refresh tokens.',
      );
    }
    final response = await _dio.post<Map<String, dynamic>>(
      'v1/${_provider.slug}/token/refresh',
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

  /// DNS can briefly return EAI_NODATA while Android changes network or
  /// Private DNS state. Two bounded retries help that transient case without
  /// changing the trusted HTTPS origin. POST is retried only for a name lookup
  /// failure, where no connection to the companion was established.
  Future<T> _withDnsRetry<T>(Future<T> Function() request) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await request();
      } on DioException catch (error) {
        if (!_isDnsLookupFailure(error) || attempt >= _dnsRetryDelays.length) {
          rethrow;
        }
        await _delay(_dnsRetryDelays[attempt]);
      }
    }
  }
}

Dio _brokerDio(String baseUrl) => Dio(
  BaseOptions(
    baseUrl: '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/',
    // Keep the initial QR flow tolerant of a companion service restart while
    // retaining finite deadlines on every individual attempt.
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 45),
    followRedirects: false,
    maxRedirects: 0,
    headers: const {'Accept': 'application/json'},
  ),
);

bool _isDnsLookupFailure(DioException error) {
  if (error.type != DioExceptionType.connectionError) return false;
  final message = '${error.error ?? error.message ?? ''}'.toLowerCase();
  return const [
    'failed host lookup',
    'no address associated with hostname',
    'temporary failure in name resolution',
    'name or service not known',
    'nodename nor servname provided',
  ].any(message.contains);
}

Duration _retryDelay(Headers? headers) {
  final value = headers?.value('retry-after')?.trim();
  var seconds = value == null ? null : int.tryParse(value);
  if (seconds == null && value != null && value.length <= 80) {
    try {
      seconds = HttpDate.parse(
        value,
      ).difference(DateTime.now().toUtc()).inSeconds;
    } catch (_) {
      // Untrusted or nonstandard header values never enter logs or UI.
    }
  }
  return Duration(seconds: (seconds ?? 60).clamp(1, 3600));
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
