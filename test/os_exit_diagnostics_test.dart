import 'dart:convert';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/diagnostics/os_exit_diagnostics.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 23);
  Map<String, Object?> exit(int age, String reason) => {
    'occurred_at_ms': now.millisecondsSinceEpoch - age,
    'reason': reason,
    'reason_code': 2,
    'status': 9,
    'importance': 'foreground',
    'pss_mb': 123,
    'rss_mb': 456,
    'process_role': 'main',
    'reportable_crash': true,
  };

  test(
    'empty unavailable and unsupported scans are not successful empty scans',
    () {
      for (final value in [
        null,
        {},
        {'scan_status': 'unavailable'},
      ]) {
        final safe = sanitizeProcessExitHistory(value, now: now);
        expect(safe['scan_status'], 'unavailable');
        expect(safe['exits'], isEmpty);
        expect(safe['low_memory_kill_report_supported'], isNull);
      }
      final safe = sanitizeProcessExitHistory({
        'scan_status': 'unsupported',
        'low_memory_kill_report_supported': true,
        'exits': [exit(1, 'native_crash')],
      }, now: now);
      expect(safe['scan_status'], 'unsupported');
      expect(safe['exits'], isEmpty);
      final scanned = sanitizeProcessExitHistory({
        'scan_status': 'scanned',
        'exits': [],
      }, now: now);
      expect(scanned['scan_status'], 'scanned');
      expect(scanned['exits'], isEmpty);
    },
  );

  test(
    'memory signals and intentional exits are not reclassified as crashes',
    () {
      final safe = sanitizeProcessExitHistory({
        'scan_status': 'scanned',
        'low_memory_kill_report_supported': false,
        'exits': [
          for (final reason in [
            'low_memory',
            'signal',
            'self_exit',
            'user_requested',
            'java_crash',
            'native_crash',
            'anr',
          ])
            exit(1, reason),
        ],
      }, now: now);
      expect(safe['low_memory_kill_report_supported'], false);
      expect((safe['exits']! as List).map((item) => item['reportable_crash']), [
        false,
        false,
        false,
        false,
        true,
        true,
        true,
      ]);
    },
  );

  test('OS evidence contains only bounded recent fixed fields', () {
    final safe = sanitizeProcessExitHistory({
      'scan_status': 'scanned',
      'description': 'private-user',
      'exits': [
        for (var age = 20; age >= 1; age--)
          {
            ...exit(age, 'private-reason'),
            'pid': 1234,
            'description': 'private-user',
            'trace': 'private-media-url',
            'process_role': 'private-user',
            'importance': 'private-user',
            'reason_code': double.infinity,
            'status': -99999,
            'pss_mb': 999999999,
            'rss_mb': double.nan,
          },
        exit(-1, 'anr'),
        exit(const Duration(hours: 49).inMilliseconds, 'anr'),
        {'occurred_at_ms': double.infinity},
      ],
    }, now: now);
    final records = safe['exits']! as List;
    expect(records, hasLength(12));
    expect(records.first['occurred_at_ms'], now.millisecondsSinceEpoch - 12);
    expect(records.last['occurred_at_ms'], now.millisecondsSinceEpoch - 1);
    expect(records.first['reason'], 'unknown');
    expect(records.first['process_role'], 'other');
    expect(records.first['importance'], 'unknown');
    expect(records.first['reason_code'], 0);
    expect(records.first['status'], -999);
    expect(records.first['pss_mb'], 1048576);
    expect(records.first['rss_mb'], 0);
    expect(records.first['reportable_crash'], false);
    expect(jsonEncode(safe), isNot(contains('private')));
    expect(
      records.first.keys,
      unorderedEquals([
        'occurred_at_ms',
        'reason',
        'reason_code',
        'status',
        'importance',
        'pss_mb',
        'rss_mb',
        'process_role',
        'reportable_crash',
      ]),
    );
  });

  test(
    'explicit diagnostics attaches OS exits separately from crash summaries',
    () {
      final report = attachRecentCrashSummaries(
        {},
        [],
        now: now,
        sourceExitHistory: {
          'scan_status': 'scanned',
          'exits': [exit(1, 'low_memory')],
        },
      );
      expect(report['recentCrashSummaries'], isEmpty);
      final evidence = report['recentProcessExitHistory']! as Map;
      expect((evidence['exits']! as List).single['reason'], 'low_memory');
      expect((evidence['exits']! as List).single['reportable_crash'], false);
    },
  );

  test('shared support report revalidates OS exit fields before export', () {
    final text = buildRedactedDiagnosticsText(
      version: const AppVersionInfo(name: '2.0.77', code: 410054),
      profile: const TvDeviceProfile(
        manufacturer: 'Amazon',
        model: 'AFTKRT',
        sdk: 30,
        abis: ['armeabi-v7a'],
        displayModes: [],
        hdrTypes: [],
        codecs: [],
        audioOutputs: [],
      ),
      isTelevision: true,
      diagnostics: {
        'recentProcessExitHistory': {
          'scan_status': 'scanned',
          'description': 'private-process-data',
          'exits': [
            {
              ...exit(1, 'signal'),
              'description': 'private-process-data',
              'pid': 1234,
              'trace': 'private-media-data',
            },
          ],
        },
      },
      generatedAt: now,
    );
    final payload = jsonDecode(text) as Map;
    final evidence = payload['diagnostics']['recentProcessExitHistory'] as Map;
    final record = (evidence['exits'] as List).single as Map;
    expect(evidence['scan_status'], 'scanned');
    expect(record['reason'], 'signal');
    expect(record['reportable_crash'], false);
    expect(text, isNot(contains('private-process-data')));
    expect(text, isNot(contains('private-media-data')));
    expect(record, isNot(contains('pid')));
    expect(record, isNot(contains('trace')));
  });
}
