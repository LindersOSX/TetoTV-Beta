import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/playback_performance_fixture.dart';

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

  test(
    'performance export keeps technical metrics without granting generic exemptions',
    () {
      final now = DateTime.utc(2026, 9, 4, 18);
      final snapshot = playbackPerformanceFixture(updatedAt: now);
      snapshot['title'] = 'Private title';
      snapshot['metadata'] = {'accountId': 'private-account'};
      final sample =
          (snapshot['samples']! as List).last as Map<String, Object?>;
      sample.addAll({
        'headers': {'Authorization': 'private-token'},
        'decoderName': 'Private media decoder',
        'rawMpv': {'url': 'https://private.example/media'},
        'path': r'C:\Private\media.mkv',
        'availableMetrics': ['private-data'],
      });
      (snapshot['summary']! as Map)['url'] = 'https://private.example/media';
      final text = _performanceReport(now, {
        'diagnosticEvents': [
          {'headers': 'private-generic-headers', 'path': 'private-path'},
        ],
        'playbackPerformanceSchema': 'private-schema',
        'playbackPerformanceWindow': {
          'invalidSnapshotCount': 3,
          'droppedOutsideWindow': 4,
          'droppedForCapacity': 2,
          'path': 'private-path',
        },
        'playbackPerformance': [snapshot],
      });
      final decoded = jsonDecode(text) as Map;
      final diagnostics = decoded['diagnostics'] as Map;
      final result = (diagnostics['playbackPerformance'] as List).single as Map;
      final latest = (result['samples'] as List).last as Map;
      expect(
        diagnostics['playbackPerformanceSchema'],
        playbackPerformanceSchema,
      );
      expect(latest['codec'], 'h264');
      expect(latest['activeHwdec'], 'mediacodec-copy');
      expect(latest['width'], 1920);
      expect(latest['sourceFps'], closeTo(23.976, 0.001));
      expect(latest, isNot(contains('decoderName')));
      expect(result['samples'], hasLength(maximumPlaybackPerformanceSamples));
      expect(result['droppedSamples'], 6);
      expect((result['summary'] as Map)['droppedFramesDelta'], 22);
      expect(text.toLowerCase(), isNot(contains('private')));
      final window = diagnostics['playbackPerformanceWindow'] as Map;
      expect(window['invalidSnapshotCount'], 3);
      expect(window['droppedOutsideWindow'], 4);
      expect(window['droppedForCapacity'], 2);
    },
  );

  test(
    'performance export orders, deduplicates, bounds and declares rejected input',
    () {
      final now = DateTime.utc(2026, 9, 4, 18);
      final older = now.subtract(const Duration(minutes: 1));
      final text = _performanceReport(now, {
        'playbackPerformance': [
          playbackPerformanceFixture(updatedAt: older, attempt: 29),
          for (var attempt = 1; attempt <= 29; attempt++)
            playbackPerformanceFixture(updatedAt: now, attempt: attempt),
          playbackPerformanceFixture(
            updatedAt: now.subtract(const Duration(hours: 49)),
            attempt: 30,
          ),
          playbackPerformanceFixture(
            updatedAt: now.add(const Duration(seconds: 1)),
            attempt: 31,
          ),
          {'sessionId': 'private-malformed'},
        ],
        'playbackPerformanceWindow': {
          'storageUnavailable': true,
          'invalidSnapshotCount': 'private-invalid',
        },
      });
      final decoded = jsonDecode(text) as Map;
      final diagnostics = decoded['diagnostics'] as Map;
      final snapshots = diagnostics['playbackPerformance'] as List;
      final window = diagnostics['playbackPerformanceWindow'] as Map;
      expect(snapshots, hasLength(maximumPersistedPlaybackPerformanceAttempts));
      expect((snapshots.first as Map)['attempt'], 29);
      expect((snapshots.first as Map)['updatedAt'], now.toIso8601String());
      expect((snapshots.last as Map)['attempt'], 6);
      expect(window['ordering'], 'newest-first');
      expect(window['retainedCount'], 24);
      expect(window['droppedForExport'], 9);
      expect(window['storageUnavailable'], true);
      expect(window, isNot(contains('invalidSnapshotCount')));
      final completeness = decoded['reportCompleteness'] as Map;
      expect(completeness['reduced'], true);
      expect((completeness['truncation'] as Map)['droppedListItems'], 9);
      expect(text, isNot(contains('private')));
    },
  );

  test(
    'capacity-sized performance plus 500 real-sized events fits and keeps newest evidence',
    () {
      final now = DateTime.utc(2026, 9, 4, 18);
      final snapshots = [
        for (var attempt = 24; attempt >= 1; attempt--)
          playbackPerformanceFixture(
            updatedAt: now.subtract(Duration(minutes: 24 - attempt)),
            attempt: attempt,
          ),
      ];
      final text = _performanceReport(now, {
        'playbackPerformance': snapshots,
        'diagnosticWindow': {'ordering': 'oldest-first', 'retainedCount': 500},
        'diagnosticEvents': [
          for (var index = 0; index < maximumPersistedDiagnosticEvents; index++)
            {
              'timestamp': now
                  .subtract(Duration(seconds: 500 - index))
                  .toIso8601String(),
              'component': 'player',
              'severity': 'info',
              'message':
                  'Playback diagnostic event $index ${List.filled(100, 'x').join()}',
              'context': {
                'session_id': 'pbs-abcdefghijklmnopqrstuvwx',
                'attempt': index ~/ 24 + 1,
                'phase': 'opening',
                'reason_code': 'video_parameters_available',
                'elapsed_ms': index * 100,
                'source_kind': 'web',
              },
            },
        ],
      });
      final decoded = jsonDecode(text) as Map;
      final diagnostics = decoded['diagnostics'] as Map;
      final performance = diagnostics['playbackPerformance'] as List;
      final events = diagnostics['diagnosticEvents'] as List;
      expect(
        text.length,
        lessThanOrEqualTo(maximumExplicitDiagnosticsCharacters),
      );
      expect(performance, hasLength(24));
      expect(performance.first, snapshots.first);
      expect(performance.last, snapshots.last);
      expect((performance.first as Map)['samples'], hasLength(6));
      expect(
        (events.last as Map)['message'],
        startsWith('Playback diagnostic event 499 '),
      );
      final eventExport = diagnostics['diagnosticEventExport'] as Map;
      expect(eventExport['exportedCount'], events.length);
      expect(eventExport['droppedForExport'], 500 - events.length);
      expect(eventExport['selection'], 'newest-retained-events');
      final completeness = decoded['reportCompleteness'] as Map;
      expect(
        completeness['fullSanitizedCharacters'],
        greaterThan(maximumExplicitDiagnosticsCharacters),
      );
      expect(completeness['reduced'], true);
      expect(events, hasLength(50));
      expect(
        (events.first as Map)['message'],
        startsWith('Playback diagnostic event 450 '),
      );
    },
  );

  test(
    'last-resort export retains full newest performance samples and declares other omissions',
    () {
      final now = DateTime.utc(2026, 9, 4, 18);
      final latest = playbackPerformanceFixture(
        updatedAt: now,
        sampleCount: 30,
      );
      final text = _performanceReport(now, {
        'playbackPerformance': [
          latest,
          for (var attempt = 2; attempt <= 24; attempt++)
            playbackPerformanceFixture(
              updatedAt: now.subtract(Duration(minutes: attempt)),
              attempt: attempt,
            ),
        ],
        'diagnosticEvents': [
          for (var index = 0; index < 500; index++) {'message': 'event-$index'},
        ],
        'unusuallyLargeNestedData': [
          for (var index = 0; index < 50; index++)
            {
              for (var field = 0; field < 20; field++)
                'field-$field': List.filled(1000, 'z').join(),
            },
        ],
      });
      final decoded = jsonDecode(text) as Map;
      final diagnostics = decoded['diagnostics'] as Map;
      final performance = diagnostics['playbackPerformance'] as List;
      expect(
        text.length,
        lessThanOrEqualTo(maximumExplicitDiagnosticsCharacters),
      );
      expect(diagnostics, isNot(contains('unusuallyLargeNestedData')));
      expect(diagnostics, isNot(contains('diagnosticEvents')));
      expect(performance, hasLength(24));
      expect(performance.first, latest);
      expect((performance.first as Map)['samples'], hasLength(6));
      expect((performance.first as Map)['droppedSamples'], 24);
      expect(
        (diagnostics['diagnosticEventExport'] as Map)['droppedForExport'],
        500,
      );
      final completeness = decoded['reportCompleteness'] as Map;
      expect(completeness['reduced'], true);
      expect((completeness['truncation'] as Map)['droppedMapFields'], 3);
    },
  );

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

String _performanceReport(DateTime now, Map<String, Object?> diagnostics) =>
    buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.70', code: 410070),
      profile: _profile,
      isTelevision: true,
      diagnostics: diagnostics,
      generatedAt: now,
    );

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
