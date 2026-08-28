import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:anime_tv/features/player/presentation/teto_player_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shared player chrome keeps every feature control available', (
    tester,
  ) async {
    final playFocus = FocusNode();
    var watchPartyPressed = false;
    var previousEpisodePressed = false;
    var nextEpisodePressed = false;
    var playbackSpeedPressed = false;
    addTearDown(playFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: TetoPlayerChrome(
            engineKey: 'test',
            title: 'A test anime • Episode 3',
            streamLabel: 'Web stream',
            engineLabel: 'MPV',
            position: const Duration(minutes: 3),
            duration: const Duration(minutes: 24),
            isPlaying: true,
            playFocusNode: playFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 30,
            onSeek: (_) {},
            onRewind: () {},
            onPlayPause: () {},
            onForward: () {},
            onPreviousEpisode: () => previousEpisodePressed = true,
            onNextEpisode: () => nextEpisodePressed = true,
            onAudio: () {},
            onSubtitles: () {},
            onPicture: () {},
            onPlaybackSpeed: () => playbackSpeedPressed = true,
            onSources: () {},
            onWatchTogether: () => watchPartyPressed = true,
            onOptions: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    const controlLabels = <String>[
      'Previous Episode',
      'Back 10s',
      'Pause',
      'Forward 30s',
      'Next Episode',
      'Playback Speed',
      'Audio',
      'CC',
      'Picture',
      'Sources',
      'Watch Party',
      'Options',
    ];
    for (final label in controlLabels) {
      expect(find.text(label), findsNothing, reason: label);
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      expect(find.byTooltip(label), findsOneWidget, reason: label);
      expect(
        tester.getSize(find.byKey(ValueKey('player-control-$label'))),
        const Size.square(40),
        reason: label,
      );
    }
    expect(find.text('Player'), findsNothing);
    expect(find.text('03:00  /  24:00'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    expect(
      find.byKey(const ValueKey('test-player-progress-bar')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('player-control-Back 10s'))),
      const Size.square(40),
    );
    expect(
      (tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('test-bottom-player-chrome')),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      const Color(0xD6080808),
    );
    expect(
      (tester
                  .widget<Container>(
                    find.byKey(const ValueKey('player-control-Options')),
                  )
                  .decoration!
              as BoxDecoration)
          .color,
      const Color(0x8F242429),
    );
    expect(
      (tester
                  .widget<Container>(
                    find.byKey(const ValueKey('player-control-Pause')),
                  )
                  .decoration!
              as BoxDecoration)
          .color,
      AppColors.accent,
    );
    final progress = tester.widget<Slider>(
      find.byKey(const ValueKey('test-player-progress-bar')),
    );
    expect(progress.activeColor, AppColors.accentBright);
    expect(progress.inactiveColor, Colors.white.withValues(alpha: .24));
    expect(
      find.byKey(const ValueKey('test-player-controls-spaced')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('test-player-controls-scroll')),
      findsNothing,
    );
    final transportRect = tester.getRect(
      find.byKey(const ValueKey('test-transport-controls')),
    );
    final utilityRect = tester.getRect(
      find.byKey(const ValueKey('test-utility-controls')),
    );
    final previousRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Previous Episode')),
    );
    final rewindRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Back 10s')),
    );
    final playRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Pause')),
    );
    final forwardRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Forward 30s')),
    );
    final nextRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Next Episode')),
    );
    final speedRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Playback Speed')),
    );
    final audioRect = tester.getRect(
      find.byKey(const ValueKey('player-control-Audio')),
    );
    expect(previousRect.right, lessThan(rewindRect.left));
    expect(rewindRect.right, lessThan(playRect.left));
    expect(playRect.right, lessThan(forwardRect.left));
    expect(forwardRect.right, lessThan(nextRect.left));
    expect(transportRect.right, lessThan(utilityRect.left));
    expect(speedRect.right, lessThan(audioRect.left));
    expect(audioRect.left - speedRect.right, closeTo(8, .01));
    expect(find.text('1x'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('test-episode-control-divider')),
      findsNothing,
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey('player-control-Options')))
          .right,
      closeTo(
        tester
                .getRect(
                  find.byKey(const ValueKey('test-bottom-player-chrome')),
                )
                .right -
            36,
        .01,
      ),
    );
    expect(tester.takeException(), isNull);

    final watchTogether = find.byKey(
      const ValueKey('player-control-Watch Party'),
    );
    await tester.ensureVisible(watchTogether);
    await tester.pumpAndSettle();
    await tester.tap(watchTogether);
    expect(watchPartyPressed, isTrue);
    expect(previousEpisodePressed, isFalse);
    expect(nextEpisodePressed, isFalse);
    final playbackSpeed = find.byKey(
      const ValueKey('player-control-Playback Speed'),
    );
    await tester.ensureVisible(playbackSpeed);
    await tester.tap(playbackSpeed);
    expect(playbackSpeedPressed, isTrue);
  });

  testWidgets(
    'compact full HUD keeps grouped order scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(520, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final playFocus = FocusNode();
      var optionsActivated = false;
      addTearDown(playFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TetoPlayerChrome(
              engineKey: 'compact-groups',
              title: 'Episode',
              streamLabel: 'Stream',
              position: Duration.zero,
              duration: const Duration(minutes: 24),
              isPlaying: true,
              playFocusNode: playFocus,
              seekBackSeconds: 10,
              seekForwardSeconds: 30,
              onSeek: (_) {},
              onRewind: () {},
              onPlayPause: () {},
              onForward: () {},
              onPreviousEpisode: () {},
              onNextEpisode: () {},
              onPlaybackSpeed: () {},
              onAudio: () {},
              onSubtitles: () {},
              onPicture: () {},
              onSources: () {},
              onWatchTogether: () {},
              onOptions: () => optionsActivated = true,
              onDismiss: () {},
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('compact-groups-player-controls-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('compact-groups-player-controls-spaced')),
        findsNothing,
      );
      final speedRect = tester.getRect(
        find.byKey(const ValueKey('player-control-Playback Speed')),
      );
      final audioRect = tester.getRect(
        find.byKey(const ValueKey('player-control-Audio')),
      );
      expect(speedRect.right, lessThan(audioRect.left));
      expect(audioRect.left - speedRect.right, closeTo(8, .01));

      playFocus.requestFocus();
      await tester.pump();
      for (var move = 0; move < 10; move++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 120));
      }
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(optionsActivated, isTrue);
      final optionsRect = tester.getRect(
        find.byKey(const ValueKey('player-control-Options')),
      );
      expect(optionsRect.left, greaterThanOrEqualTo(0));
      expect(optionsRect.right, lessThanOrEqualTo(520));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'D-pad follows the reference order and returns through the scrubber',
    (tester) async {
      final playFocus = FocusNode(debugLabel: 'player.control.play');
      final progressFocus = FocusNode(debugLabel: 'player.progress');
      addTearDown(playFocus.dispose);
      addTearDown(progressFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TetoPlayerChrome(
              engineKey: 'focus-order',
              title: 'Episode',
              streamLabel: 'Web stream',
              position: const Duration(minutes: 3),
              duration: const Duration(minutes: 24),
              isPlaying: true,
              playFocusNode: playFocus,
              progressFocusNode: progressFocus,
              seekBackSeconds: 10,
              seekForwardSeconds: 30,
              onSeek: (_) {},
              onRewind: () {},
              onPlayPause: () {},
              onForward: () {},
              onPreviousEpisode: () {},
              onNextEpisode: () {},
              onPlaybackSpeed: () {},
              onAudio: () {},
              onSubtitles: () {},
              onPicture: () {},
              onSources: () {},
              onWatchTogether: () {},
              onOptions: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      playFocus.requestFocus();
      await tester.pump();
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.play',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.rewind',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.previous-episode',
      );

      for (final expected in const [
        'player.control.rewind',
        'player.control.play',
        'player.control.fast-forward',
        'player.control.next-episode',
        'player.control.playback-speed',
        'player.control.audio',
        'player.control.captions',
        'player.control.picture',
        'player.control.sources',
        'player.control.watch-party',
        'player.control.options',
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
          tester.binding.focusManager.primaryFocus?.debugLabel,
          expected,
          reason: 'Right should move to $expected',
        );
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.binding.focusManager.primaryFocus, progressFocus);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.binding.focusManager.primaryFocus, playFocus);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'D-pad skips unavailable episode actions without trapping focus',
    (tester) async {
      final playFocus = FocusNode(debugLabel: 'player.control.play');
      addTearDown(playFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TetoPlayerChrome(
              engineKey: 'disabled-order',
              title: 'Episode',
              streamLabel: 'Stream',
              position: const Duration(minutes: 2),
              duration: const Duration(minutes: 24),
              isPlaying: true,
              playFocusNode: playFocus,
              seekBackSeconds: 10,
              seekForwardSeconds: 30,
              onSeek: (_) {},
              onRewind: () {},
              onPlayPause: () {},
              onForward: () {},
              onPreviousEpisode: () {},
              previousEpisodeEnabled: false,
              onNextEpisode: () {},
              nextEpisodeEnabled: false,
              onPlaybackSpeed: () {},
              onAudio: () {},
              onSubtitles: () {},
              onPicture: () {},
              onOptions: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      playFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.rewind',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.rewind',
        reason: 'the disabled Previous Episode button is not a focus trap',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.fast-forward',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.control.playback-speed',
        reason: 'the disabled Next Episode button must be skipped',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final viewport in const [
    Size(960, 540),
    Size(1280, 720),
    Size(1920, 1080),
  ]) {
    testWidgets(
      'reference HUD geometry stays stable at ${viewport.width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playFocus = FocusNode();
        addTearDown(playFocus.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TetoPlayerChrome(
                engineKey: 'geometry',
                title: 'Lucky Star / Episode 18',
                engineLabel: 'MPV - Automatic (adaptive)',
                streamLabel: 'Synthetic web stream',
                playbackSpeed: 1.25,
                position: const Duration(seconds: 3),
                duration: const Duration(minutes: 23, seconds: 40),
                isPlaying: true,
                playFocusNode: playFocus,
                seekBackSeconds: 10,
                seekForwardSeconds: 30,
                onSeek: (_) {},
                onRewind: () {},
                onPlayPause: () {},
                onForward: () {},
                onPreviousEpisode: () {},
                onNextEpisode: () {},
                onPlaybackSpeed: () {},
                onAudio: () {},
                onSubtitles: () {},
                onPicture: () {},
                onSources: () {},
                onWatchTogether: () {},
                onOptions: () {},
                onDismiss: () {},
              ),
            ),
          ),
        );

        final panelRect = tester.getRect(
          find.byKey(const ValueKey('geometry-bottom-player-chrome')),
        );
        final expectedInset = (viewport.width * .025).clamp(24.0, 48.0);
        expect(panelRect.left, closeTo(expectedInset, .01));
        expect(panelRect.right, closeTo(viewport.width - expectedInset, .01));

        final labels = <String>[
          'Previous Episode',
          'Back 10s',
          'Pause',
          'Forward 30s',
          'Next Episode',
          'Playback Speed',
          'Audio',
          'CC',
          'Picture',
          'Sources',
          'Watch Party',
          'Options',
        ];
        final rects = [
          for (final label in labels)
            tester.getRect(find.byKey(ValueKey('player-control-$label'))),
        ];
        for (var index = 1; index < rects.length; index++) {
          expect(
            rects[index].left,
            greaterThan(rects[index - 1].right),
            reason: '${labels[index]} must follow ${labels[index - 1]}',
          );
          expect(rects[index].center.dy, closeTo(rects.first.center.dy, .01));
        }
        expect(find.text('1.25x'), findsOneWidget);

        final titleRect = tester.getRect(find.text('Lucky Star / Episode 18'));
        final engineRect = tester.getRect(
          find.byKey(const ValueKey('geometry-engine-badge')),
        );
        final sourceRect = tester.getRect(
          find.byKey(const ValueKey('geometry-source-badge')),
        );
        final timeRect = tester.getRect(find.text('00:03  /  23:40'));
        final playRect = tester.getRect(
          find.byKey(const ValueKey('player-control-Pause')),
        );
        final nextRect = tester.getRect(
          find.byKey(const ValueKey('player-control-Next Episode')),
        );
        final speedRect = tester.getRect(
          find.byKey(const ValueKey('player-control-Playback Speed')),
        );
        final progressRect = tester.getRect(
          find.byKey(const ValueKey('geometry-player-progress-bar')),
        );
        expect(
          find.byKey(const ValueKey('geometry-player-header-spaced')),
          findsOneWidget,
        );
        expect(engineRect.left, greaterThan(titleRect.right));
        expect(sourceRect.left, greaterThan(engineRect.right));
        expect(sourceRect.right, closeTo(panelRect.right - 16, .01));
        expect(timeRect.left, greaterThan(nextRect.right));
        expect(timeRect.right, lessThan(speedRect.left));
        expect(progressRect.top, greaterThan(playRect.bottom));
        expect(panelRect.height, inInclusiveRange(96, 112));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('playback speed picker exposes every supported rate', (
    tester,
  ) async {
    double? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            autofocus: true,
            onPressed: () async {
              selected = await showPlayerPlaybackSpeedPicker(
                context: context,
                current: 1,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(playerPlaybackSpeedValues, const [.5, .75, 1, 1.25, 1.5, 1.75, 2]);
    expect(playerPlaybackSpeedValues.map(playerPlaybackSpeedLabel), const [
      '0.5x',
      '0.75x',
      '1x',
      '1.25x',
      '1.5x',
      '1.75x',
      '2x',
    ]);
    expect(find.text('1x'), findsOneWidget);
    for (var move = 0; move < 3; move++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, 1.75);
  });

  testWidgets('icon-only controls keep D-pad focus order and actions', (
    tester,
  ) async {
    final playFocus = FocusNode();
    addTearDown(playFocus.dispose);
    var rewindCount = 0;
    var playPauseCount = 0;
    var forwardCount = 0;
    var nextEpisodeCount = 0;
    var audioCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TetoPlayerChrome(
            engineKey: 'transport-actions',
            title: 'Episode',
            streamLabel: 'Stream',
            position: Duration.zero,
            duration: const Duration(minutes: 24),
            isPlaying: false,
            playFocusNode: playFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 30,
            onSeek: (_) {},
            onRewind: () => rewindCount++,
            onPlayPause: () => playPauseCount++,
            onForward: () => forwardCount++,
            onNextEpisode: () => nextEpisodeCount++,
            onAudio: () => audioCount++,
            onSubtitles: () {},
            onPicture: () {},
            onOptions: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    playFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(playPauseCount, 1);
    expect(rewindCount, 1);
    expect(forwardCount, 1);
    expect(nextEpisodeCount, 1);
    expect(audioCount, 1);
    for (final label in const [
      'Back 10s',
      'Play',
      'Forward 30s',
      'Next Episode',
      'Audio',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('next episode is absent without a route and disabled safely', (
    tester,
  ) async {
    final playFocus = FocusNode();
    addTearDown(playFocus.dispose);
    var nextEpisodeCount = 0;
    var audioCount = 0;

    Widget chrome({VoidCallback? onNextEpisode, bool enabled = true}) =>
        MaterialApp(
          home: Scaffold(
            body: TetoPlayerChrome(
              engineKey: 'next-state',
              title: 'Episode',
              streamLabel: 'Stream',
              position: Duration.zero,
              duration: const Duration(minutes: 24),
              isPlaying: false,
              playFocusNode: playFocus,
              seekBackSeconds: 10,
              seekForwardSeconds: 30,
              onSeek: (_) {},
              onRewind: () {},
              onPlayPause: () {},
              onForward: () {},
              onNextEpisode: onNextEpisode,
              nextEpisodeEnabled: enabled,
              onAudio: () => audioCount++,
              onSubtitles: () {},
              onPicture: () {},
              onOptions: () {},
              onDismiss: () {},
            ),
          ),
        );

    await tester.pumpWidget(chrome());
    expect(
      find.byKey(const ValueKey('player-control-Next Episode')),
      findsNothing,
    );
    expect(find.byTooltip('Next Episode'), findsNothing);

    await tester.pumpWidget(
      chrome(onNextEpisode: () => nextEpisodeCount++, enabled: false),
    );
    await tester.pump();
    final nextControl = find.byWidgetPredicate(
      (widget) => widget is TetoPlayerControl && widget.label == 'Next Episode',
    );
    expect(nextControl, findsOneWidget);
    expect(tester.widget<TetoPlayerControl>(nextControl).enabled, isFalse);
    expect(find.text('Next Episode'), findsNothing);
    expect(find.bySemanticsLabel('Next Episode'), findsOneWidget);
    expect(find.byTooltip('Next Episode'), findsOneWidget);

    playFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(nextEpisodeCount, 0);
    expect(audioCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'previous episode is absent without a route and disabled on episode one',
    (tester) async {
      final playFocus = FocusNode();
      addTearDown(playFocus.dispose);
      var previousEpisodeCount = 0;

      Widget chrome({VoidCallback? onPreviousEpisode, bool enabled = true}) =>
          MaterialApp(
            home: Scaffold(
              body: TetoPlayerChrome(
                engineKey: 'previous-state',
                title: 'Episode',
                streamLabel: 'Stream',
                position: Duration.zero,
                duration: const Duration(minutes: 24),
                isPlaying: false,
                playFocusNode: playFocus,
                seekBackSeconds: 10,
                seekForwardSeconds: 30,
                onSeek: (_) {},
                onRewind: () {},
                onPlayPause: () {},
                onForward: () {},
                onPreviousEpisode: onPreviousEpisode,
                previousEpisodeEnabled: enabled,
                onAudio: () {},
                onSubtitles: () {},
                onPicture: () {},
                onOptions: () {},
                onDismiss: () {},
              ),
            ),
          );

      await tester.pumpWidget(chrome());
      expect(
        find.byKey(const ValueKey('player-control-Previous Episode')),
        findsNothing,
      );

      await tester.pumpWidget(
        chrome(onPreviousEpisode: () => previousEpisodeCount++, enabled: false),
      );
      await tester.pump();
      final previousControl = find.byWidgetPredicate(
        (widget) =>
            widget is TetoPlayerControl && widget.label == 'Previous Episode',
      );
      expect(previousControl, findsOneWidget);
      expect(
        tester.widget<TetoPlayerControl>(previousControl).enabled,
        isFalse,
      );
      expect(find.bySemanticsLabel('Previous Episode'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('player-control-Previous Episode')),
        warnIfMissed: false,
      );
      expect(previousEpisodeCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('progress bar supports drag and TV D-pad seeking', (
    tester,
  ) async {
    final playFocus = FocusNode();
    final progressFocus = FocusNode();
    final seeks = <Duration>[];
    var dismissed = false;
    addTearDown(playFocus.dispose);
    addTearDown(progressFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TetoPlayerChrome(
            engineKey: 'seekable',
            title: 'Episode',
            streamLabel: 'Stream',
            position: const Duration(minutes: 3),
            duration: const Duration(minutes: 24),
            isPlaying: true,
            playFocusNode: playFocus,
            progressFocusNode: progressFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 30,
            onSeek: seeks.add,
            onRewind: () {},
            onPlayPause: () {},
            onForward: () {},
            onAudio: () {},
            onSubtitles: () {},
            onPicture: () {},
            onOptions: () {},
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    playFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(progressFocus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks, [const Duration(minutes: 3, seconds: 30)]);

    await tester.drag(
      find.byKey(const ValueKey('seekable-player-progress-bar')),
      const Offset(220, 0),
    );
    await tester.pump();
    expect(seeks.length, 2);
    expect(seeks.last, greaterThan(const Duration(minutes: 3, seconds: 30)));

    progressFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(dismissed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resting on a scrub position requests a scene preview', (
    tester,
  ) async {
    final playFocus = FocusNode();
    final progressFocus = FocusNode();
    final previews = <Duration>[];
    final seeks = <Duration>[];
    addTearDown(playFocus.dispose);
    addTearDown(progressFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TetoPlayerChrome(
            engineKey: 'preview',
            title: 'Episode',
            streamLabel: 'Stream',
            position: const Duration(minutes: 3),
            duration: const Duration(minutes: 24),
            isPlaying: true,
            playFocusNode: playFocus,
            progressFocusNode: progressFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 30,
            onSeek: seeks.add,
            onSeekPreview: previews.add,
            onRewind: () {},
            onPlayPause: () {},
            onForward: () {},
            onAudio: () {},
            onSubtitles: () {},
            onPicture: () {},
            onOptions: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    progressFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 119));
    expect(previews, isEmpty);
    expect(seeks, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    expect(previews, [const Duration(minutes: 3, seconds: 30)]);
    expect(seeks, isEmpty);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks, [const Duration(minutes: 3, seconds: 30)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('held TV scrubbing shows its target time and avoids exact EOF', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playFocus = FocusNode();
    final progressFocus = FocusNode();
    final seeks = <Duration>[];
    addTearDown(playFocus.dispose);
    addTearDown(progressFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TetoPlayerChrome(
            engineKey: 'target-time',
            title: 'Episode',
            streamLabel: 'Stream',
            position: const Duration(minutes: 23, seconds: 58),
            duration: const Duration(minutes: 24),
            isPlaying: true,
            playFocusNode: playFocus,
            progressFocusNode: progressFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 30,
            onSeek: seeks.add,
            onRewind: () {},
            onPlayPause: () {},
            onForward: () {},
            onAudio: () {},
            onSubtitles: () {},
            onPicture: () {},
            onOptions: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    progressFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    final sliderFinder = find.byKey(
      const ValueKey('target-time-player-progress-bar'),
    );
    expect(tester.widget<Slider>(sliderFinder).label, '23:59');
    expect(
      find.byKey(const ValueKey('target-time-player-seek-target-time')),
      findsOneWidget,
    );
    expect(find.text('Seek 23:59'), findsOneWidget);
    expect(seeks, isEmpty);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks, [const Duration(minutes: 23, seconds: 59)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'D-pad navigation and control activation refresh HUD idle activity',
    (tester) async {
      final playFocus = FocusNode();
      Timer? hideTimer;
      var hudVisible = true;
      var interactionCount = 0;
      var forwardPressed = false;
      addTearDown(playFocus.dispose);
      addTearDown(() => hideTimer?.cancel());

      void scheduleHide() {
        hideTimer?.cancel();
        hideTimer = Timer(playerControlsIdleTimeout, () => hudVisible = false);
      }

      void handleInteraction() {
        interactionCount += 1;
        hudVisible = true;
        scheduleHide();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TetoPlayerChrome(
              engineKey: 'control-activity',
              title: 'Episode',
              streamLabel: 'Stream',
              position: const Duration(minutes: 3),
              duration: const Duration(minutes: 24),
              isPlaying: true,
              playFocusNode: playFocus,
              seekBackSeconds: 10,
              seekForwardSeconds: 30,
              onSeek: (_) {},
              onRewind: () {},
              onPlayPause: () {},
              onForward: () => forwardPressed = true,
              onAudio: () {},
              onSubtitles: () {},
              onPicture: () {},
              onInteraction: handleInteraction,
              onOptions: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      playFocus.requestFocus();
      await tester.pump();
      expect(interactionCount, greaterThan(0));

      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final afterNavigation = interactionCount;
      expect(afterNavigation, greaterThan(1));
      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      expect(hudVisible, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(hudVisible, isFalse);

      hudVisible = true;
      scheduleHide();
      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(forwardPressed, isTrue);
      expect(interactionCount, greaterThan(afterNavigation));
      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      expect(hudVisible, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(hudVisible, isFalse);

      hudVisible = true;
      scheduleHide();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      for (var repeat = 0; repeat < 3; repeat++) {
        await tester.pump(
          playerControlsIdleTimeout - const Duration(seconds: 1),
        );
        expect(hudVisible, isTrue);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      expect(hudVisible, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(hudVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touch and held D-pad scrubbing suspend HUD auto-dismiss until release',
    (tester) async {
      final playFocus = FocusNode();
      final progressFocus = FocusNode();
      Timer? hideTimer;
      var hudVisible = true;
      final interactionStates = <bool>[];
      addTearDown(playFocus.dispose);
      addTearDown(progressFocus.dispose);
      addTearDown(() => hideTimer?.cancel());

      void scheduleHide() {
        hideTimer?.cancel();
        hideTimer = Timer(playerControlsIdleTimeout, () => hudVisible = false);
      }

      void handleInteraction(bool active) {
        interactionStates.add(active);
        hideTimer?.cancel();
        if (!active) scheduleHide();
      }

      scheduleHide();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TetoPlayerChrome(
              engineKey: 'scrub-hold',
              title: 'Episode',
              streamLabel: 'Stream',
              position: const Duration(minutes: 3),
              duration: const Duration(minutes: 24),
              isPlaying: true,
              playFocusNode: playFocus,
              progressFocusNode: progressFocus,
              seekBackSeconds: 10,
              seekForwardSeconds: 30,
              onSeek: (_) {},
              onRewind: () {},
              onPlayPause: () {},
              onForward: () {},
              onAudio: () {},
              onSubtitles: () {},
              onPicture: () {},
              onScrubInteractionChanged: handleInteraction,
              onOptions: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      final slider = find.byKey(
        const ValueKey('scrub-hold-player-progress-bar'),
      );
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump(playerControlsIdleTimeout + const Duration(seconds: 1));
      expect(hudVisible, isTrue);
      expect(interactionStates, isNotEmpty);
      expect(interactionStates.last, isTrue);

      await gesture.up();
      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      expect(hudVisible, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(hudVisible, isFalse);
      expect(interactionStates.last, isFalse);

      hudVisible = true;
      scheduleHide();
      progressFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var repeat = 0; repeat < 30; repeat++) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      }
      expect(hudVisible, isTrue);
      expect(interactionStates.last, isTrue);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(playerControlsIdleTimeout - const Duration(seconds: 1));
      expect(hudVisible, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(hudVisible, isFalse);
      expect(interactionStates.last, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('skip segment is a separate translucent overlay', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TetoSkipSegmentOverlay(
              label: 'Skip Intro',
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('player-skip-segment-overlay')),
      findsOneWidget,
    );
    expect(find.text('Skip Intro'), findsOneWidget);
  });

  for (final testCase in <({Size viewport, double textScale})>[
    (viewport: const Size(1920, 1080), textScale: 1),
    (viewport: const Size(640, 360), textScale: 2.5),
  ]) {
    testWidgets(
      'skip action clears visible HUD at ${testCase.viewport.width.toInt()}x'
      '${testCase.viewport.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = testCase.viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playFocus = FocusNode();
        addTearDown(playFocus.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(testCase.textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: Stack(
                children: [
                  TetoPlayerChrome(
                    engineKey: 'skip-spacing',
                    title: 'Episode',
                    streamLabel: 'Stream',
                    position: const Duration(minutes: 3),
                    duration: const Duration(minutes: 24),
                    isPlaying: true,
                    playFocusNode: playFocus,
                    seekBackSeconds: 10,
                    seekForwardSeconds: 30,
                    onSeek: (_) {},
                    onRewind: () {},
                    onPlayPause: () {},
                    onForward: () {},
                    onAudio: () {},
                    onSubtitles: () {},
                    onPicture: () {},
                    onOptions: () {},
                    onDismiss: () {},
                    partyStatus: 'PARTY 37363957 · HOST',
                    watchingCount: 1,
                  ),
                  Positioned(
                    right: testCase.viewport.width < 720 ? 18 : 38,
                    bottom: playerSkipOverlayBottomInset(
                      viewport: testCase.viewport,
                      controlsVisible: true,
                      textScaleFactor: testCase.textScale,
                      expandedHeader: true,
                    ),
                    child: TetoSkipSegmentOverlay(
                      label: 'Skip Intro',
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final skipRect = tester.getRect(
          find.byKey(const ValueKey('player-skip-segment-overlay')),
        );
        final chromeRect = tester.getRect(
          find.byKey(const ValueKey('skip-spacing-bottom-player-chrome')),
        );
        expect(skipRect.bottom, lessThan(chromeRect.top));
        expect(chromeRect.top - skipRect.bottom, greaterThanOrEqualTo(12));
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('skip overlay inset follows HUD visibility and safe area', () {
    expect(
      playerSkipOverlayBottomInset(
        viewport: const Size(1920, 1080),
        controlsVisible: true,
      ),
      130,
    );
    expect(
      playerSkipOverlayBottomInset(
        viewport: const Size(640, 360),
        controlsVisible: true,
        safeAreaBottom: 24,
      ),
      160,
    );
    expect(
      playerSkipOverlayBottomInset(
        viewport: const Size(640, 360),
        controlsVisible: true,
        safeAreaBottom: 24,
        textScaleFactor: 2.5,
      ),
      262,
    );
    expect(
      playerSkipOverlayBottomInset(
        viewport: const Size(640, 360),
        controlsVisible: false,
        safeAreaBottom: 24,
      ),
      50,
    );
    expect(
      playerSkipOverlayBottomInset(
        viewport: const Size(1920, 1080),
        controlsVisible: true,
        expandedHeader: true,
      ),
      174,
    );
  });

  testWidgets('shared chrome consumes every Theme Studio HUD color role', (
    tester,
  ) async {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF07131F),
      surface: const Color(0xFF1B3045),
      accent: const Color(0xFF2DAA68),
      primaryText: const Color(0xFFF2E7D5),
      mutedText: const Color(0xFF91A5B8),
    );
    final playFocus = FocusNode();
    addTearDown(playFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: Scaffold(
          body: TetoPlayerChrome(
            engineKey: 'themed',
            title: 'Themed episode',
            streamLabel: 'Stream',
            position: const Duration(minutes: 2),
            duration: const Duration(minutes: 24),
            isPlaying: true,
            playFocusNode: playFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 10,
            onSeek: (_) {},
            onRewind: () {},
            onPlayPause: () {},
            onForward: () {},
            onAudio: () {},
            onSubtitles: () {},
            onPicture: () {},
            onOptions: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    final panel = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('themed-bottom-player-chrome')),
    );
    final panelDecoration = panel.decoration as BoxDecoration;
    expect(
      panelDecoration.color,
      Color.lerp(
        palette.background,
        palette.surface,
        .62,
      )!.withValues(alpha: .84),
    );
    expect(
      panelDecoration.border!.top.color,
      palette.accent.withValues(alpha: .78),
    );

    final normalControl = tester.widget<Container>(
      find.byKey(const ValueKey('player-control-Options')),
    );
    expect(
      (normalControl.decoration! as BoxDecoration).color,
      palette.selectableSurface.withValues(alpha: .56),
    );
    final progress = tester.widget<Slider>(
      find.byKey(const ValueKey('themed-player-progress-bar')),
    );
    expect(progress.activeColor, palette.accentBright);
    expect(progress.inactiveColor, palette.primaryText.withValues(alpha: .24));
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('player-control-Options')),
              matching: find.byIcon(Icons.tune_rounded),
            ),
          )
          .color,
      palette.primaryText,
    );
    expect(find.text('Options'), findsNothing);
    expect(find.byTooltip('Options'), findsOneWidget);
    expect(
      tester.widget<Text>(find.textContaining('D-pad controls')).style?.color,
      palette.mutedText,
    );

    playFocus.requestFocus();
    await tester.pumpAndSettle();
    final focusedChrome = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('player-control-Pause')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final focusDecoration = focusedChrome.decoration as BoxDecoration;
    final focusForeground = focusedChrome.foregroundDecoration as BoxDecoration;
    expect(focusForeground.border!.top.color, palette.focusRing);
    expect(
      focusDecoration.boxShadow!.map((shadow) => shadow.color),
      contains(palette.focusGlow),
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(320, 640), Size(360, 800), Size(800, 360)]) {
    testWidgets(
      'shared chrome remains usable at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playFocus = FocusNode();
        addTearDown(playFocus.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TetoPlayerChrome(
                engineKey: 'phone',
                title: 'A very long anime episode title that must not overflow',
                streamLabel: 'A very long marketplace provider name',
                position: const Duration(minutes: 1),
                duration: const Duration(minutes: 24),
                isPlaying: false,
                playFocusNode: playFocus,
                seekBackSeconds: 10,
                seekForwardSeconds: 10,
                onSeek: (_) {},
                onRewind: () {},
                onPlayPause: () {},
                onForward: () {},
                onAudio: () {},
                onSubtitles: () {},
                onPicture: () {},
                onSources: () {},
                onWatchTogether: () {},
                onOptions: () {},
                onDismiss: () {},
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Sources'), findsNothing);
        expect(find.bySemanticsLabel('Sources'), findsOneWidget);
        expect(find.byTooltip('Sources'), findsOneWidget);
        expect(find.byType(SingleChildScrollView), findsOneWidget);

        playFocus.requestFocus();
        await tester.pump();
        for (var move = 0; move < 9; move++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 120));
        }
        final optionsRect = tester.getRect(
          find.byKey(const ValueKey('player-control-Options')),
        );
        expect(optionsRect.left, greaterThanOrEqualTo(0));
        expect(optionsRect.right, lessThanOrEqualTo(size.width));
        expect(tester.binding.focusManager.primaryFocus, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('D-pad Down dismisses the visible player HUD immediately', (
    tester,
  ) async {
    final playFocus = FocusNode();
    addTearDown(playFocus.dispose);
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TetoPlayerChrome(
            engineKey: 'dismiss',
            title: 'Episode',
            streamLabel: 'Web stream',
            position: Duration.zero,
            duration: const Duration(minutes: 24),
            isPlaying: true,
            playFocusNode: playFocus,
            seekBackSeconds: 10,
            seekForwardSeconds: 10,
            onSeek: (_) {},
            onRewind: () {},
            onPlayPause: () {},
            onForward: () {},
            onAudio: () {},
            onSubtitles: () {},
            onPicture: () {},
            onOptions: () {},
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    playFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);

    expect(dismissed, isTrue);
  });

  for (final testCase in <({Size viewport, double textScale})>[
    (viewport: const Size(640, 360), textScale: 2.5),
    (viewport: const Size(720, 480), textScale: 2.0),
  ]) {
    testWidgets(
      'edge pills stay contained at ${testCase.viewport.width.toInt()}x'
      '${testCase.viewport.height.toInt()} and ${testCase.textScale}x text',
      (tester) async {
        tester.view.physicalSize = testCase.viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playFocus = FocusNode();
        addTearDown(playFocus.dispose);
        var optionsActivated = false;
        var rewindActivated = false;

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(testCase.textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: TetoPlayerChrome(
                engineKey: 'large-text',
                title: 'Episode',
                streamLabel: 'Stream',
                position: Duration.zero,
                duration: const Duration(minutes: 24),
                isPlaying: true,
                playFocusNode: playFocus,
                seekBackSeconds: 10,
                seekForwardSeconds: 10,
                onSeek: (_) {},
                onRewind: () => rewindActivated = true,
                onPlayPause: () {},
                onForward: () {},
                onAudio: () {},
                onSubtitles: () {},
                onPicture: () {},
                onSources: () {},
                onWatchTogether: () {},
                onOptions: () => optionsActivated = true,
                onDismiss: () {},
              ),
            ),
          ),
        );

        playFocus.requestFocus();
        await tester.pump();
        for (var move = 0; move < 9; move++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 120));
        }
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();

        final control = find.byKey(const ValueKey('player-control-Options'));
        final controlRect = tester.getRect(control);
        final iconRect = tester.getRect(
          find.descendant(
            of: control,
            matching: find.byIcon(Icons.tune_rounded),
          ),
        );
        final viewportRect = Offset.zero & testCase.viewport;
        final panelRect = tester.getRect(
          find.byKey(const ValueKey('large-text-bottom-player-chrome')),
        );
        final titleContext = tester.element(find.text('Episode'));
        expect(
          MediaQuery.textScalerOf(titleContext).scale(1),
          testCase.textScale,
          reason: 'the HUD must honor the platform accessibility text scale',
        );
        expect(viewportRect.contains(controlRect.topLeft), isTrue);
        expect(viewportRect.contains(controlRect.bottomRight), isTrue);
        // The trailing gutter also contains TvFocusable's scaled focus glow
        // inside the HUD card, not just inside the physical display.
        expect(controlRect.right + 14, lessThanOrEqualTo(panelRect.right));
        expect(controlRect.width, closeTo(41, .01));
        expect(controlRect.height, closeTo(41, .01));
        expect(find.text('Options'), findsNothing);
        expect(find.bySemanticsLabel('Options'), findsOneWidget);
        expect(find.byTooltip('Options'), findsOneWidget);
        expect(controlRect.contains(iconRect.topLeft), isTrue);
        expect(controlRect.contains(iconRect.bottomRight), isTrue);
        expect(optionsActivated, isTrue);
        final scrollable = Scrollable.of(
          tester.binding.focusManager.primaryFocus!.context!,
        );
        expect(
          scrollable.position.pixels,
          closeTo(scrollable.position.maxScrollExtent, 0.01),
        );

        // Traverse all the way back from the trailing edge. This mirrors the
        // real remote-control path and catches a leading-edge regression that
        // a fresh, already-left-aligned HUD would hide.
        for (var move = 0; move < 10; move++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump(const Duration(milliseconds: 120));
        }
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();

        final rewindControl = find.byKey(
          const ValueKey('player-control-Back 10s'),
        );
        final rewindRect = tester.getRect(rewindControl);
        final rewindIconRect = tester.getRect(
          find.descendant(
            of: rewindControl,
            matching: find.byIcon(Icons.forward_rounded),
          ),
        );
        final mirroredRewind = tester.widget<Transform>(
          find.byKey(const ValueKey('player-control-Back 10s-mirrored-icon')),
        );
        expect(rewindRect.left - 14, greaterThanOrEqualTo(panelRect.left));
        expect(tester.getSize(rewindControl), const Size.square(40));
        expect(rewindRect.width, closeTo(41, .01));
        expect(rewindRect.height, closeTo(41, .01));
        expect(find.text('Back 10s'), findsNothing);
        expect(find.bySemanticsLabel('Back 10s'), findsOneWidget);
        expect(rewindRect.contains(rewindIconRect.topLeft), isTrue);
        expect(rewindRect.contains(rewindIconRect.bottomRight), isTrue);
        expect(mirroredRewind.transform.storage.first, lessThan(0));
        expect(rewindActivated, isTrue);
        expect(
          scrollable.position.pixels,
          closeTo(scrollable.position.minScrollExtent, 0.01),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
