import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes AniList and MyAnimeList airing states', () {
    expect(animeAiringStatusLabel('RELEASING'), 'AIRING');
    expect(animeAiringStatusLabel('currently_airing'), 'AIRING');
    expect(animeAiringStatusLabel('FINISHED'), 'FINISHED');
    expect(animeAiringStatusLabel('finished_airing'), 'FINISHED');
    expect(animeAiringStatusLabel('NOT_YET_RELEASED'), 'UNRELEASED');
    expect(animeAiringStatusLabel('not yet aired'), 'UNRELEASED');
    expect(animeAiringStatusLabel('upcoming'), 'UNRELEASED');
    expect(animeAiringStatusLabel(null), isNull);
    expect(animeAiringStatusLabel('unknown'), isNull);
  });

  for (final (status, label, icon, background) in const [
    ('RELEASING', 'Airing', Icons.sensors_rounded, Color(0xF215964F)),
    ('FINISHED', 'Finished', Icons.check_rounded, Color(0xF222272D)),
    (
      'NOT_YET_RELEASED',
      'Unreleased',
      Icons.schedule_rounded,
      Color(0xF2A0364D),
    ),
  ]) {
    testWidgets('$label uses the compact rounded reference badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: PosterAiringStatusBadge(status: status),
            ),
          ),
        ),
      );

      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
      final badge = find.byType(PosterAiringStatusBadge);
      final decorations = tester.widgetList<DecoratedBox>(
        find.descendant(of: badge, matching: find.byType(DecoratedBox)),
      );
      final outer = decorations.first.decoration as BoxDecoration;
      final iconDisc = decorations.last.decoration as BoxDecoration;
      expect(outer.color, background);
      const scale = .67 * 1.15;
      expect(outer.borderRadius, BorderRadius.circular(8 * scale));
      expect(iconDisc.shape, BoxShape.circle);
      expect(tester.getSize(badge).height, closeTo(22 * scale, .1));
      expect(tester.getSize(badge).width, lessThan(150 * scale));
      expect(tester.widget<Icon>(find.byIcon(icon)).size, 12 * scale);
      expect(tester.widget<Text>(find.text(label)).style?.fontSize, 9 * scale);
      expect(
        tester.widget<Text>(find.text(label)).style?.fontWeight,
        FontWeight.w900,
      );
      expect(tester.widget<Text>(find.text(label)).textAlign, TextAlign.center);
      expect(
        tester.getCenter(find.text(label)).dy,
        closeTo(tester.getCenter(badge).dy, .1),
      );
      expect(
        tester.getCenter(find.byIcon(icon)).dy,
        closeTo(tester.getCenter(badge).dy, .1),
      );
      expect(
        find.descendant(of: badge, matching: find.byType(IgnorePointer)),
        findsOneWidget,
      );
      final semantic = tester.widget<Semantics>(
        find.descendant(of: badge, matching: find.byType(Semantics)).first,
      );
      expect(semantic.properties.label, label);
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in AppLanguage.values) {
    testWidgets('status badges fit narrow posters in ${language.code}', (
      tester,
    ) async {
      for (final width in [55.0, 100.0, 150.0]) {
        for (final textScale in [1.0, 2.0]) {
          await tester.pumpWidget(
            MaterialApp(
              locale: language.locale,
              supportedLocales: TetoLocalizations.supportedLocales,
              localizationsDelegates: const [
                TetoLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PosterAiringStatusBadge(status: 'RELEASING'),
                        PosterAiringStatusBadge(status: 'FINISHED'),
                        PosterAiringStatusBadge(status: 'NOT_YET_RELEASED'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final label in ['Airing', 'Finished', 'Unreleased']) {
            final localized = TetoLocalizations(language).text(label);
            expect(find.text(localized), findsOneWidget);
          }
          for (final badge in find.byType(PosterAiringStatusBadge).evaluate()) {
            expect(
              tester.getSize(find.byWidget(badge.widget)).width,
              lessThanOrEqualTo(width),
            );
          }
          expect(tester.takeException(), isNull);
        }
      }
    });
  }

  testWidgets('unknown status does not add an empty badge or icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PosterAiringStatusBadge(status: null),
              PosterAiringStatusBadge(status: 'UNKNOWN'),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Icon), findsNothing);
    expect(find.byType(Text), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
