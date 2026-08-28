import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skip action takes focus only from playback or the transport HUD', () {
    expect(
      shouldAutoFocusSkipAction(
        controlsVisible: false,
        transportFocused: false,
        playerRouteIsCurrent: true,
      ),
      isTrue,
    );
    expect(
      shouldAutoFocusSkipAction(
        controlsVisible: true,
        transportFocused: true,
        playerRouteIsCurrent: true,
      ),
      isTrue,
      reason: 'a visible transport HUD must yield to a new intro/outro action',
    );
    expect(
      shouldAutoFocusSkipAction(
        controlsVisible: true,
        transportFocused: false,
        playerRouteIsCurrent: true,
      ),
      isFalse,
      reason: 'unrelated player controls keep their viewer-selected focus',
    );
    expect(
      shouldAutoFocusSkipAction(
        controlsVisible: false,
        transportFocused: false,
        playerRouteIsCurrent: false,
      ),
      isFalse,
      reason: 'options, track, and confirmation dialogs own focus',
    );
    expect(
      shouldAutoFocusSkipAction(
        controlsVisible: false,
        transportFocused: false,
        playerRouteIsCurrent: true,
        handoffInProgress: true,
      ),
      isFalse,
    );
  });

  test('skip autofocus is claimed once per intro and once per outro', () {
    final gate = PlayerSkipAutoFocusGate();
    expect(gate.claim('opening:60000'), isTrue);
    expect(gate.claim('opening:60000'), isFalse);
    expect(gate.claim('ending:1290000'), isTrue);
    expect(gate.claim('ending:1290000'), isFalse);
    gate.reset();
    expect(gate.claim('opening:60000'), isTrue);
  });

  test('dismissed skip action restores focus without stealing other focus', () {
    expect(
      playerSkipDismissFocusTarget(
        skipHadFocus: true,
        skipStillAvailable: false,
        controlsVisible: true,
        guestControlsLocked: false,
      ),
      PlayerSkipDismissFocusTarget.playControl,
    );
    expect(
      playerSkipDismissFocusTarget(
        skipHadFocus: true,
        skipStillAvailable: false,
        controlsVisible: false,
        guestControlsLocked: false,
      ),
      PlayerSkipDismissFocusTarget.playerRoot,
    );
    expect(
      playerSkipDismissFocusTarget(
        skipHadFocus: true,
        skipStillAvailable: false,
        controlsVisible: true,
        guestControlsLocked: true,
      ),
      PlayerSkipDismissFocusTarget.watchPartyControl,
    );
    expect(
      playerSkipDismissFocusTarget(
        skipHadFocus: false,
        skipStillAvailable: false,
        controlsVisible: true,
        guestControlsLocked: false,
      ),
      PlayerSkipDismissFocusTarget.none,
      reason: 'an unrelated HUD control must retain focus when skip expires',
    );
    expect(
      playerSkipDismissFocusTarget(
        skipHadFocus: true,
        skipStillAvailable: true,
        controlsVisible: true,
        guestControlsLocked: false,
      ),
      PlayerSkipDismissFocusTarget.none,
      reason: 'a replacement skip action keeps its own focus',
    );
  });

  testWidgets('track picker is bottom aligned and D-pad selectable', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  selected = await showPlayerTrackPicker<String>(
                    context: context,
                    title: 'Closed captions',
                    icon: Icons.closed_caption_rounded,
                    selectedValue: 'eng',
                    options: const [
                      PlayerTrackOption(value: 'off', label: 'Off'),
                      PlayerTrackOption(value: 'eng', label: 'English'),
                      PlayerTrackOption(value: 'jpn', label: 'Japanese'),
                    ],
                  );
                },
                child: const Text('Tracks'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();

    final picker = find.byKey(const ValueKey('player-track-picker'));
    expect(picker, findsOneWidget);
    expect(tester.getBottomRight(picker).dy, greaterThan(500));
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, 'jpn');
    expect(picker, findsNothing);
  });

  test('caption sizes and labels stay stable in the MPV HUD', () {
    expect(playerCaptionSizeValues, const [28.0, 34.0, 42.0, 50.0]);
    expect(nearestPlayerCaptionSize(36), 34);
    expect(nearestPlayerCaptionSize(40), 42);
    expect(playerCaptionSizeLabel(28), 'Small');
    expect(playerCaptionSizeLabel(34), 'Medium');
    expect(playerCaptionSizeLabel(42), 'Large');
    expect(playerCaptionSizeLabel(50), 'Extra large');
  });

  testWidgets('caption Size opens its direct themed D-pad picker', (
    tester,
  ) async {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF08131D),
      surface: const Color(0xFF193247),
      accent: const Color(0xFF38A870),
      primaryText: const Color(0xFFF3E8D4),
      mutedText: const Color(0xFF91A6B8),
    );
    double? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                selected = await showPlayerCaptionSizePicker(
                  context: context,
                  current: 36,
                );
              },
              child: const Text('Size'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Size'));
    await tester.pumpAndSettle();

    expect(find.text('Choose caption size'), findsOneWidget);
    for (final label in ['Small', 'Medium', 'Large', 'Extra large']) {
      expect(find.text(label), findsOneWidget);
    }
    final panel = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-track-picker-panel')),
    );
    final decoration = panel.decoration as BoxDecoration;
    expect(decoration.color, palette.surface.withValues(alpha: .98));
    expect(decoration.border!.top.color, palette.accent.withValues(alpha: .75));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, 42);
    expect(find.byKey(const ValueKey('player-track-picker')), findsNothing);
  });

  testWidgets('exit dialog exposes both remote actions with explicit focus', (
    tester,
  ) async {
    bool? shouldExit;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                shouldExit = await showPlayerExitConfirmation(context);
              },
              child: const Text('Exit'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-exit-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-exit-continue')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-exit-confirm')), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Exit video?')).style?.color,
      Colors.white,
    );
    expect(
      tester.widget<Text>(find.text('Continue watching')).style?.color,
      Colors.white,
    );
    expect(
      tester.widget<Text>(find.text('Exit video')).style?.color,
      Colors.white,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(shouldExit, isTrue);
  });

  testWidgets('exit dialog follows a custom Theme Studio palette', (
    tester,
  ) async {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF07131F),
      surface: const Color(0xFF1A3044),
      accent: const Color(0xFF35A76C),
      primaryText: const Color(0xFFF1E5D3),
      mutedText: const Color(0xFF93A7B8),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const Scaffold(body: PlayerExitDialog()),
      ),
    );
    await tester.pumpAndSettle();

    final panel = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-exit-panel')),
    );
    final panelDecoration = panel.decoration as BoxDecoration;
    expect(
      panelDecoration.color,
      palette.surface.withValues(alpha: const Color(0xFA09090B).a),
    );
    expect(
      panelDecoration.border!.top.color,
      palette.accent.withValues(alpha: .3),
    );
    final continueSurface = tester.widget<Container>(
      find.byKey(const ValueKey('player-exit-continue-surface')),
    );
    expect(
      (continueSurface.decoration! as BoxDecoration).color,
      palette.selectableSurface.withValues(alpha: const Color(0xA629292E).a),
    );
    final confirmSurface = tester.widget<Container>(
      find.byKey(const ValueKey('player-exit-confirm-surface')),
    );
    expect((confirmSurface.decoration! as BoxDecoration).color, palette.accent);
    expect(
      tester.widget<Text>(find.text('Exit video?')).style?.color,
      palette.primaryText,
    );
    expect(
      tester
          .widget<Text>(
            find.text('Your current playback position will be saved.'),
          )
          .style
          ?.color,
      palette.mutedText.withValues(alpha: const Color(0xFFF0EAEC).a),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit dialog stacks without overflow on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlayerExitDialog())),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final continueButton = find.byKey(const ValueKey('player-exit-continue'));
    final exitButton = find.byKey(const ValueKey('player-exit-confirm'));
    expect(continueButton, findsOneWidget);
    expect(exitButton, findsOneWidget);
    expect(
      tester.getTopLeft(exitButton).dy,
      greaterThan(tester.getTopLeft(continueButton).dy),
    );
  });
}
