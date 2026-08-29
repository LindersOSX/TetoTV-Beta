import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/franchise_watch_order.dart';
import 'package:anime_tv/features/catalog/presentation/franchise_screen.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows numbered relation badges and preferred-language titles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const entries = [
      FranchiseWatchOrderEntry(
        anime: AnimeSummary(
          id: 1,
          title: 'Fallback first',
          titleEnglish: 'English first',
          titleRomaji: 'Romaji first',
          description: '',
          episodes: 12,
          score: 8,
          format: 'TV',
        ),
        relationRole: FranchiseRelationRole.current,
      ),
      FranchiseWatchOrderEntry(
        anime: AnimeSummary(
          id: 2,
          title: 'Fallback movie',
          titleEnglish: 'English movie',
          titleRomaji: 'Romaji movie',
          description: '',
          episodes: 1,
          score: 8,
          format: 'MOVIE',
        ),
        relationRole: FranchiseRelationRole.sequel,
      ),
      FranchiseWatchOrderEntry(
        anime: AnimeSummary(
          id: 3,
          title: 'Fallback OVA',
          titleEnglish: 'English OVA',
          titleRomaji: 'Romaji OVA',
          description: '',
          episodes: 1,
          score: 8,
          format: 'OVA',
        ),
        relationRole: FranchiseRelationRole.sideStory,
      ),
      FranchiseWatchOrderEntry(
        anime: AnimeSummary(
          id: 4,
          title: 'Fallback special',
          titleEnglish: 'English special',
          titleRomaji: 'Romaji special',
          description: '',
          episodes: 1,
          score: 8,
          format: 'SPECIAL',
        ),
        relationRole: FranchiseRelationRole.spinOff,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          franchiseProvider(1).overrideWith((_) async => entries),
          titleLanguagePreferenceProvider.overrideWith(
            (_) =>
                _StaticTitleLanguageController(TitleLanguagePreference.romaji),
          ),
        ],
        child: const MaterialApp(home: FranchiseScreen(mediaId: 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recommended watch order'), findsOneWidget);
    expect(find.text('Romaji first'), findsOneWidget);
    expect(find.text('Romaji movie'), findsOneWidget);
    expect(find.text('English first'), findsNothing);
    expect(find.text('#1 · TV · Current'), findsOneWidget);
    expect(find.text('#2 · Movie · Sequel'), findsOneWidget);
    expect(find.text('#3 · OVA · Side story'), findsOneWidget);
    expect(find.text('#4 · Special · Spin-off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _StaticTitleLanguageController extends TitleLanguagePreferenceController {
  _StaticTitleLanguageController(TitleLanguagePreference initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}
