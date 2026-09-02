import 'dart:async';
import 'dart:io';

import 'package:anime_tv/app/router.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/manga/application/manga_acquisition_controller.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_acquisition_service.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_screen.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_screen.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDown(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('real /manga route shows the empty profile-local Library', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 844));
    addTearDown(() => _resetViewport(tester));
    addTearDown(() => appRouter.go('/'));
    final controller = _TestMangaHubController(MangaHubState());

    appRouter.go('/manga');
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(controller, isTelevision: false),
        child: MaterialApp.router(
          theme: AppTheme.dark,
          routerConfig: appRouter,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(appRouter.routeInformationProvider.value.uri.path, '/manga');
    expect(find.byKey(const ValueKey('manga-library')), findsOneWidget);
    expect(find.text('Your manga library is empty'), findsOneWidget);
    expect(
      find.text(
        'Browse a source and save titles here. Library and reading progress stay on this device and profile.',
      ),
      findsOneWidget,
    );
    expect(find.text('DEVELOPER PREVIEW'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Sources explains user-added-only policy and opens a blank form',
    (tester) async {
      _setViewport(tester, const Size(1280, 720));
      addTearDown(() => _resetViewport(tester));
      final controller = _TestMangaHubController(MangaHubState());
      await _pumpScreen(tester, controller, isTelevision: true);

      await tester.tap(
        find.byKey(const ValueKey('manga-section-sources')),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.byKey(const ValueKey('manga-sources')), findsOneWidget);
      expect(find.text('Your sources, your library'), findsOneWidget);
      expect(
        find.textContaining('never executes manga source code'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('No sources added', skipOffstage: false),
        180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('manga-sources-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No sources added'), findsOneWidget);
      expect(
        find.textContaining('Nothing is bundled or recommended by TetoTV.'),
        findsOneWidget,
      );
      expect(controller.state.sources, isEmpty);

      await tester.scrollUntilVisible(
        find.text('Add source', skipOffstage: false).first,
        -180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('manga-sources-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add source').first, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Add manga source'), findsOneWidget);
      expect(
        find.textContaining('TetoTV does not provide a source list.'),
        findsOneWidget,
      );
      final input = tester.widget<TvTextInput>(find.byType(TvTextInput).last);
      expect(input.controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Browse chooses an added catalog then shows publication cards', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 720));
    addTearDown(() => _resetViewport(tester));
    final source = _source();
    final publication = MangaPublication(
      identifier: 'urn:test:volume-one',
      title: 'Volume One',
      authors: const <MangaContributor>[
        MangaContributor(name: 'Example Author'),
      ],
      languages: const <String>['en'],
      subjects: const <String>['Adventure'],
    );
    final feed = MangaCatalogFeed(
      protocol: MangaSourceProtocol.opds2,
      documentUri: source.uri,
      title: 'My OPDS shelf',
      publications: <MangaPublication>[publication],
    );
    final controller = _TestMangaHubController(
      MangaHubState(sources: <StoredMangaSource>[source]),
      feeds: <String, MangaCatalogFeed>{source.id: feed},
    );
    await _pumpScreen(tester, controller, isTelevision: true);

    await tester.tap(
      find.byKey(const ValueKey('manga-section-browse')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byKey(const ValueKey('manga-source-picker')), findsOneWidget);
    expect(find.text('Choose a catalog'), findsOneWidget);
    expect(find.text('Only sources you add are shown here.'), findsOneWidget);
    expect(
      find.byKey(ValueKey('manga-open-source-${source.id}')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(ValueKey('manga-open-source-${source.id}')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('My OPDS shelf'), findsOneWidget);
    expect(find.text('Volume One'), findsOneWidget);
    expect(find.text('Example Author'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey('manga-publication-${mangaPublicationStableId(publication)}'),
      ),
      findsOneWidget,
    );
    expect(controller.selectedSourceIds, <String>[source.id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Browse presents enabled extensions and progressive extension results',
    (tester) async {
      _setViewport(tester, const Size(1280, 720));
      addTearDown(() => _resetViewport(tester));
      final extension = _TestMangaExtensionController(
        MangaExtensionState(
          providers: [_mangaExtensionAddon()],
          query: 'Frieren',
          searching: true,
          results: [
            MangaExtensionTitle(
              providerId: 'manga.fixture',
              providerName: 'Fixture Manga',
              id: 'title.1',
              title: 'Frieren Test Result',
              language: 'en',
            ),
          ],
        ),
        chapterFixtures: const [
          MangaExtensionChapter(
            id: 'chapter.1',
            title: 'Chapter 1: The Journey',
            chapter: '1',
            index: 0,
          ),
        ],
      );
      await _pumpScreen(
        tester,
        _TestMangaHubController(MangaHubState()),
        isTelevision: true,
        extensions: extension,
      );

      await tester.tap(
        find.byKey(const ValueKey('manga-section-browse')),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 220));

      expect(
        find.byKey(const ValueKey('manga-extension-results')),
        findsOneWidget,
      );
      expect(find.text('Results for “Frieren”'), findsOneWidget);
      expect(find.textContaining('result(s) so far'), findsOneWidget);
      expect(find.text('Frieren Test Result'), findsOneWidget);
      expect(find.text('Fixture Manga • EN'), findsOneWidget);
      expect(find.text('Search all'), findsOneWidget);
      expect(find.text('Manage extensions'), findsOneWidget);

      await tester.tap(find.text('Frieren Test Result'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(
        find.byKey(const ValueKey('manga-extension-chapters')),
        findsOneWidget,
      );
      expect(find.text('Chapter 1: The Journey'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      expect(find.byTooltip('Download chapter'), findsOneWidget);
      expect(find.text('Add to library'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Sources keeps OPDS and installed manga extensions distinct', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 720));
    addTearDown(() => _resetViewport(tester));
    final extension = _TestMangaExtensionController(
      MangaExtensionState(providers: [_mangaExtensionAddon()]),
    );
    await _pumpScreen(
      tester,
      _TestMangaHubController(
        MangaHubState(sources: <StoredMangaSource>[_source()]),
      ),
      isTelevision: true,
      extensions: extension,
    );

    await tester.tap(
      find.byKey(const ValueKey('manga-section-sources')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('Manga extensions'), findsOneWidget);
    expect(find.text('Optional OPDS catalogs'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manga-installed-extension-manga.fixture')),
      findsOneWidget,
    );
    expect(find.text('Fixture Manga'), findsOneWidget);
    expect(find.text('Manage extensions'), findsOneWidget);
    expect(find.text('My added catalog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Download starts a real acquisition and exposes the active job', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 720));
    addTearDown(() => _resetViewport(tester));
    final source = _source();
    final pageUri = Uri.parse('https://catalog.example/pages/1.png');
    final publication = MangaPublication(
      identifier: 'urn:test:download',
      title: 'Downloadable Volume',
      readingOrder: <MangaCatalogLink>[
        MangaCatalogLink(uri: pageUri, mediaType: 'image/png'),
      ],
    );
    final reader = _readerRequest(
      sourceId: source.id,
      publicationId: mangaPublicationStableId(publication),
      chapterId: mangaPublicationStableId(publication),
      title: publication.title,
      pageUri: pageUri,
    );
    final hub = _TestMangaHubController(
      MangaHubState(
        sources: <StoredMangaSource>[source],
        selectedSource: source,
        selectedFeed: MangaCatalogFeed(
          protocol: MangaSourceProtocol.opds2,
          documentUri: source.uri,
          title: 'Download catalog',
          publications: <MangaPublication>[publication],
        ),
      ),
      readerRequest: reader,
    );
    final fixture = await tester.runAsync(() async {
      final created = await _WidgetAcquisitionFixture.create();
      await created.controller.initialize();
      return created;
    });
    expect(fixture, isNotNull);
    final acquisitionFixture = fixture!;
    addTearDown(acquisitionFixture.dispose);
    await _pumpScreen(
      tester,
      hub,
      isTelevision: true,
      acquisitions: acquisitionFixture.controller,
    );
    await tester.tap(
      find.byKey(const ValueKey('manga-section-browse')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.byKey(
        ValueKey('manga-publication-${mangaPublicationStableId(publication)}'),
      ),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final downloadButton = find.ancestor(
      of: find.text('Download'),
      matching: find.byType(TvFocusable),
    );
    expect(downloadButton, findsOneWidget);
    await tester.ensureVisible(downloadButton);
    await tester.pump();
    await tester.tap(downloadButton);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('manga-download-list'))
          .evaluate()
          .isNotEmpty,
    );
    final downloadList = find.byKey(const ValueKey('manga-download-list'));
    expect(downloadList, findsOneWidget);

    expect(find.byKey(const ValueKey('manga-downloads')), findsOneWidget);
    expect(
      find.descendant(
        of: downloadList,
        matching: find.text('Downloadable Volume'),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(of: downloadList, matching: find.text('Cancel')),
      findsOneWidget,
    );
    await _pumpUntil(
      tester,
      () => acquisitionFixture.transport.requests.isNotEmpty,
    );
    expect(acquisitionFixture.transport.requests, <Uri>[pageUri]);
    expect(
      acquisitionFixture.controller.state.jobs.single.status,
      anyOf(
        MangaDownloadJobStatus.resolving,
        MangaDownloadJobStatus.downloading,
      ),
    );

    acquisitionFixture.transport.body.add(_pngBytes);
    unawaited(acquisitionFixture.transport.body.close());
    await _pumpUntil(
      tester,
      () =>
          acquisitionFixture.controller.state
              .job(acquisitionFixture.controller.state.jobs.single.id)
              ?.status ==
          MangaDownloadJobStatus.completed,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed download card opens the local reader request', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 720));
    addTearDown(() => _resetViewport(tester));
    final job = _downloadJob(
      id: 'completed-job',
      status: MangaDownloadJobStatus.completed,
      pageCount: 1,
      completedPages: 1,
    );
    final reader = _readerRequest(
      sourceId: job.sourceId,
      publicationId: job.entryId,
      chapterId: job.chapterId,
      title: job.seriesTitle,
      pageUri: Uri.parse('https://catalog.example/page.png'),
    );
    final acquisitions = _RecordingMangaAcquisitionController(
      MangaAcquisitionState(
        isInitializing: false,
        jobs: <MangaDownloadJob>[job],
      ),
      completedRequest: reader,
    );
    final hub = _TestMangaHubController(MangaHubState());
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: '/', builder: (_, _) => const MangaScreen()),
        GoRoute(
          path: MangaReaderScreen.routePath,
          builder: (_, _) => const Scaffold(body: Text('reader-target')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(
          hub,
          isTelevision: true,
          acquisitions: acquisitions,
        ),
        child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(
      find.byKey(const ValueKey('manga-section-downloads')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(find.text('Read'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(acquisitions.openedJobIds, <String>['completed-job']);
    expect(hub.resumedRequests, <MangaReaderRequest>[reader]);
    expect(find.text('reader-target'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download cards invoke cancel retry and delete callbacks', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 720));
    addTearDown(() => _resetViewport(tester));
    final active = _downloadJob(
      id: 'active-job',
      status: MangaDownloadJobStatus.downloading,
      pageCount: 2,
    );
    final failed = _downloadJob(
      id: 'failed-job',
      status: MangaDownloadJobStatus.failed,
      errorMessage: 'The source timed out.',
    );
    final acquisitions = _RecordingMangaAcquisitionController(
      MangaAcquisitionState(
        isInitializing: false,
        jobs: <MangaDownloadJob>[active, failed],
      ),
    );
    await _pumpScreen(
      tester,
      _TestMangaHubController(MangaHubState()),
      isTelevision: true,
      acquisitions: acquisitions,
    );
    await tester.tap(
      find.byKey(const ValueKey('manga-section-downloads')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 180));

    await tester.tap(find.text('Cancel'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.text('Retry'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.byTooltip('Delete download'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(
      find.widgetWithText(FilledButton, 'Delete'),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(acquisitions.cancelledJobIds, <String>['active-job']);
    expect(acquisitions.retriedJobIds, <String>['failed-job']);
    expect(acquisitions.deletedJobIds, <String>['failed-job']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source removal cleans downloads before deleting hub rows', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 720));
    addTearDown(() => _resetViewport(tester));
    final events = <String>[];
    final source = _source();
    final hub = _TestMangaHubController(
      MangaHubState(sources: <StoredMangaSource>[source]),
      removalEvents: events,
    );
    final acquisitions = _RecordingMangaAcquisitionController(
      MangaAcquisitionState(isInitializing: false),
      removalEvents: events,
    );
    await _pumpScreen(
      tester,
      hub,
      isTelevision: true,
      acquisitions: acquisitions,
    );
    await tester.tap(
      find.byKey(const ValueKey('manga-section-sources')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 180));
    await tester.scrollUntilVisible(
      find.byTooltip('Remove source', skipOffstage: false),
      220,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('manga-sources-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove source'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Remove'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(events, <String>['cleanup:${source.id}', 'hub:${source.id}']);
    expect(tester.takeException(), isNull);
  });

  for (final layout in <({String name, Size size, bool television})>[
    (name: 'phone portrait', size: const Size(390, 844), television: false),
    (name: 'television', size: const Size(1280, 720), television: true),
  ]) {
    testWidgets('${layout.name} Manga layout has no overflow', (tester) async {
      _setViewport(tester, layout.size);
      addTearDown(() => _resetViewport(tester));
      final source = _source();
      final publication = MangaPublication(
        identifier: 'urn:test:responsive',
        title: 'A deliberately long but bounded manga title for layout testing',
        authors: const <MangaContributor>[
          MangaContributor(name: 'A Long Example Author Name'),
        ],
      );
      final feed = MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: source.uri,
        title: 'Responsive catalog',
        subtitle: 'Only the user-added catalog is represented here.',
        publications: <MangaPublication>[publication],
      );
      final controller = _TestMangaHubController(
        MangaHubState(
          sources: <StoredMangaSource>[source],
          selectedSource: source,
          selectedFeed: feed,
        ),
      );
      await _pumpScreen(tester, controller, isTelevision: layout.television);

      await tester.tap(
        find.byKey(const ValueKey('manga-section-browse')),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 240));

      expect(find.byKey(const ValueKey('manga-browse')), findsOneWidget);
      expect(find.text('Responsive catalog'), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            'manga-publication-${mangaPublicationStableId(publication)}',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey(
            layout.television ? 'main-navigation' : 'phone-bottom-navigation',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

List<Override> _overrides(
  _TestMangaHubController controller, {
  required bool isTelevision,
  MangaAcquisitionController? acquisitions,
  MangaExtensionController? extensions,
}) => <Override>[
  mangaHubControllerProvider.overrideWith((_) => controller),
  if (extensions != null)
    mangaExtensionControllerProvider.overrideWith((_) => extensions),
  mangaAcquisitionControllerProvider.overrideWith(
    (_) =>
        acquisitions ??
        _RecordingMangaAcquisitionController(
          MangaAcquisitionState(isInitializing: false),
        ),
  ),
  settingsPreferencesProvider.overrideWith(
    (_) => _TestSettingsController(isTelevision: isTelevision),
  ),
  appUpdateControllerProvider.overrideWith((_) => _TestAppUpdateController()),
  isTelevisionProvider.overrideWithValue(isTelevision),
];

Future<void> _pumpScreen(
  WidgetTester tester,
  _TestMangaHubController controller, {
  required bool isTelevision,
  MangaAcquisitionController? acquisitions,
  MangaExtensionController? extensions,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(
        controller,
        isTelevision: isTelevision,
        acquisitions: acquisitions,
        extensions: extensions,
      ),
      child: MaterialApp(theme: AppTheme.dark, home: const MangaScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 240));
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
}

void _resetViewport(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

StoredMangaSource _source() => StoredMangaSource(
  id: 'source.test',
  uri: Uri.parse('https://catalog.example/opds'),
  name: 'My added catalog',
  kind: StoredMangaSourceKind.opds2,
  updatedAt: DateTime.utc(2026, 9, 1),
);

InstalledStreamingAddon _mangaExtensionAddon() => InstalledStreamingAddon(
  manifest: MarketplaceAddon(
    id: 'manga.fixture',
    name: 'Fixture Manga',
    description: 'Manga screen fixture',
    author: 'TetoTV tests',
    manifestUri: Uri.parse('https://example.test/manga.json'),
    repositoryUrl: 'https://example.test/marketplace.json',
    language: 'javascript',
    type: 'manga-provider',
    locale: 'en',
  ),
  payload: 'class Provider {}',
  enabled: true,
  installedAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
);

class _TestMangaExtensionController extends MangaExtensionController {
  _TestMangaExtensionController(
    MangaExtensionState initial, {
    this.chapterFixtures = const [],
  }) : super(
         addonStore: AddonStore(TetoTvDatabase.instance),
         mangaStore: MangaStore(),
         identityStore: _MemoryMangaExtensionIdentityStore(),
         ownerKey: () async => 'owner.test',
       ) {
    state = initial;
  }

  final List<MangaExtensionChapter> chapterFixtures;

  @override
  Future<List<MangaExtensionChapter>> chapters(
    MangaExtensionTitle title,
  ) async => chapterFixtures;

  @override
  Future<bool> isInLibrary(MangaExtensionTitle title) async => false;
}

class _MemoryMangaExtensionIdentityStore
    implements MangaExtensionIdentityStore {
  final Map<String, String> _values = {};

  String _key(String ownerKey, String sourceId, String entryId) =>
      '$ownerKey\n$sourceId\n$entryId';

  @override
  Future<void> delete({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    _values.remove(_key(ownerKey, sourceId, entryId));
  }

  @override
  Future<String?> read({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async => _values[_key(ownerKey, sourceId, entryId)];

  @override
  Future<void> write({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String mangaId,
  }) async {
    _values[_key(ownerKey, sourceId, entryId)] = mangaId;
  }
}

class _TestMangaHubController extends MangaHubController {
  _TestMangaHubController(
    MangaHubState initial, {
    this.feeds = const <String, MangaCatalogFeed>{},
    this.readerRequest,
    this.removalEvents,
  }) : super(
         client: MangaCatalogClient(
           credentials: MangaSourceCredentialStore(
             const FlutterSecureStorage(),
           ),
         ),
         credentials: MangaSourceCredentialStore(const FlutterSecureStorage()),
         store: MangaStore(),
         ownerKey: () async => 'owner.test',
       ) {
    state = initial;
  }

  final Map<String, MangaCatalogFeed> feeds;
  final MangaReaderRequest? readerRequest;
  final List<String>? removalEvents;
  final List<String> selectedSourceIds = <String>[];
  final List<MangaReaderRequest> resumedRequests = <MangaReaderRequest>[];

  @override
  Future<bool> initialize() async => true;

  @override
  Future<bool> selectSource(String sourceId) async {
    selectedSourceIds.add(sourceId);
    final matches = state.sources.where((source) => source.id == sourceId);
    final feed = feeds[sourceId];
    if (matches.isEmpty || feed == null) return false;
    state = state.copyWith(
      selectedSource: matches.first,
      selectedFeed: feed,
      breadcrumbs: const <MangaCatalogBreadcrumb>[],
      query: '',
      clearError: true,
    );
    return true;
  }

  @override
  void setQuery(String value) {
    state = state.copyWith(query: value, clearError: true);
  }

  @override
  Future<MangaReaderRequest> buildReaderRequest(
    MangaPublication publication, {
    String? chapterId,
    String? chapterTitle,
    double? chapterNumber,
  }) async {
    final request = readerRequest;
    if (request != null) return request;
    return super.buildReaderRequest(
      publication,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterNumber: chapterNumber,
    );
  }

  @override
  Future<MangaReaderRequest> applySavedProgress(
    MangaReaderRequest request,
  ) async {
    resumedRequests.add(request);
    return request;
  }

  @override
  Future<bool> removeSource(String sourceId) async {
    removalEvents?.add('cleanup:$sourceId');
    removalEvents?.add('hub:$sourceId');
    state = state.copyWith(
      sources: state.sources.where((source) => source.id != sourceId),
      clearError: true,
    );
    return true;
  }
}

class _RecordingMangaAcquisitionController extends MangaAcquisitionController {
  _RecordingMangaAcquisitionController(
    MangaAcquisitionState initial, {
    this.completedRequest,
    this.removalEvents,
  }) : super(service: Completer<MangaAcquisitionService>().future) {
    state = initial;
  }

  final MangaReaderRequest? completedRequest;
  final List<String>? removalEvents;
  final List<String> openedJobIds = <String>[];
  final List<String> cancelledJobIds = <String>[];
  final List<String> retriedJobIds = <String>[];
  final List<String> deletedJobIds = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<MangaReaderRequest?> openCompleted(String jobId) async {
    openedJobIds.add(jobId);
    return completedRequest;
  }

  @override
  Future<void> cancel(String jobId) async => cancelledJobIds.add(jobId);

  @override
  Future<MangaAcquisitionOperation> retryInSession(String jobId) {
    retriedJobIds.add(jobId);
    return Future<MangaAcquisitionOperation>.error(
      const MangaAcquisitionException(
        MangaAcquisitionFailureCode.invalidRequest,
        'Reconnect to retry.',
      ),
    );
  }

  @override
  Future<void> delete(String jobId) async => deletedJobIds.add(jobId);

  @override
  Future<int> removeDownloadsForSource(String sourceId) async {
    removalEvents?.add('cleanup:$sourceId');
    return 0;
  }
}

class _WidgetAcquisitionFixture {
  _WidgetAcquisitionFixture({
    required this.root,
    required this.controller,
    required this.transport,
  });

  final Directory root;
  final MangaAcquisitionController controller;
  final _ControlledMangaTransport transport;

  static Future<_WidgetAcquisitionFixture> create() async {
    final root = await Directory.systemTemp.createTemp('manga-screen-get-');
    final persistence = _WidgetMangaPersistence();
    final transport = _ControlledMangaTransport();
    final service = MangaAcquisitionService.withDependencies(
      persistence: persistence,
      storageRoots: MangaStorageRoots(
        downloadedPages: await Directory(
          path.join(root.path, 'downloaded'),
        ).create(),
        extractedArchives: await Directory(
          path.join(root.path, 'extracted'),
        ).create(),
      ),
      transport: transport,
      validateTarget: (_) async {},
    );
    return _WidgetAcquisitionFixture(
      root: root,
      controller: MangaAcquisitionController(
        service: Future<MangaAcquisitionService>.value(service),
      ),
      transport: transport,
    );
  }

  Future<void> dispose() async {
    if (!transport.body.isClosed) await transport.body.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _WidgetMangaPersistence implements MangaAcquisitionPersistence {
  final Map<String, MangaDownloadJob> jobs = <String, MangaDownloadJob>{};
  final Map<String, Map<int, MangaDownloadPage>> pageRows =
      <String, Map<int, MangaDownloadPage>>{};

  @override
  Future<void> clearPages(String jobId) async => pageRows.remove(jobId);

  @override
  Future<void> deleteJob(String jobId) async => jobs.remove(jobId);

  @override
  Future<MangaDownloadJob?> job(String jobId) async => jobs[jobId];

  @override
  Future<List<MangaDownloadJob>> listJobs() async =>
      jobs.values.toList(growable: false);

  @override
  Future<List<MangaDownloadPage>> pages(String jobId) async {
    final result = pageRows[jobId]?.values.toList() ?? <MangaDownloadPage>[];
    result.sort((first, second) => first.pageIndex.compareTo(second.pageIndex));
    return result;
  }

  @override
  Future<void> putJob(MangaDownloadJob job) async => jobs[job.id] = job;

  @override
  Future<void> putPage(MangaDownloadPage page) async {
    pageRows.putIfAbsent(
      page.jobId,
      () => <int, MangaDownloadPage>{},
    )[page.pageIndex] = page;
  }
}

class _ControlledMangaTransport implements MangaAcquisitionTransport {
  final StreamController<List<int>> body =
      StreamController<List<int>>.broadcast();
  final List<Uri> requests = <Uri>[];

  @override
  Future<MangaAcquisitionHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required MangaAcquisitionCancellationToken cancellation,
  }) async {
    requests.add(uri);
    return MangaAcquisitionHttpResponse(
      statusCode: HttpStatus.ok,
      headers: const <String, String>{
        HttpHeaders.contentTypeHeader: 'image/png',
      },
      body: body.stream,
    );
  }
}

MangaReaderRequest _readerRequest({
  required String sourceId,
  required String publicationId,
  required String chapterId,
  required String title,
  required Uri pageUri,
}) => MangaReaderRequest(
  sourceId: sourceId,
  publicationId: publicationId,
  chapterId: chapterId,
  seriesTitle: title,
  chapterTitle: title,
  pages: <MangaReaderPage>[
    MangaReaderPage(
      id: 'page-1',
      index: 0,
      resource: MangaRemotePageResource(uri: pageUri),
      isCover: true,
    ),
  ],
);

MangaDownloadJob _downloadJob({
  required String id,
  required MangaDownloadJobStatus status,
  int? pageCount,
  int completedPages = 0,
  String? errorMessage,
}) {
  final now = DateTime.utc(2026, 9, 1, 12);
  return MangaDownloadJob(
    id: id,
    sourceId: 'source.test',
    entryId: 'publication.test',
    chapterId: 'chapter.test',
    seriesTitle: 'Test Download $id',
    chapterLabel: 'Chapter 1',
    status: status,
    relativeDirectory: 'jobs/$id',
    pageCount: pageCount,
    completedPages: completedPages,
    receivedBytes: 0,
    queuePosition: 0,
    retryCount: 0,
    errorMessage: errorMessage,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(condition(), isTrue, reason: 'Expected widget state did not appear.');
}

class _TestSettingsController extends SettingsPreferencesController {
  _TestSettingsController({required bool isTelevision})
    : super(const FlutterSecureStorage()) {
    state = SettingsPreferences(
      interfaceMode: isTelevision
          ? InterfaceMode.automatic
          : InterfaceMode.phone,
      loaded: true,
    );
  }

  @override
  Future<void> load() async {}
}

class _TestAppUpdateController extends AppUpdateController {
  _TestAppUpdateController()
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => '2.0.0',
        () async => const <String>[],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = const AppUpdateState(loaded: true, developerMode: true);
  }

  @override
  Future<void> load() async {}
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

const List<int> _pngBytes = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
];
