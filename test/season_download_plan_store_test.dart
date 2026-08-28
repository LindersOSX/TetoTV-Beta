import 'dart:io';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/season_download_plan_store.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory temporary;
  late Database database;
  late DownloadRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tetotv-season-plan-');
    database = await databaseFactoryFfi.openDatabase(
      '${temporary.path}${Platform.pathSeparator}plans.db',
      options: OpenDatabaseOptions(
        version: 9,
        onCreate: (db, _) => createOfflineDownloadTables(db),
      ),
    );
    repository = DownloadRepository.forDatabase(database);
  });

  tearDown(() async {
    await database.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('round trips only the durable season request', () async {
    final store = SeasonDownloadPlanStore(
      repository: repository,
      clock: () => DateTime.utc(2026, 8, 24),
    );
    final plan = SeasonDownloadPlan(
      anime: const AnimeSummary(
        id: 44,
        idMal: 144,
        title: 'Main title',
        titleEnglish: 'English title',
        titleRomaji: 'Romaji title',
        description: '',
        episodes: 24,
        score: null,
        synonyms: ['Alias'],
        seasonYear: 2025,
      ),
      episodeCount: 24,
      quality: SeasonDownloadQuality.p1080,
      sourcePolicy: SeasonDownloadSourcePolicy.automatic,
      preferredAudio: PlaybackAudioPreference.dub,
    );

    await store.save(plan);
    final restored = await store.load();

    expect(restored?.anime.id, 44);
    expect(restored?.anime.idMal, 144);
    expect(restored?.anime.titleEnglish, 'English title');
    expect(restored?.anime.synonyms, ['Alias']);
    expect(restored?.episodeCount, 24);
    expect(restored?.quality, SeasonDownloadQuality.p1080);
    expect(restored?.sourcePolicy, SeasonDownloadSourcePolicy.automatic);
    expect(restored?.preferredAudio, PlaybackAudioPreference.dub);
    final raw = await repository.pendingSeasonDownloadJson();
    expect(raw, isNot(contains('sourceUri')));
    expect(raw, isNot(contains('token')));
    expect(raw, isNot(contains('magnet')));
  });

  test('damaged plan is discarded without touching download jobs', () async {
    await repository.savePendingSeasonDownload(
      anilistMediaId: 44,
      planJson: '{"schema":999}',
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    final store = SeasonDownloadPlanStore(repository: repository);

    expect(await store.load(), isNull);
    expect(await repository.pendingSeasonDownloadJson(), isNull);
  });
}
