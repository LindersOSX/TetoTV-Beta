import 'dart:io' show HttpDate;

import 'package:dio/dio.dart';

enum RealDebridOAuthStage { start, poll, exchange, refresh }

/// A privacy-safe OAuth failure that can be rendered without exposing Dio's
/// request, response body, device code, client secret, or token.
class RealDebridOAuthException implements Exception {
  const RealDebridOAuthException({
    required this.stage,
    required this.reasonCode,
    required this.message,
    this.httpStatus,
    this.retryAfter,
  });

  final RealDebridOAuthStage stage;
  final String reasonCode;
  final String message;
  final int? httpStatus;
  final Duration? retryAfter;

  /// A throttled credentials check has not failed authorization. Keep the
  /// current device code and perform one later check.
  bool get isPollingDeferred =>
      stage == RealDebridOAuthStage.poll && reasonCode == 'rate_limited';

  @override
  String toString() => message;
}

class RealDebridDeviceSession {
  const RealDebridDeviceSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.interval,
    required this.expiresAt,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUrl;
  final Duration interval;
  final DateTime expiresAt;

  factory RealDebridDeviceSession.fromJson(
    Map<String, dynamic> json, {
    DateTime? now,
  }) {
    final deviceCode = json['device_code']?.toString().trim() ?? '';
    final userCode = json['user_code']?.toString().trim() ?? '';
    final verificationUrl = Uri.tryParse(
      json['verification_url']?.toString().trim() ?? '',
    );
    final intervalSeconds = _integerValue(json['interval']) ?? 5;
    final expiresInSeconds = _integerValue(json['expires_in']) ?? 1800;

    if (deviceCode.isEmpty ||
        userCode.isEmpty ||
        !_isRealDebridVerificationUrl(verificationUrl) ||
        expiresInSeconds <= 0 ||
        expiresInSeconds > const Duration(days: 1).inSeconds) {
      throw const FormatException(
        'Real-Debrid returned an incomplete device authorization response.',
      );
    }

    return RealDebridDeviceSession(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUrl: verificationUrl!,
      interval: Duration(seconds: intervalSeconds.clamp(3, 30)),
      expiresAt: (now ?? DateTime.now()).add(
        Duration(seconds: expiresInSeconds),
      ),
    );
  }
}

int? _integerValue(Object? value) => switch (value) {
  final num number => number.toInt(),
  final String text => int.tryParse(text),
  _ => null,
};

bool _isRealDebridVerificationUrl(Uri? uri) {
  if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) return false;
  final host = uri.host.toLowerCase();
  return host == 'real-debrid.com' || host.endsWith('.real-debrid.com');
}

class RealDebridOAuthCredentials {
  const RealDebridOAuthCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  final String clientId;
  final String clientSecret;
}

class RealDebridTokenSet {
  const RealDebridTokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
}

class RealDebridOAuthClient {
  RealDebridOAuthClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.real-debrid.com/oauth/v2',
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              maxRedirects: 0,
              headers: const {'Accept': 'application/json'},
            ),
          );

  static const openSourceClientId = 'X245A4XAIBGVM';
  static const deviceGrant = 'http://oauth.net/grant_type/device/1.0';

  final Dio _dio;

  Future<RealDebridDeviceSession> startDeviceAuthorization() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/device/code',
        queryParameters: const {
          'client_id': openSourceClientId,
          'new_credentials': 'yes',
        },
      );
      final data = response.data;
      if (data == null) {
        throw const FormatException(
          'Real-Debrid returned an empty device authorization response.',
        );
      }
      return RealDebridDeviceSession.fromJson(data);
    } on DioException catch (error) {
      // Creating a device code may allocate provider-side state. Do not retry
      // automatically when the response outcome is unknown.
      throw _oauthTransportFailure(error, RealDebridOAuthStage.start);
    }
  }

  Future<RealDebridOAuthCredentials?> pollCredentials(
    RealDebridDeviceSession session,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/device/credentials',
        queryParameters: {
          'client_id': openSourceClientId,
          'code': session.deviceCode,
        },
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if (response.statusCode == 429) {
        throw _oauthStatusFailure(
          status: 429,
          headers: response.headers,
          stage: RealDebridOAuthStage.poll,
        );
      }
      if (response.statusCode != 200 || response.data?['client_id'] == null) {
        return null;
      }
      return RealDebridOAuthCredentials(
        clientId: response.data!['client_id'] as String,
        clientSecret: response.data!['client_secret'] as String,
      );
    } on RealDebridOAuthException {
      rethrow;
    } on DioException catch (error) {
      throw _oauthTransportFailure(error, RealDebridOAuthStage.poll);
    }
  }

  Future<RealDebridTokenSet> exchangeDeviceCode({
    required RealDebridDeviceSession session,
    required RealDebridOAuthCredentials credentials,
  }) {
    return _tokenRequest(
      clientId: credentials.clientId,
      clientSecret: credentials.clientSecret,
      code: session.deviceCode,
      stage: RealDebridOAuthStage.exchange,
    );
  }

  Future<RealDebridTokenSet> refresh({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) {
    return _tokenRequest(
      clientId: clientId,
      clientSecret: clientSecret,
      code: refreshToken,
      stage: RealDebridOAuthStage.refresh,
    );
  }

  Future<RealDebridTokenSet> _tokenRequest({
    required String clientId,
    required String clientSecret,
    required String code,
    required RealDebridOAuthStage stage,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/token',
        data: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': code,
          'grant_type': deviceGrant,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = response.data!;
      return RealDebridTokenSet(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String,
        expiresAt: DateTime.now().add(
          Duration(seconds: data['expires_in'] as int? ?? 3600),
        ),
      );
    } on DioException catch (error) {
      // OAuth token exchanges and refreshes can consume or rotate a grant.
      // Surface a safe error and require an explicit recovery action instead
      // of replaying the POST automatically.
      throw _oauthTransportFailure(error, stage);
    }
  }
}

RealDebridOAuthException _oauthTransportFailure(
  DioException error,
  RealDebridOAuthStage stage,
) => _oauthStatusFailure(
  status: error.response?.statusCode,
  headers: error.response?.headers,
  stage: stage,
  networkFailure: error.response == null,
);

RealDebridOAuthException _oauthStatusFailure({
  required int? status,
  required Headers? headers,
  required RealDebridOAuthStage stage,
  bool networkFailure = false,
}) {
  if (status == 429) {
    final message = switch (stage) {
      RealDebridOAuthStage.poll =>
        'Real-Debrid asked TetoTV to slow down. Pairing will continue automatically.',
      RealDebridOAuthStage.exchange =>
        'Real-Debrid approved the device, but the final connection was rate-limited. Wait before connecting again.',
      RealDebridOAuthStage.refresh =>
        'Real-Debrid is temporarily rate-limited. Try again later.',
      RealDebridOAuthStage.start =>
        'Real-Debrid is temporarily rate-limited. Wait before trying again.',
    };
    return RealDebridOAuthException(
      stage: stage,
      reasonCode: 'rate_limited',
      message: message,
      httpStatus: status,
      retryAfter: _boundedRetryAfter(headers),
    );
  }
  if (status == 400 || status == 401 || status == 403) {
    return RealDebridOAuthException(
      stage: stage,
      reasonCode: 'authorization_rejected',
      message:
          'Real-Debrid did not accept this authorization request. Start a new code and try again.',
      httpStatus: status,
    );
  }
  if (status != null && status >= 500) {
    return RealDebridOAuthException(
      stage: stage,
      reasonCode: 'service_unavailable',
      message:
          'Real-Debrid authorization is temporarily unavailable. Try again shortly.',
      httpStatus: status,
    );
  }
  return RealDebridOAuthException(
    stage: stage,
    reasonCode: networkFailure ? 'network_failure' : 'request_failed',
    message: networkFailure
        ? 'Could not reach Real-Debrid. Check your connection and try again.'
        : 'Real-Debrid could not complete authorization. Try again.',
    httpStatus: status,
  );
}

Duration _boundedRetryAfter(Headers? headers) {
  final value = _singleHeader(headers, 'retry-after');
  var seconds = value == null ? null : int.tryParse(value);
  if (seconds == null && value != null) {
    try {
      seconds = HttpDate.parse(
        value,
      ).difference(DateTime.now().toUtc()).inSeconds;
    } catch (_) {
      // Untrusted or non-standard header values use the safe default below.
    }
  }
  return Duration(seconds: (seconds ?? 60).clamp(1, 300));
}

String? _singleHeader(Headers? headers, String name) {
  if (headers == null) return null;
  final entries = headers.map.entries.where(
    (entry) => entry.key.toLowerCase() == name,
  );
  if (entries.length != 1) return null;
  final values = entries.single.value;
  if (values.length != 1) return null;
  final value = values.single.trim();
  return value.isNotEmpty && value.length <= 80 ? value : null;
}
