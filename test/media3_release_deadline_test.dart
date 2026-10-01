import 'dart:async';

import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const acknowledgementBudget = Duration(seconds: 6);

  testWidgets(
    'a missing create acknowledgement blocks release but a later explicit retry can finish',
    (tester) async {
      final creation = Completer<Object?>();
      final fixture = _ReleaseFixture((call) async {
        if (call.method == 'create') return creation.future;
        return null;
      });
      final coordinator = PlayerReleaseCoordinator();
      try {
        final first = coordinator.release(fixture.player.dispose);
        await tester.pump();
        await tester.pump(acknowledgementBudget);
        await tester.pump();
        expect(await first, isFalse);
        expect(coordinator.released, isFalse);
        expect(coordinator.lastFailure, isA<TimeoutException>());
        expect(fixture.disposeCalls, 0);
        expect(fixture.player.releaseDiagnostic, {
          'stage': 'release_waiting',
          'status': 'failed',
          'reason_code': 'timeout',
          'timeout_ms': 6000,
        });
        await expectLater(fixture.player.play(), throwsStateError);

        creation.complete({'id': 42});
        await tester.pump();
        await fixture.player.ready;
        // Merely obtaining a late ID is not a native-release acknowledgement.
        expect(coordinator.released, isFalse);
        expect(fixture.disposeCalls, 0);
        expect(await coordinator.release(fixture.player.dispose), isTrue);
        expect(fixture.disposeCalls, 1);
      } finally {
        if (!creation.isCompleted) creation.complete({'id': 42});
        await fixture.close();
      }
    },
  );

  testWidgets(
    'lost and late dispose acknowledgements never bypass native release confirmation',
    (tester) async {
      final lostReply = Completer<Object?>();
      final retryReply = Completer<Object?>();
      var attempts = 0;
      final fixture = _ReleaseFixture((call) async {
        if (call.method == 'create') return {'id': 42};
        if (call.method != 'dispose') return null;
        switch (++attempts) {
          case 1:
            return lostReply.future;
          case 2:
            return retryReply.future;
          default:
            return {
              'status': 'completed_after_wait',
              'reasonCode': 'media3_release_complete',
              'playbackThreadAlive': false,
            };
        }
      });
      final coordinator = PlayerReleaseCoordinator();
      try {
        await fixture.player.ready;
        final first = coordinator.release(fixture.player.dispose);
        final duplicate = coordinator.release(fixture.player.dispose);
        await tester.pump();
        expect(fixture.disposeCalls, 1);
        await tester.pump(acknowledgementBudget);
        await tester.pump();
        expect(await first, isFalse);
        expect(await duplicate, isFalse);
        expect(coordinator.released, isFalse);
        expect(coordinator.lastFailure, isA<TimeoutException>());
        expect(
          fixture.player.releaseDiagnostic.containsKey('playback_thread_alive'),
          isFalse,
          reason: 'A missing reply means thread state is unknown, not false.',
        );

        final retry = coordinator.release(fixture.player.dispose);
        final concurrentDispose = fixture.player.dispose();
        final anotherDispose = fixture.player.dispose();
        expect(concurrentDispose, same(anotherDispose));
        final observedConcurrent = expectLater(
          concurrentDispose,
          throwsA(isA<PlatformException>()),
        );
        await tester.pump();
        expect(fixture.disposeCalls, 2);
        lostReply.complete({
          'status': 'completed',
          'playbackThreadAlive': false,
        });
        await tester.pump();
        expect(coordinator.released, isFalse);
        expect(fixture.player.releaseDiagnostic['reason_code'], 'timeout');

        retryReply.completeError(
          PlatformException(
            code: 'media3_release_pending',
            details: {'playbackThreadAlive': true},
          ),
        );
        await tester.pump();
        expect(await retry, isFalse);
        await observedConcurrent;
        expect(coordinator.released, isFalse);
        expect(
          fixture.player.releaseDiagnostic['playback_thread_alive'],
          isTrue,
        );

        expect(await coordinator.release(fixture.player.dispose), isTrue);
        expect(coordinator.released, isTrue);
        await fixture.player.dispose();
        expect(fixture.disposeCalls, 3);
      } finally {
        if (!lostReply.isCompleted) lostReply.complete(null);
        if (!retryReply.isCompleted) retryReply.complete(null);
        await fixture.close();
      }
    },
  );

  test(
    'a paused Dart subscriber cannot strand a confirmed native release or repeat cleanup',
    () async {
      final fixture = _ReleaseFixture((call) async {
        if (call.method == 'create') return {'id': 42};
        return null;
      });
      final subscription = fixture.player.stream.position.listen((_) {});
      subscription.pause();
      var releaseCallbacks = 0;
      fixture.player.release.add(() async => releaseCallbacks++);
      final coordinator = PlayerReleaseCoordinator();
      try {
        await fixture.player.ready;
        bool? result;
        final release = coordinator.release(fixture.player.dispose).then((
          value,
        ) {
          result = value;
        });
        await Future<void>.delayed(Duration.zero);
        expect(fixture.disposeCalls, 1);
        expect(result, isNull);
        expect(releaseCallbacks, 0);
        await release.timeout(const Duration(seconds: 2));
        expect(result, isTrue);
        expect(coordinator.released, isTrue);
        await fixture.player.dispose();
        expect(fixture.disposeCalls, 1);

        subscription.resume();
        await Future<void>.delayed(Duration.zero);
        expect(releaseCallbacks, 1);
        await fixture.player.dispose();
        expect(releaseCallbacks, 1);
      } finally {
        await subscription.cancel();
        await fixture.close();
      }
    },
  );

  testWidgets('a late native failure is observed after its reply deadline', (
    tester,
  ) async {
    final reply = Completer<Object?>();
    var attempts = 0;
    final fixture = _ReleaseFixture((call) async {
      if (call.method == 'create') return {'id': 42};
      if (call.method == 'dispose' && ++attempts == 1) return reply.future;
      return null;
    });
    try {
      await fixture.player.ready;
      final result = expectLater(
        fixture.player.dispose(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump();
      await tester.pump(acknowledgementBudget);
      await tester.pump();
      await result;
      reply.completeError(PlatformException(code: 'media3_release_pending'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(fixture.player.releaseDiagnostic['reason_code'], 'timeout');
      await fixture.player.dispose();
      expect(fixture.disposeCalls, 2);
    } finally {
      if (!reply.isCompleted) reply.complete(null);
      await fixture.close();
    }
  });
}

class _ReleaseFixture {
  _ReleaseFixture(Future<Object?> Function(MethodCall) onCall) {
    _messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'dispose') disposeCalls++;
      return onCall(call);
    });
    player = Media3PlatformPlayer(channel: _channel, events: _events.stream);
  }

  static const _channel = MethodChannel(
    'dev.tetotv/media3-release-deadline-test',
  );
  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final _events = StreamController<dynamic>.broadcast(sync: true);
  late final Media3PlatformPlayer player;
  int disposeCalls = 0;

  Future<void> close() async {
    await player.dispose();
    await _events.close();
    _messenger.setMockMethodCallHandler(_channel, null);
  }
}
