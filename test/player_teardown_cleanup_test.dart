import 'dart:async';

import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:anime_tv/features/player/application/player_teardown_cleanup.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const budget = Duration(milliseconds: 10);

  for (final stage in const [
    'exit pause',
    'seek drain',
    'skip seek',
    'trickplay',
    'queued stop',
    'checkpoint',
    'preferences',
    'media session',
    'frame rate',
  ]) {
    testWidgets('a hung $stage cannot strand auxiliary teardown', (
      tester,
    ) async {
      final pending = Completer<void>();
      bool? completed;
      final cleanup = runBestEffortPlayerCleanup(
        () => pending.future,
        timeout: budget,
      ).then((value) => completed = value);
      await tester.pump();
      expect(completed, isNull);
      await tester.pump(budget);
      expect(completed, isFalse);

      // The original callback is still observed after the deadline. A late
      // native failure must not become an unhandled Flutter exception.
      pending.completeError(StateError('late auxiliary failure'));
      await tester.pump();
      await cleanup;
      expect(tester.takeException(), isNull);
    });
  }

  test('successful cleanup still waits for its completion', () async {
    final pending = Completer<void>();
    bool? completed;
    final cleanup = runBestEffortPlayerCleanup(
      () => pending.future,
      timeout: const Duration(seconds: 1),
    ).then((value) => completed = value);
    await Future<void>.value();
    expect(completed, isNull);
    pending.complete();
    await cleanup;
    expect(completed, isTrue);
  });

  test('synchronous cleanup errors remain best effort', () async {
    expect(
      await runBestEffortPlayerCleanup(
        () => throw StateError('broken auxiliary callback'),
        timeout: budget,
      ),
      isFalse,
    );
  });

  testWidgets(
    'a host exit bypasses a hung Media3 seek and queued stop without assuming release',
    (tester) async {
      const channel = MethodChannel('dev.tetotv/media3-teardown-test');
      final events = StreamController<dynamic>.broadcast(sync: true);
      final seekGate = Completer<void>();
      final methods = <String>[];
      var allowNativeRelease = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        switch (call.method) {
          case 'create':
            return {'id': 42};
          case 'seek':
            await seekGate.future;
            return null;
          case 'dispose':
            if (!allowNativeRelease) {
              throw PlatformException(code: 'media3_release_pending');
            }
            return {
              'status': 'completed_after_wait',
              'reasonCode': 'media3_release_complete',
              'playbackThreadAlive': false,
            };
          default:
            return null;
        }
      });
      final player = Media3PlatformPlayer(
        channel: channel,
        events: events.stream,
      );
      final release = PlayerReleaseCoordinator();
      try {
        await player.ready;
        final seek = player.seek(const Duration(seconds: 50));
        await tester.pump();
        expect(methods.where((method) => method == 'seek'), hasLength(1));

        Future<void> releasePlayer() async {
          await runBestEffortPlayerCleanup(player.stop, timeout: budget);
          // This must remain authoritative even when the queue is stuck.
          await player.dispose();
        }

        bool? firstResult;
        final first = release.release(releasePlayer).then((value) {
          firstResult = value;
        });
        await tester.pump();
        expect(methods, isNot(contains('dispose')));
        await tester.pump(budget);
        await tester.pump();
        await first;
        expect(methods.where((method) => method == 'stop'), isEmpty);
        expect(methods.where((method) => method == 'dispose'), hasLength(1));
        expect(firstResult, isFalse);
        expect(release.released, isFalse);
        expect(
          player.releaseDiagnostic['reason_code'],
          'media3_release_pending',
        );

        allowNativeRelease = true;
        expect(await release.release(releasePlayer), isTrue);
        expect(release.released, isTrue);
        expect(methods.where((method) => method == 'dispose'), hasLength(2));

        // Resolving the stale seek does not dispatch the queued stop against
        // an already-released decoder.
        seekGate.complete();
        await seek;
        await tester.pump();
        expect(methods.where((method) => method == 'stop'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!seekGate.isCompleted) seekGate.complete();
        allowNativeRelease = true;
        await player.dispose();
        await events.close();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
