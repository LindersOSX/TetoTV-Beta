import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mpv = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();

  test('MPV announces automatic source recovery without switching engines', () {
    expect(mpv, contains('showPlayerFailoverNotice('));
    expect(mpv, contains('playerFailoverDestination('));
    expect(mpv, contains('Stream changed manually.'));
    expect(mpv, isNot(contains('VLC player')));
    expect(mpv, isNot(contains('Use VLC')));
    expect(mpv, isNot(contains('Use Media3')));
  });

  test('terminal recovery leaves actionable MPV controls visible', () {
    expect(mpv, contains("label: 'Retry stream'"));
    expect(mpv, contains("label: 'Next stream'"));
    expect(mpv, contains("label: 'Choose stream'"));
    expect(mpv, contains('_playbackError = message'));
  });
}
