import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:dio/dio.dart';

abstract interface class DiscordDevicePairingApi {
  Future<DiscordDevicePairingSession> createSession();

  Future<DiscordDevicePairingPollResult> poll(
    DiscordDevicePairingSession session,
  );

  Future<void> cancel(DiscordDevicePairingSession session);
}

class DiscordDeviceAuthClient implements DiscordDevicePairingApi {
  DiscordDeviceAuthClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://discord.com/api/v10/',
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              headers: const {'Accept': 'application/json'},
              contentType: Headers.formUrlEncodedContentType,
              followRedirects: false,
              maxRedirects: 0,
            ),
          );

  static const applicationId = '1536801401710055474';
  static const requestedScopes = 'openid sdk.social_layer_presence';

  final Dio _dio;

  @override
  Future<DiscordDevicePairingSession> createSession() async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        'oauth2/device/authorize',
        data: const {'client_id': applicationId, 'scope': requestedScopes},
        options: _oauthPostOptions(),
      );
    } on DioException catch (error) {
      throw DiscordDeviceAuthException(_connectionMessage(error));
    }
    if (response.statusCode != 200) {
      throw const DiscordDeviceAuthException(
        'Discord returned an invalid device-linking response.',
      );
    }

    final data = response.data ?? const <String, dynamic>{};
    final deviceCode = _boundedSecret(data['device_code']);
    final userCode = _boundedString(data['user_code'], 4, 20);
    final verification = Uri.tryParse('${data['verification_uri'] ?? ''}');
    final complete = Uri.tryParse('${data['verification_uri_complete'] ?? ''}');
    final expiresIn = _integer(data['expires_in']);
    final interval = _integer(data['interval']) ?? 5;

    if (deviceCode == null ||
        userCode == null ||
        !RegExp(r'^[A-Z0-9-]{4,20}$').hasMatch(userCode) ||
        !_validDiscordVerificationUri(verification, complete: false) ||
        !_validDiscordVerificationUri(
          complete,
          complete: true,
          expectedCode: userCode,
        ) ||
        expiresIn == null ||
        expiresIn < 30 ||
        expiresIn > 900 ||
        interval < 2 ||
        interval > 15) {
      throw const DiscordDeviceAuthException(
        'Discord returned an invalid device-linking session.',
      );
    }

    return DiscordDevicePairingSession(
      // Discord's device flow has no separate public pairing identifier.
      // A redacted constant keeps routing state free of the secret code.
      pairingId: 'discord-device',
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verification!,
      verificationUriComplete: complete!,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      pollInterval: Duration(seconds: interval),
    );
  }

  @override
  Future<DiscordDevicePairingPollResult> poll(
    DiscordDevicePairingSession session,
  ) async {
    if (!session.expiresAt.isAfter(DateTime.now())) {
      return const DiscordDevicePairingPollResult(
        status: DiscordDevicePairingPollStatus.expired,
      );
    }

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'oauth2/token',
        data: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': session.deviceCode,
          'client_id': applicationId,
        },
        options: _oauthPostOptions(),
      );
      if (response.statusCode != 200) {
        throw const DiscordDeviceAuthException(
          'Discord returned an invalid account-token response.',
        );
      }
      return DiscordDevicePairingPollResult(
        status: DiscordDevicePairingPollStatus.authorized,
        token: _parseToken(response.data ?? const <String, dynamic>{}),
      );
    } on DioException catch (error) {
      final code = _oauthErrorCode(error);
      return switch (code) {
        'authorization_pending' => const DiscordDevicePairingPollResult(
          status: DiscordDevicePairingPollStatus.pending,
        ),
        'slow_down' => const DiscordDevicePairingPollResult(
          status: DiscordDevicePairingPollStatus.slowDown,
        ),
        'expired_token' ||
        'access_denied' => const DiscordDevicePairingPollResult(
          status: DiscordDevicePairingPollStatus.expired,
        ),
        _ => throw DiscordDeviceAuthException(_connectionMessage(error)),
      };
    }
  }

  @override
  Future<void> cancel(DiscordDevicePairingSession session) async {
    // Discord exposes no device-flow cancellation endpoint. Forgetting the
    // one-time code prevents this client from polling it again; Discord then
    // expires it server-side within the advertised lifetime.
  }

  DiscordTokenBundle _parseToken(Map<String, dynamic> data) {
    final access = _boundedSecret(data['access_token']);
    final refresh = _boundedSecret(data['refresh_token']);
    final tokenType = '${data['token_type'] ?? ''}'.toLowerCase();
    final scopes = switch (data['scope']) {
      final String value => value.trim(),
      _ => '',
    };
    final scopeSet = scopes
        .split(RegExp(r'\s+'))
        .where((scope) => scope.isNotEmpty)
        .toSet();
    final expiresIn = _integer(data['expires_in']);
    if (access == null ||
        refresh == null ||
        tokenType != 'bearer' ||
        expiresIn == null ||
        expiresIn < 60 ||
        expiresIn > const Duration(days: 8).inSeconds ||
        scopes.isEmpty ||
        scopes.length > 512 ||
        !scopeSet.contains('openid') ||
        !scopeSet.contains('sdk.social_layer_presence')) {
      throw const DiscordDeviceAuthException(
        'Discord returned an invalid account token.',
      );
    }
    return DiscordTokenBundle(
      accessToken: access,
      refreshToken: refresh,
      tokenType: 1,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      scopes: scopes,
    );
  }

  bool _validDiscordVerificationUri(
    Uri? uri, {
    required bool complete,
    String? expectedCode,
  }) {
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host != 'discord.com' ||
        uri.port != 443 ||
        uri.path != '/activate' ||
        uri.hasFragment) {
      return false;
    }
    if (!complete) return !uri.hasQuery;
    return uri.queryParameters.length == 1 &&
        uri.queryParameters['user_code'] == expectedCode;
  }

  String? _oauthErrorCode(DioException error) {
    final data = error.response?.data;
    if (data is Map) return data['error'] as String?;
    return null;
  }

  String _connectionMessage(DioException error) {
    return switch (error.response?.statusCode) {
      429 =>
        'Discord linking is temporarily rate-limited. Wait a moment and try again.',
      final int status when status >= 500 =>
        'Discord linking is temporarily unavailable. Try again shortly.',
      _ =>
        'Discord could not be reached securely. Check the connection and try again.',
    };
  }
}

/// Sanitized by construction: this type never stores response bodies, URLs,
/// device codes, or token strings.
class DiscordDeviceAuthException implements Exception {
  const DiscordDeviceAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

String? _boundedString(Object? value, int minimum, int maximum) {
  if (value is! String || value.length < minimum || value.length > maximum) {
    return null;
  }
  return value;
}

String? _boundedSecret(Object? value) {
  final string = _boundedString(value, 20, 4096);
  return string == null || string.contains(RegExp(r'\s')) ? null : string;
}

int? _integer(Object? value) => switch (value) {
  final int value => value,
  final num value => value.toInt(),
  _ => null,
};

Options _oauthPostOptions() => Options(
  followRedirects: false,
  maxRedirects: 0,
  validateStatus: (status) => status == 200,
);
