import 'dart:io';

import 'package:anime_tv/features/aniyomi/application/aniyomi_controller.dart';
import 'package:anime_tv/features/manga/application/manga_feature_availability.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/presentation/developer_manga_gate.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('core reader waits for Manga and Experimental options', (
    tester,
  ) async {
    final settings = _MutableSettingsController(
      const SettingsPreferences(loaded: false, mangaReaderEnabled: true),
    );
    final update = _MutableAppUpdateController(
      const AppUpdateState(loaded: false, developerMode: true),
    );
    final router = _router(_request());
    addTearDown(router.dispose);

    await _pump(tester, router, settings: settings, update: update);

    expect(
      find.byKey(const ValueKey('manga-feature-gate-loading')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);

    settings.replace(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: true),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
    update.replace(const AppUpdateState(loaded: true, developerMode: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-reader-content')), findsOneWidget);

    update.replace(const AppUpdateState(loaded: true, developerMode: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
  });

  testWidgets('core reader opens when both switches are enabled', (
    tester,
  ) async {
    final settings = _MutableSettingsController(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: true),
    );
    final update = _MutableAppUpdateController(
      const AppUpdateState(loaded: true, developerMode: true),
    );
    final router = _router(_request());
    addTearDown(router.dispose);

    await _pump(tester, router, settings: settings, update: update);

    expect(find.byKey(const ValueKey('manga-reader-content')), findsOneWidget);
  });

  testWidgets('either switch revokes an already-open core reader', (
    tester,
  ) async {
    final settings = _MutableSettingsController(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: true),
    );
    final update = _MutableAppUpdateController(
      const AppUpdateState(loaded: true, developerMode: true),
    );
    final router = _router(_request());
    addTearDown(router.dispose);

    await _pump(tester, router, settings: settings, update: update);
    expect(find.byKey(const ValueKey('manga-reader-content')), findsOneWidget);

    update.replace(const AppUpdateState(loaded: true, developerMode: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
    update.replace(const AppUpdateState(loaded: true, developerMode: true));
    await tester.pump();
    settings.replace(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
    expect(find.text('Manga is disabled in Settings.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
  });

  test('core feature work requires Manga preference and experiments', () {
    final settings = _MutableSettingsController(const SettingsPreferences());
    final update = _MutableAppUpdateController(const AppUpdateState());
    final container = ProviderContainer(
      overrides: [
        settingsPreferencesProvider.overrideWith((_) => settings),
        appUpdateControllerProvider.overrideWith((_) => update),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(mangaFeatureAvailableProvider), isFalse);
    settings.replace(const SettingsPreferences(loaded: true));
    expect(container.read(mangaFeatureAvailableProvider), isFalse);
    update.replace(const AppUpdateState(loaded: true, developerMode: true));
    expect(container.read(mangaFeatureAvailableProvider), isTrue);
    settings.replace(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
    );
    expect(container.read(mangaFeatureAvailableProvider), isFalse);
  });

  test('Aniyomi Manga runtime still requires both independent gates', () {
    final settings = _MutableSettingsController(const SettingsPreferences());
    final update = _MutableAppUpdateController(const AppUpdateState());
    final container = ProviderContainer(
      overrides: [
        settingsPreferencesProvider.overrideWith((_) => settings),
        appUpdateControllerProvider.overrideWith((_) => update),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(aniyomiMangaEnabledProvider), isFalse);
    settings.replace(const SettingsPreferences(loaded: true));
    expect(container.read(mangaFeatureAvailableProvider), isFalse);
    expect(container.read(aniyomiMangaEnabledProvider), isFalse);
    update.replace(const AppUpdateState(loaded: true, developerMode: false));
    expect(container.read(aniyomiMangaEnabledProvider), isFalse);
    update.replace(const AppUpdateState(loaded: true, developerMode: true));
    expect(container.read(aniyomiMangaEnabledProvider), isTrue);
    settings.replace(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
    );
    expect(container.read(aniyomiMangaEnabledProvider), isFalse);
    expect(container.read(aniyomiEnabledProvider), isTrue);
    settings.replace(const SettingsPreferences(loaded: true));
    expect(container.read(aniyomiMangaEnabledProvider), isTrue);
    update.replace(const AppUpdateState(loaded: true, developerMode: false));
    expect(container.read(aniyomiMangaEnabledProvider), isFalse);
    expect(container.read(mangaFeatureAvailableProvider), isFalse);
  });

  test(
    'reserved Aniyomi source identity cannot lose experimental provenance',
    () {
      final inferred = _request(sourceId: 'ANIYOMI.source-digest');
      final explicit = _request(
        sourceId: 'future-native-source',
        origin: MangaReaderOrigin.aniyomiExperimental,
      );

      expect(inferred.origin, MangaReaderOrigin.aniyomiExperimental);
      expect(inferred.requiresDeveloperMode, isTrue);
      expect(explicit.requiresDeveloperMode, isTrue);
      expect(_request().requiresDeveloperMode, isFalse);
    },
  );

  testWidgets(
    'Aniyomi reader still requires loaded Developer Mode and the Manga preference',
    (tester) async {
      final settings = _MutableSettingsController(
        const SettingsPreferences(loaded: true, mangaReaderEnabled: true),
      );
      final update = _MutableAppUpdateController(
        const AppUpdateState(loaded: false, developerMode: true),
      );
      final router = _router(_request(sourceId: 'aniyomi.source-digest'));
      addTearDown(router.dispose);

      await _pump(tester, router, settings: settings, update: update);
      expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
      expect(
        find.byKey(const ValueKey('manga-feature-gate-loading')),
        findsOneWidget,
      );

      update.replace(const AppUpdateState(loaded: true, developerMode: false));
      await tester.pump();
      expect(
        find.text('Manga reader requires Experimental options to be enabled.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
      await tester.pumpAndSettle();

      update.replace(const AppUpdateState(loaded: true, developerMode: true));
      router.go('/manga/read');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('manga-reader-content')),
        findsOneWidget,
      );

      update.replace(const AppUpdateState(loaded: true, developerMode: false));
      await tester.pump();
      expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
      expect(
        find.byKey(const ValueKey('manga-feature-gate-closed')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();

      update.replace(const AppUpdateState(loaded: true, developerMode: true));
      router.go('/manga/read');
      await tester.pumpAndSettle();
      settings.replace(
        const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('manga-reader-content')), findsNothing);
      expect(find.text('Manga is disabled in Settings.'), findsOneWidget);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  GoRouter router, {
  required _MutableSettingsController settings,
  required _MutableAppUpdateController update,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsPreferencesProvider.overrideWith((_) => settings),
        appUpdateControllerProvider.overrideWith((_) => update),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
}

GoRouter _router(MangaReaderRequest request) => GoRouter(
  initialLocation: '/manga/read',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          const Scaffold(body: SizedBox(key: ValueKey('home-content'))),
    ),
    GoRoute(
      path: '/manga/read',
      builder: (_, _) => MangaReaderRouteGate(
        request: request,
        child: const Scaffold(
          body: SizedBox(key: ValueKey('manga-reader-content')),
        ),
      ),
    ),
  ],
);

MangaReaderRequest _request({
  String sourceId = 'seanime.source',
  MangaReaderOrigin origin = MangaReaderOrigin.core,
}) => MangaReaderRequest(
  sourceId: sourceId,
  origin: origin,
  publicationId: 'publication',
  chapterId: 'chapter',
  seriesTitle: 'Series',
  chapterTitle: 'Chapter 1',
  pages: [
    MangaReaderPage(
      id: 'page-1',
      index: 0,
      resource: MangaRemotePageResource(
        uri: Uri.parse('https://example.com/page.jpg'),
      ),
    ),
  ],
);

class _MutableSettingsController extends SettingsPreferencesController {
  _MutableSettingsController(SettingsPreferences initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  void replace(SettingsPreferences next) => state = next;

  @override
  Future<void> load() async {}
}

class _MutableAppUpdateController extends AppUpdateController {
  _MutableAppUpdateController(AppUpdateState initial)
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => initial.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = initial;
  }

  void replace(AppUpdateState next) => state = next;
}

class _UnusedReleaseSource extends AppReleaseSource {
  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) =>
      throw UnimplementedError();

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => throw UnimplementedError();
}
