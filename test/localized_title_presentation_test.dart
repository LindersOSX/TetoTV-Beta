import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/features/catalog/application/localized_anime_title_provider.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_grid.dart';
import 'package:anime_tv/features/catalog/presentation/localized_anime_title.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _delegates = <LocalizationsDelegate<dynamic>>[
  TetoLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

void main() {
  testWidgets('non-English UI never requests translated title metadata', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    var lookups = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizedAnimeTitleProvider.overrideWith((_, _) async {
            lookups++;
            return 'Título localizado';
          }),
        ],
        child: MaterialApp(
          locale: const Locale('es'),
          supportedLocales: TetoLocalizations.supportedLocales,
          localizationsDelegates: _delegates,
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => show
                  ? const LocalizedAnimeTitle('Original title', aniListId: 123)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsOneWidget);
    expect(lookups, 0);
    visible.value = false;
    await tester.pumpAndSettle();
    visible.value = true;
    await tester.pumpAndSettle();
    expect(lookups, 0);
    expect(find.text('Original title'), findsOneWidget);
    expect(find.text('Título localizado'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching UI language keeps the supplied title unchanged', (
    tester,
  ) async {
    final language = ValueNotifier(AppLanguage.spanish);
    addTearDown(language.dispose);
    final requests = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizedAnimeTitleProvider.overrideWith((_, request) async {
            requests.add(request.language);
            return 'Must not be shown';
          }),
        ],
        child: ValueListenableBuilder<AppLanguage>(
          valueListenable: language,
          builder: (_, current, _) => MaterialApp(
            locale: current.locale,
            supportedLocales: TetoLocalizations.supportedLocales,
            localizationsDelegates: _delegates,
            home: const Scaffold(
              body: LocalizedAnimeTitle('Original title', aniListId: 17),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsOneWidget);
    language.value = AppLanguage.french;
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsOneWidget);
    language.value = AppLanguage.english;
    await tester.pumpAndSettle();
    expect(find.text('Original title'), findsOneWidget);
    expect(find.text('Must not be shown'), findsNothing);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Spanish UI keeps the Title Language result and AniList navigation ID',
    (tester) async {
      const anime = AnimeSummary(
        id: 123,
        title: 'Canonical title',
        description: '',
        episodes: 12,
        score: null,
      );
      final requests = <LocalizedAnimeTitleRequest>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: CatalogGrid(
                items: [anime],
                titlePreference: TitleLanguagePreference.english,
              ),
            ),
          ),
          GoRoute(
            path: '/anime/:id',
            builder: (_, state) =>
                Scaffold(body: Text('ID:${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizedAnimeTitleProvider.overrideWith((_, request) async {
              requests.add(request);
              return 'Título de prueba';
            }),
          ],
          child: MaterialApp.router(
            locale: const Locale('es'),
            supportedLocales: TetoLocalizations.supportedLocales,
            localizationsDelegates: _delegates,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Canonical title'), findsOneWidget);
      expect(find.text('Título de prueba'), findsNothing);
      expect(requests, isEmpty);
      expect(anime.title, 'Canonical title');
      await tester.tap(find.text('Canonical title'));
      await tester.pumpAndSettle();
      expect(find.text('ID:123'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final id in <int?>[null, 0, -1]) {
    testWidgets(
      'missing AniList ID $id keeps external title verbatim without lookup',
      (tester) async {
        var requests = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localizedAnimeTitleProvider.overrideWith((_, _) async {
                requests++;
                return 'Must not be used';
              }),
            ],
            child: MaterialApp(
              locale: const Locale('es'),
              supportedLocales: TetoLocalizations.supportedLocales,
              localizationsDelegates: _delegates,
              home: Scaffold(body: LocalizedAnimeTitle('Back', aniListId: id)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Back'), findsOneWidget);
        expect(requests, 0);
      },
    );
  }

  testWidgets(
    'title wrapper preserves the supplied title and text layout contract',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizedAnimeTitleProvider.overrideWith((_, _) async => null),
          ],
          child: MaterialApp(
            locale: const Locale('es'),
            supportedLocales: TetoLocalizations.supportedLocales,
            localizationsDelegates: _delegates,
            home: const Scaffold(
              body: LocalizedAnimeTitle(
                'Original title',
                aniListId: 99,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('Original title'));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.style?.fontSize, 17);
    },
  );

  testWidgets(
    'status badge translates only display text, retaining canonical status labels',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          supportedLocales: TetoLocalizations.supportedLocales,
          localizationsDelegates: _delegates,
          home: const Scaffold(
            body: Column(
              children: [
                PosterAiringStatusBadge(status: 'RELEASING'),
                PosterAiringStatusBadge(status: 'FINISHED'),
                PosterAiringStatusBadge(status: 'NOT_YET_RELEASED'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final status in ['AIRING', 'FINISHED', 'UNRELEASED']) {
        final translated = const TetoLocalizations(
          AppLanguage.spanish,
        ).text(status);
        expect(translated, isNot(status));
        expect(find.text(translated), findsOneWidget);
        expect(find.text(status), findsNothing);
      }
      expect(animeAiringStatusLabel('RELEASING'), 'AIRING');
      expect(animeAiringStatusLabel('FINISHED'), 'FINISHED');
      expect(animeAiringStatusLabel('NOT_YET_RELEASED'), 'UNRELEASED');
    },
  );
}
