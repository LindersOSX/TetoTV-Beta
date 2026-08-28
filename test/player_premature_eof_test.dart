import 'dart:io';

import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const duration = Duration(minutes: 24);
  final completedAt = DateTime.utc(2026, 8, 27, 12);

  test('early exact-duration network completion requests source failover', () {
    expect(
      shouldFailOverPrematureNetworkCompletion(
        isNetworkStream: true,
        position: duration,
        duration: duration,
        lastPlayablePosition: const Duration(minutes: 7),
        completedAt: completedAt,
      ),
      isTrue,
    );
  });

  test('local exact-duration completion remains a normal completion', () {
    expect(
      shouldFailOverPrematureNetworkCompletion(
        isNetworkStream: false,
        position: duration,
        duration: duration,
        lastPlayablePosition: const Duration(minutes: 7),
        completedAt: completedAt,
      ),
      isFalse,
    );
  });

  test('non-exact terminal positions are not classified as premature EOF', () {
    expect(
      shouldFailOverPrematureNetworkCompletion(
        isNetworkStream: true,
        position: duration - const Duration(milliseconds: 1),
        duration: duration,
        lastPlayablePosition: const Duration(minutes: 7),
        completedAt: completedAt,
      ),
      isFalse,
    );
  });

  test('playback already near the end remains a natural completion', () {
    expect(
      shouldFailOverPrematureNetworkCompletion(
        isNetworkStream: true,
        position: duration,
        duration: duration,
        lastPlayablePosition: duration - const Duration(seconds: 8),
        completedAt: completedAt,
      ),
      isFalse,
    );
  });

  test(
    'recent committed seek to the end remains user-requested completion',
    () {
      expect(
        shouldFailOverPrematureNetworkCompletion(
          isNetworkStream: true,
          position: duration,
          duration: duration,
          lastPlayablePosition: const Duration(minutes: 7),
          completedAt: completedAt,
          lastCommittedEndSeekAt: completedAt.subtract(
            const Duration(seconds: 3),
          ),
          lastCommittedEndSeekTarget: duration - const Duration(seconds: 1),
        ),
        isFalse,
      );
    },
  );

  test('stale end seek no longer excuses an early terminal jump', () {
    expect(
      shouldFailOverPrematureNetworkCompletion(
        isNetworkStream: true,
        position: duration,
        duration: duration,
        lastPlayablePosition: const Duration(minutes: 7),
        completedAt: completedAt,
        lastCommittedEndSeekAt: completedAt.subtract(
          const Duration(seconds: 30),
        ),
        lastCommittedEndSeekTarget: duration,
      ),
      isTrue,
    );
  });

  test(
    'player sends premature completion to fallback at last playable time',
    () {
      final source = File(
        'lib/features/player/presentation/tv_player_screen.dart',
      ).readAsStringSync();

      expect(source, contains('shouldFailOverPrematureNetworkCompletion('));
      expect(source, contains('resumePosition: lastPlayablePosition'));
      expect(
        source,
        contains(
          'The network stream ended unexpectedly before the episode finished.',
        ),
      );
    },
  );

  test('failed seek attempts are never recorded as committed seeks', () {
    final source = File(
      'lib/features/player/presentation/tv_player_screen.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains(
        'await _player.seek(position);\n        _recordCommittedSeek(position);',
      ),
    );
    expect(
      source,
      contains(
        'await _player.seek(target);\n            _recordCommittedSeek(target);',
      ),
    );
    expect(
      source,
      contains(
        'if (!resumeSeekNeedsRetry(resume, _player.state.position)) {\n'
        '        _recordCommittedSeek(resume);',
      ),
    );
  });
}
