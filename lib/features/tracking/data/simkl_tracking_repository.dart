import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/tracking/data/simkl_account_session.dart';
import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';

typedef SimklClientIdLoader = Future<String?> Function();
typedef SimklAppVersionLoader = Future<String> Function();

class SimklTrackingRepository
    implements
        TrackingRepository,
        ExternalIdTrackingRepository,
        AutomaticCompletionTrackingRepository,
        ResolvedStatusTrackingRepository {
  factory SimklTrackingRepository({
    required String accessToken,
    required SimklClientIdLoader clientIdLoader,
    required SimklAccountSessionRegistry sessionRegistry,
    required SimklCacheScopeLoader cacheScopeLoader,
    SimklAppVersionLoader? appVersionLoader,
  }) => SimklTrackingRepository._(
    accessToken,
    clientIdLoader,
    sessionRegistry,
    cacheScopeLoader,
    appVersionLoader ?? _loadAppVersion,
  );

  SimklTrackingRepository._(
    this._accessToken,
    this._clientIdLoader,
    this._sessionRegistry,
    this._cacheScopeLoader,
    this._appVersionLoader,
  );

  SimklTrackingRepository.forTesting(SimklAccountSession session)
    : _accessToken = '',
      _clientIdLoader = _noClientId,
      _sessionRegistry = null,
      _cacheScopeLoader = _noCacheScope,
      _appVersionLoader = _loadAppVersion,
      _sessionRequest = Future.value(session);

  final String _accessToken;
  final SimklClientIdLoader _clientIdLoader;
  final SimklAccountSessionRegistry? _sessionRegistry;
  final SimklCacheScopeLoader _cacheScopeLoader;
  final SimklAppVersionLoader _appVersionLoader;
  Future<SimklAccountSession>? _sessionRequest;

  Future<SimklUserProfile> profile() async => (await _session()).profile();

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async {
    final wantedStatus = _simklStatus(status);
    final rows = (await (await _session()).animeLibrary()).where(
      (row) => row.status == wantedStatus,
    );
    return [
      for (final row in rows)
        TrackedAnime(
          mediaId: row.simklId,
          anilistId: row.anilistId,
          malId: row.malId,
          title: row.title,
          titleEnglish: row.title,
          status: status,
          progress: row.progress,
          totalEpisodes: row.totalEpisodes,
          coverImageUrl: simklPosterUrl(row.posterPath),
          sourceUrl: simklAnimeUrl(row.simklId, row.slug),
          score: row.score,
          updatedAt: row.updatedAt,
        ),
    ];
  }

  @override
  Future<int?> currentProgress(int mediaId) =>
      currentProgressByIds(TrackingMediaIds(simklId: mediaId));

  @override
  Future<int?> currentProgressByIds(TrackingMediaIds ids) async {
    return (await (await _session()).animeByIds(
      _simklIds(ids),
    ))?.contiguousProgress;
  }

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) => updateProgressByIds(
    ids: TrackingMediaIds(simklId: mediaId),
    completedEpisodes: completedEpisodes,
  );

  @override
  Future<void> updateProgressByIds({
    required TrackingMediaIds ids,
    required int completedEpisodes,
  }) async {
    if (completedEpisodes <= 0) return;
    final session = await _session();
    final simklIds = _simklIds(ids);
    final row = await session.animeByIds(simklIds);
    final watched = row == null
        ? const <int>{}
        : row.watchedEpisodeNumbers.isNotEmpty || row.progress == 0
        ? row.watchedEpisodeNumbers
        : {for (var episode = 1; episode <= row.progress; episode++) episode};

    final missing = [
      for (var episode = 1; episode <= completedEpisodes; episode++)
        if (!watched.contains(episode)) episode,
    ];
    if (missing.isEmpty) return;
    for (var offset = 0; offset < missing.length; offset += 250) {
      final end = offset + 250 < missing.length ? offset + 250 : missing.length;
      await session.addWatchedEpisodes(
        ids: simklIds,
        episodeNumbers: missing.sublist(offset, end),
        completedEpisodes: completedEpisodes,
      );
    }
  }

  @override
  Future<void> updateProgressAndCompletion({
    required TrackingMediaIds ids,
    required int completedEpisodes,
  }) async {
    if (completedEpisodes <= 0) {
      throw ArgumentError.value(completedEpisodes, 'completedEpisodes');
    }
    final session = await _session();
    final simklIds = _simklIds(ids);
    // Reject conflicting stable mappings before any history/status mutation.
    await _completionRow(session, simklIds);
    await updateProgressByIds(ids: ids, completedEpisodes: completedEpisodes);
    final row = await _completionRow(session, simklIds);
    if (row == null) {
      throw StateError('SIMKL completion metadata is not available yet.');
    }
    final metadata = await session.client.animeCompletionMetadata(
      SimklAnimeId(row.simklId),
    );
    if (trackingSeriesIsComplete(
      completedEpisodes: completedEpisodes,
      totalEpisodes: metadata.totalEpisodes,
      finishedAiring: metadata.finishedAiring,
    )) {
      final actual = await session.setStatus(
        ids: SimklMediaIds(simkl: row.simklId),
        status: 'completed',
      );
      if (actual != 'completed') {
        // SIMKL can normalize a request back to Watching if its catalog changed.
        // Do not call this delivered until the service confirms Completed.
        throw StateError('SIMKL has not confirmed Completed status.');
      }
    }
  }

  Future<SimklAnimeListEntry?> _completionRow(
    SimklAccountSession session,
    SimklMediaIds ids,
  ) async {
    final matches = (await session.animeLibrary())
        .where(
          (row) =>
              (ids.simkl != null && ids.simkl == row.simklId) ||
              (ids.anilist != null && ids.anilist == row.anilistId) ||
              (ids.mal != null && ids.mal == row.malId),
        )
        .toList();
    if (matches.length > 1) {
      throw StateError('SIMKL returned ambiguous completion mappings.');
    }
    final row = matches.firstOrNull;
    if (row != null &&
        ((ids.simkl != null && ids.simkl != row.simklId) ||
            (ids.anilist != null &&
                row.anilistId != null &&
                ids.anilist != row.anilistId) ||
            (ids.mal != null && row.malId != null && ids.mal != row.malId))) {
      throw StateError('SIMKL returned conflicting completion mappings.');
    }
    return row;
  }

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    await updateStatusResolved(mediaId: mediaId, status: status);
  }

  @override
  Future<TrackingListStatus> updateStatusResolved({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    final actual = await (await _session()).setStatus(
      ids: SimklMediaIds(simkl: mediaId),
      status: _simklStatus(status),
    );
    return _trackingStatus(actual);
  }

  @override
  Future<void> updateStatusByIds({
    required TrackingMediaIds ids,
    required TrackingListStatus status,
  }) async {
    await (await _session()).setStatus(
      ids: _simklIds(ids),
      status: _simklStatus(status),
    );
  }

  @override
  Future<void> removeFromList({required int mediaId}) =>
      removeFromListByIds(TrackingMediaIds(simklId: mediaId));

  @override
  Future<void> removeFromListByIds(TrackingMediaIds ids) async {
    await (await _session()).remove(_simklIds(ids));
  }

  Future<SimklAccountSession> _session() => _sessionRequest ??= () async {
    final clientId = (await _clientIdLoader())?.trim();
    if (clientId == null || clientId.isEmpty) {
      throw StateError('SIMKL needs to be reconnected in Settings.');
    }
    return _sessionRegistry!.session(
      accessToken: _accessToken,
      clientId: clientId,
      appVersion: await _appVersionLoader(),
      cacheScopeLoader: _cacheScopeLoader,
    );
  }();
}

Future<String?> _noClientId() async => null;

Future<String?> _noCacheScope() async => null;

Future<String> _loadAppVersion() async {
  final version = await AndroidTvBridge.instance.getAppVersion();
  return version.name == 'unknown' ? '2' : version.name;
}

SimklMediaIds _simklIds(TrackingMediaIds ids) =>
    SimklMediaIds(simkl: ids.simklId, anilist: ids.anilistId, mal: ids.malId);

String _simklStatus(TrackingListStatus status) => switch (status) {
  TrackingListStatus.watching => 'watching',
  TrackingListStatus.planToWatch => 'plantowatch',
  TrackingListStatus.completed => 'completed',
  TrackingListStatus.dropped => 'dropped',
  TrackingListStatus.onHold => 'hold',
};

TrackingListStatus _trackingStatus(String status) => switch (status) {
  'watching' => TrackingListStatus.watching,
  'plantowatch' => TrackingListStatus.planToWatch,
  'completed' => TrackingListStatus.completed,
  'dropped' => TrackingListStatus.dropped,
  'hold' => TrackingListStatus.onHold,
  _ => throw StateError('SIMKL returned an unknown list status.'),
};

String? simklPosterUrl(String? posterPath) {
  if (posterPath == null) return null;
  return 'https://wsrv.nl/?url=https://simkl.in/posters/${posterPath}_m.webp&q=90';
}

String simklAnimeUrl(int simklId, String? slug) {
  final suffix = slug == null || slug.isEmpty ? '' : '/$slug';
  return 'https://simkl.com/anime/$simklId$suffix';
}
