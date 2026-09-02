import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

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
    onCreate: (database, _) async {
      await database.execute('''
        CREATE TABLE manga_library_entries (
          owner_key TEXT NOT NULL,
          source_id TEXT NOT NULL,
          entry_id TEXT NOT NULL,
          title TEXT NOT NULL,
          metadata_json TEXT NOT NULL,
          cover_url TEXT,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (owner_key, source_id, entry_id)
        )
      ''');
      await database.execute('''
        CREATE TABLE manga_reading_progress (
          owner_key TEXT NOT NULL,
          source_id TEXT NOT NULL,
          entry_id TEXT NOT NULL,
          chapter_id TEXT NOT NULL,
          chapter_number REAL,
          page_index INTEGER NOT NULL,
          page_offset REAL NOT NULL,
          page_count INTEGER,
          completed INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (owner_key, source_id, entry_id)
        )
      ''');
    },
  ),
);
