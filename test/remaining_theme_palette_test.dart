import 'dart:io';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/features/settings/presentation/privacy_screen.dart';
import 'package:anime_tv/features/settings/presentation/third_party_notices_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final palette = AppThemePalette.fromSeeds(
    background: const Color(0xFF102030),
    surface: const Color(0xFF203040),
    accent: const Color(0xFF00C080),
    primaryText: const Color(0xFFF3F8FC),
    mutedText: const Color(0xFFABC0D0),
  );

  testWidgets('privacy and notices use the active Theme Studio palette', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const PrivacyScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      palette.background,
    );
    expect(
      tester.widget<Text>(find.text('Privacy & data')).style?.color,
      palette.primaryText,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const ThirdPartyNoticesScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      palette.background,
    );
    final header = tester
        .widgetList<Text>(find.text('Third-party notices'))
        .first;
    expect(header.style?.color, palette.primaryText);
  });

  testWidgets('poster score badge uses the active accent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const Scaffold(
          body: PosterMetadataOverlay(score: 8.7, releaseYear: 2026),
        ),
      ),
    );

    final accentBadge = find.descendant(
      of: find.byType(PosterMetadataOverlay),
      matching: find.byWidgetPredicate((widget) {
        if (widget is! Container) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.color == palette.accent;
      }),
    );
    expect(accentBadge, findsOneWidget);
  });

  test('remaining non-player screens do not bypass Theme Studio colors', () {
    const paths = [
      'lib/core/widgets/poster_metadata_overlay.dart',
      'lib/features/settings/presentation/diagnostics_screen.dart',
      'lib/features/settings/presentation/privacy_screen.dart',
      'lib/features/settings/presentation/third_party_notices_screen.dart',
      'lib/features/streaming/presentation/resolve_episode_screen.dart',
      'lib/features/tracking/presentation/catalog_tracking_action.dart',
    ];

    for (final path in paths) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('AppColors.')),
        reason: '$path should read semantic colors from context.appPalette.',
      );
    }
  });
}
