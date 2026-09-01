import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/manga/application/manga_discord_presence.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('renders a remote page with its ephemeral request headers', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    final pageClient = _MemoryMangaPageFetchClient();
    final request = MangaReaderRequest(
      sourceId: 'remote-source',
      publicationId: 'remote-publication',
      chapterId: 'chapter-1',
      seriesTitle: 'Remote series',
      chapterTitle: 'Chapter 1',
      pages: [
        MangaReaderPage(
          id: 'remote-0',
          index: 0,
          resource: MangaRemotePageResource(
            uri: Uri.parse('https://reader.example.test/page-1.png'),
            headers: const {'Authorization': 'Bearer runtime-only'},
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      _readerHarness(
        request: request,
        roots: roots,
        pageFetchClient: pageClient,
      ),
    );
    await tester.pump();
    await tester.pump();
    await _allowImageWorkers(tester);

    expect(pageClient.lastResource, same(request.pages.single.resource));
    expect(
      pageClient.lastResource?.headers,
      containsPair('Authorization', 'Bearer runtime-only'),
    );
    final image = tester.widget<Image>(
      find.byKey(const ValueKey('manga-page-remote-0')),
    );
    final provider = image.image as ResizeImage;
    expect(provider.imageProvider, isA<MemoryImage>());
    expect(provider.width, inInclusiveRange(1, 4096));
  });

  testWidgets('resolves a trusted local page through app-owned roots', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    final pageFile = File(
      '${roots.downloadedPages.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}page-1.png',
    );
    pageFile.parent.createSync(recursive: true);
    pageFile.writeAsBytesSync(_transparentPng);
    final request = _localRequest(
      relativePaths: const ['chapter-1/page-1.png'],
    );

    await tester.pumpWidget(_readerHarness(request: request, roots: roots));
    await tester.pump();
    await _allowImageWorkers(tester);

    final image = tester.widget<Image>(
      find.byKey(const ValueKey('manga-page-local-0')),
    );
    final provider = image.image as ResizeImage;
    final fileProvider = provider.imageProvider as FileImage;
    expect(fileProvider.file.absolute.path, pageFile.absolute.path);
    expect(provider.width, inInclusiveRange(1, 4096));
  });

  testWidgets('D-pad movement follows right-to-left page direction', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 3);
    final request = _localRequest(
      relativePaths: const [
        'chapter-1/page-1.png',
        'chapter-1/page-2.png',
        'chapter-1/page-3.png',
      ],
    );

    await tester.pumpWidget(_readerHarness(request: request, roots: roots));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'manga.reader');
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('tap zones navigate RTL pages and center toggles the HUD', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 3);
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const [
            'chapter-1/page-1.png',
            'chapter-1/page-2.png',
            'chapter-1/page-3.png',
          ],
        ),
        roots: roots,
      ),
    );
    await tester.pump();
    final size = tester.getSize(find.byType(MangaReaderScreen));

    await tester.tapAt(Offset(size.width * .1, size.height * .5));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tapAt(Offset(size.width * .9, size.height * .5));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tapAt(Offset(size.width * .5, size.height * .5));
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });

  testWidgets('tap zones navigate continuous LTR reading in visual order', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 3);
    final preferences = _FixedMangaPreferencesController(
      const MangaReaderPreferences(
        loaded: true,
        mode: MangaReadingMode.vertical,
        direction: MangaReadingDirection.leftToRight,
        spreadMode: MangaSpreadMode.single,
        preloadPages: 0,
        keepScreenAwake: false,
        showDiscordTitle: false,
        bookAnimationEnabled: false,
      ),
    );
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const [
            'chapter-1/page-1.png',
            'chapter-1/page-2.png',
            'chapter-1/page-3.png',
          ],
        ),
        roots: roots,
        preferencesController: preferences,
      ),
    );
    await tester.pump();
    final size = tester.getSize(find.byType(MangaReaderScreen));

    await tester.tapAt(Offset(size.width * .9, size.height * .5));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tapAt(Offset(size.width * .1, size.height * .5));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('Back returns to the manga screen instead of leaving the app', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 1);
    final request = _localRequest(
      relativePaths: const ['chapter-1/page-1.png'],
    );
    final router = GoRouter(
      initialLocation: MangaReaderScreen.routePath,
      routes: [
        GoRoute(
          path: '/manga',
          builder: (_, _) => const Scaffold(
            body: SizedBox(key: ValueKey('manga-library-screen')),
          ),
        ),
        GoRoute(
          path: MangaReaderScreen.routePath,
          builder: (_, _) => MangaReaderScreen(request: request),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _readerScope(
        roots: roots,
        child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      platform: 'android',
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pump();
    await tester.pump();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/manga');
    expect(find.byKey(const ValueKey('manga-library-screen')), findsOneWidget);
  });

  testWidgets('D-pad reaches reader chrome and returns to page navigation', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 2);
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const ['chapter-1/page-1.png', 'chapter-1/page-2.png'],
        ),
        roots: roots,
      ),
    );
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'manga.reader');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'manga.reader.progress',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'manga.reader');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'manga.reader.back');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'manga.reader.settings',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'manga.reader.progress',
    );
  });

  testWidgets('preserves the exact page when reading mode changes', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 5);
    final preferences = _FixedMangaPreferencesController(
      const MangaReaderPreferences(
        loaded: true,
        spreadMode: MangaSpreadMode.double,
        coverStartsAlone: false,
        preloadPages: 0,
        keepScreenAwake: false,
        showDiscordTitle: false,
        bookAnimationEnabled: false,
      ),
    );
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const [
            'chapter-1/page-1.png',
            'chapter-1/page-2.png',
            'chapter-1/page-3.png',
            'chapter-1/page-4.png',
            'chapter-1/page-5.png',
          ],
        ),
        roots: roots,
        preferencesController: preferences,
      ),
    );
    await tester.pump();
    await tester.pump();

    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('manga-reader-progress')),
    );
    slider.onChanged!(3);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('4 / 5'), findsOneWidget);

    preferences.replace(
      preferences.state.copyWith(mode: MangaReadingMode.vertical),
    );
    await tester.pump();
    await tester.pump();
    await _allowImageWorkers(tester);
    expect(find.text('4 / 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-page-local-3')), findsOneWidget);

    preferences.replace(
      preferences.state.copyWith(mode: MangaReadingMode.paged),
    );
    await tester.pump();
    await tester.pump();
    await _allowImageWorkers(tester);
    expect(find.text('4 / 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-page-local-3')), findsOneWidget);
  });

  for (final direction in MangaReadingDirection.values) {
    testWidgets(
      'final double-page spread saves completion and its exact $direction anchor',
      (tester) async {
        final roots = _temporaryRoots();
        _writeLocalPages(roots, 4);
        final preferences = _FixedMangaPreferencesController(
          MangaReaderPreferences(
            loaded: true,
            direction: direction,
            spreadMode: MangaSpreadMode.double,
            coverStartsAlone: false,
            preloadPages: 0,
            keepScreenAwake: false,
            showDiscordTitle: false,
            bookAnimationEnabled: false,
          ),
        );
        final hub = _SilentMangaHubController();
        await tester.pumpWidget(
          _readerHarness(
            request: _localRequest(
              relativePaths: const [
                'chapter-1/page-1.png',
                'chapter-1/page-2.png',
                'chapter-1/page-3.png',
                'chapter-1/page-4.png',
              ],
            ),
            roots: roots,
            preferencesController: preferences,
            mangaHubController: hub,
          ),
        );
        await tester.pump();
        await tester.pump();
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('manga-reader-progress')),
        );
        slider.onChanged!(2);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('3 / 4'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 550));

        expect(hub.savedPageIndexes, <int>[2]);
        expect(hub.savedCompletion, <bool>[true]);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(hub.savedPageIndexes, <int>[2, 2]);
        expect(hub.savedCompletion, <bool>[true, true]);
      },
    );
  }

  testWidgets('leaving a final spread before debounce still saves completion', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 4);
    final hub = _SilentMangaHubController();
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const [
            'chapter-1/page-1.png',
            'chapter-1/page-2.png',
            'chapter-1/page-3.png',
            'chapter-1/page-4.png',
          ],
        ),
        roots: roots,
        preferencesController: _FixedMangaPreferencesController(
          const MangaReaderPreferences(
            loaded: true,
            spreadMode: MangaSpreadMode.double,
            coverStartsAlone: false,
            preloadPages: 0,
            keepScreenAwake: false,
            showDiscordTitle: false,
            bookAnimationEnabled: false,
          ),
        ),
        mangaHubController: hub,
      ),
    );
    await tester.pump();
    await tester.pump();
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('manga-reader-progress')),
    );
    slider.onChanged!(2);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3 / 4'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(hub.savedPageIndexes, <int>[2]);
    expect(hub.savedCompletion, <bool>[true]);
  });

  testWidgets('camera cutouts do not disable automatic double-page spreads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 4);
    final preferences = _FixedMangaPreferencesController(
      const MangaReaderPreferences(
        loaded: true,
        spreadMode: MangaSpreadMode.automatic,
        coverStartsAlone: false,
        preloadPages: 0,
        keepScreenAwake: false,
        showDiscordTitle: false,
        bookAnimationEnabled: false,
      ),
    );
    const displayFeatures = <DisplayFeature>[
      DisplayFeature(
        bounds: Rect.fromLTWH(540, 0, 120, 36),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      ),
    ];
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const [
            'chapter-1/page-1.png',
            'chapter-1/page-2.png',
            'chapter-1/page-3.png',
            'chapter-1/page-4.png',
          ],
        ),
        roots: roots,
        preferencesController: preferences,
        displayFeatures: displayFeatures,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('1 / 4'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3 / 4'), findsOneWidget);
  });

  testWidgets('a zero-width fold uses both open foldable panes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 4);
    final preferences = _FixedMangaPreferencesController(
      const MangaReaderPreferences(
        loaded: true,
        spreadMode: MangaSpreadMode.automatic,
        coverStartsAlone: false,
        preloadPages: 0,
        keepScreenAwake: false,
        showDiscordTitle: false,
        bookAnimationEnabled: false,
      ),
    );
    const displayFeatures = <DisplayFeature>[
      DisplayFeature(
        bounds: Rect.fromLTWH(350, 0, 0, 1000),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(
          relativePaths: const [
            'chapter-1/page-1.png',
            'chapter-1/page-2.png',
            'chapter-1/page-3.png',
            'chapter-1/page-4.png',
          ],
        ),
        roots: roots,
        preferencesController: preferences,
        displayFeatures: displayFeatures,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3 / 4'), findsOneWidget);
  });

  testWidgets('page semantics remain while hidden HUD controls are excluded', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 1);
    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(relativePaths: const ['chapter-1/page-1.png']),
        roots: roots,
      ),
    );
    await tester.pump();
    await tester.pump();
    await _allowImageWorkers(tester);
    expect(
      tester
          .widget<Image>(find.byKey(const ValueKey('manga-page-local-0')))
          .semanticLabel,
      'Manga page 1',
    );
    final position = tester.widget<Semantics>(
      find.byKey(const ValueKey('manga-reader-position-semantics')),
    );
    expect(position.properties.label, 'Page 1 of 1');
    expect(position.properties.liveRegion, isTrue);
    expect(
      tester
          .widget<ExcludeSemantics>(
            find.byKey(const ValueKey('manga-reader-chrome-semantics')),
          )
          .excluding,
      isFalse,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<Image>(find.byKey(const ValueKey('manga-page-local-0')))
          .semanticLabel,
      'Manga page 1',
    );
    expect(
      tester
          .widget<ExcludeSemantics>(
            find.byKey(const ValueKey('manga-reader-chrome-semantics')),
          )
          .excluding,
      isTrue,
    );
  });

  testWidgets('reader applies and clears the Android keep-awake flag', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('dev.tetotv/android_tv');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setMangaKeepScreenAwake') calls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 1);
    final preferences = _FixedMangaPreferencesController(
      const MangaReaderPreferences(
        loaded: true,
        spreadMode: MangaSpreadMode.single,
        preloadPages: 0,
        keepScreenAwake: true,
        showDiscordTitle: false,
        bookAnimationEnabled: false,
      ),
    );

    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(relativePaths: const ['chapter-1/page-1.png']),
        roots: roots,
        preferencesController: preferences,
      ),
    );
    await tester.pump();
    expect((calls.first.arguments as Map<Object?, Object?>)['enabled'], isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect((calls.last.arguments as Map<Object?, Object?>)['enabled'], isFalse);
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'Discord title sharing fails closed while persisted preferences load',
    (tester) async {
      final roots = _temporaryRoots();
      _writeLocalPages(roots, 1);
      final preferences = _DelayedMangaPreferencesController();
      final platform = _RecordingMangaDiscordPresencePlatform();

      await tester.pumpWidget(
        _readerHarness(
          request: _localRequest(relativePaths: const ['chapter-1/page-1.png']),
          roots: roots,
          preferencesController: preferences,
          mangaDiscordPlatform: platform,
          discordController: _ConnectedDiscordPresenceController(),
        ),
      );
      await tester.pump();

      expect(platform.titles, <String>['Reading manga']);
      expect(platform.chapterLabels, <String>['Private chapter']);

      preferences.completePersistedPrivacyLoad();
      await tester.pump();

      expect(platform.titles, <String>['Reading manga']);
      expect(platform.chapterLabels, <String>['Private chapter']);
    },
  );

  testWidgets('Discord title sharing resumes after an allowed setting loads', (
    tester,
  ) async {
    final roots = _temporaryRoots();
    _writeLocalPages(roots, 1);
    final preferences = _DelayedMangaPreferencesController();
    final platform = _RecordingMangaDiscordPresencePlatform();

    await tester.pumpWidget(
      _readerHarness(
        request: _localRequest(relativePaths: const ['chapter-1/page-1.png']),
        roots: roots,
        preferencesController: preferences,
        mangaDiscordPlatform: platform,
        discordController: _ConnectedDiscordPresenceController(),
      ),
    );
    await tester.pump();

    preferences.completePersistedPrivacyLoad(shareTitle: true);
    await tester.pump();

    expect(platform.titles, <String>['Reading manga', 'Local series']);
    expect(platform.chapterLabels, <String>['Private chapter', 'Chapter 1']);
  });
}

Future<void> _allowImageWorkers(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pump();
}

Widget _readerHarness({
  required MangaReaderRequest request,
  required MangaStorageRoots roots,
  MangaPageFetchClient? pageFetchClient,
  MangaReaderPreferencesController? preferencesController,
  MangaDiscordPresencePlatform? mangaDiscordPlatform,
  DiscordPresenceController? discordController,
  MangaHubController? mangaHubController,
  List<DisplayFeature> displayFeatures = const <DisplayFeature>[],
}) => _readerScope(
  roots: roots,
  pageFetchClient: pageFetchClient,
  preferencesController: preferencesController,
  mangaDiscordPlatform: mangaDiscordPlatform,
  discordController: discordController,
  mangaHubController: mangaHubController,
  child: MaterialApp(
    theme: AppTheme.dark,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(displayFeatures: displayFeatures),
        child: MangaReaderScreen(request: request),
      ),
    ),
  ),
);

Widget _readerScope({
  required MangaStorageRoots roots,
  required Widget child,
  MangaPageFetchClient? pageFetchClient,
  MangaReaderPreferencesController? preferencesController,
  MangaDiscordPresencePlatform? mangaDiscordPlatform,
  DiscordPresenceController? discordController,
  MangaHubController? mangaHubController,
}) => ProviderScope(
  overrides: [
    mangaReaderPreferencesProvider.overrideWith(
      (_) =>
          preferencesController ??
          _FixedMangaPreferencesController(
            const MangaReaderPreferences(
              loaded: true,
              spreadMode: MangaSpreadMode.single,
              preloadPages: 0,
              keepScreenAwake: false,
              showDiscordTitle: false,
              bookAnimationEnabled: false,
            ),
          ),
    ),
    mangaStorageRootsProvider.overrideWith((_) async => roots),
    mangaPageFetchClientProvider.overrideWithValue(
      pageFetchClient ?? _MemoryMangaPageFetchClient(),
    ),
    mangaHubControllerProvider.overrideWith(
      (_) => mangaHubController ?? _SilentMangaHubController(),
    ),
    discordPresencePlatformProvider.overrideWithValue(
      _SilentDiscordPresencePlatform(),
    ),
    if (discordController != null)
      discordPresenceControllerProvider.overrideWith((_) => discordController),
    mangaDiscordPresencePlatformProvider.overrideWithValue(
      mangaDiscordPlatform ?? _SilentMangaDiscordPresencePlatform(),
    ),
  ],
  child: child,
);

MangaReaderRequest _localRequest({required List<String> relativePaths}) =>
    MangaReaderRequest(
      sourceId: 'local-source',
      publicationId: 'local-publication',
      chapterId: 'chapter-1',
      seriesTitle: 'Local series',
      chapterTitle: 'Chapter 1',
      pages: [
        for (var index = 0; index < relativePaths.length; index += 1)
          MangaReaderPage(
            id: 'local-$index',
            index: index,
            resource: MangaTrustedLocalPageResource(
              area: MangaLocalStorageArea.downloadedPages,
              relativePath: relativePaths[index],
            ),
          ),
      ],
    );

MangaStorageRoots _temporaryRoots() {
  final root = Directory.systemTemp.createTempSync('tetotv-reader-test-');
  addTearDown(() async {
    imageCache
      ..clear()
      ..clearLiveImages();
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        if (await root.exists()) await root.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  });
  final downloaded = Directory(
    '${root.path}${Platform.pathSeparator}downloaded',
  );
  final extracted = Directory('${root.path}${Platform.pathSeparator}extracted');
  downloaded.createSync(recursive: true);
  extracted.createSync(recursive: true);
  return MangaStorageRoots(
    downloadedPages: downloaded,
    extractedArchives: extracted,
  );
}

void _writeLocalPages(MangaStorageRoots roots, int count) {
  for (var index = 0; index < count; index += 1) {
    final file = File(
      '${roots.downloadedPages.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}page-${index + 1}.png',
    );
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_transparentPng);
  }
}

final _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _FixedMangaPreferencesController
    extends MangaReaderPreferencesController {
  _FixedMangaPreferencesController(MangaReaderPreferences preferences)
    : super(const FlutterSecureStorage()) {
    state = preferences;
  }

  void replace(MangaReaderPreferences preferences) => state = preferences;
}

class _DelayedMangaPreferencesController
    extends MangaReaderPreferencesController {
  _DelayedMangaPreferencesController() : super(const FlutterSecureStorage()) {
    state = const MangaReaderPreferences(
      loaded: false,
      showDiscordTitle: true,
      keepScreenAwake: false,
      preloadPages: 0,
      spreadMode: MangaSpreadMode.single,
      bookAnimationEnabled: false,
    );
  }

  void completePersistedPrivacyLoad({bool shareTitle = false}) {
    state = state.copyWith(loaded: true, showDiscordTitle: shareTitle);
  }
}

class _MemoryMangaPageFetchClient extends MangaPageFetchClient {
  MangaRemotePageResource? lastResource;

  @override
  Future<Uint8List> fetch(MangaRemotePageResource resource) async {
    lastResource = resource;
    return _transparentPng;
  }
}

class _SilentMangaHubController extends MangaHubController {
  factory _SilentMangaHubController() {
    final credentials = MangaSourceCredentialStore(
      const FlutterSecureStorage(),
    );
    return _SilentMangaHubController._(credentials);
  }

  _SilentMangaHubController._(MangaSourceCredentialStore credentials)
    : super(
        client: MangaCatalogClient(credentials: credentials),
        credentials: credentials,
        store: MangaStore(
          databaseProvider: () => throw UnsupportedError('No test database.'),
          credentials: credentials,
        ),
        ownerKey: () async => 'test-owner',
      );

  final List<int> savedPageIndexes = <int>[];
  final List<bool> savedCompletion = <bool>[];

  @override
  Future<bool> initialize() async => true;

  @override
  Future<bool> saveProgress(
    MangaReaderRequest request, {
    required int pageIndex,
    double pageOffset = 0,
    bool completed = false,
  }) async {
    savedPageIndexes.add(pageIndex);
    savedCompletion.add(completed);
    return true;
  }
}

class _SilentDiscordPresencePlatform implements DiscordPresencePlatform {
  @override
  Stream<DiscordBridgeEvent> get events => Stream<DiscordBridgeEvent>.empty();

  @override
  Future<Map<Object?, Object?>> sdkInfo() async => const {
    'available': false,
    'status': 'disconnected',
  };

  @override
  Future<DiscordTokenBundle> authenticate() => throw UnimplementedError();

  @override
  Future<void> cancelAuthentication() async {}

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) =>
      throw UnimplementedError();

  @override
  Future<void> connect(DiscordTokenBundle token) async {}

  @override
  Future<bool> revoke(String token) async => true;

  @override
  Future<void> disconnect() async {}
}

class _ConnectedDiscordPresenceController extends DiscordPresenceController {
  _ConnectedDiscordPresenceController()
    : super(const FlutterSecureStorage(), _PendingDiscordPresencePlatform()) {
    state = const DiscordPresenceState(
      loaded: true,
      available: true,
      linked: true,
      enabled: true,
      connectionStatus: 'ready',
    );
  }
}

class _PendingDiscordPresencePlatform extends _SilentDiscordPresencePlatform {
  @override
  Future<Map<Object?, Object?>> sdkInfo() =>
      Completer<Map<Object?, Object?>>().future;
}

class _SilentMangaDiscordPresencePlatform
    implements MangaDiscordPresencePlatform {
  @override
  Future<void> updateReading({
    required String title,
    required String chapterLabel,
    required int page,
    required int pageCount,
  }) async {}

  @override
  Future<void> clear() async {}
}

class _RecordingMangaDiscordPresencePlatform
    implements MangaDiscordPresencePlatform {
  final titles = <String>[];
  final chapterLabels = <String>[];

  @override
  Future<void> updateReading({
    required String title,
    required String chapterLabel,
    required int page,
    required int pageCount,
  }) async {
    titles.add(title);
    chapterLabels.add(chapterLabel);
  }

  @override
  Future<void> clear() async {}
}
