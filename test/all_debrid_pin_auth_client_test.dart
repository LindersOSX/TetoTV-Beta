import 'package:anime_tv/features/auth/data/all_debrid_pin_auth_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts and completes the official PIN authorization flow', () async {
    var checks = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final data = options.path == '/v4.1/pin/get'
                ? const <String, dynamic>{
                    'status': 'success',
                    'data': {
                      'pin': 'TETO',
                      'check': 'check-id',
                      'expires_in': 600,
                      'user_url': 'https://alldebrid.com/pin/?pin=TETO',
                    },
                  }
                : <String, dynamic>{
                    'status': 'success',
                    'data': {
                      'activated': ++checks > 1,
                      'expires_in': 590,
                      if (checks > 1) 'apikey': 'approved-api-key',
                    },
                  };
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
    final client = AllDebridPinAuthClient(dio: dio);

    final session = await client.start();
    expect(session.pin, 'TETO');
    expect(session.verificationUrl.scheme, 'https');
    expect(await client.poll(session), isNull);
    expect(await client.poll(session), 'approved-api-key');
  });

  test('rejects a PIN page outside the AllDebrid service', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'status': 'success',
                'data': {
                  'pin': 'TETO',
                  'check': 'check-id',
                  'expires_in': 600,
                  'user_url': 'https://alldebrid.com.attacker.test/pin/',
                },
              },
            ),
          ),
        ),
      );

    expect(
      AllDebridPinAuthClient(dio: dio).start(),
      throwsA(isA<AllDebridException>()),
    );
  });
}
