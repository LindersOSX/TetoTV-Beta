import 'package:anime_tv/features/catalog/application/localized_anime_description_provider.dart';
import 'package:anime_tv/features/catalog/presentation/localized_anime_description.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('replaces the fallback when selected-language metadata arrives', (
    tester,
  ) async {
    LocalizedAnimeDescriptionRequest? request;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizedAnimeDescriptionProvider.overrideWith((_, value) async {
            request = value;
            return 'Descripción localizada.';
          }),
        ],
        child: const MaterialApp(
          home: LocalizedAnimeDescription(
            aniListId: 154587,
            language: 'es',
            fallbackDescription: 'English fallback.',
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

    expect(find.text('English fallback.'), findsOneWidget);
    await tester.pump();
    expect(find.text('Descripción localizada.'), findsOneWidget);
    expect(request, (aniListId: 154587, language: 'es'));
  });

  testWidgets('English always keeps the catalog synopsis without a lookup', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizedAnimeDescriptionProvider.overrideWith((_, _) async {
            calls++;
            return 'Must not render';
          }),
        ],
        child: const MaterialApp(
          home: LocalizedAnimeDescription(
            aniListId: 1,
            language: 'en',
            fallbackDescription: 'Canonical English synopsis.',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Canonical English synopsis.'), findsOneWidget);
    expect(find.text('Must not render'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('missing localized metadata retains the safe catalog fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizedAnimeDescriptionProvider.overrideWith((_, _) async => null),
        ],
        child: const MaterialApp(
          home: LocalizedAnimeDescription(
            aniListId: 1,
            language: 'fr',
            fallbackDescription: 'Existing synopsis.',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Existing synopsis.'), findsOneWidget);
  });
}
