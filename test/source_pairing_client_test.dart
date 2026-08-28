import 'package:anime_tv/features/marketplace/data/source_pairing_client.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('requires a root public HTTPS broker origin', () {
    for (final value in [
      'http://auth.example.com',
      'https://user:pass@auth.example.com',
      'https://auth.example.com/prefix',
      'https://auth.example.com?token=secret',
    ]) {
      expect(
        () => SourcePairingClient(baseUrl: value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('validates a bounded same-origin source session', () async {
    final dio = _stubDio((options, handler) {
      if (options.path.endsWith('health')) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'status': 'ok',
              'source_pairing': true,
              'source_pairing_version': 2,
            },
          ),
        );
        return;
      }
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 201,
          data: <String, dynamic>{
            'pairing_id': 'pairing_id_1234567890',
            'device_code': _deviceCode,
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://auth.example.com/source-pair',
            'verification_uri_complete':
                'https://auth.example.com/source-pair?code=ABCD-EFGH',
            'expires_at': DateTime.now()
                .add(const Duration(minutes: 10))
                .toUtc()
                .toIso8601String(),
            'interval': 3,
          },
        ),
      );
    });
    final client = SourcePairingClient(
      baseUrl: 'https://auth.example.com',
      dio: dio,
    );

    await client.ensureReady();
    final session = await client.createSession();

    expect(session.userCode, 'ABCD-EFGH');
    expect(session.deviceCode, hasLength(43));
    expect(session.verificationUri.path, '/source-pair');
  });

  test('rejects a legacy broker without completion receipts', () async {
    final dio = _stubDio((options, handler) {
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: <String, dynamic>{'status': 'ok', 'source_pairing': true},
        ),
      );
    });
    final client = SourcePairingClient(
      baseUrl: 'https://auth.example.com',
      dio: dio,
    );

    await expectLater(
      client.ensureReady(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('must be updated'),
        ),
      ),
    );
  });

  test('falls back to the legacy root health route only on 404', () async {
    final paths = <String>[];
    final dio = _stubDio((options, handler) {
      paths.add(options.path);
      if (options.path.endsWith('v1/source-pairings/health')) {
        handler.reject(
          DioException.badResponse(
            statusCode: 404,
            requestOptions: options,
            response: Response<void>(requestOptions: options, statusCode: 404),
          ),
        );
        return;
      }
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: <String, dynamic>{
            'status': 'ok',
            'source_pairing': true,
            'source_pairing_version': 2,
          },
        ),
      );
    });
    final client = SourcePairingClient(
      baseUrl: 'https://auth.example.com',
      dio: dio,
    );

    await client.ensureReady();

    expect(paths, ['v1/source-pairings/health', 'health']);
  });

  test('rejects unknown poll status instead of polling forever', () async {
    final dio = _stubDio((options, handler) {
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: <String, dynamic>{'status': 'surprise'},
        ),
      );
    });
    final client = SourcePairingClient(
      baseUrl: 'https://auth.example.com',
      dio: dio,
    );

    expect(() => client.poll(_session()), throwsA(isA<FormatException>()));
  });

  test('cancel authenticates with the private device code', () async {
    RequestOptions? captured;
    final dio = _stubDio((options, handler) {
      captured = options;
      handler.resolve(Response<void>(requestOptions: options, statusCode: 204));
    });
    final client = SourcePairingClient(
      baseUrl: 'https://auth.example.com',
      dio: dio,
    );
    final session = _session();

    await client.cancel(session);

    expect(captured?.method, 'DELETE');
    expect(
      captured?.path,
      endsWith('v1/source-pairings/pairing_id_1234567890'),
    );
    expect(captured?.headers['Authorization'], 'Pairing ${session.deviceCode}');
  });

  test('acknowledgement sends only bounded persistence counts', () async {
    RequestOptions? captured;
    final dio = _stubDio((options, handler) {
      captured = options;
      handler.resolve(Response<void>(requestOptions: options, statusCode: 204));
    });
    final client = SourcePairingClient(
      baseUrl: 'https://auth.example.com',
      dio: dio,
    );

    await client.acknowledge(
      _session(),
      const SourceImportSummary(
        repositoriesAdded: 1,
        manifestsAdded: 2,
        errors: ['Rejected https://secret.example/manifest.json?token=hidden'],
      ),
    );

    expect(captured?.method, 'POST');
    expect(captured?.path, endsWith('/pairing_id_1234567890/complete'));
    expect(captured?.headers['Authorization'], 'Pairing $_deviceCode');
    expect(captured?.data, {
      'repositories_saved': 1,
      'manifests_saved': 2,
      'rejected_count': 1,
    });
    expect(captured?.data.toString(), isNot(contains('secret.example')));
    expect(captured?.data.toString(), isNot(contains('hidden')));
  });
}

Dio _stubDio(
  void Function(RequestOptions, RequestInterceptorHandler) callback,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://auth.example.com/'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => callback(options, handler),
    ),
  );
  return dio;
}

SourcePairingSession _session() => SourcePairingSession(
  pairingId: 'pairing_id_1234567890',
  deviceCode: _deviceCode,
  userCode: 'ABCD-EFGH',
  verificationUri: Uri.parse('https://auth.example.com/source-pair'),
  verificationUriComplete: Uri.parse(
    'https://auth.example.com/source-pair?code=ABCD-EFGH',
  ),
  expiresAt: DateTime.now().add(const Duration(minutes: 10)),
  pollInterval: const Duration(seconds: 3),
);

final _deviceCode = List<String>.filled(43, 'A').join();
