import 'dart:async';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/core/telemetry/anonymous_usage_reporter.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUsageClient implements AnonymousUsageClient {
  final events = <String>[];
  Completer<AnonymousUsageSession>? createGate;
  bool failNextHeartbeatUnauthorized = false;

  @override
  Future<AnonymousUsageSession> createSession(AnonymousUsageState state) async {
    events.add('create:${state.name}');
    final gate = createGate;
    if (gate != null) return gate.future;
    return const AnonymousUsageSession(
      token: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      heartbeatInterval: Duration(seconds: 45),
    );
  }

  @override
  Future<void> heartbeat(String token, AnonymousUsageState state) async {
    events.add('heartbeat:${state.name}');
    if (failNextHeartbeatUnauthorized) {
      failNextHeartbeatUnauthorized = false;
      throw DioException.badResponse(
        statusCode: 401,
        requestOptions: RequestOptions(
          path: '/v1/app-presence/sessions/current',
        ),
        response: Response<void>(
          requestOptions: RequestOptions(
            path: '/v1/app-presence/sessions/current',
          ),
          statusCode: 401,
        ),
      );
    }
  }

  @override
  Future<void> closeSession(String token) async {
    events.add('close');
  }
}

Future<void> _flushReporter() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses only the fixed first-party Wispbyte presence origin', () {
    expect(AppConfig.anonymousPresenceBaseUrl, 'https://tetotv-bot.wisp.uno');
    expect(
      validatedAnonymousPresenceOrigin(),
      AppConfig.anonymousPresenceBaseUrl,
    );
  });

  test('installed Beta gating excludes Public and debug builds', () {
    expect(
      anonymousUsageEnabledForInstalledVersion(
        '2.0.24+410001',
        isDebugBuild: false,
      ),
      isTrue,
    );
    expect(
      anonymousUsageEnabledForInstalledVersion(
        '1.0.4+410001',
        isDebugBuild: false,
      ),
      isFalse,
    );
    expect(
      anonymousUsageEnabledForInstalledVersion(
        '2.0.24+410001',
        isDebugBuild: true,
      ),
      isFalse,
    );
    expect(
      anonymousUsageEnabledForInstalledVersion('unknown', isDebugBuild: false),
      isFalse,
    );
  });

  test('fresh setup fails closed until the privacy step is completed', () {
    expect(
      anonymousUsageConsentReady(
        preferencesLoaded: true,
        enabled: true,
        setupLoaded: true,
        setupCompleted: false,
      ),
      isFalse,
    );
    expect(
      anonymousUsageConsentReady(
        preferencesLoaded: true,
        enabled: true,
        setupLoaded: true,
        setupCompleted: true,
      ),
      isTrue,
    );
    expect(
      anonymousUsageConsentReady(
        preferencesLoaded: false,
        enabled: true,
        setupLoaded: true,
        setupCompleted: true,
      ),
      isFalse,
    );
    expect(
      anonymousUsageConsentReady(
        preferencesLoaded: true,
        enabled: true,
        setupLoaded: false,
        setupCompleted: false,
      ),
      isFalse,
    );
  });

  test(
    'reports only active/streaming and reference-counts MPV owners',
    () async {
      final client = _FakeUsageClient();
      final reporter = AnonymousUsageReporter(client, observeLifecycle: false);
      addTearDown(reporter.dispose);

      reporter.setConsent(true);
      await _flushReporter();
      expect(
        client.events,
        isEmpty,
        reason: 'build eligibility must fail closed',
      );

      reporter.setBuildEligible(true);
      await _flushReporter();
      expect(client.events, ['create:active']);

      final firstPlayer = Object();
      final nextPlayer = Object();
      reporter.beginStreaming(firstPlayer);
      await _flushReporter();
      reporter.beginStreaming(nextPlayer);
      await _flushReporter();
      reporter.endStreaming(firstPlayer);
      await _flushReporter();
      reporter.endStreaming(nextPlayer);
      await _flushReporter();

      expect(client.events, [
        'create:active',
        'heartbeat:streaming',
        'heartbeat:streaming',
        'heartbeat:streaming',
        'heartbeat:active',
      ]);
      expect(client.events.join(' '), isNot(contains('title')));
      reporter.setConsent(false);
      await _flushReporter();
      expect(client.events.last, 'close');
    },
  );

  test(
    'keeps streaming alive while backgrounded and closes when idle',
    () async {
      final client = _FakeUsageClient();
      final reporter = AnonymousUsageReporter(client, observeLifecycle: false);
      addTearDown(reporter.dispose);
      reporter.setConsent(true);
      reporter.setBuildEligible(true);
      await _flushReporter();
      final player = Object();
      reporter.beginStreaming(player);
      await _flushReporter();

      reporter.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _flushReporter();
      expect(client.events.last, 'heartbeat:streaming');
      reporter.endStreaming(player);
      await _flushReporter();
      expect(client.events.last, 'close');
    },
  );

  test('closes a capability issued after consent is withdrawn', () async {
    final client = _FakeUsageClient();
    final gate = Completer<AnonymousUsageSession>();
    client.createGate = gate;
    final reporter = AnonymousUsageReporter(client, observeLifecycle: false);
    addTearDown(reporter.dispose);
    reporter.setConsent(true);
    reporter.setBuildEligible(true);
    await _flushReporter();
    expect(client.events, ['create:active']);

    reporter.setConsent(false);
    gate.complete(
      const AnonymousUsageSession(
        token: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        heartbeatInterval: Duration(seconds: 45),
      ),
    );
    await _flushReporter();
    expect(client.events, ['create:active', 'close']);
  });

  test('renews an expired server capability immediately', () async {
    final client = _FakeUsageClient();
    final reporter = AnonymousUsageReporter(client, observeLifecycle: false);
    addTearDown(reporter.dispose);
    reporter.setConsent(true);
    reporter.setBuildEligible(true);
    await _flushReporter();
    client.failNextHeartbeatUnauthorized = true;

    reporter.beginStreaming(Object());
    await _flushReporter();
    await _flushReporter();

    expect(client.events, [
      'create:active',
      'heartbeat:streaming',
      'create:streaming',
    ]);
  });
}
