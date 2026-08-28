import 'dart:async';

import 'package:anime_tv/core/performance/performance_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('throttles slow frames and keeps the worst pending duration', () async {
    final records = <Duration>[];
    final monitor = PerformanceMonitor(
      slowFrameSampleInterval: const Duration(milliseconds: 20),
      recorder: (_, duration) async => records.add(duration),
    );

    monitor.recordSlowFrame(const Duration(milliseconds: 24));
    monitor.recordSlowFrame(const Duration(milliseconds: 31));
    monitor.recordSlowFrame(const Duration(milliseconds: 27));
    await Future<void>.delayed(const Duration(milliseconds: 35));
    await monitor.flush();

    expect(records, const [
      Duration(milliseconds: 24),
      Duration(milliseconds: 31),
    ]);
  });

  test('serializes performance database writes', () async {
    final firstWrite = Completer<void>();
    final started = <Duration>[];
    final monitor = PerformanceMonitor(
      slowFrameSampleInterval: Duration.zero,
      recorder: (_, duration) {
        started.add(duration);
        return started.length == 1 ? firstWrite.future : Future.value();
      },
    );

    monitor.recordSlowFrame(const Duration(milliseconds: 21));
    monitor.recordSlowFrame(const Duration(milliseconds: 22));
    await Future<void>.delayed(Duration.zero);
    expect(started, const [Duration(milliseconds: 21)]);

    firstWrite.complete();
    await monitor.flush();
    expect(started, const [
      Duration(milliseconds: 21),
      Duration(milliseconds: 22),
    ]);
  });
}
