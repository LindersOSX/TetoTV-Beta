import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/local_media/application/library_episode_source_service.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const episode = EpisodeReference(
    anilistMediaId: 123,
    malMediaId: 456,
    title: 'Frieren: Beyond Journey’s End',
    titleEnglish: "Frieren: Beyond Journey's End",
    titleRomaji: 'Sousou no Frieren',
    alternativeTitles: ['Frieren at the Funeral'],
    episode: 7,
  );

  test(
    'catalog matcher accepts exact bounded aliases and harmless year tags',
    () {
      final keys = libraryCatalogTitleKeys(episode);

      expect(
        librarySeriesMatchesCatalog(
          serverSeriesTitle: 'Frieren: Beyond Journey’s End (2023)',
          catalogTitleKeys: keys,
        ),
        isTrue,
      );
      expect(
        librarySeriesMatchesCatalog(
          serverSeriesTitle: 'Sousou no Frieren',
          catalogTitleKeys: keys,
        ),
        isTrue,
      );
      expect(libraryCatalogSearchTerms(episode), hasLength(4));
      expect(libraryCatalogSearchTerms(episode), isNot(contains('123')));
      expect(libraryCatalogSearchTerms(episode), isNot(contains('456')));
    },
  );

  test('decorative catalog symbols match metadata-provider title spacing', () {
    const luckyStar = EpisodeReference(
      anilistMediaId: 1887,
      malMediaId: 1887,
      title: 'Lucky☆Star',
      year: 2007,
      episode: 19,
    );
    const jellyfinEpisode = JellyfinMediaItem(
      id: 'lucky-star-episode-19',
      name: 'There is Substance in 2-D',
      type: 'Episode',
      seriesName: 'Lucky Star',
      productionYear: 2007,
      seriesProductionYear: 2007,
      seasonNumber: 1,
      episodeNumber: 19,
    );

    expect(normalizeLibraryTitle(luckyStar.title), 'lucky star');
    expect(
      jellyfinItemMatchesEpisode(item: jellyfinEpisode, episode: luckyStar),
      isTrue,
    );
  });

  test('authoritative anime IDs win and conflicting exact IDs fail closed', () {
    const lain = EpisodeReference(
      anilistMediaId: 339,
      malMediaId: 339,
      title: 'Serial Experiments Lain',
      episode: 5,
    );
    const idMatched = JellyfinMediaItem(
      id: 'lain-episode-05',
      name: 'Distortion',
      type: 'Episode',
      seriesName: 'Lain (TMDb order)',
      seasonNumber: 1,
      episodeNumber: 5,
      seriesProviderIds: {'AniList': '339'},
    );
    const conflicting = JellyfinMediaItem(
      id: 'lain-wrong-id',
      name: 'Distortion',
      type: 'Episode',
      seriesName: 'Serial Experiments Lain',
      seasonNumber: 1,
      episodeNumber: 5,
      seriesProviderIds: {'MyAnimeList': '999999'},
    );

    expect(jellyfinItemMatchesEpisode(item: idMatched, episode: lain), isTrue);
    expect(
      jellyfinItemMatchesEpisode(item: conflicting, episode: lain),
      isFalse,
    );
  });

  test('bounded release-group series prefixes match without fuzzy titles', () {
    const lain = EpisodeReference(
      anilistMediaId: 339,
      malMediaId: 339,
      title: 'Serial Experiments Lain',
      episode: 5,
    );
    const jellyfin = JellyfinMediaItem(
      id: 'reaktor-lain-05',
      name: 'Distortion',
      type: 'Episode',
      seriesName: '[Reaktor] Serial Experiments Lain',
      seasonNumber: 1,
      episodeNumber: 5,
    );
    const plex = PlexMediaItem(
      ratingKey: 'plex-reaktor-lain-05',
      key: '/library/metadata/plex-reaktor-lain-05',
      title: 'Distortion',
      type: PlexMediaType.episode,
      grandparentTitle: '[Reaktor] Serial Experiments Lain',
      parentIndex: 1,
      index: 5,
    );
    const unrelated = JellyfinMediaItem(
      id: 'reaktor-lain-commentary-05',
      name: 'Commentary',
      type: 'Episode',
      seriesName: '[Reaktor] Serial Experiments Lain Commentary',
      seasonNumber: 1,
      episodeNumber: 5,
    );
    const doubleTagged = JellyfinMediaItem(
      id: 'double-tagged-lain-05',
      name: 'Distortion',
      type: 'Episode',
      seriesName: '[Reaktor] [1080p] Serial Experiments Lain',
      seasonNumber: 1,
      episodeNumber: 5,
    );

    expect(jellyfinItemMatchesEpisode(item: jellyfin, episode: lain), isTrue);
    expect(plexItemMatchesEpisode(item: plex, episode: lain), isTrue);
    expect(jellyfinItemMatchesEpisode(item: unrelated, episode: lain), isFalse);
    expect(
      jellyfinItemMatchesEpisode(item: doubleTagged, episode: lain),
      isFalse,
      reason: 'only one bounded release-group prefix may be ignored',
    );
  });

  test(
    'release-decorated Jellyfin series matches exact Lain identity only',
    () {
      const lain = EpisodeReference(
        anilistMediaId: 339,
        malMediaId: 339,
        title: 'Serial Experiments Lain',
        year: 1998,
        episode: 1,
      );
      const decoratedTitle =
          '[Reaktor] Serial Experiments Lain - Complete '
          '[1080p][x265][10-bit][Dual-Audio]';
      const matching = JellyfinMediaItem(
        id: 'reaktor-lain-episode-01',
        name: 'Serial Experiments Lain - E01',
        type: 'Episode',
        seriesName: decoratedTitle,
      );
      const unrelated = JellyfinMediaItem(
        id: 'reaktor-lain-commentary-01',
        name: 'Serial Experiments Lain - E01',
        type: 'Episode',
        seriesName:
            '[Reaktor] Serial Experiments Lain Commentary - Complete '
            '[1080p][x265][10-bit][Dual-Audio]',
      );
      const wrongYear = JellyfinMediaItem(
        id: 'reaktor-lain-remake-01',
        name: 'Serial Experiments Lain - E01',
        type: 'Episode',
        seriesName:
            '[Reaktor] Serial Experiments Lain (2018) - Complete '
            '[1080p][x265][10-bit][Dual-Audio]',
      );

      expect(
        librarySeriesMayContainEpisode(
          serverSeriesTitle: decoratedTitle,
          episode: lain,
        ),
        isTrue,
      );
      expect(jellyfinItemMatchesEpisode(item: matching, episode: lain), isTrue);
      expect(
        jellyfinItemMatchesEpisode(item: unrelated, episode: lain),
        isFalse,
      );
      expect(
        jellyfinItemMatchesEpisode(item: wrongYear, episode: lain),
        isFalse,
        reason: 'release decoration must not bypass remake-year safety',
      );
    },
  );

  test(
    'missing server index falls back only to a full title and episode token',
    () {
      const lain = EpisodeReference(
        anilistMediaId: 339,
        title: 'Serial Experiments Lain',
        episode: 5,
      );
      const safeFallback = JellyfinMediaItem(
        id: 'lain-fallback-05',
        name: 'Episode 05',
        type: 'Episode',
        seriesName: 'Serial Experiments Lain',
        seasonNumber: 1,
      );
      const vagueEpisodeTitle = JellyfinMediaItem(
        id: 'lain-vague-05',
        name: 'Protocol 05',
        type: 'Episode',
        seriesName: 'Serial Experiments Lain',
        seasonNumber: 1,
      );
      const authoritativeConflict = JellyfinMediaItem(
        id: 'lain-conflict-06',
        name: 'Serial Experiments Lain - Episode 05',
        type: 'Episode',
        seriesName: 'Serial Experiments Lain',
        seasonNumber: 1,
        episodeNumber: 6,
      );
      const plexSafeFallback = PlexMediaItem(
        ratingKey: 'plex-lain-fallback-05',
        key: '/library/metadata/plex-lain-fallback-05',
        title: 'E05',
        type: PlexMediaType.episode,
        grandparentTitle: 'Serial Experiments Lain',
        parentIndex: 1,
      );
      const plexWrongFallback = PlexMediaItem(
        ratingKey: 'plex-lain-fallback-04',
        key: '/library/metadata/plex-lain-fallback-04',
        title: 'Episode 04',
        type: PlexMediaType.episode,
        grandparentTitle: 'Serial Experiments Lain',
        parentIndex: 1,
      );

      expect(
        jellyfinItemMatchesEpisode(item: safeFallback, episode: lain),
        isTrue,
      );
      expect(
        jellyfinItemMatchesEpisode(item: vagueEpisodeTitle, episode: lain),
        isFalse,
      );
      expect(
        jellyfinItemMatchesEpisode(item: authoritativeConflict, episode: lain),
        isFalse,
        reason: 'IndexNumber must override filename-like display text',
      );
      expect(
        plexItemMatchesEpisode(item: plexSafeFallback, episode: lain),
        isTrue,
      );
      expect(
        plexItemMatchesEpisode(item: plexWrongFallback, episode: lain),
        isFalse,
      );

      final jellyfinSource = LibraryEpisodeSource.jellyfin(safeFallback);
      final plexSource = LibraryEpisodeSource.plex(plexSafeFallback);
      expect(jellyfinSource.episodeNumber, 5);
      expect(plexSource.episodeNumber, 5);
      expect(
        unambiguousLibraryAutoPickSources(
          sources: [jellyfinSource],
          episode: lain,
        ),
        [same(jellyfinSource)],
      );
      expect(
        unambiguousLibraryAutoPickSources(sources: [plexSource], episode: lain),
        [same(plexSource)],
      );
      expect(LibraryEpisodeSource.jellyfin(vagueEpisodeTitle).episodeNumber, 0);

      LocalMediaDocument document(String name, String id) => LocalMediaDocument(
        uri: Uri.parse('content://media/external/video/$id'),
        name: name,
        mimeType: 'video/x-matroska',
        persistedReadPermission: true,
      );
      expect(
        localDocumentMatchesEpisode(
          document: document(
            '[Reaktor] Serial Experiments Lain - 05 [BD].mkv',
            'reaktor-lain-05',
          ),
          episode: lain,
        ),
        isTrue,
      );
      expect(
        localDocumentMatchesEpisode(
          document: document(
            '[Reaktor] Serial Experiments Lain Commentary - 05 [BD].mkv',
            'lain-commentary-05',
          ),
          episode: lain,
        ),
        isFalse,
        reason:
            'an exact title token cannot authorize a longer unrelated title',
      );
    },
  );

  test('season-labeled catalog media maps only to the same server season', () {
    const seasonTwo = EpisodeReference(
      anilistMediaId: 11111,
      title: 'Example Show 2nd Season',
      episode: 3,
      format: 'TV',
    );
    JellyfinMediaItem jellyfin(int season) => JellyfinMediaItem(
      id: 'example-season-$season-03',
      name: 'Episode Three',
      type: 'Episode',
      seriesName: 'Example Show',
      seasonNumber: season,
      episodeNumber: 3,
    );
    PlexMediaItem plex(int season) => PlexMediaItem(
      ratingKey: 'example-season-$season-03',
      key: '/library/metadata/example-season-$season-03',
      title: 'Episode Three',
      type: PlexMediaType.episode,
      grandparentTitle: 'Example Show',
      parentIndex: season,
      index: 3,
    );

    expect(libraryCatalogSeasonHint(seasonTwo), 2);
    expect(
      jellyfinItemMatchesEpisode(item: jellyfin(2), episode: seasonTwo),
      isTrue,
    );
    expect(
      jellyfinItemMatchesEpisode(item: jellyfin(1), episode: seasonTwo),
      isFalse,
    );
    expect(plexItemMatchesEpisode(item: plex(2), episode: seasonTwo), isTrue);
    expect(plexItemMatchesEpisode(item: plex(1), episode: seasonTwo), isFalse);
  });

  test('Steins Gate titled specials map safely to parent season zero', () {
    const title = 'Steins;Gate: Soumei Eichi no Cognitive Computing';
    expect(
      libraryCatalogHierarchySearchTerms(
        const EpisodeReference(
          anilistMediaId: 99900,
          title: title,
          episode: 1,
          format: 'SPECIAL',
        ),
      ),
      contains('Steins;Gate'),
    );
    for (var number = 1; number <= 4; number++) {
      final special = EpisodeReference(
        anilistMediaId: 99900,
        malMediaId: 99901,
        title: title,
        year: 2014,
        episode: number,
        format: 'SPECIAL',
      );
      final jellyfin = JellyfinMediaItem(
        id: 'steins-special-$number',
        name: 'Cognitive Computing $number',
        type: 'Episode',
        seriesName: 'Steins;Gate',
        seriesProductionYear: 2011,
        seasonNumber: 0,
        episodeNumber: number,
        // A parent-show ID can legitimately differ because AniList/MAL model
        // this special as separate media while Jellyfin uses Season 0.
        seriesProviderIds: const {'MyAnimeList': '9253'},
      );
      final plex = PlexMediaItem(
        ratingKey: 'steins-special-$number',
        key: '/library/metadata/steins-special-$number',
        title: 'Cognitive Computing $number',
        type: PlexMediaType.episode,
        grandparentTitle: 'Steins;Gate',
        seriesYear: 2011,
        parentIndex: 0,
        index: number,
      );
      final device = LocalMediaDocument(
        uri: Uri.parse('content://media/external/video/steins-$number'),
        name: '[Trix] $title - 0$number [ABC123].mkv',
        mimeType: 'video/x-matroska',
        persistedReadPermission: true,
      );

      expect(libraryCatalogSeasonHint(special), 0);
      expect(
        jellyfinItemMatchesEpisode(item: jellyfin, episode: special),
        isTrue,
      );
      expect(
        jellyfinItemMatchesEpisode(
          item: JellyfinMediaItem(
            id: 'steins-full-title-$number',
            name: 'Episode $number',
            type: 'Episode',
            seriesName: 'Steins;Gate Soumei Eichi no Cognitive Computing',
            episodeNumber: number,
          ),
          episode: special,
        ),
        isTrue,
      );
      expect(plexItemMatchesEpisode(item: plex, episode: special), isTrue);
      expect(
        localDocumentMatchesEpisode(document: device, episode: special),
        isTrue,
      );
      expect(
        jellyfinItemMatchesEpisode(
          item: JellyfinMediaItem(
            id: 'steins-wrong-season-$number',
            name: 'Cognitive Computing $number',
            type: 'Episode',
            seriesName: 'Steins;Gate',
            seasonNumber: 1,
            episodeNumber: number,
          ),
          episode: special,
        ),
        isFalse,
      );
    }
  });

  test('special parent parsing preserves colons inside franchise names', () {
    const special = EpisodeReference(
      anilistMediaId: 100049,
      title: 'Re:ZERO -Starting Life in Another World-: Memory Snow',
      episode: 1,
      format: 'SPECIAL',
    );
    final terms = libraryCatalogHierarchySearchTerms(special);

    expect(terms, contains('Re:ZERO -Starting Life in Another World-'));
    expect(terms, isNot(contains('Re')));
    expect(
      jellyfinItemMatchesEpisode(
        item: const JellyfinMediaItem(
          id: 'rezero-memory-snow-episode',
          name: 'Memory Snow',
          type: 'Episode',
          seriesName: 'Re ZERO Starting Life in Another World',
          seasonNumber: 0,
          episodeNumber: 1,
        ),
        episode: special,
      ),
      isTrue,
    );
    expect(
      jellyfinItemMatchesEpisode(
        item: const JellyfinMediaItem(
          id: 'ambiguous-re-series-episode',
          name: 'Memory Snow',
          type: 'Episode',
          seriesName: 'Re',
          seasonNumber: 0,
          episodeNumber: 1,
        ),
        episode: special,
      ),
      isFalse,
    );
  });

  test(
    'trusted cross-database IDs match only through an explicit crosswalk',
    () {
      const mapped = EpisodeReference(
        anilistMediaId: 1887,
        malMediaId: 1887,
        title: 'Lucky☆Star',
        episode: 1,
        publicProviderIds: {'tmdb': '31911', 'tvdb': '80554'},
      );
      const unmapped = EpisodeReference(
        anilistMediaId: 1887,
        malMediaId: 1887,
        title: 'Lucky☆Star',
        episode: 1,
      );
      const tmdbBacked = JellyfinMediaItem(
        id: 'lucky-tmdb-episode-01',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Unrelated metadata title',
        seasonNumber: 1,
        episodeNumber: 1,
        seriesProviderIds: {'tmdb': '31911'},
      );

      expect(
        jellyfinItemMatchesEpisode(item: tmdbBacked, episode: mapped),
        true,
      );
      expect(
        jellyfinItemMatchesEpisode(item: tmdbBacked, episode: unmapped),
        false,
        reason: 'TMDb is never compared directly to AniList or MAL IDs',
      );
      expect(
        libraryProviderIdsMatchCatalog(
          providerIds: const {'tmdb': '99999'},
          episode: mapped,
        ),
        LibraryCatalogIdMatch.conflict,
      );
    },
  );

  test('suffix-style OVA identity maps only to parent season zero', () {
    const luckyOva = EpisodeReference(
      anilistMediaId: 4472,
      title: 'Lucky☆Star OVA',
      titleEnglish: 'Lucky Star OVA',
      year: 2008,
      episode: 1,
      format: 'OVA',
    );
    const jellyfin = JellyfinMediaItem(
      id: 'lucky-star-ova-01',
      name: 'Original Visuals and Animation',
      type: 'Episode',
      seriesName: 'Lucky Star',
      seriesProductionYear: 2007,
      seasonNumber: 0,
      episodeNumber: 1,
    );
    const plex = PlexMediaItem(
      ratingKey: 'plex-lucky-star-ova-01',
      key: '/library/metadata/plex-lucky-star-ova-01',
      title: 'Original Visuals and Animation',
      type: PlexMediaType.episode,
      grandparentTitle: 'Lucky Star',
      seriesYear: 2007,
      parentIndex: 0,
      index: 1,
    );

    expect(libraryCatalogSeasonHint(luckyOva), 0);
    expect(jellyfinItemMatchesEpisode(item: jellyfin, episode: luckyOva), true);
    expect(plexItemMatchesEpisode(item: plex, episode: luckyOva), true);
    expect(
      jellyfinItemMatchesEpisode(
        item: const JellyfinMediaItem(
          id: 'lucky-star-ova-wrong-season',
          name: 'Original Visuals and Animation',
          type: 'Episode',
          seriesName: 'Lucky Star',
          seasonNumber: 1,
          episodeNumber: 1,
        ),
        episode: luckyOva,
      ),
      false,
    );
    const conflictingAliases = EpisodeReference(
      anilistMediaId: 4472,
      title: 'Lucky Star OVA',
      alternativeTitles: ['Lucky Star Season 2'],
      episode: 1,
      format: 'OVA',
    );
    expect(libraryCatalogSeasonHint(conflictingAliases), isNull);
    expect(
      jellyfinItemMatchesEpisode(item: jellyfin, episode: conflictingAliases),
      false,
      reason: 'conflicting structural aliases cannot authorize Season 0',
    );
  });

  test('similar titles and the wrong episode fail closed', () {
    const similar = JellyfinMediaItem(
      id: 'episode-id-12345678',
      name: 'Episode 7',
      type: 'Episode',
      seriesName: 'Frieren Fan Commentary',
      episodeNumber: 7,
    );
    const wrongEpisode = JellyfinMediaItem(
      id: 'episode-id-87654321',
      name: 'Episode 8',
      type: 'Episode',
      seriesName: 'Sousou no Frieren',
      episodeNumber: 8,
    );

    expect(
      jellyfinItemMatchesEpisode(item: similar, episode: episode),
      isFalse,
    );
    expect(
      jellyfinItemMatchesEpisode(item: wrongEpisode, episode: episode),
      isFalse,
    );
  });

  test(
    'explicit remake years reject conflicts but episode air years do not',
    () {
      const fruits2019 = EpisodeReference(
        anilistMediaId: 5114,
        title: 'Fruits Basket',
        year: 2019,
        episode: 1,
      );
      const wrongNamedYear = JellyfinMediaItem(
        id: 'fruits-2001',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Fruits Basket (2001)',
        productionYear: 2019,
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const longRunningAirYear = JellyfinMediaItem(
        id: 'fruits-air-year',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Fruits Basket',
        productionYear: 2020,
        seriesProductionYear: 2019,
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const unknownJellyfinSeriesYear = JellyfinMediaItem(
        id: 'fruits-ambiguous',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Fruits Basket',
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const wrongPlexTitleYear = PlexMediaItem(
        ratingKey: 'plex-fruits-2001',
        key: '/library/metadata/plex-fruits-2001',
        title: 'Episode 1',
        type: PlexMediaType.episode,
        grandparentTitle: 'Fruits Basket (2001)',
        year: 2019,
        index: 1,
        parentIndex: 1,
        parts: [PlexMediaPart(key: '/library/parts/fruits/file.mkv')],
      );
      const plexLaterAirYear = PlexMediaItem(
        ratingKey: 'plex-fruits-air-year',
        key: '/library/metadata/plex-fruits-air-year',
        title: 'Episode 1',
        type: PlexMediaType.episode,
        grandparentTitle: 'Fruits Basket',
        year: 2020,
        seriesYear: 2019,
        index: 1,
        parentIndex: 1,
        parts: [PlexMediaPart(key: '/library/parts/fruits-2020/file.mkv')],
      );
      const unknownPlexSeriesYear = PlexMediaItem(
        ratingKey: 'plex-fruits-ambiguous',
        key: '/library/metadata/plex-fruits-ambiguous',
        title: 'Episode 1',
        type: PlexMediaType.episode,
        grandparentTitle: 'Fruits Basket',
        index: 1,
        parentIndex: 1,
      );

      expect(
        jellyfinItemMatchesEpisode(item: wrongNamedYear, episode: fruits2019),
        isFalse,
      );
      expect(
        jellyfinItemMatchesEpisode(
          item: unknownJellyfinSeriesYear,
          episode: fruits2019,
        ),
        isTrue,
        reason: 'an exact title remains available for manual selection',
      );
      expect(
        jellyfinItemMatchesEpisode(
          item: longRunningAirYear,
          episode: fruits2019,
        ),
        isTrue,
        reason: 'episode production year is not the series/remake year',
      );
      expect(
        plexItemMatchesEpisode(item: wrongPlexTitleYear, episode: fruits2019),
        isFalse,
      );
      expect(
        plexItemMatchesEpisode(
          item: unknownPlexSeriesYear,
          episode: fruits2019,
        ),
        isTrue,
        reason: 'Plex also permits the exact manual fallback',
      );
      expect(
        plexItemMatchesEpisode(item: plexLaterAirYear, episode: fruits2019),
        isTrue,
        reason: 'Plex episode year can be the air year of a later episode',
      );
    },
  );

  test('movie production year is part of exact public identity', () {
    const catalog = EpisodeReference(
      anilistMediaId: 437,
      title: 'Perfect Blue',
      year: 1997,
      episode: 1,
    );
    const correct = JellyfinMediaItem(
      id: 'perfect-blue-1997',
      name: 'Perfect Blue',
      type: 'Movie',
      productionYear: 1997,
    );
    const wrong = JellyfinMediaItem(
      id: 'perfect-blue-2001',
      name: 'Perfect Blue',
      type: 'Movie',
      productionYear: 2001,
    );

    expect(jellyfinItemMatchesEpisode(item: correct, episode: catalog), isTrue);
    expect(jellyfinItemMatchesEpisode(item: wrong, episode: catalog), isFalse);
  });

  test(
    'numeric official title tokens are not mistaken for production years',
    () {
      const catalog = EpisodeReference(
        anilistMediaId: 12345,
        title: '2001: A Space Odyssey',
        year: 1968,
        episode: 1,
      );
      const noCatalogYear = EpisodeReference(
        anilistMediaId: 12345,
        title: '2001: A Space Odyssey',
        episode: 1,
      );
      const jellyfinExact = JellyfinMediaItem(
        id: 'odyssey-jellyfin',
        name: '2001: A Space Odyssey',
        type: 'Movie',
        productionYear: 1968,
      );
      const jellyfinWrongSuffix = JellyfinMediaItem(
        id: 'odyssey-jellyfin-wrong',
        name: '2001: A Space Odyssey (1984)',
        type: 'Movie',
        productionYear: 1968,
      );
      const jellyfinProductionSuffix = JellyfinMediaItem(
        id: 'odyssey-jellyfin-suffix',
        name: '2001: A Space Odyssey (1968)',
        type: 'Movie',
        productionYear: 1968,
      );
      const jellyfinMissingTitleToken = JellyfinMediaItem(
        id: 'odyssey-jellyfin-short',
        name: 'A Space Odyssey',
        type: 'Movie',
        productionYear: 1968,
      );
      const plexExact = PlexMediaItem(
        ratingKey: 'odyssey-plex',
        key: '/library/metadata/odyssey-plex',
        title: '2001: A Space Odyssey',
        type: PlexMediaType.movie,
        year: 1968,
      );
      const plexWrongSuffix = PlexMediaItem(
        ratingKey: 'odyssey-plex-wrong',
        key: '/library/metadata/odyssey-plex-wrong',
        title: '2001: A Space Odyssey (1984)',
        type: PlexMediaType.movie,
        year: 1968,
      );

      expect(libraryCatalogYear(noCatalogYear), isNull);
      expect(
        jellyfinItemMatchesEpisode(item: jellyfinExact, episode: catalog),
        isTrue,
      );
      expect(
        jellyfinItemMatchesEpisode(item: jellyfinWrongSuffix, episode: catalog),
        isFalse,
      );
      expect(
        jellyfinItemMatchesEpisode(
          item: jellyfinProductionSuffix,
          episode: catalog,
        ),
        isTrue,
      );
      expect(
        jellyfinItemMatchesEpisode(
          item: jellyfinMissingTitleToken,
          episode: catalog,
        ),
        isFalse,
      );
      expect(plexItemMatchesEpisode(item: plexExact, episode: catalog), isTrue);
      expect(
        plexItemMatchesEpisode(item: plexWrongSuffix, episode: catalog),
        isFalse,
      );
    },
  );

  test('a title year equal to production year remains required identity', () {
    const catalog = EpisodeReference(
      anilistMediaId: 40515,
      title: 'Japan Sinks: 2020',
      year: 2020,
      episode: 1,
    );
    const exact = JellyfinMediaItem(
      id: 'japan-sinks-2020',
      name: 'Episode 1',
      type: 'Episode',
      seriesName: 'Japan Sinks: 2020',
      episodeNumber: 1,
    );
    const missingTitleYear = JellyfinMediaItem(
      id: 'japan-sinks-short',
      name: 'Episode 1',
      type: 'Episode',
      seriesName: 'Japan Sinks',
      episodeNumber: 1,
    );

    expect(jellyfinItemMatchesEpisode(item: exact, episode: catalog), isTrue);
    expect(
      jellyfinItemMatchesEpisode(item: missingTitleYear, episode: catalog),
      isFalse,
    );

    LocalMediaDocument document(String name, String id) => LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/$id'),
      name: name,
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('Japan Sinks 2020 Episode 1.mkv', 'exact'),
        episode: catalog,
      ),
      isTrue,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('Japan Sinks Episode 1.mkv', 'missing-year'),
        episode: catalog,
      ),
      isFalse,
    );
  });

  test('Auto Pick accepts one known remake and rejects ambiguous seasons', () {
    const fruits2019 = EpisodeReference(
      anilistMediaId: 5114,
      title: 'Fruits Basket',
      year: 2019,
      episode: 1,
    );
    final exact = LibraryEpisodeSource.jellyfin(
      const JellyfinMediaItem(
        id: 'fruits-2019',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Fruits Basket (2019)',
        seasonNumber: 1,
        episodeNumber: 1,
      ),
    );
    final unknown = LibraryEpisodeSource.plex(
      const PlexMediaItem(
        ratingKey: 'fruits-unknown',
        key: '/library/metadata/fruits-unknown',
        title: 'Episode 1',
        type: PlexMediaType.episode,
        grandparentTitle: 'Fruits Basket',
        index: 1,
        parentIndex: 1,
        parts: [PlexMediaPart(key: '/library/parts/fruits/file.mkv')],
      ),
    );
    expect(
      unambiguousLibraryAutoPickSources(
        sources: [unknown, exact],
        episode: fruits2019,
      ),
      [same(exact)],
      reason: 'the unique source carrying the catalog remake year is exact',
    );
    expect(
      unambiguousLibraryAutoPickSources(
        sources: [unknown],
        episode: fruits2019,
      ),
      isEmpty,
      reason: 'a yearless remake candidate never becomes hands-free playback',
    );

    const bareCatalog = EpisodeReference(
      anilistMediaId: 999,
      title: 'Collision Show',
      episode: 1,
    );
    final seasonOne = LibraryEpisodeSource.jellyfin(
      const JellyfinMediaItem(
        id: 'collision-s1',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Collision Show',
        seasonNumber: 1,
        episodeNumber: 1,
      ),
    );
    final seasonTwo = LibraryEpisodeSource.jellyfin(
      const JellyfinMediaItem(
        id: 'collision-s2',
        name: 'Episode 1',
        type: 'Episode',
        seriesName: 'Collision Show',
        seasonNumber: 2,
        episodeNumber: 1,
      ),
    );
    expect(
      unambiguousLibraryAutoPickSources(
        sources: [seasonOne, seasonTwo],
        episode: bareCatalog,
      ),
      isEmpty,
    );
    expect(
      [
        seasonOne,
        seasonTwo,
      ].where((source) => librarySourceMatchesEpisode(source, bareCatalog)),
      hasLength(2),
      reason: 'both choices remain visible for a manual decision',
    );
  });

  test('Jellyfin requires exact series and episode identity', () {
    const item = JellyfinMediaItem(
      id: 'episode-id-12345678',
      name: 'Like a Fairy Tale',
      type: 'Episode',
      seriesName: 'Sousou no Frieren',
      episodeNumber: 7,
      videoCodec: 'h264',
      audioCodec: 'aac',
      container: 'mkv',
      videoHeight: 1080,
    );

    expect(jellyfinItemMatchesEpisode(item: item, episode: episode), isTrue);
    final source = LibraryEpisodeSource.jellyfin(item);
    expect(source.stableKey, 'jellyfin:episode-id-12345678');
    expect(source.subtitle, contains('1080p'));
    expect(source.subtitle, contains('H264'));
    expect(source.providerId, 'library-jellyfin');
    expect(source.providerName, 'Jellyfin');
    expect(source.qualityLabel, '1080p');
    expect(source.container, 'mkv');
    expect(source.audioCodec, 'aac');
    expect(source.isPlayableCandidate, isTrue);
  });

  test('Plex requires exact grandparent title and episode index', () {
    const item = PlexMediaItem(
      ratingKey: 'episode-123',
      key: '/library/metadata/episode-123',
      title: 'Like a Fairy Tale',
      type: PlexMediaType.episode,
      grandparentTitle: "Frieren: Beyond Journey's End",
      index: 7,
      parts: [
        PlexMediaPart(
          key: '/library/parts/part-123/file.mkv',
          container: 'mkv',
          videoCodec: 'hevc',
          audioCodec: 'aac',
          videoWidth: 1920,
          videoHeight: 1080,
        ),
      ],
    );

    expect(plexItemMatchesEpisode(item: item, episode: episode), isTrue);
    final source = LibraryEpisodeSource.plex(item);
    expect(source.stableKey, 'plex:episode-123');
    expect(source.subtitle, contains('Plex'));
    expect(source.subtitle, contains('MKV'));
    expect(source.subtitle, contains('HEVC'));
    expect(source.providerId, 'library-plex');
    expect(source.providerName, 'Plex');
    expect(source.videoWidth, 1920);
    expect(source.qualityLabel, '1080p');
    expect(source.isPlayableCandidate, isTrue);
  });

  test('movies match only episode one and never a substring', () {
    const movieEpisode = EpisodeReference(
      anilistMediaId: 999,
      title: 'Perfect Blue',
      episode: 1,
    );
    const matching = JellyfinMediaItem(
      id: 'movie-id-12345678',
      name: 'Perfect Blue (1997)',
      type: 'Movie',
    );
    const unrelated = JellyfinMediaItem(
      id: 'movie-id-87654321',
      name: 'Perfect Blue: Behind the Scenes',
      type: 'Movie',
    );

    expect(
      jellyfinItemMatchesEpisode(item: matching, episode: movieEpisode),
      isTrue,
    );
    expect(
      jellyfinItemMatchesEpisode(item: unrelated, episode: movieEpisode),
      isFalse,
    );
  });

  test('recent device filename requires the exact title and episode', () {
    final matching = LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/123'),
      name: '[Trix] Frieren - Beyond Journey’s End - 07 [ABC123].mkv',
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );
    final wrongEpisode = LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/124'),
      name: '[Trix] Frieren - Beyond Journey’s End - 08 [ABC123].mkv',
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );
    final unrelated = LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/125'),
      name: 'Frieren Fan Commentary - 07.mkv',
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );

    expect(
      localDocumentMatchesEpisode(document: matching, episode: episode),
      isTrue,
    );
    expect(
      localDocumentMatchesEpisode(document: wrongEpisode, episode: episode),
      isFalse,
    );
    expect(
      localDocumentMatchesEpisode(document: unrelated, episode: episode),
      isFalse,
    );
  });

  test(
    'explicit filename episode markers take precedence over bare numbers',
    () {
      const requested = EpisodeReference(
        anilistMediaId: 1000,
        title: 'Show',
        episode: 2,
      );
      LocalMediaDocument document(String name, String id) => LocalMediaDocument(
        uri: Uri.parse('content://media/external/video/$id'),
        name: name,
        mimeType: 'video/x-matroska',
        persistedReadPermission: true,
      );

      expect(
        localDocumentMatchesEpisode(
          document: document('Show Season 2 Episode 1.mkv', 'season-label'),
          episode: requested,
        ),
        isFalse,
      );
      expect(
        localDocumentMatchesEpisode(
          document: document('Show S02E01.mkv', 'season-token'),
          episode: requested,
        ),
        isFalse,
      );
      expect(
        localDocumentMatchesEpisode(
          document: document('Show Episode 2.mkv', 'exact'),
          episode: requested,
        ),
        isTrue,
      );
      expect(
        localDocumentMatchesEpisode(
          document: document(
            'Show Episode 1 sample Episode 2.mkv',
            'multiple-explicit',
          ),
          episode: requested,
        ),
        isFalse,
        reason:
            'a multi-episode file has no safe chapter mapping for Auto Pick',
      );
      expect(
        localDocumentMatchesEpisode(
          document: document('Show S01E01-E02.mkv', 'explicit-range'),
          episode: requested,
        ),
        isFalse,
      );
    },
  );

  test('local matching accepts multiple bounded trailing release tags', () {
    const requested = EpisodeReference(
      anilistMediaId: 1000,
      title: 'Show',
      episode: 2,
    );
    LocalMediaDocument document(String name, String id) => LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/$id'),
      name: name,
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );

    expect(
      localDocumentMatchesEpisode(
        document: document(
          '[Group] Show - 02 [1080p][x265 10bit][Hi10P][Dual-Audio].mkv',
          'multi-release-tags',
        ),
        episode: requested,
      ),
      isTrue,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document(
          '[Group] Show Commentary - 02 [1080p][x264][Dual-Audio].mkv',
          'commentary-tags',
        ),
        episode: requested,
      ),
      isFalse,
      reason: 'technical tag stripping must not authorize an unrelated title',
    );
    expect(
      localDocumentMatchesEpisode(
        document: document(
          '[Group] Show - 02 [Fansub note].mkv',
          'semantic-trailing-tag',
        ),
        episode: requested,
      ),
      isFalse,
      reason: 'an unknown bracketed phrase is not a technical release tag',
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('Show [OVA][1080p][x264].mkv', 'ova-movie'),
        episode: const EpisodeReference(
          anilistMediaId: 1001,
          title: 'Show OVA',
          episode: 1,
          format: 'MOVIE',
        ),
      ),
      isTrue,
      reason: 'semantic title brackets must survive technical tag stripping',
    );
  });

  test('an explicit local filename year cannot cross-match a remake', () {
    const requested = EpisodeReference(
      anilistMediaId: 5114,
      title: 'Fruits Basket',
      year: 2019,
      episode: 1,
    );
    LocalMediaDocument document(String name, String id) => LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/$id'),
      name: name,
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );

    expect(
      localDocumentMatchesEpisode(
        document: document('Fruits Basket (2001) Episode 1.mkv', 'wrong-year'),
        episode: requested,
      ),
      isFalse,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document(
          'Fruits Basket (2019) Episode 1 1920x1080.mkv',
          'right-year',
        ),
        episode: requested,
      ),
      isTrue,
      reason: 'a width token must not be mistaken for a production year',
    );
    expect(
      localDocumentMatchesEpisode(
        document: document(
          'Fruits Basket (2001) remastered 2019 Episode 1.mkv',
          'mixed-years',
        ),
        episode: requested,
      ),
      isFalse,
      reason: 'any conflicting explicit filename year must fail closed',
    );
  });

  test('numeric official titles remain valid local filename identities', () {
    const requested = EpisodeReference(
      anilistMediaId: 12345,
      title: '2001: A Space Odyssey',
      year: 1968,
      episode: 1,
    );
    LocalMediaDocument document(String name, String id) => LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/$id'),
      name: name,
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );

    expect(
      localDocumentMatchesEpisode(
        document: document('2001 A Space Odyssey Episode 1.mkv', 'odyssey'),
        episode: requested,
      ),
      isTrue,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document(
          '2001 A Space Odyssey (1984) Episode 1.mkv',
          'wrong-suffix',
        ),
        episode: requested,
      ),
      isFalse,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('A Space Odyssey Episode 1.mkv', 'missing-token'),
        episode: requested,
      ),
      isFalse,
    );
  });

  test('bare episode fallback ignores numbers inside the matched title', () {
    const requested = EpisodeReference(
      anilistMediaId: 1535,
      title: '7 Seeds',
      episode: 7,
    );
    LocalMediaDocument document(String name, String id) => LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/$id'),
      name: name,
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );

    expect(
      localDocumentMatchesEpisode(
        document: document('7 Seeds.mkv', 'title-only'),
        episode: requested,
      ),
      isFalse,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('7 Seeds - 07.mkv', 'episode-seven'),
        episode: requested,
      ),
      isTrue,
    );
  });

  test(
    'explicit-looking markers inside the title are masked as title text',
    () {
      const requested = EpisodeReference(
        anilistMediaId: 777,
        title: 'Episode 1',
        episode: 1,
      );
      LocalMediaDocument document(String name, String id) => LocalMediaDocument(
        uri: Uri.parse('content://media/external/video/$id'),
        name: name,
        mimeType: 'video/x-matroska',
        persistedReadPermission: true,
      );

      expect(
        localDocumentMatchesEpisode(
          document: document('Episode 1.mkv', 'title-only-marker'),
          episode: requested,
        ),
        isFalse,
      );
      expect(
        localDocumentMatchesEpisode(
          document: document('Episode 1 - Episode 1.mkv', 'real-marker'),
          episode: requested,
        ),
        isTrue,
      );
    },
  );

  test('exact local movies do not require a synthetic episode-one token', () {
    const requested = EpisodeReference(
      anilistMediaId: 437,
      title: 'Perfect Blue',
      year: 1997,
      format: 'MOVIE',
      episode: 1,
    );
    LocalMediaDocument document(String name, String id) => LocalMediaDocument(
      uri: Uri.parse('content://media/external/video/$id'),
      name: name,
      mimeType: 'video/x-matroska',
      persistedReadPermission: true,
    );

    expect(
      localDocumentMatchesEpisode(
        document: document('Perfect Blue (1997).mkv', 'exact-movie'),
        episode: requested,
      ),
      isTrue,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('Perfect Blue trailer (1997).mkv', 'trailer'),
        episode: requested,
      ),
      isFalse,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('Perfect Blue (2001).mkv', 'wrong-year-movie'),
        episode: requested,
      ),
      isFalse,
    );
    expect(
      localDocumentMatchesEpisode(
        document: document('Unrelated (1997).mkv', 'unrelated-movie'),
        episode: requested,
      ),
      isFalse,
    );
  });

  test(
    'recent exact device episode is returned without opening a picker',
    () async {
      final document = LocalMediaDocument(
        uri: Uri.parse('content://media/external/video/frieren-7'),
        name: 'Sousou no Frieren S01E07.mkv',
        mimeType: 'video/x-matroska',
        size: 1024 * 1024 * 1400,
        persistedReadPermission: true,
      );
      final local = _RecentDocumentController(document);
      final service = LibraryEpisodeSourceService(
        local,
        _FakePlexController(Future.value(const [])),
        () => true,
        () => false,
        () => false,
        () => '',
        () => '',
      );

      expect(service.hasConnectedServer, isTrue);
      final result = await service.search(episode);

      expect(result.sources, hasLength(1));
      final source = result.sources.single;
      expect(source.origin, LibraryEpisodeOrigin.device);
      expect(source.localDocument, same(document));
      expect(source.subtitle, contains('Local device'));

      final playback = await service.preparePlayback(source);
      expect(playback.source, document.uri);
      expect(playback.streamLabel, 'Local device media');
    },
  );

  test(
    'public Watch identity is explicit and never weakens library isolation',
    () {
      LibraryPlaybackRequest request({
        LibraryWatchPartyIdentity? watchPartyIdentity,
      }) => LibraryPlaybackRequest(
        source: Uri.parse('https://media.example/private/item.m3u8'),
        title: 'Private filename.mkv',
        releaseName: 'Private filename.mkv',
        streamLabel: 'Jellyfin',
        checkpointKey: 'local:private-server-item',
        timelineIdentity: 'private-server-item',
        headers: const {'Authorization': 'private-token'},
        watchPartyIdentity: watchPartyIdentity,
      );

      final directLibrary = request();
      expect(directLibrary.watchPartyIdentity, isNull);

      final publicEpisode = request(
        watchPartyIdentity: LibraryWatchPartyIdentity(
          anilistMediaId: 123,
          episode: 7,
          title: '  Frieren:\nBeyond Journey’s End  ',
        ),
      );
      expect(publicEpisode.watchPartyIdentity?.anilistMediaId, 123);
      expect(publicEpisode.watchPartyIdentity?.episode, 7);
      expect(
        publicEpisode.watchPartyIdentity?.title,
        'Frieren: Beyond Journey’s End',
      );
      expect(publicEpisode.watchPartyIdentity?.title, isNot(contains('token')));
      expect(publicEpisode.isolation.animeTrackingEnabled, isFalse);
      expect(publicEpisode.isolation.animeCheckpointEnabled, isFalse);
      expect(publicEpisode.isolation.aniSkipEnabled, isTrue);
      expect(publicEpisode.isolation.nextEpisodeEnabled, isTrue);
    },
  );

  test('public Watch identity rejects private/invalid identity shapes', () {
    expect(
      () => LibraryWatchPartyIdentity(
        anilistMediaId: 0,
        episode: 1,
        title: 'Title',
      ),
      throwsArgumentError,
    );
    expect(
      () => LibraryWatchPartyIdentity(
        anilistMediaId: 123,
        episode: 0,
        title: 'Title',
      ),
      throwsArgumentError,
    );
    expect(
      () => LibraryWatchPartyIdentity(
        anilistMediaId: 123,
        episode: 1,
        title: 'x' * 241,
      ),
      throwsArgumentError,
    );
  });

  test(
    'library subtitle capabilities are bounded and reject URL credentials',
    () {
      expect(
        () => LibraryExternalSubtitleTrack(
          uri: Uri.parse('https://user:secret@media.example/subtitle.vtt'),
          label: 'English',
          contentType: 'text/vtt',
        ),
        throwsArgumentError,
      );
      expect(
        () => LibraryExternalSubtitleTrack(
          uri: Uri.parse('https://media.example/subtitle.vtt#private'),
          label: 'English',
          contentType: 'text/vtt',
        ),
        throwsArgumentError,
      );

      final tracks = List.generate(
        35,
        (index) => LibraryExternalSubtitleTrack(
          uri: Uri.parse('https://media.example/subtitle-$index.vtt'),
          label: ' Track $index\n',
          language: index == 0 ? 'eng' : null,
          contentType: 'text/vtt',
        ),
      );
      final request = LibraryPlaybackRequest(
        source: Uri.parse('https://media.example/video.m3u8'),
        title: 'Episode',
        releaseName: 'Episode',
        streamLabel: 'Jellyfin',
        checkpointKey: 'local:subtitle-capability',
        timelineIdentity: 'subtitle-capability',
        externalSubtitleTracks: tracks,
      );

      expect(request.externalSubtitleTracks, hasLength(32));
      expect(request.externalSubtitleTracks.first.label, 'Track 0');
      expect(request.externalSubtitleTracks.first.language, 'eng');
      expect(
        () => request.externalSubtitleTracks.add(tracks.last),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'Jellyfin playback carries the preferred language and every subtitle capability',
    () async {
      const item = JellyfinMediaItem(
        id: 'episode-id-12345678',
        name: 'Like a Fairy Tale',
        type: 'Episode',
        seriesName: 'Sousou no Frieren',
        episodeNumber: 7,
      );
      final local = _PlaybackLocalMediaController();
      final service = LibraryEpisodeSourceService(
        local,
        _FakePlexController(Future.value(const [])),
        () => true,
        () => true,
        () => false,
        () => 'jellyfin-scope',
        () => '',
      );

      final request = await service.preparePlayback(
        LibraryEpisodeSource.jellyfin(item),
        preferredSubtitleLanguage: 'jpn',
        requestedAudio: PlaybackAudioPreference.dub,
      );

      expect(local.preferredSubtitleLanguage, 'jpn');
      expect(local.requestedAudio, PlaybackAudioPreference.dub);
      expect(request.requestedAudio, PlaybackAudioPreference.dub);
      expect(request.externalSubtitleTracks.map((track) => track.label), [
        'Japanese',
        'English',
      ]);
      expect(request.externalSubtitleTracks.map((track) => track.language), [
        'jpn',
        'eng',
      ]);
      expect(request.externalSubtitle, endsWith('/japanese.vtt'));
      expect(request.sourceProviderId, 'library-jellyfin');
      expect(request.sourceProviderName, 'Jellyfin');
      expect(request.source.queryParameters, isNot(contains('api_key')));
      expect(
        request.externalSubtitleTracks
            .map((track) => track.uri.toString())
            .join(' '),
        isNot(contains('private-token')),
      );
    },
  );

  test(
    'Jellyfin compatibility retry selects and labels the transcode plan',
    () async {
      const item = JellyfinMediaItem(
        id: 'episode-id-12345678',
        name: 'Like a Fairy Tale',
        type: 'Episode',
        seriesName: 'Sousou no Frieren',
        episodeNumber: 7,
      );
      final local = _PlaybackLocalMediaController();
      final service = LibraryEpisodeSourceService(
        local,
        _FakePlexController(Future.value(const [])),
        () => true,
        () => true,
        () => false,
        () => 'jellyfin-scope',
        () => '',
      );

      final request = await service.preparePlayback(
        LibraryEpisodeSource.jellyfin(item),
        forceCompatibility: true,
      );

      expect(local.compatibilityRequested, isTrue);
      expect(request.isCompatibilityStream, isTrue);
      expect(request.streamLabel, contains('compatibility stream'));
    },
  );

  test(
    'connected media servers populate independently and sort deterministically',
    () async {
      final jellyfin = Completer<List<JellyfinMediaItem>>();
      final plex = Completer<List<PlexMediaItem>>();
      final service = LibraryEpisodeSourceService(
        _FakeLocalMediaController(jellyfin.future),
        _FakePlexController(plex.future),
        () => true,
        () => true,
        () => true,
        () => 'jellyfin-scope',
        () => 'plex-scope',
      );
      final snapshots = <LibraryEpisodeSearchResult>[];
      final done = Completer<void>();
      service.watchSearch(episode).listen(snapshots.add, onDone: done.complete);

      jellyfin.complete(const [
        JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'Like a Fairy Tale',
          type: 'Episode',
          seriesName: 'Sousou no Frieren',
          episodeNumber: 7,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, hasLength(1));
      expect(
        snapshots.single.sources.single.origin,
        LibraryEpisodeOrigin.jellyfin,
      );

      plex.complete(const [
        PlexMediaItem(
          ratingKey: 'episode-123',
          key: '/library/metadata/episode-123',
          title: 'Like a Fairy Tale',
          type: PlexMediaType.episode,
          grandparentTitle: "Frieren: Beyond Journey's End",
          index: 7,
          parts: [PlexMediaPart(key: '/library/parts/part-123/file.mkv')],
        ),
      ]);
      await done.future;

      expect(snapshots, hasLength(2));
      expect(snapshots.last.sources.map((source) => source.origin), [
        LibraryEpisodeOrigin.jellyfin,
        LibraryEpisodeOrigin.plex,
      ]);
      expect(
        snapshots.last.sources.map((source) => source.stableKey).toSet(),
        hasLength(2),
        reason: 'ambiguous exact matches remain separate manual choices',
      );
    },
  );

  test('discovery omits exact-looking sources that are not playable', () async {
    final service = LibraryEpisodeSourceService(
      _FakeLocalMediaController(
        Future.value(const [
          JellyfinMediaItem(
            id: 'short',
            name: 'Like a Fairy Tale',
            type: 'Episode',
            seriesName: 'Sousou no Frieren',
            episodeNumber: 7,
          ),
        ]),
      ),
      _FakePlexController(
        Future.value(const [
          PlexMediaItem(
            ratingKey: 'missing-part',
            key: '/library/metadata/missing-part',
            title: 'Like a Fairy Tale',
            type: PlexMediaType.episode,
            grandparentTitle: 'Sousou no Frieren',
            index: 7,
          ),
        ]),
      ),
      () => true,
      () => true,
      () => true,
      () => 'jellyfin-scope',
      () => 'plex-scope',
    );

    final result = await service.search(episode);

    expect(result.sources, isEmpty);
    expect(result.unavailableServers, isEmpty);
  });

  test('unavailable media servers are deduplicated and sorted', () async {
    final jellyfin = Completer<List<JellyfinMediaItem>>();
    final plex = Completer<List<PlexMediaItem>>();
    final service = LibraryEpisodeSourceService(
      _FakeLocalMediaController(jellyfin.future),
      _FakePlexController(plex.future),
      () => true,
      () => true,
      () => true,
      () => 'jellyfin-scope',
      () => 'plex-scope',
    );
    final snapshots = <LibraryEpisodeSearchResult>[];
    final done = Completer<void>();
    service.watchSearch(episode).listen(snapshots.add, onDone: done.complete);

    plex.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    jellyfin.completeError(StateError('offline'));
    await done.future;

    expect(snapshots, hasLength(2));
    expect(snapshots.last.sources, isEmpty);
    expect(snapshots.last.unavailableServers, ['Jellyfin', 'Plex']);
    expect(
      snapshots.last.unavailableServers.toSet(),
      hasLength(snapshots.last.unavailableServers.length),
    );
  });

  test(
    'equal library titles use stable source identity as a tie-break',
    () async {
      final service = LibraryEpisodeSourceService(
        _FakeLocalMediaController(
          Future.value(const [
            JellyfinMediaItem(
              id: 'episode-z-12345678',
              name: 'Same episode title',
              type: 'Episode',
              seriesName: 'Sousou no Frieren',
              episodeNumber: 7,
            ),
            JellyfinMediaItem(
              id: 'episode-a-12345678',
              name: 'Same episode title',
              type: 'Episode',
              seriesName: 'Sousou no Frieren',
              episodeNumber: 7,
            ),
          ]),
        ),
        _FakePlexController(Future.value(const [])),
        () => true,
        () => true,
        () => false,
        () => 'jellyfin-scope',
        () => '',
      );

      final result = await service.search(episode);

      expect(result.sources.map((source) => source.stableKey), [
        'jellyfin:episode-a-12345678',
        'jellyfin:episode-z-12345678',
      ]);
    },
  );

  test(
    'secure local picker keeps file identity private and preserves resume',
    () async {
      final privateDocument = LocalMediaDocument(
        uri: Uri.parse(
          'content://com.android.providers.media.documents/'
          'document/private-file-id',
        ),
        name: 'My Secret Filename.mkv',
        mimeType: 'video/x-matroska',
        persistedReadPermission: true,
      );
      final local = _LocalDocumentController(privateDocument);
      final service = LibraryEpisodeSourceService(
        local,
        _FakePlexController(Future.value(const [])),
        () => true,
        () => false,
        () => false,
        () => '',
        () => '',
      );
      final publicIdentity = LibraryWatchPartyIdentity(
        anilistMediaId: 123,
        episode: 7,
        title: 'Frieren: Beyond Journey’s End',
      );

      final request = await service.chooseLocalVideo(
        watchPartyIdentity: publicIdentity,
      );

      expect(local.pickCount, 1);
      expect(request, isNotNull);
      expect(request!.source, privateDocument.uri);
      expect(request.title, privateDocument.name);
      expect(request.mediaContentType, privateDocument.mimeType);
      expect(request.initialPosition, const Duration(seconds: 42));
      expect(request.checkpointKey, 'local:hashed-local-checkpoint');
      expect(request.timelineIdentity, 'hashed-local-checkpoint');
      expect(request.checkpointKey, isNot(contains('private-file-id')));
      expect(request.watchPartyIdentity?.anilistMediaId, 123);
      expect(request.watchPartyIdentity?.episode, 7);
      expect(
        request.watchPartyIdentity?.title,
        'Frieren: Beyond Journey’s End',
      );
      expect(
        request.watchPartyIdentity?.title,
        isNot(contains('Secret Filename')),
      );
      expect(request.isolation.animeTrackingEnabled, isFalse);
      expect(request.isolation.animeCheckpointEnabled, isFalse);
      expect(request.isolation.aniSkipEnabled, isTrue);
      expect(request.isolation.nextEpisodeEnabled, isTrue);

      await request.onProgress!(
        LibraryPlaybackProgress(
          position: const Duration(seconds: 50),
          duration: const Duration(minutes: 24),
          playing: true,
          sampledAt: DateTime.utc(2026, 8, 22),
        ),
      );
      expect(local.savedPositions, [const Duration(seconds: 50)]);
      await request.onFinished!(
        const LibraryPlaybackResult(
          position: Duration(minutes: 24),
          duration: Duration(minutes: 24),
          reason: LibraryPlaybackEndReason.completed,
          started: true,
        ),
      );
      expect(local.clearedUris, [privateDocument.uri]);
    },
  );
}

class _FakeLocalMediaController implements LocalMediaController {
  _FakeLocalMediaController(this.matches);

  final Future<List<JellyfinMediaItem>> matches;

  @override
  Future<List<JellyfinMediaItem>> findEpisodeMatches(
    EpisodeReference episode,
  ) => matches;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlexController implements PlexController {
  _FakePlexController(this.matches);

  final Future<List<PlexMediaItem>> matches;

  @override
  Future<List<PlexMediaItem>> findEpisodeMatches(EpisodeReference episode) =>
      matches;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlaybackLocalMediaController implements LocalMediaController {
  String? preferredSubtitleLanguage;
  PlaybackAudioPreference? requestedAudio;
  bool compatibilityRequested = false;

  @override
  String createPlaybackSessionId() => 'session_1234567890abcdef';

  @override
  JellyfinPlaybackPlan playbackPlan(
    JellyfinMediaItem item, {
    required String playSessionId,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
  }) {
    this.preferredSubtitleLanguage = preferredSubtitleLanguage;
    this.requestedAudio = requestedAudio;
    return JellyfinPlaybackPlan(
      uri: Uri.parse('https://media.example/master.m3u8'),
      headers: const {'Authorization': 'private-token'},
      method: JellyfinPlayMethod.transcode,
      playSessionId: playSessionId,
      mediaContentType: 'application/x-mpegURL',
      externalSubtitleTracks: [
        JellyfinPlaybackSubtitleTrack(
          uri: Uri.parse('https://media.example/japanese.vtt'),
          label: 'Japanese',
          language: 'jpn',
          contentType: 'text/vtt',
        ),
        JellyfinPlaybackSubtitleTrack(
          uri: Uri.parse('https://media.example/english.vtt'),
          label: 'English',
          language: 'eng',
          contentType: 'text/vtt',
        ),
      ],
    );
  }

  @override
  JellyfinPlaybackPlan compatibilityPlaybackPlan(
    JellyfinMediaItem item, {
    required String playSessionId,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
  }) {
    compatibilityRequested = true;
    return playbackPlan(
      item,
      playSessionId: playSessionId,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      requestedAudio: requestedAudio,
    );
  }

  @override
  Future<Duration> resumePosition(Uri uri) async => Duration.zero;

  @override
  Duration serverResumePosition(JellyfinMediaItem item) => Duration.zero;

  @override
  Uri? imageUri(JellyfinMediaItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalDocumentController implements LocalMediaController {
  _LocalDocumentController(this.document);

  final LocalMediaDocument? document;
  int pickCount = 0;
  final savedPositions = <Duration>[];
  final clearedUris = <Uri>[];

  @override
  Future<LocalMediaDocument?> pickLocalVideo() async {
    pickCount++;
    return document;
  }

  @override
  String checkpointId(Uri uri) => 'hashed-local-checkpoint';

  @override
  Future<Duration> resumePosition(Uri uri) async => const Duration(seconds: 42);

  @override
  Future<void> saveResumePosition(Uri uri, Duration position) async {
    savedPositions.add(position);
  }

  @override
  Future<void> clearResumePosition(Uri uri) async {
    clearedUris.add(uri);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecentDocumentController extends _LocalDocumentController {
  _RecentDocumentController(super.document);

  @override
  LocalMediaDocument? get recentLocalDocument => document;
}
