import 'dart:io';

import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/application/offline_catalog_snapshot_service.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/data/public_catalog_artwork_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory root;
  late Database database;
  late DownloadRepository repository;
  late OfflineDownloadStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tetotv-offline-catalog-');
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE offline_media_metadata (
            anilist_media_id INTEGER PRIMARY KEY,
            mal_media_id INTEGER,
            title TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            metadata_json TEXT NOT NULL,
            cover_relative_path TEXT,
            banner_relative_path TEXT,
            updated_at INTEGER NOT NULL
          )
        '''),
        version: 1,
      ),
    );
    repository = DownloadRepository.forDatabase(database);
    storage = OfflineDownloadStorage(resolveRoot: () async => root);
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'pins artwork atomically and returns verified local file URIs',
    () async {
      final service = OfflineCatalogSnapshotService(
        repository: repository,
        storage: storage,
        artworkFetcher: _ArtworkFetcher(),
        clock: () => DateTime.utc(2026, 8, 24, 12),
      );

      final pinned = await service.pin(_anime());
      final loaded = await service.load(41);
      final listed = await service.list();

      expect(pinned.artworkWarnings, isEmpty);
      expect(pinned.hasPinnedCover, isTrue);
      expect(pinned.hasPinnedBanner, isTrue);
      expect(loaded?.anime.coverImageUrl, startsWith('file:'));
      expect(loaded?.anime.bannerImageUrl, startsWith('file:'));
      expect(listed.single.anime.title, 'Offline show');
      expect(
        await root
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.part'))
            .isEmpty,
        isTrue,
      );

      final stored = await repository.mediaMetadata(41);
      expect(stored?.coverRelativePath, startsWith('artwork/41-cover-'));
      expect(stored?.bannerRelativePath, startsWith('artwork/41-banner-'));
    },
  );

  test('does not trust a missing or tampered local artwork file', () async {
    final service = OfflineCatalogSnapshotService(
      repository: repository,
      storage: storage,
      artworkFetcher: _ArtworkFetcher(),
    );
    await service.pin(_anime());
    final metadata = await repository.mediaMetadata(41);
    final cover = await storage.resolveFile(metadata!.coverRelativePath!);
    await cover.writeAsString('not an image');

    final loaded = await service.load(41);

    expect(loaded?.hasPinnedCover, isFalse);
    expect(loaded?.anime.coverImageUrl, 'https://cdn.example.test/cover.jpg');
    expect(loaded?.hasPinnedBanner, isTrue);
  });

  test('keeps textual metadata when artwork is unavailable', () async {
    final service = OfflineCatalogSnapshotService(
      repository: repository,
      storage: storage,
      artworkFetcher: _ArtworkFetcher(fail: true),
    );

    final pinned = await service.pin(_anime());
    final loaded = await service.load(41);

    expect(pinned.artworkWarnings, hasLength(2));
    expect(pinned.hasPinnedCover, isFalse);
    expect(loaded?.anime.title, 'Offline show');
    expect(loaded?.anime.coverImageUrl, 'https://cdn.example.test/cover.jpg');
  });
}

AnimeSummary _anime() => const AnimeSummary(
  id: 41,
  idMal: 141,
  title: 'Offline show',
  description: 'Available without the network.',
  episodes: 12,
  score: 8,
  coverImageUrl: 'https://cdn.example.test/cover.jpg',
  bannerImageUrl: 'https://cdn.example.test/banner.jpg',
);

class _ArtworkFetcher implements PublicCatalogArtworkFetcher {
  _ArtworkFetcher({this.fail = false});

  final bool fail;

  @override
  Future<PublicCatalogArtwork> fetch(Uri uri) async {
    if (fail) {
      throw const PublicCatalogArtworkException(
        'offline',
        'Artwork is unavailable.',
      );
    }
    final marker = uri.path.contains('banner') ? 0x02 : 0x01;
    return PublicCatalogArtwork.validate(
      bytes: [0xff, 0xd8, 0xff, marker, 0x00, 0x00],
      contentType: 'image/jpeg',
    );
  }
}
