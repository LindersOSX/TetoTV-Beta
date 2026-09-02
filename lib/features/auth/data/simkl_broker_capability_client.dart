import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:dio/dio.dart';

/// Public SIMKL metadata returned only when the companion has a complete
/// server-side OAuth registration.
///
/// The client ID is public OAuth application metadata. The client secret is
/// deliberately not part of this model or the companion health response.
class SimklBrokerCapability {
  const SimklBrokerCapability({
    required this.clientId,
    required this.callbackUri,
  });

  final String clientId;
  final Uri callbackUri;
}

/// Fail-closed readiness probe used before SIMKL can become a visible option.
class SimklBrokerCapabilityClient {
  SimklBrokerCapabilityClient({required String baseUrl, Dio? dio})
    : _brokerOrigin = _validBrokerOrigin(baseUrl),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              maxRedirects: 0,
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final Uri _brokerOrigin;

  Future<SimklBrokerCapability?> probe() async {
    try {
      final response = await _dio.get<Object?>(
        _brokerOrigin.resolve('/health').toString(),
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status == 200,
        ),
      );
      final data = _stringMap(response.data);
      if (data == null || data['status'] != 'ok') return null;
      final providers = _stringMap(data['providers']);
      if (providers?['simkl'] != true) return null;

      final callbackValue = _stringMap(data['callbacks'])?['simkl'];
      final callback = callbackValue is String
          ? Uri.tryParse(callbackValue.trim())
          : null;
      if (!_trustedCallback(callback, _brokerOrigin)) return null;

      final rawClientId = _stringMap(data['provider_client_ids'])?['simkl'];
      final clientId = rawClientId is String ? rawClientId.trim() : '';
      if (clientId.isEmpty ||
          clientId.length > 512 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(clientId)) {
        return null;
      }
      return SimklBrokerCapability(clientId: clientId, callbackUri: callback!);
    } on DioException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Creates a hidden SIMKL pairing only after [probe] returned a capability.
  Future<PairingSession> createPairing(SimklBrokerCapability capability) async {
    if (!_validCapability(capability, _brokerOrigin)) {
      throw StateError('SIMKL is not ready on this broker.');
    }
    late final Response<Object?> response;
    try {
      response = await _dio.post<Object?>(
        _brokerOrigin.resolve('/v1/simkl/pairings').toString(),
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status == 201,
          headers: const {'Accept': 'application/json'},
        ),
      );
    } on DioException {
      throw StateError('SIMKL pairing is unavailable on this broker.');
    }
    final data = _stringMap(response.data);
    final pairingId = _boundedToken(data?['pairing_id'], 16, 80);
    final deviceCode = _boundedToken(data?['device_code'], 32, 128);
    final userCode = data?['user_code'];
    final expiresAt = DateTime.tryParse(data?['expires_at']?.toString() ?? '');
    final interval = data?['interval'];
    final verificationUri = _sameOriginUri(
      data?['verification_uri'],
      _brokerOrigin,
    );
    final verificationUriComplete = _sameOriginUri(
      data?['verification_uri_complete'],
      _brokerOrigin,
    );
    if (pairingId == null ||
        deviceCode == null ||
        userCode is! String ||
        !RegExp(r'^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$').hasMatch(userCode) ||
        expiresAt == null ||
        interval is! int ||
        interval < 1 ||
        interval > 30 ||
        verificationUri == null ||
        verificationUriComplete == null) {
      throw StateError('The broker returned an invalid SIMKL pairing.');
    }
    return PairingSession(
      pairingId: pairingId,
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri.toString(),
      verificationUriComplete: verificationUriComplete.toString(),
      expiresAt: expiresAt,
      pollInterval: Duration(seconds: interval),
    );
  }

  Future<PairingPollResult> pollPairing(PairingSession session) async {
    if (_boundedToken(session.pairingId, 16, 80) == null ||
        _boundedToken(session.deviceCode, 32, 128) == null) {
      throw StateError('The SIMKL pairing session is invalid.');
    }
    late final Response<Object?> response;
    try {
      response = await _dio.get<Object?>(
        _brokerOrigin
            .resolve('/v1/simkl/pairings/${session.pairingId}')
            .toString(),
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status == 200,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Pairing ${session.deviceCode}',
          },
        ),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const PairingPollResult(status: PairingStatus.expired);
      }
      if (error.response?.statusCode == 429) {
        return const PairingPollResult(status: PairingStatus.pending);
      }
      throw StateError('SIMKL pairing polling is unavailable.');
    }
    final data = _stringMap(response.data);
    final status = data?['status'];
    if (status == 'pending') {
      return const PairingPollResult(status: PairingStatus.pending);
    }
    if (status == 'expired') {
      return const PairingPollResult(status: PairingStatus.expired);
    }
    final accessToken = _boundedOpaque(data?['access_token'], 1, 4096);
    if (status != 'authorized' || accessToken == null) {
      throw StateError('The broker returned an invalid SIMKL authorization.');
    }
    final expiresValue = data?['expires_at'];
    final expiresAt = expiresValue is String
        ? DateTime.tryParse(expiresValue)
        : null;
    if (expiresValue != null && expiresAt == null) {
      throw StateError('The broker returned an invalid SIMKL authorization.');
    }
    return PairingPollResult(
      status: PairingStatus.authorized,
      accessToken: accessToken,
      expiresAt: expiresAt,
    );
  }
}

Map<String, dynamic>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Uri _validBrokerOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ArgumentError.value(value, 'baseUrl', 'Use one root HTTPS origin.');
  }
  return Uri(scheme: 'https', host: uri.host, port: uri.port);
}

bool _trustedCallback(Uri? callback, Uri origin) =>
    callback != null &&
    callback.scheme == origin.scheme &&
    callback.host.toLowerCase() == origin.host.toLowerCase() &&
    callback.port == origin.port &&
    callback.userInfo.isEmpty &&
    callback.path == '/oauth/simkl/callback' &&
    !callback.hasQuery &&
    !callback.hasFragment;

bool _validCapability(SimklBrokerCapability value, Uri origin) =>
    value.clientId.trim().isNotEmpty &&
    value.clientId.length <= 512 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value.clientId) &&
    _trustedCallback(value.callbackUri, origin);

String? _boundedToken(Object? value, int minimum, int maximum) {
  if (value is! String ||
      value.length < minimum ||
      value.length > maximum ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _boundedOpaque(Object? value, int minimum, int maximum) {
  if (value is! String ||
      value.length < minimum ||
      value.length > maximum ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  return value;
}

Uri? _sameOriginUri(Object? value, Uri origin) {
  final uri = value is String ? Uri.tryParse(value.trim()) : null;
  if (uri == null ||
      uri.scheme != origin.scheme ||
      uri.host.toLowerCase() != origin.host.toLowerCase() ||
      uri.port != origin.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}
