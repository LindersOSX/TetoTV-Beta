import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit report is per-share, bounded, and redacted', () {
    const token =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final report = ExplicitDiagnosticsReport.fromSnapshot(
      version: const AppVersionInfo(name: '2.0.9', code: 410001),
      profile: _profile,
      isTelevision: true,
      diagnostics: {
        'diagnosticEvents': [
          {
            'message':
                'Failed https://private.example/watch?token=secret $token',
            'details_json': 'Bearer private-token',
          },
        ],
      },
      submittedAt: DateTime.utc(2026, 8, 16, 12),
      random: Random(7),
    );

    expect(report.eventId, startsWith('diag-'));
    expect(report.eventId, hasLength(greaterThanOrEqualTo(32)));
    expect(
      report.report.length,
      lessThanOrEqualTo(maximumExplicitDiagnosticsCharacters),
    );
    expect(report.report, contains('[URL]'));
    expect(report.report, contains('[INFO_HASH]'));
    expect(report.report, contains('Bearer [REDACTED]'));
    expect(report.report, isNot(contains('private.example')));
    expect(report.report, isNot(contains(token)));
    expect(report.toWireJson(), isNot(contains('account_id')));
    expect(report.toWireJson()['device_class'], 'tv');
  });

  test('retains the complete bounded event ring and redacts keyed PII', () {
    final diagnostics = <String, Object?>{
      'account_id': 123456789,
      'username': 'private-user',
      'diagnosticEvents': [
        for (var index = 0; index < 100; index++)
          {
            'category': 'playback',
            'message':
                'failure $index user@example.com from 192.168.1.20 ${List.filled(600, 'x').join()}',
            'details_json':
                'bounded detail $index ${List.filled(1200, 'y').join()}',
          },
      ],
    };

    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.11', code: 410002),
      profile: _profile,
      isTelevision: true,
      diagnostics: diagnostics,
      generatedAt: DateTime.utc(2026, 8, 20),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final safeDiagnostics = decoded['diagnostics'] as Map<String, dynamic>;

    expect(text.length, greaterThan(10000));
    expect(
      text.length,
      lessThanOrEqualTo(maximumExplicitDiagnosticsCharacters),
    );
    expect(safeDiagnostics['diagnosticEvents'], hasLength(100));
    expect(safeDiagnostics['account_id'], '[REDACTED]');
    expect(safeDiagnostics['username'], '[REDACTED]');
    expect(text, isNot(contains('private-user')));
    expect(text, isNot(contains('user@example.com')));
    expect(text, isNot(contains('192.168.1.20')));
    expect(text, contains('[EMAIL]'));
    expect(text, contains('[NETWORK ADDRESS]'));
  });

  test('redacts camelCase, compact sensitive keys, and IPv6 addresses', () {
    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.11', code: 410002),
      profile: _profile,
      isTelevision: true,
      diagnostics: const {
        'accessToken': 'access-secret-value',
        'refreshtoken': 'refresh-secret-value',
        'clientSecret': 'client-secret-value',
        'apikey': 'api-secret-value',
        'deviceId': 'device-private-value',
        'streamUrl': 'stream-private-value',
        'roomCode': '23456789',
        'roomCapability': 'watch-secret',
        'anilistMediaId': 998877,
        'displayName': 'Private Viewer',
        'avatarUrl': 'avatar-private-value',
        'mediaBytes': [1, 2, 3],
        'networkFailure': 'peer 2001:db8:85a3::8a2e:370:7334 refused',
      },
      generatedAt: DateTime.utc(2026, 8, 20),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final diagnostics = decoded['diagnostics'] as Map<String, dynamic>;

    for (final key in const [
      'accessToken',
      'refreshtoken',
      'clientSecret',
      'apikey',
      'deviceId',
      'streamUrl',
      'roomCode',
      'roomCapability',
      'anilistMediaId',
      'displayName',
      'avatarUrl',
      'mediaBytes',
    ]) {
      expect(diagnostics[key], '[REDACTED]', reason: key);
    }
    expect(text, isNot(contains('2001:db8:85a3::8a2e:370:7334')));
    expect(text, contains('[NETWORK ADDRESS]'));
  });

  test('removes audio product names but keeps technical capabilities', () {
    const privateAudioName = "Alice's Living Room Speaker";
    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.16', code: 410001),
      profile: const TvDeviceProfile(
        manufacturer: 'Example',
        model: 'TV',
        sdk: 36,
        abis: ['arm64-v8a'],
        displayModes: [],
        hdrTypes: [],
        codecs: [],
        audioOutputs: [
          {
            'type': 8,
            'name': privateAudioName,
            'channels': [2, 6],
            'sampleRates': [48000],
            'encodings': [2, 5],
            'hdmi': true,
          },
        ],
      ),
      isTelevision: true,
      diagnostics: const {},
      generatedAt: DateTime.utc(2026, 8, 22),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final device = decoded['deviceCapabilities'] as Map<String, dynamic>;
    final audio = (device['audioOutputs'] as List).single as Map;

    expect(text, isNot(contains(privateAudioName)));
    expect(audio, isNot(contains('name')));
    expect(audio['type'], 8);
    expect(audio['channels'], [2, 6]);
    expect(audio['sampleRates'], [48000]);
    expect(audio['encodings'], [2, 5]);
    expect(audio['hdmi'], isTrue);
  });

  test('redacts standalone room codes, signed paths, cookies, and hashes', () {
    const base32Hash = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.16', code: 410001),
      profile: _profile,
      isTelevision: true,
      diagnostics: const {
        'message':
            'join 23456789 //cdn.example/video?X-Amz-Signature=private '
            'edge.example/file?sig=private root.example?signature=root-private '
            '"Cookie":"session=private-cookie"\n'
            '"display_name":"Quoted Viewer"\n'
            'Basic private-basic $base32Hash 01:23:45:67:89:ab '
            'fe80::1%private-zone',
        'member': 'Private Viewer',
        'episode': 'Private local episode',
        'host': 'private-nas.home',
      },
      generatedAt: DateTime.utc(2026, 8, 22),
    );

    for (final privateValue in const [
      '23456789',
      'cdn.example',
      'edge.example',
      'root.example',
      'root-private',
      'private-cookie',
      'Quoted Viewer',
      'private-basic',
      base32Hash,
      '01:23:45:67:89:ab',
      'private-zone',
      'Private Viewer',
      'Private local episode',
      'private-nas.home',
    ]) {
      expect(text, isNot(contains(privateValue)), reason: privateValue);
    }
    expect(text, contains('[ROOM CODE]'));
    expect(text, contains('[URL]'));
    expect(text, contains('[INFO_HASH]'));
    expect(text, contains('[NETWORK ADDRESS]'));
  });

  test('oversized capability data is reduced as valid declared JSON', () {
    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.11', code: 410002),
      profile: _profile,
      isTelevision: true,
      diagnostics: {
        'unusuallyLargeList': [
          for (var index = 0; index < 300; index++)
            'entry-$index ${List.filled(4000, 'z').join()}',
        ],
      },
      generatedAt: DateTime.utc(2026, 8, 20),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;

    expect(
      text.length,
      lessThanOrEqualTo(maximumExplicitDiagnosticsCharacters),
    );
    expect(
      (decoded['reportCompleteness'] as Map<String, dynamic>)['reduced'],
      isTrue,
    );
    expect(
      (decoded['diagnostics'] as Map<String, dynamic>)['unusuallyLargeList'],
      hasLength(50),
    );
    final completeness = decoded['reportCompleteness'] as Map<String, dynamic>;
    final truncation = completeness['truncation'] as Map<String, dynamic>;
    expect(truncation['truncatedLists'], greaterThanOrEqualTo(1));
    expect(truncation['droppedListItems'], greaterThanOrEqualTo(250));
    expect(completeness['fullSanitizedCharacters'], greaterThan(480000));
  });

  test('normal reports declare zero truncation counts', () {
    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.16', code: 410001),
      profile: _profile,
      isTelevision: true,
      diagnostics: const {'message': 'bounded'},
      generatedAt: DateTime.utc(2026, 8, 22),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final completeness = decoded['reportCompleteness'] as Map<String, dynamic>;
    final truncation = completeness['truncation'] as Map<String, dynamic>;
    expect(completeness['reduced'], isFalse);
    expect(truncation.values, everyElement(0));
  });

  test('local crash history bridge metadata is bounded and typed', () {
    final history = LocalCrashSummaryHistory.fromMap({
      'summaries': [
        {'kind': 'native', 'message': 'safe'},
      ],
      'dropped_outside_window': 4,
      'dropped_for_capacity': 3,
    });

    expect(history.summaries, hasLength(1));
    expect(history.droppedOutsideWindow, 4);
    expect(history.droppedForCapacity, 3);
  });

  test('client accepts only a root HTTPS receiver origin', () {
    for (final value in [
      'http://tetotv-bot.wisp.uno',
      'https://user:pass@tetotv-bot.wisp.uno',
      'https://tetotv-bot.wisp.uno/prefix',
      'https://tetotv-bot.wisp.uno?token=secret',
    ]) {
      expect(
        () => ExplicitDiagnosticsReportClient(baseUrl: value),
        throwsA(isA<DiagnosticsShareException>()),
        reason: value,
      );
    }
  });

  test(
    'transient failure retries the same report and requires a valid ack',
    () async {
      var attempts = 0;
      final payloads = <Object?>[];
      final delays = <Duration>[];
      final dio = _stubDio((options, handler) {
        attempts++;
        payloads.add(options.data);
        expect(
          options.uri.toString(),
          'https://tetotv-bot.wisp.uno/v1/diagnostic-reports',
        );
        handler.resolve(
          Response<Object?>(
            requestOptions: options,
            statusCode: attempts == 1 ? 503 : 202,
            data: attempts == 1
                ? {'error': 'diagnostic_channel_unavailable'}
                : {'status': 'posted', 'incident_id': 'AbCdEfGhIjKlMnOp'},
          ),
        );
      });
      final client = ExplicitDiagnosticsReportClient(
        dio: dio,
        baseUrl: 'https://tetotv-bot.wisp.uno',
        retryDelay: (duration) async => delays.add(duration),
      );
      final report = _report();

      final acknowledgement = await client.send(report);

      expect(acknowledgement.reference, 'AbCdEfGhIjKlMnOp');
      expect(acknowledgement.duplicate, isFalse);
      expect(attempts, 2);
      expect(payloads[0], equals(payloads[1]));
      expect(delays, [const Duration(milliseconds: 350)]);
    },
  );

  test(
    'rate-limit response is actionable and is not retried immediately',
    () async {
      var attempts = 0;
      final dio = _stubDio((options, handler) {
        attempts++;
        handler.resolve(
          Response<Object?>(
            requestOptions: options,
            statusCode: 429,
            data: {'error': 'rate_limited'},
          ),
        );
      });
      final client = ExplicitDiagnosticsReportClient(
        dio: dio,
        baseUrl: 'https://tetotv-bot.wisp.uno',
        retryDelay: (_) async {},
      );

      await expectLater(
        client.send(_report()),
        throwsA(
          isA<DiagnosticsShareException>().having(
            (error) => error.message,
            'message',
            contains('Wait one minute'),
          ),
        ),
      );
      expect(attempts, 1);
    },
  );
}

Dio _stubDio(
  void Function(RequestOptions, RequestInterceptorHandler) callback,
) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => callback(options, handler),
    ),
  );
  return dio;
}

ExplicitDiagnosticsReport _report() => ExplicitDiagnosticsReport(
  eventId: 'diag-AbCdEfGhIjKlMnOpQrStUvWx',
  submittedAt: DateTime.utc(2026, 8, 16, 12),
  appVersion: '2.0.9',
  buildNumber: 410001,
  androidSdk: 36,
  abi: 'arm64-v8a',
  deviceClass: 'tv',
  report: 'Redacted diagnostic report',
);

const _profile = TvDeviceProfile(
  manufacturer: 'Example',
  model: 'TV',
  sdk: 36,
  abis: ['arm64-v8a'],
  displayModes: [],
  hdrTypes: [],
  codecs: [],
  audioOutputs: [],
);
