import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/presentation/diagnostics_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('refresh happens after the delivery outcome has been recorded', (
    tester,
  ) async {
    final recorded = Completer<void>();
    var refreshes = 0;
    await _pump(
      tester,
      onFinished: () => refreshes++,
      sink: (details) =>
          details['outcome'] == 'started' ? Future.value() : recorded.future,
      factory: (token) => ExplicitDiagnosticsReportClient(
        cancelToken: token,
        dio: _dio(
          (options, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 202,
              data: {'status': 'posted', 'incident_id': 'AbCdEfGhIjKlMnOp'},
            ),
          ),
        ),
      ),
    );
    await _confirm(tester);
    expect(find.text('Send to support'), findsOneWidget);
    expect(refreshes, 0);
    recorded.complete();
    await tester.pump();
    expect(refreshes, 1);
  });
  testWidgets('nothing is built or uploaded when confirmation is cancelled', (
    tester,
  ) async {
    var built = 0;
    var clients = 0;
    await _pump(
      tester,
      reportBuilder: () {
        built++;
        return _report();
      },
      factory: (token) {
        clients++;
        return ExplicitDiagnosticsReportClient(cancelToken: token);
      },
    );
    await tester.tap(find.text('Send to support'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(built, 0);
    expect(clients, 0);
  });

  testWidgets('TV can cancel a stalled send with the remote and retry', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    var attempts = 0;
    RequestOptions? request;
    await _pump(
      tester,
      events: events,
      factory: (token) => ExplicitDiagnosticsReportClient(
        cancelToken: token,
        dio: _dio((options, _) {
          attempts++;
          request = options;
        }),
      ),
    );
    await _confirm(tester);
    expect(find.text('Sending… Cancel'), findsOneWidget);
    expect(attempts, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(request!.cancelToken!.isCancelled, isTrue);
    expect(find.text('Send to support'), findsOneWidget);
    expect(find.textContaining('delivery was not confirmed'), findsOneWidget);
    expect(events.last['reason_code'], 'cancelled');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Send to support'));
    await tester.pumpAndSettle();
    expect(find.text('Send diagnostic report?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('timeout clears sending and records only safe bounded context', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    await _pump(
      tester,
      events: events,
      factory: (token) => ExplicitDiagnosticsReportClient(
        cancelToken: token,
        overallTimeout: const Duration(seconds: 2),
        dio: _dio((_, _) {}),
      ),
    );
    await _confirm(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Send to support'), findsOneWidget);
    expect(find.textContaining('no confirmation arrived'), findsOneWidget);
    expect(events.last['reason_code'], 'timeout');
    expect(
      events.last.keys,
      unorderedEquals(['operation', 'outcome', 'elapsed_ms', 'reason_code']),
    );
    final safe = sanitizeDiagnosticContext(
      events.last,
      component: 'diagnostic-share',
    );
    expect(safe, events.last);
    final exported = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.77', code: 410054),
      profile: _profile,
      isTelevision: true,
      diagnostics: {
        'diagnosticEvents': [
          {'component': 'diagnostic-share', 'context': safe},
        ],
      },
      generatedAt: DateTime.utc(2026, 9, 30),
    );
    expect(
      (jsonDecode(exported)['diagnostics']['diagnosticEvents'] as List)
          .single['context']['reason_code'],
      'timeout',
    );
    expect(exported, isNot(contains('private report data')));
  });

  testWidgets('successful receipt shows reference and releases busy state', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    await _pump(
      tester,
      events: events,
      factory: (token) => ExplicitDiagnosticsReportClient(
        cancelToken: token,
        dio: _dio(
          (options, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 202,
              data: {'status': 'posted', 'incident_id': 'AbCdEfGhIjKlMnOp'},
            ),
          ),
        ),
      ),
    );
    await _confirm(tester);
    expect(find.text('Send to support'), findsOneWidget);
    expect(
      find.textContaining('sent. Reference: AbCdEfGhIjKlMnOp'),
      findsOneWidget,
    );
    expect(events.last['outcome'], 'confirmed');
  });

  testWidgets('leaving screen cancels upload without a stale notification', (
    tester,
  ) async {
    RequestOptions? request;
    await _pump(
      tester,
      factory: (token) => ExplicitDiagnosticsReportClient(
        cancelToken: token,
        dio: _dio((options, _) => request = options),
      ),
    );
    await _confirm(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Another page'))),
    );
    await tester.pumpAndSettle();
    expect(request!.cancelToken!.isCancelled, isTrue);
    expect(find.textContaining('Diagnostic report sent'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a blocked diagnostic logger cannot block confirmed delivery', (
    tester,
  ) async {
    final never = Completer<void>();
    await _pump(
      tester,
      sink: (_) => never.future,
      factory: (token) => ExplicitDiagnosticsReportClient(
        cancelToken: token,
        dio: _dio(
          (options, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 202,
              data: {'status': 'posted', 'incident_id': 'AbCdEfGhIjKlMnOp'},
            ),
          ),
        ),
      ),
    );
    await _confirm(tester);
    expect(find.text('Send to support'), findsOneWidget);
    expect(find.textContaining('sent. Reference'), findsOneWidget);
    never.complete();
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required DiagnosticsClientFactory factory,
  ExplicitDiagnosticsReport Function()? reportBuilder,
  List<Map<String, Object?>>? events,
  DiagnosticsShareEventSink? sink,
  VoidCallback? onFinished,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: DiagnosticsSendAction(
            reportBuilder: reportBuilder ?? _report,
            clientFactory: factory,
            eventSink:
                sink ??
                (details) async {
                  events?.add(details);
                },
            onDeliveryFinished: onFinished,
          ),
        ),
      ),
    ),
  );
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text('Send to support'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Send report'));
  await tester.pumpAndSettle();
}

Dio _dio(void Function(RequestOptions, RequestInterceptorHandler) callback) =>
    Dio()..interceptors.add(InterceptorsWrapper(onRequest: callback));

ExplicitDiagnosticsReport _report() => ExplicitDiagnosticsReport(
  eventId: 'diag-AbCdEfGhIjKlMnOpQrStUvWx',
  submittedAt: DateTime.utc(2026, 9, 30),
  appVersion: '2.0.77',
  buildNumber: 410054,
  androidSdk: 36,
  abi: 'arm64-v8a',
  deviceClass: 'tv',
  report: 'private report data',
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
