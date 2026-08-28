import 'dart:async';

import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_collection_screen.dart';
import 'package:anime_tv/features/catalog/presentation/credits_screen.dart';
import 'package:anime_tv/features/catalog/presentation/franchise_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty collection and franchise screens start on Back', (
    tester,
  ) async {
    await _pump(
      tester,
      overrides: [studioAnimeProvider(1).overrideWith((_) async => const [])],
      child: const CatalogCollectionScreen(
        id: 1,
        name: 'Example studio',
        type: CatalogCollectionType.studio,
      ),
    );
    _expectFirstControlFocused(tester);

    await _pump(
      tester,
      overrides: [franchiseProvider(1).overrideWith((_) async => const [])],
      child: const FranchiseScreen(mediaId: 1),
    );
    _expectFirstControlFocused(tester);
  });

  testWidgets('credits starts on Back when no cast entries are available', (
    tester,
  ) async {
    await _pump(
      tester,
      overrides: [
        animeDetailsProvider(1).overrideWith(
          (_) async => const AnimeSummary(
            id: 1,
            title: 'Example anime',
            description: '',
            episodes: 1,
            score: 8,
          ),
        ),
      ],
      child: const CreditsScreen(mediaId: 1),
    );
    _expectFirstControlFocused(tester);
  });

  testWidgets('credits keeps a focused Back control while loading', (
    tester,
  ) async {
    final pending = Completer<AnimeSummary>();
    await _pumpWithoutSettling(
      tester,
      overrides: [animeDetailsProvider(1).overrideWith((_) => pending.future)],
      child: const CreditsScreen(mediaId: 1),
    );

    expect(find.byKey(const ValueKey('credits-back')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    _expectFirstControlFocused(tester);
  });

  testWidgets('credits keeps a focused Back control after an error', (
    tester,
  ) async {
    await _pump(
      tester,
      overrides: [
        animeDetailsProvider(1).overrideWith(
          (_) => Future<AnimeSummary>.error(StateError('offline')),
        ),
      ],
      child: const CreditsScreen(mediaId: 1),
    );

    expect(find.textContaining('Could not load credits'), findsOneWidget);
    _expectFirstControlFocused(tester);
  });

  testWidgets(
    'character cards without an English voice actor are not focusable',
    (tester) async {
      await _pump(
        tester,
        overrides: [
          animeDetailsProvider(1).overrideWith(
            (_) async => const AnimeSummary(
              id: 1,
              title: 'Example anime',
              description: '',
              episodes: 1,
              score: 8,
              characters: [
                AnimeCharacter(id: 7, name: 'Silent card', role: 'MAIN'),
              ],
            ),
          ),
        ],
        child: const CreditsScreen(mediaId: 1),
      );

      expect(find.text('Silent card'), findsOneWidget);
      expect(find.byType(TvFocusable), findsOneWidget);
      _expectFirstControlFocused(tester);
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<Override> overrides,
  required Widget child,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: MaterialApp(home: TvShortcuts(child: child)),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _pumpWithoutSettling(
  WidgetTester tester, {
  required List<Override> overrides,
  required Widget child,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: MaterialApp(home: TvShortcuts(child: child)),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void _expectFirstControlFocused(WidgetTester tester) {
  final detector = find.descendant(
    of: find.byType(TvFocusable).first,
    matching: find.byType(FocusableActionDetector),
  );
  expect(
    tester.widget<FocusableActionDetector>(detector).focusNode?.hasFocus,
    isTrue,
  );
}
