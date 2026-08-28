import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skip markers remain available to hosts with a hidden HUD', () {
    expect(playerCanUseSkipMarkers(guestControlsLocked: false), isTrue);
  });

  test('Watch Party guests cannot issue a local marker skip', () {
    expect(playerCanUseSkipMarkers(guestControlsLocked: true), isFalse);
  });
}
