import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/player/presentation/player_paused_metadata_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps the title fixed and scrolls an overflowing synopsis', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final description = List.filled(
      20,
      'A long episode synopsis continues with another important detail.',
    ).join(' ');
    await tester.pumpWidget(_testApp(visible: true, description: description));
    await tester.pump();

    final title = tester.widget<Text>(
      find.byKey(const ValueKey('player-paused-episode-title')),
    );
    expect(title.data, 'The Choice of Steins Gate');
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);

    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('player-paused-description-scroll')),
    );
    expect(scroll.physics, isA<NeverScrollableScrollPhysics>());
    expect(scroll.controller!.offset, 0);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('player-paused-description-scroll')),
          )
          .height,
      closeTo(70.2, .1),
    );

    await tester.pump(
      playerPausedMetadataScrollDelay - const Duration(milliseconds: 1),
    );
    expect(scroll.controller!.offset, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(scroll.controller!.offset, greaterThan(0));
    expect(title.data, 'The Choice of Steins Gate');

    await tester.pumpWidget(_testApp(visible: false, description: description));
    await tester.pump();
    expect(scroll.controller!.offset, 0);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not move text that fits or when motion is disabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(visible: true, description: 'A short synopsis.'),
    );
    await tester.pump(playerPausedMetadataScrollDelay);
    await tester.pump(const Duration(seconds: 2));
    var scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('player-paused-description-scroll')),
    );
    expect(scroll.controller!.offset, 0);

    final longDescription = List.filled(
      20,
      'This synopsis would overflow if accessibility motion were enabled.',
    ).join(' ');
    await tester.pumpWidget(
      _testApp(
        visible: true,
        description: longDescription,
        disableAnimations: true,
      ),
    );
    await tester.pump(playerPausedMetadataScrollDelay);
    await tester.pump(const Duration(seconds: 2));
    scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('player-paused-description-scroll')),
    );
    expect(scroll.controller!.offset, 0);
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp({
  required bool visible,
  required String description,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(1000, 600),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 466,
            child: PlayerPausedMetadataOverlay(
              visible: visible,
              episodeTitle: 'The Choice of Steins Gate',
              description: description,
            ),
          ),
        ),
      ),
    ),
  );
}
