import 'dart:io';

import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reporting stays completely dormant until explicit opt in', () async {
    final client = _CrashClient();
    final platform = _CrashPlatform();
    final reporter = AnonymousCrashReporter(client, platform);

    await reporter.record(
      kind: 'flutter',
      error: StateError('should stay local'),
      stack: StackTrace.current,
    );

    expect(client.reports, isEmpty);
    expect(platform.stored, isEmpty);
    expect(platform.enabled, isFalse);
  });

  test('opted-in report is redacted, delivered, and acknowledged', () async {
    const sha256LikeValue =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final client = _CrashClient();
    final platform = _CrashPlatform();
    final reporter = AnonymousCrashReporter(client, platform);
    reporter.setEnabled(true);

    await reporter.record(
      kind: 'flutter',
      error: StateError(
        'failed at https://secret.example/path?token=abc '
        'content://media.documents/document/video%3Aprivate-show.mkv '
        '$sha256LikeValue',
      ),
      stack: StackTrace.fromString(
        'Bearer very-secret-token\n'
        'https://source.example/episode\n'
        '/storage/emulated/0/Private Show Episode 7.mkv\n'
        'at dev.animetv.Player.open(Player.kt:42)',
      ),
    );

    expect(platform.enabled, isTrue);
    expect(client.reports, hasLength(1));
    final report = client.reports.single;
    expect(report.message, contains('[URL]'));
    expect(report.message, contains('[INFO_HASH]'));
    expect(report.message, isNot(contains(sha256LikeValue)));
    expect(report.message, isNot(contains('secret.example')));
    expect(report.message, isNot(contains('private-show')));
    expect(report.message, contains('[URI]'));
    expect(report.stack, contains('Bearer [REDACTED]'));
    expect(report.stack, isNot(contains('source.example')));
    expect(report.stack, isNot(contains('Private Show Episode 7.mkv')));
    expect(report.stack, contains('[PATH]'));
    expect(report.stack, contains('dev.animetv.Player.open(Player.kt:42)'));
    expect(report.toWireJson(), isNot(contains('report_id')));
    expect(report.toWireJson()['event_id'], report.reportId);
    expect(platform.acknowledged, [report.reportId]);
    expect(report.deviceClass, 'tv');
  });

  test('failed delivery remains queued and is retried next launch', () async {
    final platform = _CrashPlatform();
    final failing = _CrashClient(fail: true);
    final first = AnonymousCrashReporter(failing, platform);
    first.setEnabled(true);
    await first.record(
      kind: 'platform',
      error: ArgumentError('boom'),
      stack: StackTrace.current,
    );

    expect(platform.pendingReport, isNotNull);
    expect(platform.acknowledged, isEmpty);

    final succeeding = _CrashClient();
    final second = AnonymousCrashReporter(succeeding, platform);
    second.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(succeeding.reports, hasLength(1));
    expect(platform.pendingReport, isNull);
    expect(platform.acknowledged, hasLength(1));
  });

  test('opting out clears any queued report', () async {
    final platform = _CrashPlatform()
      ..pendingReport = {
        'report_id': 'dart-1',
        'kind': 'flutter',
        'message': 'queued',
        'stack': '',
        'occurred_at': '2026-08-12T12:00:00.000Z',
      };
    final reporter = AnonymousCrashReporter(_CrashClient(), platform);
    reporter.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    reporter.setEnabled(false);
    await Future<void>.delayed(Duration.zero);

    expect(platform.enabled, isFalse);
    expect(platform.pendingReport, isNull);
    expect(platform.clearCalls, greaterThanOrEqualTo(1));
  });

  test(
    'handled errors use the consent gate and redact their details',
    () async {
      final client = _CrashClient();
      final platform = _CrashPlatform();
      final reporter = AnonymousCrashReporter(client, platform);

      await reporter.recordHandled(
        area: AnonymousErrorArea.playback,
        error: StateError('failed at https://private.example/watch?token=abc'),
        stack: StackTrace.fromString('Bearer private-token'),
      );
      expect(client.reports, isEmpty);

      reporter.setEnabled(true);
      await reporter.recordHandled(
        area: AnonymousErrorArea.playback,
        error: StateError('failed at https://private.example/watch?token=abc'),
        stack: StackTrace.fromString('Bearer private-token'),
      );

      expect(client.reports, hasLength(1));
      expect(client.reports.single.kind, 'platform');
      expect(client.reports.single.message, contains('Handled playback error'));
      expect(client.reports.single.message, contains('[URL]'));
      expect(client.reports.single.message, isNot(contains('private.example')));
      expect(client.reports.single.stack, contains('Bearer [REDACTED]'));
    },
  );

  test(
    'expected cancellations, cache misses, and no-results states stay quiet',
    () async {
      final client = _CrashClient();
      final reporter = AnonymousCrashReporter(client, _CrashPlatform());
      reporter.setEnabled(true);
      final errors = <Object>[
        DioException(
          requestOptions: RequestOptions(path: '/cancelled'),
          type: DioExceptionType.cancel,
        ),
        const DebridCacheMissException(DebridService.realDebrid),
        StateError('No results matched these filters.'),
        StateError('authorization_pending'),
        StateError('access_denied'),
      ];

      for (final error in errors) {
        await reporter.recordHandled(
          area: AnonymousErrorArea.applicationState,
          error: error,
          stack: StackTrace.current,
        );
      }

      expect(client.reports, isEmpty);
    },
  );

  test(
    'artwork DNS failures stay local while real network state errors report',
    () async {
      final client = _CrashClient();
      final platform = _CrashPlatform();
      final reporter = AnonymousCrashReporter(client, platform);
      reporter.setEnabled(true);

      await reporter.record(
        kind: 'flutter',
        error: Exception(
          "ClientException with SocketException: Failed host lookup: 's4.anilist.co'",
        ),
      );
      await reporter.recordHandled(
        area: AnonymousErrorArea.applicationState,
        error: Exception(
          "ClientException: Failed host lookup: 'cdn.myanimelist.net'",
        ),
      );
      await reporter.record(
        kind: 'flutter',
        error: HttpException(
          'Connection reset by peer',
          uri: Uri.https('artworks.thetvdb.com', '/logo.png'),
        ),
      );
      await reporter.record(
        kind: 'flutter',
        error: HttpException(
          'Connection reset by peer',
          uri: Uri.https('assets.fanart.tv', '/fanart/logo.png'),
        ),
      );

      expect(client.reports, isEmpty);
      expect(platform.stored, isEmpty);

      await reporter.record(
        kind: 'platform',
        error: Exception(
          "DioException: Failed host lookup: 'graphql.anilist.co'",
        ),
        stack: StackTrace.fromString('CatalogController.refresh'),
      );

      expect(client.reports, hasLength(1));
      expect(client.reports.single.message, contains('Failed host lookup'));
    },
  );

  test(
    'handled reports are deduplicated and capped per rolling window',
    () async {
      final client = _CrashClient();
      final reporter = AnonymousCrashReporter(client, _CrashPlatform());
      reporter.setEnabled(true);
      final stack = StackTrace.fromString('frame one');

      await reporter.recordHandled(
        area: AnonymousErrorArea.catalog,
        error: StateError('duplicate'),
        stack: stack,
      );
      await reporter.recordHandled(
        area: AnonymousErrorArea.catalog,
        error: StateError('duplicate'),
        stack: stack,
      );
      for (var index = 1; index <= 6; index++) {
        await reporter.recordHandled(
          area: AnonymousErrorArea.catalog,
          error: StateError('unique $index'),
          stack: stack,
        );
      }

      // The first report plus five unique reports consume the six-report quota.
      expect(client.reports, hasLength(6));
      expect(
        client.reports.where((report) => report.message.contains('duplicate')),
        hasLength(1),
      );
      expect(client.reports.last.message, contains('unique 5'));
    },
  );

  test(
    'provider observer captures an AsyncError once until recovery',
    () async {
      final captured = <Object>[];
      final observer = AnonymousHandledErrorObserver(
        report: ({required area, required error, stack}) async {
          expect(area, AnonymousErrorArea.applicationState);
          captured.add(error);
        },
      );
      final provider = Provider<int>((ref) => 1);
      final container = ProviderContainer();
      final error = StateError('provider failed');
      final asyncError = AsyncError<int>(error, StackTrace.current);
      addTearDown(container.dispose);

      observer.didUpdateProvider(provider, null, asyncError, container);
      observer.providerDidFail(
        provider,
        error,
        asyncError.stackTrace,
        container,
      );
      expect(captured, [error]);

      observer.didUpdateProvider(
        provider,
        asyncError,
        const AsyncData(1),
        container,
      );
      observer.didUpdateProvider(
        provider,
        const AsyncData(1),
        asyncError,
        container,
      );
      expect(captured, [error, error]);
    },
  );
}

class _CrashClient implements AnonymousCrashReportClient {
  _CrashClient({this.fail = false});

  final bool fail;
  final reports = <AnonymousCrashReport>[];

  @override
  Future<void> send(AnonymousCrashReport report) async {
    reports.add(report);
    if (fail) throw StateError('broker unavailable');
  }
}

class _CrashPlatform implements AnonymousCrashPlatform {
  bool enabled = false;
  int clearCalls = 0;
  final stored = <Map<String, Object?>>[];
  final acknowledged = <String>[];
  Map<String, Object?>? pendingReport;

  @override
  Future<void> acknowledge(String reportId) async {
    acknowledged.add(reportId);
    if (pendingReport?['report_id'] == reportId) pendingReport = null;
  }

  @override
  Future<AppVersionInfo> appVersion() async =>
      const AppVersionInfo(name: '1.2.3', code: 123001);

  @override
  Future<void> clear() async {
    clearCalls += 1;
    pendingReport = null;
  }

  @override
  Future<TvDeviceProfile> deviceProfile() async => const TvDeviceProfile(
    manufacturer: 'Not sent',
    model: 'Not sent',
    sdk: 36,
    abis: ['arm64-v8a'],
    displayModes: [],
    hdrTypes: [],
    codecs: [],
    audioOutputs: [],
  );

  @override
  Future<bool> isTelevision() async => true;

  @override
  Future<Map<String, Object?>?> pending() async => pendingReport;

  @override
  Future<void> setEnabled(bool value) async {
    enabled = value;
  }

  @override
  Future<bool> store(Map<String, Object?> report) async {
    if (!enabled) return false;
    stored.add(report);
    pendingReport = Map<String, Object?>.from(report);
    return true;
  }
}
