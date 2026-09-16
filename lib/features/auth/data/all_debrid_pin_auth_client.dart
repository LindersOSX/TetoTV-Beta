import 'dart:io' show HttpDate;

import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:dio/dio.dart';

/// A privacy-safe failure from AllDebrid's PIN authorization endpoints.
///
/// The exception deliberately retains neither Dio's request/response objects
/// nor AllDebrid's response body because either can contain the PIN, check
/// secret, API key, or other provider-controlled text.
class AllDebridPinAuthException extends AllDebridException {
  const AllDebridPinAuthException(
    super.message, {
    super.code,
    this.httpStatus,
    this.retryAfter,
    this.isPollingDeferred = false,
  });

  final int? httpStatus;
  final Duration? retryAfter;

  /// A throttled authorization check is still pending. The caller should keep
  /// the existing PIN session and schedule one later check.
  final bool isPollingDeferred;
}

class AllDebridPinSession {
  const AllDebridPinSession({
    required this.pin,
    required this.check,
    required this.verificationUrl,
    required this.expiresAt,
  });

  final String pin;
  final String check;
  final Uri verificationUrl;
  final DateTime expiresAt;

  Duration get pollInterval => const Duration(seconds: 5);
}

class AllDebridPinAuthClient {
  AllDebridPinAuthClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.alldebrid.com',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              maxRedirects: 0,
              headers: const {
                'Accept': 'application/json',
                'User-Agent': 'TetoTV Android',
              },
            ),
          );

  final Dio _dio;

  Future<AllDebridPinSession> start() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/v4.1/pin/get');
      final data = _successData(response.data);
      final pin = data['pin']?.toString().trim() ?? '';
      final check = data['check']?.toString().trim() ?? '';
      final url = Uri.tryParse(data['user_url']?.toString() ?? '');
      final expiresIn = _asInt(data['expires_in']);
      if (pin.isEmpty ||
          check.isEmpty ||
          !_isAllDebridVerificationUrl(url) ||
          expiresIn <= 0) {
        throw const AllDebridPinAuthException(
          'AllDebrid returned an incomplete PIN authorization response.',
        );
      }
      return AllDebridPinSession(
        pin: pin,
        check: check,
        verificationUrl: url!,
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      );
    } on AllDebridPinAuthException {
      rethrow;
    } on DioException catch (error) {
      // Starting a PIN session may allocate provider-side state. Do not retry
      // it automatically when the outcome is unknown.
      throw _transportFailure(error, duringPoll: false);
    }
  }

  Future<String?> poll(AllDebridPinSession session) async {
    if (DateTime.now().isAfter(session.expiresAt)) {
      throw const AllDebridPinAuthException('The AllDebrid PIN expired.');
    }
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/v4/pin/check',
        data: {'pin': session.pin, 'check': session.check},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = _successData(response.data);
      if (data['activated'] != true) return null;
      final token = data['apikey']?.toString().trim() ?? '';
      if (token.isEmpty) {
        throw const AllDebridPinAuthException(
          'AllDebrid approved the PIN without returning an API key.',
        );
      }
      return token;
    } on AllDebridPinAuthException {
      rethrow;
    } on DioException catch (error) {
      throw _transportFailure(error, duringPoll: true);
    }
  }
}

bool _isAllDebridVerificationUrl(Uri? uri) {
  if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) return false;
  final host = uri.host.toLowerCase();
  return host == 'alldebrid.com' || host.endsWith('.alldebrid.com');
}

Map<String, dynamic> _successData(Map<String, dynamic>? body) {
  final value = body ?? const <String, dynamic>{};
  if (value['status'] != 'success') {
    // Provider-controlled error messages are intentionally not surfaced. They
    // have historically included request details and are not needed to guide
    // the user through recovery.
    throw const AllDebridPinAuthException(
      'AllDebrid did not accept this authorization request. Try again.',
    );
  }
  final data = value['data'];
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  throw const AllDebridPinAuthException(
    'AllDebrid returned an invalid authorization response.',
  );
}

AllDebridPinAuthException _transportFailure(
  DioException error, {
  required bool duringPoll,
}) {
  final status = error.response?.statusCode;
  if (status == 429) {
    return AllDebridPinAuthException(
      duringPoll
          ? 'AllDebrid asked TetoTV to slow down. Pairing will continue automatically.'
          : 'AllDebrid is temporarily rate-limited. Wait before trying again.',
      code: 'RATE_LIMITED',
      httpStatus: status,
      retryAfter: _boundedRetryAfter(error.response?.headers),
      isPollingDeferred: duringPoll,
    );
  }
  if (status == 401 || status == 403) {
    return AllDebridPinAuthException(
      'AllDebrid did not accept this authorization request. Try connecting again.',
      code: 'AUTHORIZATION_REJECTED',
      httpStatus: status,
    );
  }
  if (status != null && status >= 500) {
    return AllDebridPinAuthException(
      'AllDebrid authorization is temporarily unavailable. Try again shortly.',
      code: 'SERVICE_UNAVAILABLE',
      httpStatus: status,
    );
  }
  return AllDebridPinAuthException(
    'Could not reach AllDebrid. Check your connection and try again.',
    code: 'NETWORK_FAILURE',
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

int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};
