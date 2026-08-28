// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/downloaded_episode_asset.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final downloadedEpisodeSourceServiceProvider =
    Provider<DownloadedEpisodeSourceService>((ref) {
      return DownloadedEpisodeSourceService(
        repository: ref.watch(downloadRepositoryProvider),
        storage: ref.watch(offlineDownloadStorageProvider),
      );
    });

/// Verifies completed database rows against app-private files and issues the
/// exact URI capability consumed by typed player navigation.
class DownloadedEpisodeSourceService {
  DownloadedEpisodeSourceService({
    required DownloadRepository repository,
    required OfflineDownloadStorage storage,
    DownloadedPlaybackRegistry? registry,
  }) : _repository = repository,
       _storage = storage,
       _registry = registry ?? DownloadedPlaybackRegistry.instance;

  final DownloadRepository _repository;
  final OfflineDownloadStorage _storage;
  final DownloadedPlaybackRegistry _registry;

  Future<DownloadedEpisodeAsset?> completedEpisode(
    int anilistMediaId,
    int episode, {
    int? malMediaId,
    Iterable<String> seriesTitles = const [],
  }) async {
    final exactJobs = await _repository.completedEpisodeCandidates(
      anilistMediaId,
      episode,
    );
    for (final job in exactJobs) {
      final asset = await _verifyAndRegister(job);
      if (asset != null) return asset;
    }

    // A catalog fallback can legitimately reopen the same show with a
    // different primary AniList identifier. Preserve the user's completed
    // copy by falling back to stable MAL identity, then to an exact normalized
    // public title. This is intentionally episode-scoped and never uses a
    // filename, provider URL, or fuzzy substring match.
    final normalizedTitles = seriesTitles
        .map(_normalizeDownloadedSeriesTitle)
        .where((title) => title.isNotEmpty)
        .toSet();
    if (malMediaId == null && normalizedTitles.isEmpty) return null;
    final exactIds = exactJobs.map((job) => job.id).toSet();
    final fallbackJobs =
        (await _repository.listJobs(
              statuses: const {DownloadJobStatus.completed},
            ))
            .where((job) {
              return !exactIds.contains(job.id) &&
                  downloadedJobMatchesEpisodeIdentity(
                    job,
                    anilistMediaId: anilistMediaId,
                    malMediaId: malMediaId,
                    episode: episode,
                    normalizedSeriesTitles: normalizedTitles,
                  );
            })
            .toList(growable: false)
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    for (final job in fallbackJobs) {
      final asset = await _verifyAndRegister(job);
      if (asset != null) return asset;
    }
    return null;
  }

  Future<DownloadedEpisodeAsset?> completedJob(String jobId) async {
    final job = await _repository.job(jobId);
    return job == null ? null : _verifyAndRegister(job);
  }

  Future<List<DownloadedEpisodeAsset>> completedEpisodesForMedia(
    int anilistMediaId,
  ) async {
    final jobs = await _repository.completedEpisodesForMedia(anilistMediaId);
    final assets = <DownloadedEpisodeAsset>[];
    final seenEpisodes = <int>{};
    for (final job in jobs) {
      if (seenEpisodes.contains(job.episode)) continue;
      final asset = await _verifyAndRegister(job);
      if (asset != null) {
        seenEpisodes.add(job.episode);
        assets.add(asset);
      }
    }
    return assets;
  }

  Future<DownloadedEpisodeAsset?> _verifyAndRegister(DownloadJob job) async {
    if (job.status != DownloadJobStatus.completed) return null;
    if (!await _storage.completedArtifactIsValid(job)) return null;
    final file = await _storage.finalFile(job);
    final asset = DownloadedEpisodeAsset(job: job, file: file);
    _registry.register(asset);
    return asset;
  }
}

bool downloadedJobMatchesEpisodeIdentity(
  DownloadJob job, {
  required int anilistMediaId,
  required int episode,
  int? malMediaId,
  Iterable<String> seriesTitles = const [],
  Set<String>? normalizedSeriesTitles,
}) {
  if (job.episode != episode) return false;
  if (job.anilistMediaId == anilistMediaId) return true;
  if (malMediaId != null && job.malMediaId == malMediaId) return true;
  if (malMediaId != null &&
      job.malMediaId != null &&
      job.malMediaId != malMediaId) {
    return false;
  }
  final normalized =
      normalizedSeriesTitles ??
      seriesTitles
          .map(_normalizeDownloadedSeriesTitle)
          .where((title) => title.isNotEmpty)
          .toSet();
  return normalized.contains(_normalizeDownloadedSeriesTitle(job.seriesTitle));
}

String _normalizeDownloadedSeriesTitle(String value) {
  if (value.length > 500) return '';
  return value
      .trim()
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll('×', ' x ')
      .replaceAll(
        RegExp(r'''[\[\](){}<>:;,.!?/\\|_+\-=~`'"‘’“”★☆＊♥♡♪♫・·•—–−：]'''),
        ' ',
      )
      .replaceAll(RegExp(r'[\u200B-\u200D\u2060\uFEFF]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Builds the same typed MPV launch for every downloaded-episode entry point.
PlaybackLaunch downloadedEpisodePlaybackLaunch({
  required DownloadedEpisodeAsset asset,
  required EpisodeReference episode,
  PlaybackAudioPreference? requestedAudio,
}) {
  final job = asset.job;
  final audio = job.audioLabel?.toLowerCase() ?? '';
  final multiAudio = audio.contains('multi') || audio.contains('dual');
  final dubbed =
      multiAudio || audio.contains('dub') || audio.contains('english');
  return PlaybackLaunch(
    stream: StreamReady(
      uri: asset.playbackUri,
      displayName: '${episode.title} • Episode ${episode.episode}',
      mediaContentType: job.mimeType,
      providerId: 'offline-download',
      providerName: 'Downloaded episode',
      isDownloaded: true,
    ),
    episode: episode,
    selectedRelease: ReleaseCandidate(
      infoHash: sha256.convert(utf8.encode('offline:${job.id}')).toString(),
      magnetUri: '',
      releaseName: job.sourceLabel,
      seeders: 0,
      sourceId: 'offline-download',
      quality: job.quality,
      provider: job.providerName ?? 'Downloads',
      isDubbed: dubbed,
      audioIntent: multiAudio
          ? ReleaseAudioIntent.multi
          : dubbed
          ? ReleaseAudioIntent.dub
          : ReleaseAudioIntent.unknown,
      hasSubtitles: multiAudio || audio.contains('sub'),
    ),
    requestedAudio: requestedAudio,
  );
}
