import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:dio/dio.dart';

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
      throw const AllDebridException(
        'AllDebrid returned an incomplete PIN authorization response.',
      );
    }
    return AllDebridPinSession(
      pin: pin,
      check: check,
      verificationUrl: url!,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  Future<String?> poll(AllDebridPinSession session) async {
    if (DateTime.now().isAfter(session.expiresAt)) {
      throw const AllDebridException('The AllDebrid PIN expired.');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/v4/pin/check',
      data: {'pin': session.pin, 'check': session.check},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = _successData(response.data);
    if (data['activated'] != true) return null;
    final token = data['apikey']?.toString().trim() ?? '';
    if (token.isEmpty) {
      throw const AllDebridException(
        'AllDebrid approved the PIN without returning an API key.',
      );
    }
    return token;
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
    final error = value['error'];
    if (error is Map) {
      throw AllDebridException(
        error['message']?.toString() ?? 'AllDebrid authorization failed.',
        code: error['code']?.toString(),
      );
    }
    throw const AllDebridException('AllDebrid authorization failed.');
  }
  final data = value['data'];
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  throw const AllDebridException(
    'AllDebrid returned an invalid authorization response.',
  );
}

int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};
