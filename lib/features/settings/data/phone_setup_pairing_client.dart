import 'dart:convert';

import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

abstract interface class PhoneSetupPairingApi {
  Future<void> ensureReady();

  Future<PhoneSetupPairingSession> createSession(
    PhoneSetupKeyMaterial keyMaterial,
  );

  Future<PhoneSetupPollResult> poll(PhoneSetupPairingSession session);

  Future<void> acknowledge(
    PhoneSetupPairingSession session, {
    required int revision,
    required bool applied,
  });

  Future<void> cancel(PhoneSetupPairingSession session);

  PhoneSetupPairingSession restoreSession(Object? value);
}

class PhoneSetupPairingClient implements PhoneSetupPairingApi {
  PhoneSetupPairingClient({required String baseUrl, Dio? dio})
    : _origin = Uri.parse(baseUrl.replaceFirst(RegExp(r'/+$'), '')),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/',
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 25),
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
        'Phone setup requires the trusted public HTTPS TetoTV service.',
      );
    }
  }

  static const _algorithm = 'P-256-HKDF-SHA256-AES-256-GCM';
  final Uri _origin;
  final Dio _dio;

  @override
  Future<void> ensureReady() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'v1/setup-pairings/health',
      );
      final data = response.data ?? const <String, dynamic>{};
      final version = _integer(data['setup_pairing_version']);
      if (data['status'] != 'ok' ||
          data['setup_pairing'] != true ||
          version != 1 ||
          data['end_to_end_encryption'] != true) {
        throw StateError('The secure phone-setup service needs to be updated.');
      }
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
  }

  @override
  Future<PhoneSetupPairingSession> createSession(
    PhoneSetupKeyMaterial keyMaterial,
  ) async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        'v1/setup-pairings',
        data: <String, Object?>{
          'version': 1,
          'device_public_key': keyMaterial.encodedPublicKey,
        },
      );
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
    return _parseSession(
      response.data ?? const <String, dynamic>{},
      keyMaterial: keyMaterial,
      requireCryptoContract: true,
    );
  }

  @override
  Future<PhoneSetupPollResult> poll(PhoneSetupPairingSession session) async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        'v1/setup-pairings/${session.pairingId}',
        options: _deviceAuthorization(session),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404 ||
          error.response?.statusCode == 410) {
        return const PhoneSetupPollResult(
          status: PhoneSetupPairingStatus.expired,
          revision: 0,
        );
      }
      if (error.response?.statusCode == 429) {
        return const PhoneSetupPollResult(
          status: PhoneSetupPairingStatus.pending,
          revision: 0,
        );
      }
      throw StateError(_connectionMessage(error));
    }
    final data = response.data ?? const <String, dynamic>{};
    if (data['version'] != 1) {
      throw const FormatException(
        'The phone-setup response version is invalid.',
      );
    }
    final revision = _integer(data['revision']);
    if (revision < 0 || revision > 1000000) {
      throw const FormatException('The phone-setup revision is invalid.');
    }
    final status = switch (data['status']) {
      'pending' => PhoneSetupPairingStatus.pending,
      'bound' => PhoneSetupPairingStatus.bound,
      'submitted' || 'delivered' => PhoneSetupPairingStatus.submitted,
      'completed' => PhoneSetupPairingStatus.completed,
      'failed' => PhoneSetupPairingStatus.failed,
      'expired' => PhoneSetupPairingStatus.expired,
      _ => throw const FormatException(
        'The phone-setup response status is invalid.',
      ),
    };
    PhoneSetupEncryptedSubmission? envelope;
    if (status == PhoneSetupPairingStatus.submitted) {
      final value = data['envelope'];
      if (value is! Map || value['algorithm'] != _algorithm) {
        throw const FormatException(
          'The encrypted phone-setup envelope is invalid.',
        );
      }
      envelope = PhoneSetupEncryptedSubmission(
        browserPublicKey: decodeSetupBase64Url(
          value['ephemeral_public_key'],
          minimum: 65,
          maximum: 65,
          label: 'browser public key',
        ),
        nonce: decodeSetupBase64Url(
          value['iv'],
          minimum: 12,
          maximum: 12,
          label: 'nonce',
        ),
        ciphertext: decodeSetupBase64Url(
          value['ciphertext'],
          minimum: 17,
          maximum: 64 * 1024 + 16,
          label: 'setup payload',
        ),
      );
    }
    return PhoneSetupPollResult(
      status: status,
      revision: revision,
      envelope: envelope,
    );
  }

  @override
  Future<void> acknowledge(
    PhoneSetupPairingSession session, {
    required int revision,
    required bool applied,
  }) async {
    try {
      await _dio.post<void>(
        'v1/setup-pairings/${session.pairingId}/ack',
        data: <String, Object?>{
          'version': 1,
          'revision': revision,
          'outcome': applied ? 'applied' : 'rejected',
        },
        options: _deviceAuthorization(session),
      );
    } on DioException catch (error) {
      throw StateError(_connectionMessage(error));
    }
  }

  @override
  Future<void> cancel(PhoneSetupPairingSession session) async {
    try {
      await _dio.delete<void>(
        'v1/setup-pairings/${session.pairingId}',
        options: _deviceAuthorization(session),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404 ||
          error.response?.statusCode == 410) {
        return;
      }
      throw StateError(_connectionMessage(error));
    }
  }

  @override
  PhoneSetupPairingSession restoreSession(Object? value) {
    if (value is! Map) {
      throw const FormatException('The saved phone setup is invalid.');
    }
    final map = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('The saved phone setup is invalid.');
      }
      map[entry.key as String] = entry.value;
    }
    return _parseSession(
      map,
      keyMaterial: PhoneSetupKeyMaterial.fromJson(map['key']),
    );
  }

  PhoneSetupPairingSession _parseSession(
    Map<String, dynamic> data, {
    required PhoneSetupKeyMaterial keyMaterial,
    bool requireCryptoContract = false,
  }) {
    if (data['version'] != 1) {
      throw const FormatException(
        'The phone-setup session version is invalid.',
      );
    }
    final pairingId = _bounded(data['pairing_id'], 16, 80);
    final deviceCode = _bounded(data['device_code'], 40, 128);
    final userCode = _bounded(data['user_code'], 9, 9);
    final verification = Uri.tryParse('${data['verification_uri'] ?? ''}');
    final complete = Uri.tryParse('${data['verification_uri_complete'] ?? ''}');
    final bindExpiresAt = DateTime.tryParse(
      '${data['bind_expires_at'] ?? data['code_expires_at'] ?? ''}',
    );
    final absoluteExpiresAt = DateTime.tryParse(
      '${data['absolute_expires_at'] ?? data['expires_at'] ?? ''}',
    );
    final interval = _integer(data['interval'] ?? data['interval_seconds']);
    final fingerprint = _bounded(data['device_key_fingerprint'], 8, 128);
    final confirmation = _bounded(data['confirmation_code'], 4, 32);
    final localIdentity = _deviceKeyIdentity(keyMaterial);
    final crypto = data['crypto'];
    if ((requireCryptoContract && crypto == null) ||
        (crypto != null &&
            (crypto is! Map ||
                crypto['algorithm'] != _algorithm ||
                crypto['hkdf_salt'] != 'pairing_id_utf8' ||
                crypto['hkdf_info'] != 'tetotv-setup-v1' ||
                crypto['aad'] != 'pairing_id_utf8'))) {
      throw const FormatException(
        'The phone-setup encryption contract is invalid.',
      );
    }
    final now = DateTime.now();
    if (pairingId == null ||
        deviceCode == null ||
        userCode == null ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(pairingId) ||
        !RegExp(r'^[A-Za-z0-9_-]{40,128}$').hasMatch(deviceCode) ||
        !RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$').hasMatch(userCode) ||
        !_validVerification(verification, complete: false) ||
        !_validVerification(
          complete,
          complete: true,
          expectedCode: userCode,
          expectedKey: fingerprint,
        ) ||
        bindExpiresAt == null ||
        absoluteExpiresAt == null ||
        bindExpiresAt.isBefore(now.subtract(const Duration(days: 8))) ||
        absoluteExpiresAt.isBefore(bindExpiresAt) ||
        absoluteExpiresAt.isAfter(now.add(const Duration(days: 8))) ||
        interval < 2 ||
        interval > 30 ||
        fingerprint == null ||
        fingerprint != localIdentity.fingerprint ||
        confirmation == null ||
        confirmation != localIdentity.confirmationCode ||
        !RegExp(r'^[A-Za-z0-9:_-]+$').hasMatch(fingerprint) ||
        !RegExp(r'^[A-Z0-9 -]+$').hasMatch(confirmation)) {
      throw const FormatException(
        'The TetoTV service returned an invalid phone-setup session.',
      );
    }
    return PhoneSetupPairingSession(
      pairingId: pairingId,
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verification!,
      verificationUriComplete: complete!,
      codeExpiresAt: bindExpiresAt,
      expiresAt: absoluteExpiresAt,
      pollInterval: Duration(seconds: interval),
      keyMaterial: keyMaterial,
      deviceKeyFingerprint: fingerprint,
      confirmationCode: confirmation,
    );
  }

  bool _validVerification(
    Uri? uri, {
    required bool complete,
    String? expectedCode,
    String? expectedKey,
  }) {
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != _origin.host ||
        uri.port != _origin.port ||
        uri.userInfo.isNotEmpty ||
        uri.path != '/setup') {
      return false;
    }
    if (!complete) return !uri.hasQuery && !uri.hasFragment;
    if (uri.hasQuery || !uri.hasFragment) return false;
    late final Map<String, String> fragment;
    try {
      fragment = Uri.splitQueryString(uri.fragment);
    } catch (_) {
      return false;
    }
    return fragment.length == 2 &&
        fragment['code'] == expectedCode &&
        fragment['key'] == expectedKey;
  }

  Options _deviceAuthorization(PhoneSetupPairingSession session) =>
      Options(headers: {'Authorization': 'Pairing ${session.deviceCode}'});

  String _connectionMessage(DioException error) {
    return switch (error.response?.statusCode) {
      404 => 'The secure phone-setup service is not available yet.',
      409 => 'This phone setup was already completed or changed.',
      429 =>
        'Phone setup is temporarily rate-limited. Wait one minute and retry.',
      503 => 'The secure phone-setup service is temporarily busy.',
      _ => 'The secure TetoTV phone-setup service could not be reached.',
    };
  }
}

({String fingerprint, String confirmationCode}) _deviceKeyIdentity(
  PhoneSetupKeyMaterial key,
) {
  final digest = sha256.convert(<int>[0x04, ...key.publicX, ...key.publicY]);
  final bytes = digest.bytes;
  final value =
      (bytes[0] << 24) |
      (bytes[1] << 16) |
      (bytes[2] << 8) |
      bytes[3];
  return (
    fingerprint: base64UrlEncode(bytes).replaceAll('=', ''),
    confirmationCode: (value % 1000000).toString().padLeft(6, '0'),
  );
}

int _integer(Object? value) => switch (value) {
  final int value => value,
  final num value => value.toInt(),
  _ => -1,
};

String? _bounded(Object? value, int minimum, int maximum) {
  if (value is! String || value.length < minimum || value.length > maximum) {
    return null;
  }
  return value;
}
