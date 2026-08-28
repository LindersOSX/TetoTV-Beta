import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';
import 'package:anime_tv/features/downloads/domain/offline_anime_snapshot_codec.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = OfflineAnimeSnapshotCodec();
  final updatedAt = DateTime.utc(2026, 8, 24, 12);

  test(
    'round trips the complete catalog summary through versioned metadata',
    () {
      final trailer = AnimeTrailer.tryCreate(
        provider: 'youtube',
        videoId: 'abcdefghijk',
        thumbnailUrl: 'https://cdn.example.test/trailer.jpg',
      );
      final anime = AnimeSummary(
        id: 21,
        idMal: 121,
        title: 'Main title',
        titleEnglish: 'English title',
        titleRomaji: 'Romaji title',
        description: 'Description',
        episodes: 12,
        score: 8.75,
        coverImageUrl: 'https://cdn.example.test/cover.jpg?width=600',
        bannerImageUrl: 'https://cdn.example.test/banner.webp',
        trailer: trailer,
        genres: const ['Comedy', 'Drama'],
        synonyms: const ['Alias'],
        format: 'TV',
        status: 'FINISHED',
        season: 'SPRING',
        seasonYear: 2024,
        durationMinutes: 24,
        nextAiringEpisode: 13,
        isAdult: true,
        metadataSource: CatalogMetadataSource.kitsu,
        studios: const [AnimeStudio(id: 1, name: 'Studio')],
        staff: const [
          AnimePerson(
            id: 2,
            name: 'Director',
            imageUrl: 'https://cdn.example.test/staff.jpg',
          ),
        ],
        characters: const [
          AnimeCharacter(
            id: 3,
            name: 'Hero',
            role: 'MAIN',
            voiceActor: AnimePerson(id: 4, name: 'Actor'),
          ),
        ],
        relatedAnime: const [
          RelatedAnime(
            relationType: 'SEQUEL',
            anime: AnimeSummary(
              id: 22,
              title: 'Sequel',
              description: '',
              episodes: null,
              score: null,
            ),
          ),
        ],
      );

      final metadata = codec.encode(
        anime,
        updatedAt: updatedAt,
        coverRelativePath: 'artwork/21-cover.jpg',
      );
      final restored = codec.decode(metadata);

      expect(
        metadata.schemaVersion,
        OfflineAnimeSnapshotCodec.currentSchemaVersion,
      );
      expect(metadata.metadata['kind'], 'anime-summary');
      expect(restored.id, 21);
      expect(restored.idMal, 121);
      expect(restored.titleEnglish, 'English title');
      expect(restored.score, 8.75);
      expect(restored.genres, ['Comedy', 'Drama']);
      expect(restored.metadataSource, CatalogMetadataSource.kitsu);
      expect(restored.trailer?.videoId, 'abcdefghijk');
      expect(restored.studios.single.name, 'Studio');
      expect(restored.staff.single.name, 'Director');
      expect(restored.characters.single.voiceActor?.name, 'Actor');
      expect(restored.relatedAnime.single.anime.title, 'Sequel');
    },
  );

  test('tolerates future envelopes and malformed optional fields', () {
    final metadata = OfflineMediaMetadata(
      anilistMediaId: 99,
      malMediaId: 199,
      title: 'Durable fallback',
      schemaVersion: 7,
      metadata: <String, Object?>{
        'kind': 'future-kind',
        'version': 999,
        'newField': 'ignored',
        'anime': <String, Object?>{
          'id': 'invalid',
          'title': 123,
          'episodes': '24',
          'score': '7.5',
          'genres': <Object?>['Drama', null, 4, ''],
          'staff': <Object?>[
            <String, Object?>{'id': -1, 'name': 'Invalid'},
          ],
          'coverImageUrl': 'https://user:secret@cdn.example/cover.jpg',
          'bannerImageUrl': 'https://cdn.example/banner.jpg?token=secret',
        },
      },
      updatedAt: updatedAt,
    );

    final restored = codec.decode(metadata);

    expect(restored.id, 99);
    expect(restored.idMal, 199);
    expect(restored.title, 'Durable fallback');
    expect(restored.episodes, 24);
    expect(restored.score, 7.5);
    expect(restored.genres, ['Drama']);
    expect(restored.staff, isEmpty);
    expect(restored.coverImageUrl, isNull);
    expect(restored.bannerImageUrl, isNull);
  });

  test('only applies a pre-verified local file URI override', () {
    final metadata = codec.encode(
      const AnimeSummary(
        id: 5,
        title: 'Offline',
        description: '',
        episodes: 1,
        score: null,
        coverImageUrl: 'https://cdn.example.test/cover.jpg',
      ),
      updatedAt: updatedAt,
    );

    expect(
      codec
          .decode(metadata, verifiedCoverFileUri: Uri.file('/safe/cover.jpg'))
          .coverImageUrl,
      startsWith('file:'),
    );
    expect(
      codec
          .decode(
            metadata,
            verifiedCoverFileUri: Uri.parse('https://attacker.test/cover.jpg'),
          )
          .coverImageUrl,
      'https://cdn.example.test/cover.jpg',
    );
  });
}
