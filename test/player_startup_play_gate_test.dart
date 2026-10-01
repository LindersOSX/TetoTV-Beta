import 'dart:io';

import 'package:anime_tv/features/player/application/player_startup_play_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new episode confirms play only after its media is ready', () {
    final gate = PlayerStartupPlayGate()..begin(1, play: true);
    expect(gate.take(1, mediaReady: false), isFalse);
    expect(gate.take(1, mediaReady: true), isTrue);
    expect(gate.take(1, mediaReady: true), isFalse);
    gate.begin(2, play: true);
    expect(gate.take(2, mediaReady: true), isTrue);
  });

  test('a deliberate pause cancels the pending confirmation', () {
    final gate = PlayerStartupPlayGate()..begin(1, play: true);
    gate.cancel();
    expect(gate.take(1, mediaReady: true), isFalse);
  });

  test('watch party and paused decoder reopens never request autoplay', () {
    final gate = PlayerStartupPlayGate()..begin(1, play: false);
    expect(gate.take(1, mediaReady: true), isFalse);
    gate.begin(2, play: true);
    gate.begin(3, play: false);
    expect(gate.take(2, mediaReady: true), isFalse);
    expect(gate.take(3, mediaReady: true), isFalse);
  });

  test('a late event from an old file cannot consume the new intent', () {
    final gate = PlayerStartupPlayGate()..begin(1, play: true);
    gate.begin(2, play: true);
    expect(gate.take(1, mediaReady: true), isFalse);
    expect(gate.take(2, mediaReady: true), isTrue);
  });

  final source = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();
  String method(String start, String end) {
    final begin = source.indexOf(start);
    final finish = source.indexOf(end, begin + start.length);
    expect(begin, greaterThanOrEqualTo(0));
    expect(finish, greaterThan(begin));
    return source.substring(begin, finish);
  }

  test('MPV readiness confirms explicit play, never toggles playback', () {
    final confirm = method(
      'Future<void> _confirmMpvStartupPlay()',
      'Future<bool> _openMedia(',
    );
    for (final guard in [
      '_canApplyTrackSelection',
      '_usesMedia3',
      '_watchPartyActive',
      '_performanceInForeground',
      '_confirmingExit',
      '_mediaOpenInProgress',
      'revision != _mediaOpenRevision',
    ]) {
      expect(confirm, contains(guard));
    }
    expect(confirm, contains('_startupPlay.take('));
    expect(confirm, contains('await _player.play()'));
    expect(confirm, isNot(contains('playOrPause')));
    expect(confirm, isNot(contains('Timer')));
    expect(source, contains('unawaited(_confirmMpvStartupPlay())'));
    final open = method(
      'Future<int?> _openCurrentMedia(',
      'Future<void> _confirmMpvStartupPlay()',
    );
    expect(open, contains('play: play && !_usesMedia3'));
    expect(open, contains('await _confirmMpvStartupPlay()'));
  });

  test('user pause, backgrounding, exit and handoff cancel autoplay', () {
    for (final range in [
      ['void _playOrPauseLocal()', 'bool get _skipFocusAvailable'],
      ['void _handleMediaAction(', 'Future<void> _matchContentFrameRate()'],
      ['Future<void> _confirmExit()', 'void dispose()'],
      [
        'Future<bool> _prepareForEngineHandoff(',
        'void _recordPlayerTeardownStage(',
      ],
      [
        'void didChangeAppLifecycleState(',
        'Future<String?> _readPlaybackPerformanceProperty(',
      ],
      [
        'Future<void> _openExternalPlayer()',
        'Future<void> _openAudioTrackPicker()',
      ],
    ]) {
      expect(method(range[0], range[1]), contains('_startupPlay.cancel()'));
    }
    expect(source, contains('if (active) _startupPlay.cancel()'));
    final partyPause = source.substring(
      source.indexOf('pause: () => _trackPlayerMutation('),
      source.indexOf('seekTo: (position) => _trackPlayerMutation('),
    );
    expect(partyPause, contains('_startupPlay.cancel()'));
  });
}
