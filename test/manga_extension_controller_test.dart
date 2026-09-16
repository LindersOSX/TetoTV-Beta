import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  test(
    'update batches cover more than 500 titles across restarts, including failed sources',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
      final database = await _openMangaDatabase();
      addTearDown(database.close);
      final store = MangaStore(databaseProvider: () async => database);
      for (var i = 0; i < 620; i++) {
        await store.upsertLibraryEntry(_sweepEntry(i));
      }
      await store.upsertLibraryEntry(_sweepEntry(900, legacy: true));
      await store.upsertLibraryEntry(_sweepEntry(901, owner: 'owner.other'));
      expect(
        await store.libraryEntries('owner.test'),
        hasLength(500),
        reason: 'UI cap unchanged',
      );
      final seen = <String>[];
      final remaining = <int>[];
      for (var batch = 0; batch < 7; batch++) {
        final controller = _SweepController(
          store: store,
          seen: seen,
          failRequests: batch == 0,
          owner: () async => 'owner.test',
        );
        final result = await controller.checkLibraryUpdates();
        controller.dispose();
        expect(result.checked + result.failed, batch == 6 ? 20 : 100);
        expect(result.failed, batch == 0 ? 100 : 0);
        remaining.add(result.remaining);
      }
      expect(remaining, [520, 420, 320, 220, 120, 20, 0]);
      expect(seen, hasLength(620));
      expect(
        seen.toSet(),
        hasLength(620),
        reason: 'Failed sources advance too; no batch-head starvation',
      );
      final nextPass = _SweepController(
        store: store,
        seen: seen,
        owner: () async => 'owner.test',
      );
      addTearDown(nextPass.dispose);
      expect((await nextPass.checkLibraryUpdates()).remaining, 520);
      expect(
        seen.skip(620),
        seen.take(100),
        reason: 'End of pass resets explicitly',
      );
      expect(
        (await store.libraryEntry(
          ownerKey: 'owner.test',
          sourceId: _sweepEntry(0).sourceId,
          entryId: _sweepEntry(0).entryId,
        ))!.chapterCheckedAt,
        isNull,
        reason: 'Failed attempt is not a successful snapshot timestamp',
      );
    },
  );

  test(
    'keyset update page is owner-scoped, deterministic and bounded independently of UI order',
    () async {
      final database = await _openMangaDatabase();
      addTearDown(database.close);
      final store = MangaStore(databaseProvider: () async => database);
      final entries = [for (var i = 0; i < 105; i++) _sweepEntry(i)]
        ..sort(
          (a, b) => a.sourceId == b.sourceId
              ? a.entryId.compareTo(b.entryId)
              : a.sourceId.compareTo(b.sourceId),
        );
      for (final entry in entries.reversed) {
        await store.upsertLibraryEntry(entry);
      }
      await store.upsertLibraryEntry(_sweepEntry(500, legacy: true));
      await store.upsertLibraryEntry(_sweepEntry(501, owner: 'owner.other'));
      final first = await store.extensionLibraryUpdatePage(
        'owner.test',
        limit: 9999,
      );
      expect(first.remaining, 105);
      expect(first.entries, hasLength(100));
      expect(
        first.entries.map((e) => e.entryId),
        entries.take(100).map((e) => e.entryId),
      );
      final cursor = first.entries.last;
      await store.deleteLibraryEntry(
        ownerKey: cursor.ownerKey,
        sourceId: cursor.sourceId,
        entryId: cursor.entryId,
      );
      final next = await store.extensionLibraryUpdatePage(
        'owner.test',
        afterSourceId: cursor.sourceId,
        afterEntryId: cursor.entryId,
      );
      expect(next.remaining, 5);
      expect(
        next.entries.map((e) => e.entryId),
        entries.skip(100).map((e) => e.entryId),
      );
      await expectLater(
        store.extensionLibraryUpdatePage(
          'owner.test',
          afterSourceId: cursor.sourceId,
        ),
        throwsFormatException,
      );
    },
  );

  test('concurrent update actions share one sequential batch', () async {
    FlutterSecureStorage.setMockInitialValues({});
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
    final database = await _openMangaDatabase();
    addTearDown(database.close);
    final store = MangaStore(databaseProvider: () async => database);
    for (var i = 0; i < 3; i++) {
      await store.upsertLibraryEntry(_sweepEntry(i));
    }
    final entered = Completer<void>();
    final gate = Completer<void>();
    final seen = <String>[];
    final controller = _SweepController(
      store: store,
      seen: seen,
      owner: () async => 'owner.test',
      onRequest: () async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
      },
    );
    addTearDown(controller.dispose);
    final first = controller.checkLibraryUpdates();
    await entered.future;
    final second = controller.checkLibraryUpdates();
    expect(identical(first, second), true);
    expect(seen, hasLength(1));
    gate.complete();
    expect((await first).checked, 3);
    expect((await second).remaining, 0);
    expect(seen, hasLength(3));
  });

  test(
    'profile change stops an update batch without checking the next title',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
      final database = await _openMangaDatabase();
      addTearDown(database.close);
      final store = MangaStore(databaseProvider: () async => database);
      for (var i = 0; i < 3; i++) {
        await store.upsertLibraryEntry(_sweepEntry(i));
      }
      var owner = 'owner.test';
      final seen = <String>[];
      final controller = _SweepController(
        store: store,
        seen: seen,
        owner: () async => owner,
        onRequest: () async {
          owner = 'owner.other';
        },
      );
      addTearDown(controller.dispose);
      await expectLater(controller.checkLibraryUpdates(), throwsStateError);
      expect(seen, hasLength(1));
      expect(await store.libraryEntries('owner.other'), isEmpty);
      owner = 'owner.test';
      final resumed = _SweepController(
        store: store,
        seen: seen,
        owner: () async => owner,
      );
      addTearDown(resumed.dispose);
      expect((await resumed.checkLibraryUpdates()).checked, 2);
      expect(seen.toSet(), hasLength(3));
    },
  );

  test(
    'disposal cancels the active provider lookup and stops the batch',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
      final database = await _openMangaDatabase();
      addTearDown(database.close);
      final store = MangaStore(databaseProvider: () async => database);
      await store.upsertLibraryEntry(_sweepEntry(0));
      await store.upsertLibraryEntry(_sweepEntry(1));
      final entered = Completer<void>();
      final gate = Completer<void>();
      final seen = <String>[];
      final controller = _SweepController(
        store: store,
        seen: seen,
        owner: () async => 'owner.test',
        onRequest: () async {
          entered.complete();
          await gate.future;
        },
      );
      final pending = controller.checkLibraryUpdates();
      final assertion = expectLater(pending, throwsStateError);
      await entered.future;
      controller.dispose();
      expect(controller.lastCancellation?.isCancelled, true);
      gate.complete();
      await assertion;
      expect(seen, hasLength(1));
    },
  );

  test(
    'saved manga can be removed with its provider absent, retaining reading history',
    () async {
      final database = await _openMangaDatabase();
      addTearDown(database.close);
      final store = MangaStore(databaseProvider: () async => database);
      final identities = _MemoryIdentityStore();
      final controller = MangaExtensionController(
        addonStore: _NoopAddonStore(),
        mangaStore: store,
        identityStore: identities,
        ownerKey: () async => 'owner.test',
      );
      addTearDown(controller.dispose);
      final title = MangaExtensionTitle(
        providerId: 'missing',
        providerName: 'Missing',
        id: 'opaque-identity',
        title: 'A title',
      );
      await controller.toggleLibrary(title);
      final entry = (await store.libraryEntries('owner.test')).single;
      await store.setChapterRead(
        ownerKey: entry.ownerKey,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
        chapterId: 'chapter',
        completed: true,
      );
      await controller.removeLibraryEntry(entry);
      expect(await store.libraryEntries('owner.test'), isEmpty);
      expect(
        await identities.read(
          ownerKey: entry.ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        ),
        isNull,
      );
      expect(
        (await store.chapterProgress(
          ownerKey: entry.ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
          chapterId: 'chapter',
        ))!.completed,
        isTrue,
      );
    },
  );

  test('another profile cannot remove or reopen a saved manga', () async {
    final database = await _openMangaDatabase();
    addTearDown(database.close);
    final store = MangaStore(databaseProvider: () async => database);
    final controller = MangaExtensionController(
      addonStore: _NoopAddonStore(),
      mangaStore: store,
      identityStore: _MemoryIdentityStore(),
      ownerKey: () async => 'owner.current',
    );
    addTearDown(controller.dispose);
    final entry = MangaLibraryEntry(
      ownerKey: 'owner.other',
      sourceId: 'source',
      entryId: 'entry',
      title: 'Private',
      metadata: const {'kind': 'seanime-manga-extension'},
      updatedAt: DateTime.now(),
    );
    await store.upsertLibraryEntry(entry);
    await expectLater(controller.removeLibraryEntry(entry), throwsStateError);
    await expectLater(controller.openLibraryEntry(entry), throwsStateError);
    expect(await store.libraryEntries('owner.other'), hasLength(1));
  });

  test('installed provider state retains manga extensions only', () async {
    final database = await _openMangaDatabase();
    addTearDown(database.close);
    final controller = MangaExtensionController(
      addonStore: _NoopAddonStore(),
      mangaStore: MangaStore(databaseProvider: () async => database),
      identityStore: _MemoryIdentityStore(),
      ownerKey: () async => 'owner.test',
    );
    addTearDown(controller.dispose);

    controller.syncInstalled(<InstalledStreamingAddon>[
      _addon('anime.source', type: 'online-stream-provider'),
      _addon('manga.source', type: 'manga-provider'),
    ]);

    expect(controller.state.providers, hasLength(1));
    expect(controller.state.providers.single.manifest.id, 'manga.source');
  });

  test('a cancelled health lookup cannot revive a stale search', () async {
    final database = await _openMangaDatabase();
    addTearDown(database.close);
    final addonStore = _DelayedHealthAddonStore();
    final controller = MangaExtensionController(
      addonStore: addonStore,
      mangaStore: MangaStore(databaseProvider: () async => database),
      identityStore: _MemoryIdentityStore(),
      ownerKey: () async => 'owner.test',
    );
    addTearDown(controller.dispose);
    controller.syncInstalled(<InstalledStreamingAddon>[
      _addon('manga.source', type: 'manga-provider'),
    ]);

    final staleSearch = controller.search('stale query');
    controller.selectProvider(null);
    addonStore.health.complete(const <String, ProviderHealth>{});

    expect(await staleSearch, isFalse);
    expect(controller.state.searching, isFalse);
    expect(controller.state.query, isEmpty);
    expect(controller.state.results, isEmpty);
  });

  test('extension models defensively copy capabilities and bound numbers', () {
    final imageHeaders = <String, String>{'Referer': 'https://reader.example/'};
    final pageHeaders = <String, String>{'X-Page': 'one'};
    final title = MangaExtensionTitle(
      providerId: 'manga.source',
      providerName: 'Manga Source',
      id: 'title-id',
      title: 'Title',
      imageHeaders: imageHeaders,
    );
    final page = MangaExtensionPage(
      uri: Uri.parse('https://cdn.example/page.jpg'),
      index: 0,
      headers: pageHeaders,
    );

    imageHeaders['Authorization'] = 'Bearer later';
    pageHeaders['X-Page'] = 'mutated';

    expect(title.imageHeaders, <String, String>{
      'Referer': 'https://reader.example/',
    });
    expect(page.headers, <String, String>{'X-Page': 'one'});
    expect(
      const MangaExtensionChapter(
        id: 'chapter',
        title: 'Chapter',
        chapter: 'NaN',
        index: 0,
      ).chapterNumber,
      isNull,
    );
  });

  test(
    'library keeps opaque extension identity in protected storage',
    () async {
      final database = await _openMangaDatabase();
      addTearDown(database.close);
      final identities = _MemoryIdentityStore();
      final store = MangaStore(databaseProvider: () async => database);
      final controller = MangaExtensionController(
        addonStore: _NoopAddonStore(),
        mangaStore: store,
        identityStore: identities,
        ownerKey: () async => 'owner.test',
      );
      addTearDown(controller.dispose);
      controller.syncInstalled(<InstalledStreamingAddon>[
        _addon('manga.source', type: 'manga-provider'),
      ]);
      final title = MangaExtensionTitle(
        providerId: 'manga.source',
        providerName: 'Manga Source',
        id: 'private-upstream-title-id',
        title: 'Example title',
        year: 2026,
        image: Uri.parse('https://images.example/cover.jpg'),
        imageHeaders: const <String, String>{
          'Referer': 'https://reader.example/',
        },
      );

      expect(await controller.toggleLibrary(title), isTrue);
      final entries = await store.libraryEntries('owner.test');
      expect(entries, hasLength(1));
      expect(entries.single.entryId, isNot(contains(title.id)));
      expect(entries.single.sourceId, isNot(contains(title.providerId)));
      expect(entries.single.coverUri, isNull);
      expect(entries.single.metadata.toString(), isNot(contains(title.id)));

      final reopened = await controller.openLibraryEntry(entries.single);
      expect(reopened?.id, title.id);
      expect(reopened?.title, title.title);

      expect(await controller.toggleLibrary(title), isFalse);
      expect(await store.libraryEntries('owner.test'), isEmpty);
      expect(
        await identities.read(
          ownerKey: 'owner.test',
          sourceId: mangaExtensionSourceId(title.providerId),
          entryId: mangaExtensionEntryId(title.providerId, title.id),
        ),
        isNull,
      );
    },
  );

  test('stable database identifiers do not expose provider values', () {
    const provider = 'private.provider.example';
    const manga = 'private/manga/123';
    const chapter = 'chapter-secret-9';

    final sourceId = mangaExtensionSourceId(provider);
    final entryId = mangaExtensionEntryId(provider, manga);
    final chapterId = mangaExtensionChapterId(provider, manga, chapter);

    expect(sourceId, startsWith('extension.'));
    expect(entryId, startsWith('publication.'));
    expect(chapterId, startsWith('chapter.'));
    for (final value in <String>[sourceId, entryId, chapterId]) {
      expect(value, isNot(contains(provider)));
      expect(value, isNot(contains(manga)));
      expect(value, isNot(contains(chapter)));
    }
  });

  test('secure identity storage rejects unsafe identifiers', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    addTearDown(
      () => FlutterSecureStorage.setMockInitialValues(<String, String>{}),
    );
    const storage = FlutterSecureStorage();
    const identities = ProtectedMangaExtensionIdentityStore(storage);

    await identities.write(
      ownerKey: 'owner.test',
      sourceId: 'extension.test',
      entryId: 'publication.test',
      mangaId: 'remote-id',
    );
    expect(
      await identities.read(
        ownerKey: 'owner.test',
        sourceId: 'extension.test',
        entryId: 'publication.test',
      ),
      'remote-id',
    );
    expect(
      () => identities.write(
        ownerKey: 'owner.test',
        sourceId: 'extension.test',
        entryId: 'publication.test',
        mangaId: 'unsafe\nvalue',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

MangaLibraryEntry _sweepEntry(
  int i, {
  String owner = 'owner.test',
  bool legacy = false,
}) => MangaLibraryEntry(
  ownerKey: owner,
  sourceId: legacy
      ? 'source.legacy'
      : mangaExtensionSourceId('provider.${i % 3}'),
  entryId: mangaExtensionEntryId('provider.${i % 3}', 'title-$i'),
  title: 'Title $i',
  metadata: {'kind': legacy ? 'opds' : 'seanime-manga-extension'},
  updatedAt: DateTime.utc(2026).add(Duration(seconds: i)),
);

class _SweepController extends MangaExtensionController {
  _SweepController({
    required MangaStore store,
    required this.seen,
    required Future<String> Function() owner,
    this.failRequests = false,
    this.onRequest,
  }) : super(
         addonStore: _NoopAddonStore(),
         mangaStore: store,
         identityStore: _MemoryIdentityStore(),
         ownerKey: owner,
       );
  final List<String> seen;
  final bool failRequests;
  final Future<void> Function()? onRequest;
  WebProviderCancellation? lastCancellation;
  @override
  Future<MangaExtensionTitle?> openLibraryEntry(
    MangaLibraryEntry entry,
  ) async => MangaExtensionTitle(
    providerId: 'test',
    providerName: 'Test',
    id: '${entry.sourceId}/${entry.entryId}',
    title: entry.title,
  );
  @override
  Future<List<MangaExtensionChapter>> chapters(
    MangaExtensionTitle title, {
    String? expectedOwnerKey,
    WebProviderCancellation? cancellation,
  }) async {
    expect(expectedOwnerKey, 'owner.test');
    lastCancellation = cancellation;
    seen.add(title.id);
    await onRequest?.call();
    cancellation?.throwIfCancelled();
    if (failRequests) throw StateError('offline');
    return const [];
  }
}

InstalledStreamingAddon _addon(String id, {required String type}) =>
    InstalledStreamingAddon(
      manifest: MarketplaceAddon(
        id: id,
        name: id,
        description: 'Test provider',
        author: 'Tests',
        manifestUri: Uri.parse('https://catalog.example/$id/manifest.json'),
        repositoryUrl: 'https://catalog.example/marketplace.json',
        language: 'javascript',
        type: type,
        locale: 'en',
        payloadUri: Uri.parse('https://catalog.example/$id/provider.js'),
      ),
      payload: 'class Provider {}',
      enabled: true,
      installedAt: DateTime.utc(2026, 9, 2),
      updatedAt: DateTime.utc(2026, 9, 2),
    );

class _NoopAddonStore extends AddonStore {
  _NoopAddonStore() : super(TetoTvDatabase.instance);

  @override
  Future<Map<String, ProviderHealth>> providerHealth() async => const {};
}

class _DelayedHealthAddonStore extends AddonStore {
  _DelayedHealthAddonStore() : super(TetoTvDatabase.instance);

  final Completer<Map<String, ProviderHealth>> health =
      Completer<Map<String, ProviderHealth>>();

  @override
  Future<Map<String, ProviderHealth>> providerHealth() => health.future;
}

class _MemoryIdentityStore implements MangaExtensionIdentityStore {
  final Map<String, String> _values = <String, String>{};

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

Future<Database> _openMangaDatabase() => databaseFactoryFfi.openDatabase(
  inMemoryDatabasePath,
  options: OpenDatabaseOptions(
    version: 1,
    onConfigure: configureTetoTvDatabase,
    onCreate: (database, _) => createMangaTables(database),
  ),
);
