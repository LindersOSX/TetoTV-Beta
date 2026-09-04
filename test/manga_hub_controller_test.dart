import 'dart:convert';

import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();
  late MangaSourceCredentialStore credentials;
  late _MemoryMangaStore store;
  late _FakeMangaCatalogClient client;
  late MangaHubController controller;
  late MangaSourceDownloadCleanup cleanupDownloadsForSource;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    credentials = MangaSourceCredentialStore(storage);
    store = _MemoryMangaStore(credentials);
    client = _FakeMangaCatalogClient(credentials);
    cleanupDownloadsForSource = (_) async => 0;
    controller = MangaHubController(
      client: client,
      credentials: credentials,
      store: store,
      ownerKey: () async => 'owner.test',
      cleanupDownloadsForSource: (sourceId) =>
          cleanupDownloadsForSource(sourceId),
    );
  });

  tearDown(() {
    controller.dispose();
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'owner key prefers local then tracking and protects raw identifiers',
    () async {
      final local = await resolveMangaOwnerKey(
        storage: storage,
        activeLocalProfileId: 'private-local-profile-id',
        preferredTrackingProvider: TrackingProvider.anilist,
        activeTrackingProfileIds: const <TrackingProvider, String>{
          TrackingProvider.anilist: 'private-tracker-slot-id',
        },
      );
      final tracking = await resolveMangaOwnerKey(
        storage: storage,
        preferredTrackingProvider: TrackingProvider.anilist,
        activeTrackingProfileIds: const <TrackingProvider, String>{
          TrackingProvider.anilist: 'private-tracker-slot-id',
        },
      );
      final deviceOne = await resolveMangaOwnerKey(storage: storage);
      final deviceTwo = await resolveMangaOwnerKey(storage: storage);

      expect(local, startsWith('local.'));
      expect(local, isNot(contains('private-local-profile-id')));
      expect(tracking, startsWith('tracking.anilist.'));
      expect(tracking, isNot(contains('private-tracker-slot-id')));
      expect(deviceTwo, deviceOne);
      expect(deviceOne, matches(RegExp(r'^device\.[a-f0-9]{64}$')));
    },
  );

  test(
    'rejects a Mihon protobuf store before catalog network access',
    () async {
      final added = await controller.addSource(
        Uri.parse('https://repo.example/index.pb?utm_source=example'),
      );

      expect(added, isFalse);
      expect(client.calls, isEmpty);
      expect(store.sourceRows, isEmpty);
      expect(
        controller.state.error,
        contains('Mihon/Tachiyomi Android extension store'),
      );
      expect(controller.state.error, contains('manga-provider'));
    },
  );

  test(
    'repository credentials reach only the explicitly intended matching child',
    () async {
      final repositoryUri = Uri.parse('https://repo.example/manga.json');
      final repository = MangaRepositoryManifest(
        id: 'repo.example',
        name: 'Example repository',
        documentUri: repositoryUri,
        sources: <MangaSourceDescriptor>[
          MangaSourceDescriptor(
            id: 'public',
            name: 'Public OPDS',
            protocol: MangaSourceProtocol.opds2,
            entryPoint: Uri.parse('https://public.example/opds'),
          ),
          MangaSourceDescriptor(
            id: 'secure',
            name: 'Secure OPDS',
            protocol: MangaSourceProtocol.opds1,
            entryPoint: Uri.parse('https://secure.example/opds'),
            authentication: const MangaSourceAuthentication(
              kind: MangaSourceAuthenticationKind.basic,
            ),
          ),
        ],
      );
      client.responses[repositoryUri] = MangaFetchedRepository(
        requestedUri: repositoryUri,
        finalUri: repositoryUri,
        mediaType: 'application/json',
        repository: repository,
      );

      final added = await controller.addSource(
        repositoryUri,
        credential: MangaSourceCredential.basic(
          username: 'reader',
          password: 'secret',
        ),
        repositoryCredentialSourceId: 'secure',
      );

      expect(added, isTrue);
      expect(client.calls.single.sourceId, isNull);
      expect(controller.state.sources, hasLength(3));
      final rootId = mangaSourceStableId(repositoryUri);
      final secureId = mangaRepositoryChildStableId(
        rootId,
        repository.sources.last,
      );
      final publicId = mangaRepositoryChildStableId(
        rootId,
        repository.sources.first,
      );
      expect(await credentials.read(rootId), isNull);
      expect(await credentials.read(publicId), isNull);
      expect(
        (await credentials.read(secureId))?.kind,
        MangaSourceAuthenticationKind.basic,
      );

      expect(await controller.removeSource(rootId), isTrue);
      expect(controller.state.sources, isEmpty);
      expect(await credentials.read(secureId), isNull);
    },
  );

  test(
    'rejects a repository credential whose declared auth does not match',
    () async {
      final uri = Uri.parse('https://repo.example/mismatch.json');
      final descriptor = MangaSourceDescriptor(
        id: 'secure',
        name: 'Secure OPDS',
        protocol: MangaSourceProtocol.opds2,
        entryPoint: Uri.parse('https://secure.example/opds'),
        authentication: const MangaSourceAuthentication(
          kind: MangaSourceAuthenticationKind.bearer,
        ),
      );
      client.responses[uri] = MangaFetchedRepository(
        requestedUri: uri,
        finalUri: uri,
        mediaType: 'application/json',
        repository: MangaRepositoryManifest(
          id: 'repo.mismatch',
          name: 'Mismatch repository',
          documentUri: uri,
          sources: <MangaSourceDescriptor>[descriptor],
        ),
      );

      expect(
        await controller.addSource(
          uri,
          credential: MangaSourceCredential.basic(
            username: 'reader',
            password: 'secret',
          ),
          repositoryCredentialSourceId: 'secure',
        ),
        isFalse,
      );
      expect(store.sourceRows, isEmpty);
      expect(controller.state.error, contains('does not match'));
    },
  );

  test(
    'repository pruning cleans completed and active child downloads before deleting the child',
    () async {
      final repositoryUri = Uri.parse(
        'https://repo.example/prunable-manga.json',
      );
      final descriptor = MangaSourceDescriptor(
        id: 'soon-removed',
        name: 'Temporary catalog',
        protocol: MangaSourceProtocol.opds2,
        entryPoint: Uri.parse('https://catalog.example/temporary-opds'),
      );
      MangaFetchedRepository response(List<MangaSourceDescriptor> sources) =>
          MangaFetchedRepository(
            requestedUri: repositoryUri,
            finalUri: repositoryUri,
            mediaType: 'application/json',
            repository: MangaRepositoryManifest(
              id: 'repo.prunable',
              name: 'Prunable repository',
              documentUri: repositoryUri,
              sources: sources,
            ),
          );
      client.responses[repositoryUri] = response(<MangaSourceDescriptor>[
        descriptor,
      ]);
      expect(await controller.addSource(repositoryUri), isTrue);

      final rootId = mangaSourceStableId(repositoryUri);
      final childId = mangaRepositoryChildStableId(rootId, descriptor);
      final now = DateTime.utc(2026, 9, 1, 12);
      store.downloadRows['completed-child'] = _storedDownloadJob(
        id: 'completed-child',
        sourceId: childId,
        status: MangaDownloadJobStatus.completed,
        now: now,
      );
      store.downloadRows['active-child'] = _storedDownloadJob(
        id: 'active-child',
        sourceId: childId,
        status: MangaDownloadJobStatus.downloading,
        now: now,
      );
      final events = <String>[];
      cleanupDownloadsForSource = (sourceId) async {
        expect(sourceId, childId);
        expect(
          store.downloadRows.values.map((job) => job.status),
          containsAll(<MangaDownloadJobStatus>[
            MangaDownloadJobStatus.completed,
            MangaDownloadJobStatus.downloading,
          ]),
        );
        final before = store.downloadRows.length;
        store.downloadRows.removeWhere((_, job) => job.sourceId == sourceId);
        events.add('cleanup:$sourceId');
        return before - store.downloadRows.length;
      };
      store.onDeleteSource = (sourceId) {
        if (sourceId != childId) return;
        expect(store.downloadRows, isEmpty);
        events.add('delete:$sourceId');
      };

      client.responses[repositoryUri] = response(
        const <MangaSourceDescriptor>[],
      );
      expect(await controller.addSource(repositoryUri), isTrue);

      expect(events, <String>['cleanup:$childId', 'delete:$childId']);
      expect(store.sourceRows.containsKey(childId), isFalse);
      expect(store.downloadRows, isEmpty);
    },
  );

  test('source removal always cleans downloads before deleting rows', () async {
    final sourceUri = Uri.parse('https://catalog.example/removable');
    final sourceId = mangaSourceStableId(sourceUri);
    await store.upsertSource(
      StoredMangaSource(
        id: sourceId,
        uri: sourceUri,
        name: 'Removable catalog',
        kind: StoredMangaSourceKind.opds2,
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    );
    final events = <String>[];
    cleanupDownloadsForSource = (id) async {
      events.add('cleanup:$id');
      return 1;
    };
    store.onDeleteSource = (id) => events.add('delete:$id');

    expect(await controller.removeSource(sourceId), isTrue);
    expect(events, <String>['cleanup:$sourceId', 'delete:$sourceId']);
    expect(await store.source(sourceId), isNull);
  });

  test('failed download cleanup keeps the source row', () async {
    final sourceUri = Uri.parse('https://catalog.example/cleanup-failure');
    final sourceId = mangaSourceStableId(sourceUri);
    await store.upsertSource(
      StoredMangaSource(
        id: sourceId,
        uri: sourceUri,
        name: 'Protected catalog',
        kind: StoredMangaSourceKind.opds2,
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    );
    cleanupDownloadsForSource = (_) =>
        Future<int>.error(StateError('download cleanup failed'));

    expect(await controller.removeSource(sourceId), isFalse);
    expect(await store.source(sourceId), isNotNull);
  });

  test('repository refresh preserves a disabled child source', () async {
    final repositoryUri = Uri.parse('https://repo.example/toggle-state.json');
    final descriptor = MangaSourceDescriptor(
      id: 'catalog',
      name: 'Optional catalog',
      protocol: MangaSourceProtocol.opds2,
      entryPoint: Uri.parse('https://catalog.example/optional-opds'),
    );
    client.responses[repositoryUri] = MangaFetchedRepository(
      requestedUri: repositoryUri,
      finalUri: repositoryUri,
      mediaType: 'application/json',
      repository: MangaRepositoryManifest(
        id: 'repo.toggle-state',
        name: 'Toggle state repository',
        documentUri: repositoryUri,
        sources: <MangaSourceDescriptor>[descriptor],
      ),
    );

    expect(await controller.addSource(repositoryUri), isTrue);
    final childId = mangaRepositoryChildStableId(
      mangaSourceStableId(repositoryUri),
      descriptor,
    );
    expect(await controller.setSourceEnabled(childId, false), isTrue);
    expect((await store.source(childId))!.enabled, isFalse);

    expect(await controller.addSource(repositoryUri), isTrue);
    expect((await store.source(childId))!.enabled, isFalse);
    expect(
      controller.state.sources
          .singleWhere((item) => item.id == childId)
          .enabled,
      isFalse,
    );
  });

  test(
    'direct feed supports local search, navigation, back, and safe library',
    () async {
      final sourceUri = Uri.parse('https://catalog.example/root');
      final childUri = Uri.parse('https://other.example/child');
      final publication = _publication(
        title: 'Moon Library',
        identifier: 'urn:book:moon',
        authors: const <MangaContributor>[
          MangaContributor(name: 'Example Author'),
        ],
        readingOrder: <MangaCatalogLink>[
          _image('https://catalog.example/pages/1.jpg'),
        ],
      );
      final rootFeed = MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: sourceUri,
        title: 'Root catalog',
        publications: <MangaPublication>[
          publication,
          _publication(title: 'Sun Book', identifier: 'urn:book:sun'),
        ],
        navigation: <MangaNavigationItem>[
          MangaNavigationItem(
            title: 'Child',
            links: <MangaCatalogLink>[MangaCatalogLink(uri: childUri)],
          ),
        ],
      );
      final childFeed = MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: childUri,
        title: 'Child catalog',
      );
      client.responses[sourceUri] = MangaFetchedFeed(
        requestedUri: sourceUri,
        finalUri: sourceUri,
        mediaType: 'application/opds+json',
        feed: rootFeed,
      );
      client.responses[childUri] = MangaFetchedFeed(
        requestedUri: childUri,
        finalUri: childUri,
        mediaType: 'application/opds+json',
        feed: childFeed,
      );

      expect(
        await controller.addSource(
          sourceUri,
          credential: MangaSourceCredential.bearer('catalog-token'),
        ),
        isTrue,
      );
      final sourceId = mangaSourceStableId(sourceUri);
      expect(client.calls.first.sourceId, sourceId);
      expect(await controller.selectSource(sourceId), isTrue);

      controller.setQuery('author');
      expect(controller.state.visiblePublications.single.title, 'Moon Library');
      controller.setQuery('missing');
      expect(controller.state.visiblePublications, isEmpty);
      controller.setQuery('');

      expect(await controller.navigateTo(childUri), isTrue);
      expect(
        client.calls.last.sourceId,
        isNull,
        reason: 'credentials cannot follow a cross-origin catalog link',
      );
      expect(controller.state.selectedFeed?.title, 'Child catalog');
      expect(controller.state.breadcrumbs, hasLength(1));
      expect(controller.back(), isTrue);
      expect(controller.state.selectedFeed?.title, 'Root catalog');

      expect(await controller.toggleLibrary(publication), isTrue);
      expect(controller.state.library.single.title, 'Moon Library');
      final encodedMetadata = jsonEncode(
        controller.state.library.single.metadata,
      );
      expect(encodedMetadata, contains(sourceUri.toString()));
      expect(controller.state.library.single.metadata['catalogPath'], <String>[
        sourceUri.toString(),
      ]);
      expect(encodedMetadata, isNot(contains('/pages/1.jpg')));
      expect(encodedMetadata, isNot(contains('catalog-token')));
      expect(encodedMetadata.toLowerCase(), isNot(contains('header')));
      expect(await controller.toggleLibrary(publication), isTrue);
      expect(controller.state.library, isEmpty);
    },
  );

  test('signed cover remains session-only when a title is saved', () async {
    final sourceUri = Uri.parse('https://catalog.example/root');
    final publication = _publication(
      title: 'Signed cover',
      identifier: 'urn:book:signed-cover',
      images: <MangaCatalogLink>[
        MangaCatalogLink(
          uri: Uri.parse(
            'https://images.example/cover.jpg?X-Amz-Signature=secret',
          ),
          relations: const <String>{'cover'},
          mediaType: 'image/jpeg',
        ),
      ],
    );
    client.responses[sourceUri] = MangaFetchedFeed(
      requestedUri: sourceUri,
      finalUri: sourceUri,
      mediaType: 'application/opds+json',
      feed: MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: sourceUri,
        title: 'Root catalog',
        publications: <MangaPublication>[publication],
      ),
    );

    expect(await controller.addSource(sourceUri), isTrue);
    expect(
      await controller.selectSource(mangaSourceStableId(sourceUri)),
      isTrue,
    );
    expect(
      controller.state.publications.single.images.single.uri.query,
      contains('X-Amz-Signature'),
    );
    expect(await controller.toggleLibrary(publication), isTrue);
    expect(controller.state.library.single.coverUri, isNull);
  });

  test(
    'nested library item survives restart and root navigation, then removes without current feed',
    () async {
      final rootUri = Uri.parse('https://catalog.example/root');
      final shelfUri = Uri.parse('https://catalog.example/shelves/fantasy');
      final pageUri = Uri.parse('https://catalog.example/pages/secret-1.jpg');
      final publication = _publication(
        title: 'Nested Moon',
        identifier: 'urn:book:nested-moon',
        readingOrder: <MangaCatalogLink>[_image(pageUri.toString())],
      );
      final rootFeed = MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: rootUri,
        title: 'Root catalog',
        navigation: <MangaNavigationItem>[
          MangaNavigationItem(
            title: 'Fantasy shelf',
            links: <MangaCatalogLink>[MangaCatalogLink(uri: shelfUri)],
          ),
        ],
      );
      final shelfFeed = MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: shelfUri,
        title: 'Fantasy shelf',
        publications: <MangaPublication>[publication],
      );
      client.responses[rootUri] = MangaFetchedFeed(
        requestedUri: rootUri,
        finalUri: rootUri,
        mediaType: 'application/opds+json',
        feed: rootFeed,
      );
      client.responses[shelfUri] = MangaFetchedFeed(
        requestedUri: shelfUri,
        finalUri: shelfUri,
        mediaType: 'application/opds+json',
        feed: shelfFeed,
      );

      expect(await controller.addSource(rootUri), isTrue);
      final sourceId = mangaSourceStableId(rootUri);
      expect(await controller.selectSource(sourceId), isTrue);
      expect(await controller.navigateTo(shelfUri), isTrue);
      expect(await controller.toggleLibrary(publication), isTrue);
      final saved = controller.state.library.single;
      expect(saved.metadata['catalogPath'], <String>[
        rootUri.toString(),
        shelfUri.toString(),
      ]);
      final metadata = jsonEncode(saved.metadata);
      expect(metadata, isNot(contains(pageUri.toString())));
      expect(metadata.toLowerCase(), isNot(contains('header')));

      controller.dispose();
      controller = MangaHubController(
        client: client,
        credentials: credentials,
        store: store,
        ownerKey: () async => 'owner.test',
      );
      expect(await controller.initialize(), isTrue);
      expect(controller.state.selectedFeed, isNull);
      expect(controller.state.library.single.entryId, saved.entryId);

      final reopened = await controller.openLibraryEntry(saved);
      expect(reopened?.title, 'Nested Moon');
      expect(controller.state.selectedFeed?.documentUri, shelfUri);
      expect(controller.state.breadcrumbs.single.uri, rootUri);
      expect(
        client.calls.sublist(client.calls.length - 2).map((call) => call.uri),
        <Uri>[rootUri, shelfUri],
      );

      expect(await controller.selectSource(sourceId), isTrue);
      expect(controller.state.selectedFeed?.documentUri, rootUri);
      expect(await controller.removeLibraryEntry(saved), isTrue);
      expect(controller.state.library, isEmpty);
      expect(store.libraryRows, isEmpty);
    },
  );

  test(
    'library reopen and removal reject an entry from another profile',
    () async {
      final sourceUri = Uri.parse('https://catalog.example/profile-root');
      final publication = _publication(
        title: 'Profile private',
        identifier: 'urn:book:profile-private',
      );
      final sourceId = mangaSourceStableId(sourceUri);
      final entry = MangaLibraryEntry(
        ownerKey: 'owner.other',
        sourceId: sourceId,
        entryId: mangaPublicationStableId(publication),
        title: publication.title,
        metadata: <String, Object?>{
          'catalogPath': <String>[sourceUri.toString()],
        },
        updatedAt: DateTime.utc(2026, 9, 1),
      );
      await store.upsertLibraryEntry(entry);

      expect(await controller.openLibraryEntry(entry), isNull);
      expect(controller.state.error, contains('another profile'));
      expect(await controller.removeLibraryEntry(entry), isFalse);
      expect(
        await store.libraryEntry(
          ownerKey: entry.ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        ),
        isNotNull,
      );
    },
  );

  test(
    'reader resumes progress and strips credentials from cross-origin pages',
    () async {
      final sourceUri = Uri.parse('https://catalog.example/root');
      final publication = _publication(
        title: 'Reader test',
        identifier: 'urn:reader:test',
        readingOrder: <MangaCatalogLink>[
          _image(
            'https://catalog.example/pages/1.jpg',
            properties: const <String, Object?>{'width': 800, 'height': 1200},
          ),
          _image('https://cdn.example/pages/2.png'),
        ],
        links: <MangaCatalogLink>[
          MangaCatalogLink(
            uri: Uri.parse('https://catalog.example/archive.cbz'),
            relations: const <String>{'http://opds-spec.org/acquisition'},
            mediaType: 'application/vnd.comicbook+zip',
          ),
        ],
      );
      final feed = MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: sourceUri,
        title: 'Reader catalog',
        publications: <MangaPublication>[publication],
      );
      client.responses[sourceUri] = MangaFetchedFeed(
        requestedUri: sourceUri,
        finalUri: sourceUri,
        mediaType: 'application/opds+json',
        feed: feed,
      );
      final sourceId = mangaSourceStableId(sourceUri);
      await store.upsertSource(
        StoredMangaSource(
          id: sourceId,
          uri: sourceUri,
          name: 'Reader catalog',
          kind: StoredMangaSourceKind.opds2,
          updatedAt: DateTime.utc(2026, 9, 1),
        ),
      );
      await credentials.write(sourceId, MangaSourceCredential.bearer('secret'));
      await controller.initialize();
      expect(await controller.selectSource(sourceId), isTrue);

      final first = await controller.buildReaderRequest(
        publication,
        chapterId: 'chapter.7',
        chapterTitle: 'Chapter 7',
        chapterNumber: 7,
      );
      expect(first.initialPageIndex, 0);
      expect(first.pages, hasLength(2));
      expect(first.pages.first.pixelWidth, 800);
      expect(
        (first.pages.first.resource as MangaRemotePageResource)
            .headers['authorization'],
        'Bearer secret',
      );
      expect(
        (first.pages.last.resource as MangaRemotePageResource).headers,
        isEmpty,
      );
      expect(
        await controller.saveProgress(first, pageIndex: 1, pageOffset: 0.5),
        isTrue,
      );

      final offlineResume = await controller.applySavedProgress(first);
      expect(offlineResume.initialPageIndex, 1);
      final otherProfile = MangaHubController(
        client: client,
        credentials: credentials,
        store: store,
        ownerKey: () async => 'owner.other',
      );
      try {
        final isolated = await otherProfile.applySavedProgress(first);
        expect(isolated.initialPageIndex, 0);
      } finally {
        otherProfile.dispose();
      }

      final resumed = await controller.buildReaderRequest(
        publication,
        chapterId: 'chapter.7',
        chapterTitle: 'Chapter 7',
        chapterNumber: 7,
      );
      expect(resumed.initialPageIndex, 1);
      expect(
        resumed.pages.map((page) => page.id),
        first.pages.map((page) => page.id),
      );

      final acquisition = await controller.selectCbzAcquisition(publication);
      expect(acquisition.uri.path, endsWith('.cbz'));
      expect(acquisition.headers['authorization'], 'Bearer secret');
      expect(acquisition.toString(), isNot(contains('secret')));

      final unsafePublication = _publication(
        title: 'Unsafe links',
        readingOrder: <MangaCatalogLink>[
          _image('http://private.example/page.jpg'),
        ],
        links: <MangaCatalogLink>[
          MangaCatalogLink(
            uri: Uri.parse('http://private.example/archive.cbz'),
            relations: const <String>{'http://opds-spec.org/acquisition'},
            mediaType: 'application/zip',
          ),
        ],
      );
      await expectLater(
        controller.buildReaderRequest(unsafePublication),
        throwsA(
          isA<MangaReaderBuildException>().having(
            (error) => error.failure,
            'failure',
            MangaReaderBuildFailure.noImagePages,
          ),
        ),
      );
      await expectLater(
        controller.selectCbzAcquisition(unsafePublication),
        throwsA(
          isA<MangaCbzAcquisitionException>().having(
            (error) => error.failure,
            'failure',
            MangaCbzAcquisitionFailure.unsafe,
          ),
        ),
      );
    },
  );

  test('source URLs cannot persist credentials in query parameters', () {
    expect(
      () => mangaSourceStableId(
        Uri.parse('https://catalog.example/opds?access_token=secret'),
      ),
      throwsFormatException,
    );
  });

  test('reader rejects AVIF media declarations and file extensions', () async {
    final sourceUri = Uri.parse('https://catalog.example/avif-root');
    final sourceId = mangaSourceStableId(sourceUri);
    await store.upsertSource(
      StoredMangaSource(
        id: sourceId,
        uri: sourceUri,
        name: 'AVIF catalog',
        kind: StoredMangaSourceKind.opds2,
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    );
    client.responses[sourceUri] = MangaFetchedFeed(
      requestedUri: sourceUri,
      finalUri: sourceUri,
      mediaType: 'application/opds+json',
      feed: MangaCatalogFeed(
        protocol: MangaSourceProtocol.opds2,
        documentUri: sourceUri,
        title: 'AVIF catalog',
      ),
    );
    await controller.initialize();
    expect(await controller.selectSource(sourceId), isTrue);

    for (final link in <MangaCatalogLink>[
      MangaCatalogLink(
        uri: Uri.parse('https://catalog.example/page.bin'),
        mediaType: 'image/avif',
      ),
      MangaCatalogLink(uri: Uri.parse('https://catalog.example/page.avif')),
    ]) {
      await expectLater(
        controller.buildReaderRequest(
          _publication(
            title: 'Unsupported AVIF',
            readingOrder: <MangaCatalogLink>[link],
          ),
        ),
        throwsA(
          isA<MangaReaderBuildException>().having(
            (error) => error.failure,
            'failure',
            MangaReaderBuildFailure.noImagePages,
          ),
        ),
      );
    }
  });

  test('errors are bounded and do not expose source URLs', () async {
    final sourceUri = Uri.parse('https://catalog.example/private-path');
    await store.upsertSource(
      StoredMangaSource(
        id: mangaSourceStableId(sourceUri),
        uri: sourceUri,
        name: 'Broken',
        kind: StoredMangaSourceKind.opds2,
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    );
    client.failures[sourceUri] = const FormatException(
      'Bad response from https://catalog.example/private-path?token=secret',
    );

    await controller.initialize();
    expect(
      await controller.selectSource(mangaSourceStableId(sourceUri)),
      isFalse,
    );
    expect(controller.state.error, isNot(contains('https://')));
    expect(controller.state.error, isNot(contains('secret')));
    expect(controller.state.error!.length, lessThanOrEqualTo(240));
  });
}

MangaPublication _publication({
  required String title,
  String? identifier,
  List<MangaContributor> authors = const <MangaContributor>[],
  List<MangaCatalogLink> links = const <MangaCatalogLink>[],
  List<MangaCatalogLink> images = const <MangaCatalogLink>[],
  List<MangaCatalogLink> readingOrder = const <MangaCatalogLink>[],
}) => MangaPublication(
  title: title,
  identifier: identifier,
  authors: authors,
  links: links,
  images: images,
  readingOrder: readingOrder,
  description: 'A safe description.',
  languages: const <String>['en'],
  subjects: const <String>['Fantasy'],
);

MangaCatalogLink _image(
  String uri, {
  Map<String, Object?> properties = const <String, Object?>{},
}) => MangaCatalogLink(
  uri: Uri.parse(uri),
  mediaType: uri.endsWith('.png') ? 'image/png' : 'image/jpeg',
  properties: properties,
);

MangaDownloadJob _storedDownloadJob({
  required String id,
  required String sourceId,
  required MangaDownloadJobStatus status,
  required DateTime now,
}) => MangaDownloadJob(
  id: id,
  sourceId: sourceId,
  entryId: 'entry.$id',
  chapterId: 'chapter.$id',
  seriesTitle: 'Series $id',
  chapterLabel: 'Chapter 1',
  status: status,
  relativeDirectory: 'jobs/$id',
  pageCount: 1,
  completedPages: status == MangaDownloadJobStatus.completed ? 1 : 0,
  receivedBytes: status == MangaDownloadJobStatus.completed ? 8 : 0,
  queuePosition: 0,
  retryCount: 0,
  createdAt: now,
  updatedAt: now,
);

class _CatalogCall {
  const _CatalogCall(this.uri, this.sourceId, this.protocolHint);

  final Uri uri;
  final String? sourceId;
  final MangaSourceProtocol? protocolHint;
}

class _FakeMangaCatalogClient extends MangaCatalogClient {
  _FakeMangaCatalogClient(MangaSourceCredentialStore credentials)
    : super(credentials: credentials);

  final Map<Uri, MangaFetchedDocument> responses =
      <Uri, MangaFetchedDocument>{};
  final Map<Uri, Object> failures = <Uri, Object>{};
  final List<_CatalogCall> calls = <_CatalogCall>[];

  @override
  Future<MangaFetchedDocument> fetch(
    Uri uri, {
    String? sourceId,
    MangaSourceProtocol? protocolHint,
  }) async {
    calls.add(_CatalogCall(uri, sourceId, protocolHint));
    final failure = failures[uri];
    if (failure != null) throw failure;
    final response = responses[uri];
    if (response == null) {
      throw const FormatException('Fake manga response was not registered.');
    }
    return response;
  }
}

class _MemoryMangaStore extends MangaStore {
  _MemoryMangaStore(this.credentialStore);

  final MangaSourceCredentialStore credentialStore;
  final Map<String, StoredMangaSource> sourceRows =
      <String, StoredMangaSource>{};
  final Map<String, MangaLibraryEntry> libraryRows =
      <String, MangaLibraryEntry>{};
  final Map<String, MangaReadingProgress> progressRows =
      <String, MangaReadingProgress>{};
  final Map<String, MangaDownloadJob> downloadRows =
      <String, MangaDownloadJob>{};
  void Function(String sourceId)? onDeleteSource;

  String _libraryKey(String owner, String source, String entry) =>
      '$owner\u0000$source\u0000$entry';

  String _progressKey(String owner, String source, String entry) =>
      '$owner\u0000$source\u0000$entry';

  @override
  Future<void> upsertSource(StoredMangaSource value) async {
    sourceRows[value.id] = value;
  }

  @override
  Future<StoredMangaSource?> source(String sourceId) async =>
      sourceRows[sourceId];

  @override
  Future<List<StoredMangaSource>> sources({bool includeDisabled = true}) async {
    final result =
        sourceRows.values
            .where((source) => includeDisabled || source.enabled)
            .toList()
          ..sort((first, second) => first.name.compareTo(second.name));
    return result;
  }

  @override
  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final current = sourceRows[sourceId];
    if (current == null) return;
    sourceRows[sourceId] = StoredMangaSource(
      id: current.id,
      uri: current.uri,
      name: current.name,
      kind: current.kind,
      enabled: enabled,
      updatedAt: current.updatedAt,
    );
  }

  @override
  Future<void> deleteSource(String sourceId) async {
    onDeleteSource?.call(sourceId);
    sourceRows.remove(sourceId);
    libraryRows.removeWhere((_, value) => value.sourceId == sourceId);
    progressRows.removeWhere((_, value) => value.sourceId == sourceId);
    downloadRows.removeWhere((_, value) => value.sourceId == sourceId);
    await credentialStore.delete(sourceId);
  }

  @override
  Future<void> upsertLibraryEntry(MangaLibraryEntry value) async {
    libraryRows[_libraryKey(value.ownerKey, value.sourceId, value.entryId)] =
        value;
  }

  @override
  Future<MangaLibraryEntry?> libraryEntry({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async => libraryRows[_libraryKey(ownerKey, sourceId, entryId)];

  @override
  Future<List<MangaLibraryEntry>> libraryEntries(
    String ownerKey, {
    int limit = 500,
  }) async => libraryRows.values
      .where((entry) => entry.ownerKey == ownerKey)
      .take(limit)
      .toList();

  @override
  Future<void> deleteLibraryEntry({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    libraryRows.remove(_libraryKey(ownerKey, sourceId, entryId));
  }

  @override
  Future<void> upsertProgress(MangaReadingProgress value) async {
    progressRows[_progressKey(value.ownerKey, value.sourceId, value.entryId)] =
        value;
  }

  @override
  Future<MangaReadingProgress?> progress({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async => progressRows[_progressKey(ownerKey, sourceId, entryId)];

  @override
  Future<List<MangaDownloadJob>> downloadJobs({
    MangaDownloadJobStatus? status,
    int limit = 500,
  }) async => downloadRows.values
      .where((job) => status == null || job.status == status)
      .take(limit)
      .toList();
}
