import 'dart:io';

import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:dio/dio.dart';

/// SIMKL's official limited-input PIN flow for TVs and consoles.
///
/// This flow is intentionally direct: the public OAuth client ID is safe to
/// ship to a device, while no client secret or TetoTV callback is involved.
class SimklPinClient {
  SimklPinClient({
    required String clientId,
    required String appVersion,
    String appName = 'tetotv',
    Dio? dio,
    DateTime Function()? now,
  }) : _clientId = _credential(clientId, 'clientId', 512),
       _appName = _appSlug(appName),
       _appVersion = _version(appVersion),
       _now = now ?? DateTime.now,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://api.simkl.com',
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 20),
               followRedirects: false,
               maxRedirects: 0,
             ),
           );

  final Dio _dio;
  final String _clientId;
  final String _appName;
  final String _appVersion;
  final DateTime Function() _now;

  Future<PairingSession> createPairing() async {
    final response = await _get('/oauth/pin');
    final data = _map(response.data);
    if (data?['result'] != 'OK') {
      throw const SimklPinException('SIMKL could not create a sign-in code.');
    }
    final userCode = _opaqueCode(data?['user_code']);
    final verificationUri = _verificationUri(
      data?['verification_uri'] ?? data?['verification_url'],
    );
    final expiresIn = _boundedInt(data?['expires_in'], 60, 1800);
    final interval = _boundedInt(data?['interval'], 1, 30);
    if (userCode == null ||
        verificationUri == null ||
        expiresIn == null ||
        interval == null) {
      throw const SimklPinException('SIMKL returned an invalid sign-in code.');
    }
    return PairingSession(
      pairingId: userCode,
      deviceCode: userCode,
      userCode: userCode,
      verificationUri: verificationUri.toString(),
      // SIMKL does not provide a pre-filled URL for its PIN flow.
      verificationUriComplete: verificationUri.toString(),
      expiresAt: _now().toUtc().add(Duration(seconds: expiresIn)),
      pollInterval: Duration(seconds: interval),
    );
  }

  Future<PairingPollResult> pollPairing(PairingSession session) async {
    final userCode = _opaqueCode(session.userCode);
    if (userCode == null) {
      throw const SimklPinException('The SIMKL sign-in code is invalid.');
    }
    if (!_now().toUtc().isBefore(session.expiresAt.toUtc())) {
      return const PairingPollResult(status: PairingStatus.expired);
    }
    late final Response<Object?> response;
    try {
      response = await _get('/oauth/pin/${Uri.encodeComponent(userCode)}');
    } on SimklPinExpiredException {
      return const PairingPollResult(status: PairingStatus.expired);
    }
    final data = _map(response.data);

    // SIMKL may recycle an unknown/expired poll into a fresh PIN-init payload.
    // Check this before `result == OK`: an init response can also be successful,
    // but it is never authorization for the session being polled.
    if (data?.containsKey('device_code') == true ||
        data?.containsKey('user_code') == true) {
      return const PairingPollResult(status: PairingStatus.expired);
    }
    if (data?['result'] == 'OK') {
      final token = _opaqueToken(data?['access_token']);
      if (token == null) {
        throw const SimklPinException(
          'SIMKL completed sign-in without a valid access token.',
        );
      }
      return PairingPollResult(
        status: PairingStatus.authorized,
        accessToken: token,
      );
    }

    if (data?['result'] == 'KO' &&
        _plainMessage(data?['message']) == 'authorization pending') {
      return const PairingPollResult(status: PairingStatus.pending);
    }
    throw const SimklPinException('SIMKL sign-in could not be completed.');
  }

  Future<Response<Object?>> _get(String path) async {
    try {
      return await _dio.get<Object?>(
        path,
        queryParameters: {
          'client_id': _clientId,
          'app-name': _appName,
          'app-version': _appVersion,
        },
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status == 200,
          headers: {
            'Accept': 'application/json',
            'User-Agent': '$_appName/$_appVersion',
          },
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 404) {
        throw const SimklPinExpiredException();
      }
      if (_isTransientPinFailure(error)) {
        throw SimklPinTransientException(
          statusCode: status,
          retryAfter: _retryAfter(
            error.response?.headers.value('retry-after'),
            _now().toUtc(),
          ),
        );
      }
      throw const SimklPinException('SIMKL sign-in could not be completed.');
    }
  }
}

class SimklPinException implements Exception {
  const SimklPinException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SimklPinExpiredException extends SimklPinException {
  const SimklPinExpiredException() : super('The SIMKL sign-in code expired.');
}

/// A safe-to-retry SIMKL PIN read failure.
///
/// Callers own the retry schedule so polling can still respect the PIN's
/// server-provided interval and absolute expiry time.
class SimklPinTransientException extends SimklPinException {
  const SimklPinTransientException({this.statusCode, this.retryAfter})
    : super('SIMKL sign-in is temporarily unavailable.');

  final int? statusCode;
  final Duration? retryAfter;
}

Map<String, dynamic>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _credential(String value, String name, int maximum) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
    throw ArgumentError.value('', name, 'Must be a bounded non-empty value.');
  }
  return normalized;
}

String _appSlug(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'appName', 'Use a lowercase app slug.');
  }
  return normalized;
}

String _version(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'appVersion', 'Use a bounded version.');
  }
  return normalized;
}

String? _opaqueCode(Object? value) {
  if (value is! String ||
      value.length < 4 ||
      value.length > 16 ||
      !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _opaqueToken(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 4096 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  return value;
}

Uri? _verificationUri(Object? value) {
  final uri = value is String ? Uri.tryParse(value.trim()) : null;
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'simkl.com' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      (uri.path != '/pin' && uri.path != '/pin/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

int? _boundedInt(Object? value, int minimum, int maximum) {
  if (value is! num || !value.isFinite) return null;
  final integer = value.toInt();
  return integer >= minimum && integer <= maximum ? integer : null;
}

String? _plainMessage(Object? value) {
  if (value is! String || value.length > 200) return null;
  return value.trim().toLowerCase();
}

bool _isTransientPinFailure(DioException error) {
  final status = error.response?.statusCode;
  if (status == 429 || status == 500 || status == 502 || status == 503) {
    return true;
  }
  if (status != null) return false;
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.unknown => true,
    DioExceptionType.badCertificate ||
    DioExceptionType.badResponse ||
    DioExceptionType.cancel => false,
  };
}

Duration? _retryAfter(String? value, DateTime now) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final seconds = int.tryParse(normalized);
  if (seconds != null) {
    return seconds < 0 ? null : Duration(seconds: seconds);
  }
  try {
    final retryAt = HttpDate.parse(normalized).toUtc();
    final delay = retryAt.difference(now.toUtc());
    return delay > Duration.zero ? delay : Duration.zero;
  } on FormatException {
    return null;
  }
}
