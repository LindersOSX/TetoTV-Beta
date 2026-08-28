import 'package:anime_tv/app/app.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ordinary settings writes do not reconstruct or animate theme', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isTelevisionProvider.overrideWithValue(true),
          trendingAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          seasonalAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          trackingHomeProvider.overrideWith(
            (_) => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const TetoTvApp(),
      ),
    );
    await tester.pumpAndSettle();

    final materialFinder = find.byType(MaterialApp);
    final before = tester.widget<MaterialApp>(materialFinder);
    final textColorBefore = before.theme!.textTheme.titleMedium!.color;
    final container = ProviderScope.containerOf(tester.element(materialFinder));

    await container
        .read(settingsPreferencesProvider.notifier)
        .setNavigationSounds(false);
    await tester.pump();

    final after = tester.widget<MaterialApp>(materialFinder);
    expect(identical(after, before), isTrue);
    expect(after.themeAnimationDuration, Duration.zero);
    expect(after.theme!.brightness, Brightness.dark);
    expect(after.theme!.textTheme.titleMedium!.color, textColorBefore);
    expect(textColorBefore, isNot(Colors.black));
    expect(tester.takeException(), isNull);
  });
}
