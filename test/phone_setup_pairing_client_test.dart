import 'dart:convert';

import 'package:anime_tv/features/settings/data/phone_setup_pairing_client.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PhoneSetupPairingClient trusted origin', () {
    for (final invalid in <String>[
      'http://setup.example',
      'https://user:password@setup.example',
      'https://setup.example/api',
      'https://setup.example?redirect=evil',
      'https://setup.example/#fragment',
      'https://',
    ]) {
      test('rejects $invalid', () {
        expect(
          () => PhoneSetupPairingClient(baseUrl: invalid),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
        );
      });
    }

    test('accepts a root HTTPS origin with an explicit port', () {
      expect(
        () => PhoneSetupPairingClient(baseUrl: 'https://setup.example:8443/'),
        returnsNormally,
      );
    });
  });

  group('PhoneSetupPairingClient contract', () {
    test('health requires versioned end-to-end phone setup', () async {
      final good = _Harness(
        (_) => {
          'status': 'ok',
          'setup_pairing': true,
          'setup_pairing_version': 1,
          'end_to_end_encryption': true,
        },
      );
      await good.client.ensureReady();

      for (final response in <Map<String, Object?>>[
        {'status': 'ok', 'setup_pairing': true, 'setup_pairing_version': 1},
        {
          'status': 'ok',
          'setup_pairing': true,
          'setup_pairing_version': 2,
          'end_to_end_encryption': true,
        },
        {
          'status': 'degraded',
          'setup_pairing': true,
          'setup_pairing_version': 1,
          'end_to_end_encryption': true,
        },
      ]) {
        final bad = _Harness((_) => response);
        await expectLater(bad.client.ensureReady(), throwsA(isA<StateError>()));
      }
    });

    test(
      'creates a session with only the public key and validates full crypto contract',
      () async {
        late RequestOptions request;
        final harness = _Harness((options) {
          request = options;
          return _sessionResponse();
        });
        final key = _keyMaterial();

        final session = await harness.client.createSession(key);

        expect(request.method, 'POST');
        expect(request.path, 'v1/setup-pairings');
        expect(request.data, {
          'version': 1,
          'device_public_key': key.encodedPublicKey,
        });
        expect(request.data.toString(), isNot(contains('device-secret')));
        expect(session.pairingId, 'pairing_1234567890');
        expect(session.userCode, 'ABCD-EFGH');
        expect(
          session.verificationUri.toString(),
          'https://setup.example/setup',
        );
        expect(
          session.verificationUriComplete.fragment,
          'code=ABCD-EFGH&key=${_testIdentity.fingerprint}',
        );
        expect(session.keyMaterial.privateD, key.privateD);
      },
    );

    test('rejects missing or altered create-session crypto contract', () async {
      final missing = _Harness((_) {
        final response = _sessionResponse();
        response.remove('crypto');
        return response;
      });
      await expectLater(
        missing.client.createSession(_keyMaterial()),
        throwsFormatException,
      );

      final altered = _Harness((_) {
        final response = _sessionResponse();
        response['crypto'] = {
          'algorithm': 'P-256-HKDF-SHA256-AES-256-GCM',
          'hkdf_salt': 'wrong',
          'hkdf_info': 'tetotv-setup-v1',
          'aad': 'pairing_id_utf8',
        };
        return response;
      });
      await expectLater(
        altered.client.createSession(_keyMaterial()),
        throwsFormatException,
      );
    });

    test('derives the QR identity locally instead of trusting the relay', () async {
      for (final field in const [
        'device_key_fingerprint',
        'confirmation_code',
      ]) {
        final harness = _Harness((_) {
          final response = _sessionResponse();
          response[field] = field == 'confirmation_code'
              ? '000000'
              : List.filled(43, 'A').join();
          if (field == 'device_key_fingerprint') {
            response['verification_uri_complete'] =
                'https://setup.example/setup#code=ABCD-EFGH&key=${response[field]}';
          }
          return response;
        });
        await expectLater(
          harness.client.createSession(_keyMaterial()),
          throwsFormatException,
          reason: field,
        );
      }
    });

    test(
      'requires same-origin fragment-only verification completion',
      () async {
        final mutations = <String>[
          'https://evil.example/setup#code=ABCD-EFGH&key=${_testIdentity.fingerprint}',
          'https://setup.example/setup?code=ABCD-EFGH&key=${_testIdentity.fingerprint}',
          'https://setup.example/setup#code=WXYZ-2345&key=${_testIdentity.fingerprint}',
          'https://setup.example/setup#code=ABCD-EFGH&key=WRONG_KEY',
          'https://setup.example/setup#code=ABCD-EFGH&key=${_testIdentity.fingerprint}&extra=1',
          'https://setup.example/other#code=ABCD-EFGH&key=${_testIdentity.fingerprint}',
        ];
        for (final uri in mutations) {
          final harness = _Harness(
            (_) => _sessionResponse(verificationUriComplete: uri),
          );
          await expectLater(
            harness.client.createSession(_keyMaterial()),
            throwsFormatException,
            reason: uri,
          );
        }
      },
    );

    test(
      'poll sends device capability in header and parses a 65-byte envelope',
      () async {
        late RequestOptions request;
        final browserKey = [0x04, ...List<int>.filled(64, 9)];
        final nonce = List<int>.filled(12, 8);
        final ciphertext = List<int>.filled(33, 7);
        final harness = _Harness((options) {
          request = options;
          return {
            'version': 1,
            'status': 'submitted',
            'revision': 4,
            'envelope': {
              'algorithm': 'P-256-HKDF-SHA256-AES-256-GCM',
              'ephemeral_public_key': _b64(browserKey),
              'iv': _b64(nonce),
              'ciphertext': _b64(ciphertext),
            },
          };
        });

        final result = await harness.client.poll(_session());

        expect(request.method, 'GET');
        expect(request.headers['Authorization'], 'Pairing ${'d' * 48}');
        expect(request.uri.query, isEmpty);
        expect(result.status, PhoneSetupPairingStatus.submitted);
        expect(result.revision, 4);
        expect(result.envelope?.browserPublicKey, browserKey);
        expect(result.envelope?.nonce, nonce);
        expect(result.envelope?.ciphertext, ciphertext);
      },
    );

    test(
      'poll rejects invalid versions, revisions, statuses, and envelopes',
      () async {
        for (final response in <Map<String, Object?>>[
          {'version': 2, 'status': 'pending', 'revision': 0},
          {'version': 1, 'status': 'pending', 'revision': -1},
          {'version': 1, 'status': 'unknown', 'revision': 0},
          {'version': 1, 'status': 'submitted', 'revision': 1},
          {
            'version': 1,
            'status': 'submitted',
            'revision': 1,
            'envelope': {
              'algorithm': 'plaintext',
              'ephemeral_public_key': _b64([0x04, ...List.filled(64, 1)]),
              'iv': _b64(List.filled(12, 1)),
              'ciphertext': _b64(List.filled(17, 1)),
            },
          },
        ]) {
          final harness = _Harness((_) => response);
          await expectLater(
            harness.client.poll(_session()),
            throwsFormatException,
          );
        }
      },
    );

    test(
      'acknowledge and cancel authenticate without URL credentials',
      () async {
        final requests = <RequestOptions>[];
        final harness = _Harness((options) {
          requests.add(options);
          return <String, Object?>{};
        });

        await harness.client.acknowledge(
          _session(),
          revision: 9,
          applied: false,
        );
        await harness.client.cancel(_session());

        expect(requests[0].method, 'POST');
        expect(requests[0].data, {
          'version': 1,
          'revision': 9,
          'outcome': 'rejected',
        });
        expect(requests[1].method, 'DELETE');
        for (final request in requests) {
          expect(request.headers['Authorization'], 'Pairing ${'d' * 48}');
          expect(request.uri.query, isEmpty);
          expect(request.uri.fragment, isEmpty);
        }
      },
    );

    test(
      'saved session round-trips while malformed saved state is rejected',
      () {
        final client = _Harness((_) => <String, Object?>{}).client;
        final original = _session();
        final restored = client.restoreSession(original.toJson());
        expect(restored.pairingId, original.pairingId);
        expect(restored.deviceCode, original.deviceCode);
        expect(restored.keyMaterial.privateD, original.keyMaterial.privateD);

        final malformed = Map<String, Object?>.from(original.toJson())
          ..['device_code'] = 'short';
        expect(() => client.restoreSession(malformed), throwsFormatException);
      },
    );
  });
}

class _Harness {
  _Harness(this.respond) {
    dio = Dio(BaseOptions(baseUrl: 'https://setup.example/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: Map<String, dynamic>.from(respond(options)),
            ),
          );
        },
      ),
    );
    client = PhoneSetupPairingClient(
      baseUrl: 'https://setup.example',
      dio: dio,
    );
  }

  final Map<String, Object?> Function(RequestOptions options) respond;
  late final Dio dio;
  late final PhoneSetupPairingClient client;
}

Map<String, Object?> _sessionResponse({
  String? verificationUriComplete,
}) {
  final now = DateTime.now().toUtc();
  return {
    'version': 1,
    'pairing_id': 'pairing_1234567890',
    'device_code': 'd' * 48,
    'user_code': 'ABCD-EFGH',
    'verification_uri': 'https://setup.example/setup',
    'verification_uri_complete':
        verificationUriComplete ??
        'https://setup.example/setup#code=ABCD-EFGH&key=${_testIdentity.fingerprint}',
    'bind_expires_at': now.add(const Duration(hours: 24)).toIso8601String(),
    'absolute_expires_at': now.add(const Duration(days: 7)).toIso8601String(),
    'interval': 5,
    'device_key_fingerprint': _testIdentity.fingerprint,
    'confirmation_code': _testIdentity.confirmationCode,
    'crypto': {
      'algorithm': 'P-256-HKDF-SHA256-AES-256-GCM',
      'hkdf_salt': 'pairing_id_utf8',
      'hkdf_info': 'tetotv-setup-v1',
      'aad': 'pairing_id_utf8',
    },
  };
}

PhoneSetupKeyMaterial _keyMaterial() => PhoneSetupKeyMaterial(
  privateD: List<int>.filled(32, 1),
  publicX: List<int>.filled(32, 2),
  publicY: List<int>.filled(32, 3),
);

PhoneSetupPairingSession _session() {
  final now = DateTime.now().toUtc();
  return PhoneSetupPairingSession(
    pairingId: 'pairing_1234567890',
    deviceCode: 'd' * 48,
    userCode: 'ABCD-EFGH',
    verificationUri: Uri.parse('https://setup.example/setup'),
    verificationUriComplete: Uri.parse(
      'https://setup.example/setup#code=ABCD-EFGH&key=${_testIdentity.fingerprint}',
    ),
    codeExpiresAt: now.add(const Duration(hours: 24)),
    expiresAt: now.add(const Duration(days: 7)),
    pollInterval: const Duration(seconds: 5),
    keyMaterial: _keyMaterial(),
    deviceKeyFingerprint: _testIdentity.fingerprint,
    confirmationCode: _testIdentity.confirmationCode,
  );
}

String _b64(List<int> value) => base64UrlEncode(value).replaceAll('=', '');

final _testIdentity = _keyIdentity(_keyMaterial());

({String fingerprint, String confirmationCode}) _keyIdentity(
  PhoneSetupKeyMaterial key,
) {
  final bytes = sha256
      .convert(<int>[0x04, ...key.publicX, ...key.publicY])
      .bytes;
  final value =
      (bytes[0] << 24) |
      (bytes[1] << 16) |
      (bytes[2] << 8) |
      bytes[3];
  return (
    fingerprint: _b64(bytes),
    confirmationCode: (value % 1000000).toString().padLeft(6, '0'),
  );
}
