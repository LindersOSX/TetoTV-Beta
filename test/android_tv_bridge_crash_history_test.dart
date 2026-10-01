import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing crash history is not represented as a successful OS scan', () {
    expect(const LocalCrashSummaryHistory.empty().exitHistory, {
      'scan_status': 'unavailable',
    });
    expect(
      LocalCrashSummaryHistory.fromMap({'summaries': <Object>[]}).exitHistory,
      {'scan_status': 'unavailable'},
    );
  });

  test(
    'Android bridge keeps OS exit evidence separate from crash summaries',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      final exitHistory = {
        'schema': 'tetotv-os-exit-history-v1',
        'scan_status': 'scanned',
        'low_memory_kill_report_supported': false,
        'hours': 48,
        'capacity': 12,
        'exits': [
          {
            'occurred_at_ms': 1800000000000,
            'reason': 'signal',
            'reason_code': 2,
            'status': 9,
            'importance': 'foreground',
            'pss_mb': 256,
            'rss_mb': 400,
            'process_role': 'main',
            'reportable_crash': false,
          },
        ],
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getRecentLocalCrashSummaries');
        return {
          'summaries': <Object>[],
          'dropped_outside_window': -1,
          'dropped_for_capacity': 1,
          'exit_history': exitHistory,
        };
      });

      final history = await AndroidTvBridge.instance
          .getRecentLocalCrashSummaries();

      expect(history.summaries, isEmpty);
      expect(history.droppedOutsideWindow, 0);
      expect(history.droppedForCapacity, 1);
      expect(history.exitHistory, exitHistory);
    },
  );

  test(
    'unavailable OS scan does not remove separately persisted Java summary',
    () {
      final history = LocalCrashSummaryHistory.fromMap({
        'summaries': [
          {
            'kind': 'java',
            'message': 'Unhandled exception',
            'occurred_at_ms': 1800000000000,
          },
        ],
        'exit_history': {'scan_status': 'unavailable', 'exits': <Object>[]},
      });

      expect(history.summaries, hasLength(1));
      expect(history.summaries.single['kind'], 'java');
      expect(history.exitHistory['scan_status'], 'unavailable');
    },
  );

  test('malformed OS history does not hide the local crash summary ring', () {
    final history = LocalCrashSummaryHistory.fromMap({
      'summaries': [
        {'kind': 'native', 'occurred_at_ms': 1800000000000},
      ],
      'exit_history': 'not-a-map',
    });

    expect(history.summaries.single['kind'], 'native');
    expect(history.exitHistory, {'scan_status': 'unavailable'});
  });
}
