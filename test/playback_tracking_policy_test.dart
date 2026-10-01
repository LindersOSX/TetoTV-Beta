import 'dart:io';

import 'package:anime_tv/features/player/application/playback_tracking_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool canStart({
    bool playing = true,
    bool buffering = false,
    bool decodedVideo = true,
    bool opening = false,
    bool closing = false,
    bool provisionalSeek = false,
    Duration position = const Duration(milliseconds: 1),
  }) => playbackCanStartTracking(
    playing: playing,
    buffering: buffering,
    decodedVideo: decodedVideo,
    opening: opening,
    closing: closing,
    provisionalSeek: provisionalSeek,
    position: position,
  );

  test(
    'actual playback can start tracking without duration or a threshold',
    () {
      expect(canStart(), isTrue);
    },
  );

  test('preparing a paused Watch Party stream does not add it to Watching', () {
    expect(
      canStart(playing: false, position: const Duration(minutes: 8)),
      isFalse,
    );
    expect(
      canStart(playing: true, position: const Duration(minutes: 8)),
      isTrue,
    );
  });

  test('failed opens, buffering, missing video, and teardown do not count', () {
    expect(canStart(opening: true), isFalse);
    expect(canStart(buffering: true), isFalse);
    expect(canStart(decodedVideo: false), isFalse);
    expect(canStart(closing: true), isFalse);
    expect(canStart(position: Duration.zero), isFalse);
    expect(canStart(position: const Duration(seconds: -1)), isFalse);
    expect(canStart(provisionalSeek: true), isFalse);
  });

  test('both engines notify the shared once-per-episode start path', () {
    final source = File(
      'lib/features/player/presentation/tv_player_screen.dart',
    ).readAsStringSync();
    for (final start in [
      '_videoParamsSubscription =',
      '_playingSubscription =',
      '_bufferingSubscription =',
      'void _onPosition(',
    ]) {
      final index = source.indexOf(start);
      expect(index, greaterThanOrEqualTo(0));
      expect(
        source.substring(index, index + 1300),
        contains('_maybeSyncWatching();'),
      );
    }
    final gate = source.substring(
      source.indexOf('void _maybeSyncWatching()'),
      source.indexOf('Future<void> _syncWatching()'),
    );
    expect(gate, contains('_watchingHandled'));
    expect(gate, contains('_watchingSyncInFlight'));
    expect(
      gate.indexOf('_watchingSyncInFlight = true'),
      lessThan(gate.indexOf('_syncWatching();')),
    );
    expect(gate, contains('playbackCanStartTracking('));
    expect(gate, contains('_animeFeaturesEnabled'));
    expect(
      source,
      contains('if (opened && attemptIsActive()) _maybeSyncWatching();'),
    );
    expect(source, contains('if (watching != null) await watching;'));
  });
}
