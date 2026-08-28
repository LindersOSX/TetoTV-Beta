import 'package:dio/dio.dart';

class TorBoxDeviceSession {
  const TorBoxDeviceSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.friendlyVerificationUrl,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUrl;
  final Uri friendlyVerificationUrl;
  final DateTime expiresAt;
  final Duration interval;

  factory TorBoxDeviceSession.fromJson(Map<String, dynamic> json) {
    final verificationUrl = Uri.tryParse(
      json['verification_url']?.toString() ?? '',
    );
    final friendlyUrl = Uri.tryParse(
      json['friendly_verification_url']?.toString() ?? '',
    );
    final deviceCode = json['device_code']?.toString() ?? '';
    final userCode = json['code']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(json['expires_at']?.toString() ?? '');
    final intervalSeconds = switch (json['interval']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 5,
      _ => 5,
    };
    if (deviceCode.isEmpty ||
        userCode.isEmpty ||
        !_isTrustedTorBoxVerificationUrl(verificationUrl) ||
        !_isTrustedTorBoxVerificationUrl(friendlyUrl) ||
        expiresAt == null) {
      throw const FormatException(
        'TorBox returned an incomplete device authorization response.',
      );
    }
    return TorBoxDeviceSession(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUrl: verificationUrl!,
      friendlyVerificationUrl: friendlyUrl!,
      expiresAt: expiresAt,
      interval: Duration(seconds: intervalSeconds.clamp(3, 30)),
    );
  }
}

bool _isTrustedTorBoxVerificationUrl(Uri? uri) {
  if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) return false;
  final host = uri.host.toLowerCase();
  return host == 'torbox.app' ||
      host.endsWith('.torbox.app') ||
      host == 'tor.box';
}

class TorBoxDeviceAuthClient {
  TorBoxDeviceAuthClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.torbox.app/v1/api',
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              maxRedirects: 0,
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;

  Future<TorBoxDeviceSession> start() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/user/auth/device/start',
      queryParameters: const {'app': 'TetoTV'},
    );
    final body = response.data ?? const <String, dynamic>{};
    final data = body['data'];
    if (body['success'] != true || data is! Map<String, dynamic>) {
      throw StateError(
        body['detail']?.toString() ??
            'TorBox could not start device authorization.',
      );
    }
    return TorBoxDeviceSession.fromJson(data);
  }

  Future<String?> poll(TorBoxDeviceSession session) async {
    if (DateTime.now().isAfter(session.expiresAt)) {
      throw StateError('The TorBox authorization code expired.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/user/auth/device/token',
      data: {'device_code': session.deviceCode},
      options: Options(
        contentType: Headers.jsonContentType,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final body = response.data ?? const <String, dynamic>{};
    if (response.statusCode == 200 && body['success'] == true) {
      final data = body['data'];
      final token = data is Map<String, dynamic>
          ? data['access_token']?.toString()
          : null;
      if (token == null || token.isEmpty) {
        throw const FormatException(
          'TorBox approved the device without returning an API token.',
        );
      }
      return token;
    }
    if (response.statusCode == 400) return null;
    throw StateError(
      body['detail']?.toString() ?? 'TorBox device authorization failed.',
    );
  }
}
