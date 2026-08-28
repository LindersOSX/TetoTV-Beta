import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final player = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();
  final chrome = File(
    'lib/features/player/presentation/teto_player_chrome.dart',
  ).readAsStringSync();

  test('the player router has one MPV destination', () {
    expect(player, contains('return MpvTvPlayerScreen('));
    expect(player, isNot(contains('NativeMedia3PlayerScreen(')));
    expect(player, isNot(contains('VlcTvPlayerScreen(')));
    expect(player, isNot(contains('showPlayerEnginePicker(')));
    expect(player, isNot(contains('onSelectEngine')));
  });

  test('MPV owns the shared TV HUD without a player switch control', () {
    expect(player, contains("engineKey: 'mpv'"));
    expect(player, contains('TetoPlayerChrome('));
    expect(chrome, isNot(contains('onFixVideo')));
    expect(chrome, isNot(contains("label: 'Player'")));
    expect(chrome, contains("label: 'Watch Party'"));
    expect(chrome, contains("label: 'Playback Speed'"));
    expect(chrome, isNot(contains("label: 'Size'")));
    expect(chrome, contains('watchingCount'));
    expect(player, contains('preferences.showWatchTogether'));
    expect(player, contains('_resetPlaybackRateForWatchParty'));
    expect(player, contains('playbackSpeed: playbackRate'));
  });

  test('MPV HUD exposes the existing safe next-episode handoff', () {
    expect(chrome, contains('icon: Icons.skip_previous_rounded'));
    expect(chrome, contains("label: 'Previous Episode'"));
    expect(
      RegExp(r'icon: Icons\.forward_rounded,').allMatches(chrome).length,
      greaterThanOrEqualTo(2),
    );
    expect(chrome, contains('mirrorIconHorizontally: true'));
    expect(chrome, contains('icon: Icons.skip_next_rounded'));
    expect(chrome, contains("label: 'Next Episode'"));
    expect(player, contains('onNextEpisode: _hasNextEpisodeControl'));
    expect(player, contains('unawaited(_playNextEpisode())'));
    expect(player, contains('nextEpisodeEnabled: _nextEpisodeControlEnabled'));
    expect(player, contains('previousEpisodeEnabled:'));
    expect(player, contains('_previousEpisodeControlEnabled'));
    expect(player, contains('unawaited(_playPreviousEpisode())'));
    expect(player, contains('widget.launch.episode.episodeCount'));

    final previous = chrome.indexOf("label: 'Previous Episode'");
    final rewind = chrome.indexOf("label: 'Back ");
    final play = chrome.indexOf("label: widget.isPlaying ? 'Pause' : 'Play'");
    final forward = chrome.indexOf("label: 'Forward ");
    final next = chrome.indexOf("label: 'Next Episode'");
    final speed = chrome.indexOf("label: 'Playback Speed'");
    final audio = chrome.indexOf("label: 'Audio'");
    expect(previous, greaterThanOrEqualTo(0));
    expect(rewind, greaterThan(previous));
    expect(play, greaterThan(rewind));
    expect(forward, greaterThan(play));
    expect(next, greaterThan(forward));
    expect(speed, greaterThan(next));
    expect(audio, greaterThan(speed));
  });

  test('progress interaction holds the HUD idle timer until scrub release', () {
    expect(chrome, contains('onInteractionChanged: onScrubInteractionChanged'));
    expect(player, contains('_controlsTimer?.cancel();'));
    expect(player, contains('if (_progressScrubActive) return;'));
    expect(player, contains('onScrubInteractionChanged:'));
    expect(player, contains('_handleProgressScrubInteraction'));
  });

  test('every HUD interaction and picker suspends idle auto-hide', () {
    expect(chrome, contains('onInteraction?.call();'));
    expect(chrome, contains('event is! KeyRepeatEvent'));
    expect(player, contains('onInteraction: _handlePlayerHudInteraction'));
    expect(player, contains('onInteraction: onInteraction'));
    expect(player, contains('bool get _hudAutoHideSuspended'));
    expect(player, contains('_hudAutoHideHoldCount > 0'));
    expect(
      RegExp('_withHudAutoHideSuspended').allMatches(player).length,
      greaterThanOrEqualTo(9),
    );

    final audioPicker = player.indexOf(
      'Future<void> _openAudioTrackPicker() async',
    );
    final audioTimerCancel = player.indexOf(
      '_controlsTimer?.cancel();',
      audioPicker,
    );
    final audioDiscovery = player.indexOf(
      'waitForStableTrackSnapshot<List<AudioTrack>>',
      audioPicker,
    );
    expect(audioTimerCancel, greaterThan(audioPicker));
    expect(audioTimerCancel, lessThan(audioDiscovery));

    final subtitlePicker = player.indexOf(
      'Future<void> _openSubtitleTrackPicker() async',
    );
    final subtitleTimerCancel = player.indexOf(
      '_controlsTimer?.cancel();',
      subtitlePicker,
    );
    final subtitleDiscovery = player.indexOf(
      'waitForStableTrackSnapshot<List<SubtitleTrack>>',
      subtitlePicker,
    );
    expect(subtitleTimerCancel, greaterThan(subtitlePicker));
    expect(subtitleTimerCancel, lessThan(subtitleDiscovery));
  });

  test('skip actions retain focus priority when the HUD hides', () {
    expect(player, contains('bool get _skipFocusAvailable'));
    expect(player, contains('_skipControlFocus.requestFocus()'));
    expect(player, contains('if (_skipFocusAvailable)'));
  });
}
