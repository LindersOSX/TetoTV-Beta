import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mpv = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();
  final panel = File(
    'lib/features/player/presentation/player_playback_error_panel.dart',
  ).readAsStringSync();

  test('MPV announces automatic source recovery without switching engines', () {
    expect(mpv, contains('showPlayerFailoverNotice('));
    expect(mpv, contains('playerFailoverDestination('));
    expect(mpv, contains('Stream changed manually.'));
    expect(mpv, isNot(contains('VLC player')));
    expect(mpv, isNot(contains('Use VLC')));
    expect(mpv, isNot(contains('Use Media3')));
  });

  test('terminal recovery owns focus and exposes recovery and dismissal', () {
    for (final label in [
      'Retry stream',
      'Next stream',
      'Choose stream',
      'Dismiss',
      'Exit',
    ]) {
      expect(panel, contains("'$label'"));
    }
    expect(mpv, contains('PlayerPlaybackErrorPanel('));
    expect(mpv, contains('onDismiss: _dismissPlaybackError'));
    expect(mpv, contains('onExit: () => unawaited(_confirmExit())'));
    expect(mpv, contains('_playbackError = message'));
    expect(panel, contains('TraversalEdgeBehavior.closedLoop'));
    expect(panel, isNot(contains('BackdropFilter(')));
  });

  test('terminal errors stop watchdogs and repeated native recovery', () {
    final subscription = mpv.substring(
      mpv.indexOf('_errorSubscription = _player.stream.error.listen'),
      mpv.indexOf('_completedSubscription ='),
    );
    expect(subscription, contains('_playbackError != null'));
    final showError = mpv.substring(
      mpv.indexOf('void _showPlaybackError('),
      mpv.indexOf('void _dismissPlaybackError()'),
    );
    for (final guard in [
      '_controlsTimer?.cancel()',
      '_videoWatchdog?.cancel()',
      '_performanceWatchdog?.cancel()',
      '_hiddenHudDpadSeek.cancel()',
      '_controlsVisible = false',
    ]) {
      expect(showError, contains(guard));
    }
    final dismiss = mpv.substring(
      mpv.indexOf('void _dismissPlaybackError()'),
      mpv.indexOf('void _retryNextStreamAfterError()'),
    );
    expect(dismiss, contains('_playbackErrorDismissed = true'));
    expect(dismiss, isNot(contains('_playbackError = null')));
    expect(dismiss, contains('_showControls(focusControls: true)'));
    final keys = mpv.substring(
      mpv.indexOf('KeyEventResult _handleKey(FocusNode node'),
      mpv.indexOf('Future<void> _seekBy('),
    );
    expect(
      keys.indexOf('if (_playbackErrorVisible)'),
      lessThan(keys.indexOf('_hiddenHudDpadSeek.handleKeyEvent')),
    );
    expect(
      mpv,
      contains('excluding: !_controlsVisible || _playbackErrorVisible'),
    );
    expect(
      mpv,
      contains('ignoring: !_controlsVisible || _playbackErrorVisible'),
    );
  });
}
