import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/discover_screen.dart';
import 'package:anime_tv/features/home/presentation/home_screen.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:anime_tv/features/tracking/presentation/my_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final palette = AppThemePalette.fromSeeds(
    background: const Color(0xFF112233),
    surface: const Color(0xFF223344),
    accent: const Color(0xFF00CC88),
    primaryText: const Color(0xFFF4FAFF),
    mutedText: const Color(0xFFAABCCC),
  );

  testWidgets('Home uses the saved Theme Studio palette', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    await _setTvSize(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trendingAnimeProvider.overrideWith((_) async => const []),
          seasonalAnimeProvider.overrideWith((_) async => const []),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      palette.background,
    );
    final hero = tester.widget<Container>(
      find.byKey(const ValueKey('home-hero')),
    );
    expect((hero.decoration! as BoxDecoration).color, palette.surface);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Discover uses the saved Theme Studio palette', (tester) async {
    await _setTvSize(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogClientProvider.overrideWithValue(_EmptyCatalog())],
        child: MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: const DiscoverScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      palette.background,
    );
    final emptyMessage = tester.widget<Text>(
      find.text('No anime matched these filters.'),
    );
    expect(emptyMessage.style?.color, palette.mutedText);
  });

  testWidgets('My List uses the saved Theme Studio palette', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await _setTvSize(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trackingListProvider(
            TrackingListStatus.watching,
          ).overrideWith((_) async => const TrackingListResult(items: [])),
        ],
        child: MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: const MyListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      palette.background,
    );
    final guidance = tester.widget<Text>(
      find.textContaining('Select to view episodes.'),
    );
    expect(guidance.style?.color, palette.mutedText);
  });
}

Future<void> _setTvSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _EmptyCatalog extends AniListCatalogClient {
  @override
  Future<List<AnimeSummary>> discover(
    CatalogFilters filters, {
    int page = 1,
  }) async => const [];
}
