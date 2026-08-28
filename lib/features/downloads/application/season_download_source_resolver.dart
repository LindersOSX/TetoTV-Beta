// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/downloads/data/android_direct_peer_download_worker.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/debrid_resolver_factory.dart';
import 'package:anime_tv/features/streaming/application/debrid_token_service.dart';
import 'package:anime_tv/features/streaming/application/episode_release_search_cache.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef SeasonDebridResolverFactory =
    StreamResolver Function({
      required DebridService service,
      required String token,
      required ReleaseSource source,
    });

class SeasonDownloadAffinity {
  const SeasonDownloadAffinity({
    this.releaseSourceId,
    this.releaseProvider,
    this.releaseGroup,
    this.webProviderId,
  });

  final String? releaseSourceId;
  final String? releaseProvider;
  final String? releaseGroup;
  final String? webProviderId;
}

class ResolvedSeasonDownload {
  const ResolvedSeasonDownload({
    required this.request,
    required this.affinity,
    this.close,
  });

  final OfflineDownloadRequest request;
  final SeasonDownloadAffinity affinity;
  final Future<void> Function()? close;
}

abstract interface class SeasonEpisodeDownloadResolver {
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  });

  Future<bool> directTorrentAvailable();
}

final seasonEpisodeDownloadResolverProvider =
    Provider<SeasonEpisodeDownloadResolver>((ref) {
      return CatalogSeasonEpisodeDownloadResolver(
        releaseSearch: ref.watch(episodeReleaseSearchCacheProvider).watch,
        webSearch: ref
            .watch(webStreamAggregatorProvider)
            .watchSearchIncrementally,
        readToken: ref.watch(debridTokenServiceProvider).accessToken,
        readSettings: () => ref.read(settingsPreferencesProvider),
        readDirectCapability:
            AndroidTvBridge.instance.getDirectTorrentCapability,
      );
    });

class CatalogSeasonEpisodeDownloadResolver
    implements SeasonEpisodeDownloadResolver {
  CatalogSeasonEpisodeDownloadResolver({
    required Stream<ReleaseSearchProgress> Function(EpisodeReference episode)
    releaseSearch,
    required Stream<WebStreamSearchProgress> Function(EpisodeReference episode)
    webSearch,
    required Future<String?> Function(DebridService service) readToken,
    required SettingsPreferences Function() readSettings,
    required Future<DirectTorrentCapability> Function() readDirectCapability,
    SeasonDebridResolverFactory resolverFactory = createDebridStreamResolver,
    WebStreamPreflight? webPreflight,
    this.discoveryTimeout = const Duration(seconds: 24),
    this.resolutionTimeout = const Duration(seconds: 18),
    this.debridEpisodeBudget = const Duration(seconds: 40),
  }) : _releaseSearch = releaseSearch,
       _webSearch = webSearch,
       _readToken = readToken,
       _readSettings = readSettings,
       _readDirectCapability = readDirectCapability,
       _resolverFactory = resolverFactory,
       _webPreflight = webPreflight ?? const WebStreamValidator().validate;

  final Stream<ReleaseSearchProgress> Function(EpisodeReference episode)
  _releaseSearch;
  final Stream<WebStreamSearchProgress> Function(EpisodeReference episode)
  _webSearch;
  final Future<String?> Function(DebridService service) _readToken;
  final SettingsPreferences Function() _readSettings;
  final Future<DirectTorrentCapability> Function() _readDirectCapability;
  final SeasonDebridResolverFactory _resolverFactory;
  final WebStreamPreflight _webPreflight;
  final Duration discoveryTimeout;
  final Duration resolutionTimeout;
  final Duration debridEpisodeBudget;
  bool _directSupported = false;

  @override
  Future<bool> directTorrentAvailable() async {
    final settings = _readSettings();
    if (!settings.directTorrentStreamingEnabled) return false;
    if (_directSupported) return true;
    try {
      final capability = await _readDirectCapability().timeout(
        const Duration(seconds: 4),
      );
      _directSupported = capability.supported;
      return _directSupported;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  }) async {
    final settings = _readSettings();
    return switch (plan.sourcePolicy) {
      SeasonDownloadSourcePolicy.automatic => _resolveAutomatic(
        plan,
        episode,
        affinity,
        settings,
      ),
      SeasonDownloadSourcePolicy.debrid => _resolveDebrid(
        plan,
        episode,
        affinity,
        settings,
      ),
      SeasonDownloadSourcePolicy.web => _resolveWeb(
        plan,
        episode,
        affinity,
        settings,
      ),
      SeasonDownloadSourcePolicy.directTorrent => _resolveDirect(
        plan,
        episode,
        affinity,
        settings,
      ),
    };
  }

  Future<ResolvedSeasonDownload?> _resolveAutomatic(
    SeasonDownloadPlan plan,
    EpisodeReference episode,
    SeasonDownloadAffinity affinity,
    SettingsPreferences settings,
  ) async {
    try {
      final debrid = await _resolveDebrid(plan, episode, affinity, settings);
      if (debrid != null) return debrid;
    } on DebridProviderFailure catch (error) {
      // Rate limiting applies to every torrent candidate but does not make an
      // already-discovered Web source unsafe. Automatic downloads may fall
      // back once to Web; explicit Debrid-only requests still surface the
      // original provider error through their dedicated branch above.
      if (error.failureCategory != DebridFailureCategory.rateLimited) rethrow;
    }
    return _resolveWeb(plan, episode, affinity, settings);
  }

  Future<ResolvedSeasonDownload?> _resolveDebrid(
    SeasonDownloadPlan plan,
    EpisodeReference episode,
    SeasonDownloadAffinity affinity,
    SettingsPreferences settings,
  ) async {
    if (!settings.debridStreamsEnabled) return null;
    final service = settings.debridProvider;
    String? token;
    try {
      token = await _readToken(service).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
    if (token == null || token.isEmpty) return null;
    final releases = await _findReleases(episode);
    final ranked = rankSeasonReleaseCandidates(
      releases,
      quality: plan.quality,
      preferredAudio: plan.preferredAudio,
      affinity: affinity,
    );
    final episodeClock = Stopwatch()..start();
    for (final release in ranked.take(6)) {
      final remaining = debridEpisodeBudget - episodeClock.elapsed;
      if (remaining <= Duration.zero) break;
      StreamReady? ready;
      try {
        final resolver = _resolverFactory(
          service: service,
          token: token,
          source: SingleReleaseSource(release),
        );
        ready = await _firstReady(
          resolver.resolve(episode),
          timeout: remaining < resolutionTimeout
              ? remaining
              : resolutionTimeout,
        );
        final publicUri = safePublicHttpsUri(ready?.uri.toString());
        if (ready == null || publicUri == null) {
          await ready?.playbackLease?.close();
          continue;
        }
        return ResolvedSeasonDownload(
          request: OfflineDownloadRequest(
            anilistMediaId: episode.anilistMediaId,
            malMediaId: episode.malMediaId,
            episode: episode.episode,
            seriesTitle: episode.title,
            episodeTitle: 'Episode ${episode.episode}',
            sourceLabel:
                '${service.displayName} • ${_qualityLabel(release.quality, releaseQualityHeight(release))}',
            transport: DownloadTransport.https,
            sourceUri: publicUri,
            providerId: service.slug,
            providerName: service.displayName,
            quality: _qualityLabel(
              release.quality,
              releaseQualityHeight(release),
            ),
            audioLabel: releaseAudioPickerLabel(release),
            mimeType: ready.mediaContentType ?? 'video/x-matroska',
            fileExtension: _safeVideoExtension(publicUri) ?? 'mkv',
            requestHeaders: sanitizeWebStreamHeaders(ready.headers),
          ),
          affinity: SeasonDownloadAffinity(
            releaseSourceId: release.sourceId,
            releaseProvider: release.provider,
            releaseGroup: releaseGroupKey(release.releaseName),
            webProviderId: affinity.webProviderId,
          ),
          close: ready.playbackLease?.close,
        );
      } catch (error) {
        await ready?.playbackLease?.close();
        if (isTerminalDebridFailoverFailure(error)) rethrow;
      }
    }
    return null;
  }

  Future<ResolvedSeasonDownload?> _resolveWeb(
    SeasonDownloadPlan plan,
    EpisodeReference episode,
    SeasonDownloadAffinity affinity,
    SettingsPreferences settings,
  ) async {
    if (!settings.webStreamsEnabled) return null;
    final streams = await _findWebStreams(episode);
    final ranked = rankSeasonWebCandidates(
      streams.where(
        (stream) =>
            stream.subtitleUri == null &&
            safePublicHttpsUri(stream.uri.toString()) != null,
      ),
      quality: plan.quality,
      preferredAudio: plan.preferredAudio,
      affinity: affinity,
    );
    for (final stream in ranked.take(5)) {
      final uri = safePublicHttpsUri(stream.uri.toString())!;
      ValidatedWebStream? validated;
      String? contentType;
      try {
        validated = await _webPreflight(
          uri,
          sanitizeWebStreamHeaders(stream.headers),
          subtitleUri: stream.subtitleUri,
        ).timeout(resolutionTimeout);
        contentType = validated.contentType;
      } catch (_) {
        continue;
      } finally {
        try {
          await validated?.session?.close();
        } catch (_) {
          // A completed probe is not invalidated by best-effort proxy cleanup.
        }
      }
      final isHls = _isHls(uri, stream.title, contentType);
      final height = webStreamQualityHeight(stream);
      return ResolvedSeasonDownload(
        request: OfflineDownloadRequest(
          anilistMediaId: episode.anilistMediaId,
          malMediaId: episode.malMediaId,
          episode: episode.episode,
          seriesTitle: episode.title,
          episodeTitle: 'Episode ${episode.episode}',
          sourceLabel:
              '${stream.providerName} • ${_qualityLabel(stream.quality, height)}',
          transport: DownloadTransport.https,
          sourceUri: uri,
          providerId: stream.providerId,
          providerName: stream.providerName,
          quality: _qualityLabel(stream.quality, height),
          audioLabel: stream.effectiveAudioCapability.pickerLabel,
          mimeType: isHls ? 'application/vnd.apple.mpegurl' : contentType,
          fileExtension: isHls ? 'm3u8' : (_safeVideoExtension(uri) ?? 'mp4'),
          requestHeaders: sanitizeWebStreamHeaders(stream.headers),
        ),
        affinity: SeasonDownloadAffinity(
          releaseSourceId: affinity.releaseSourceId,
          releaseProvider: affinity.releaseProvider,
          releaseGroup: affinity.releaseGroup,
          webProviderId: stream.providerId,
        ),
      );
    }
    return null;
  }

  Future<ResolvedSeasonDownload?> _resolveDirect(
    SeasonDownloadPlan plan,
    EpisodeReference episode,
    SeasonDownloadAffinity affinity,
    SettingsPreferences settings,
  ) async {
    if (!settings.directTorrentStreamingEnabled ||
        !await directTorrentAvailable()) {
      return null;
    }
    final ranked = rankSeasonReleaseCandidates(
      await _findReleases(episode),
      quality: plan.quality,
      preferredAudio: plan.preferredAudio,
      affinity: affinity,
    );
    if (ranked.isEmpty) return null;
    final release = ranked.first;
    final height = releaseQualityHeight(release);
    return ResolvedSeasonDownload(
      request: OfflineDownloadRequest(
        anilistMediaId: episode.anilistMediaId,
        malMediaId: episode.malMediaId,
        episode: episode.episode,
        seriesTitle: episode.title,
        episodeTitle: 'Episode ${episode.episode}',
        sourceLabel:
            'Direct torrent • ${_qualityLabel(release.quality, height)}',
        transport: DownloadTransport.directPeer,
        providerId: release.sourceId,
        providerName: release.provider ?? 'Torrent source',
        quality: _qualityLabel(release.quality, height),
        audioLabel: releaseAudioPickerLabel(release),
        mimeType: 'video/x-matroska',
        fileExtension: 'mkv',
        directPeerCapability: DirectPeerDownloadCapability(
          magnet: release.magnetUri,
          episode: episode.episode,
          preferredFileIndex: release.preferredFileIndex,
        ),
      ),
      affinity: SeasonDownloadAffinity(
        releaseSourceId: release.sourceId,
        releaseProvider: release.provider,
        releaseGroup: releaseGroupKey(release.releaseName),
        webProviderId: affinity.webProviderId,
      ),
    );
  }

  Future<List<ReleaseCandidate>> _findReleases(EpisodeReference episode) async {
    var latest = const <ReleaseCandidate>[];
    try {
      await for (final progress in _releaseSearch(
        episode,
      ).timeout(discoveryTimeout)) {
        latest = progress.candidates;
        if (progress.isComplete) break;
      }
    } catch (_) {
      // A bounded timeout keeps the season worker moving with any partial set.
    }
    return latest;
  }

  Future<List<WebStreamResult>> _findWebStreams(
    EpisodeReference episode,
  ) async {
    var latest = const <WebStreamResult>[];
    try {
      await for (final progress in _webSearch(
        episode,
      ).timeout(discoveryTimeout)) {
        latest = progress.aggregation.streams;
        if (progress.isComplete) break;
      }
    } catch (_) {
      // Partial provider results remain usable when another add-on stalls.
    }
    return latest;
  }
}

List<ReleaseCandidate> rankSeasonReleaseCandidates(
  Iterable<ReleaseCandidate> input, {
  required SeasonDownloadQuality quality,
  required PlaybackAudioPreference preferredAudio,
  SeasonDownloadAffinity affinity = const SeasonDownloadAffinity(),
}) {
  final result = input.toList(growable: false);
  result.sort((left, right) {
    final audio = releaseAudioPreferenceRank(
      left,
      preferredAudio,
    ).compareTo(releaseAudioPreferenceRank(right, preferredAudio));
    if (audio != 0) return audio;
    final qualityOrder = _qualityPreferenceRank(
      releaseQualityHeight(left),
      quality,
    ).compareTo(_qualityPreferenceRank(releaseQualityHeight(right), quality));
    if (qualityOrder != 0) return qualityOrder;
    final affinityOrder = _releaseAffinityRank(
      left,
      affinity,
    ).compareTo(_releaseAffinityRank(right, affinity));
    if (affinityOrder != 0) return affinityOrder;
    return compareReleaseCandidates(
      left,
      right,
      sort: DebridStreamSort.bestQuality,
      preferredAudio: preferredAudio,
    );
  });
  return result;
}

List<WebStreamResult> rankSeasonWebCandidates(
  Iterable<WebStreamResult> input, {
  required SeasonDownloadQuality quality,
  required PlaybackAudioPreference preferredAudio,
  SeasonDownloadAffinity affinity = const SeasonDownloadAffinity(),
}) {
  final result = input.toList(growable: false);
  result.sort((left, right) {
    final audio = webStreamAudioPreferenceRank(
      left,
      preferredAudio,
    ).compareTo(webStreamAudioPreferenceRank(right, preferredAudio));
    if (audio != 0) return audio;
    final qualityOrder = _qualityPreferenceRank(
      webStreamQualityHeight(left),
      quality,
    ).compareTo(_qualityPreferenceRank(webStreamQualityHeight(right), quality));
    if (qualityOrder != 0) return qualityOrder;
    final leftAffinity = left.providerId == affinity.webProviderId ? 0 : 1;
    final rightAffinity = right.providerId == affinity.webProviderId ? 0 : 1;
    final affinityOrder = leftAffinity.compareTo(rightAffinity);
    if (affinityOrder != 0) return affinityOrder;
    return compareWebStreamCandidates(
      left,
      right,
      quality: WebStreamQualityPreference.bestAvailable,
      preferredAudio: preferredAudio,
    );
  });
  return result;
}

Future<StreamReady?> _firstReady(
  Stream<StreamResolution> resolutions, {
  required Duration timeout,
}) async {
  try {
    await for (final resolution in resolutions.timeout(timeout)) {
      if (resolution is StreamReady) return resolution;
    }
  } catch (error) {
    if (isTerminalDebridFailoverFailure(error)) rethrow;
    return null;
  }
  return null;
}

int _qualityPreferenceRank(int height, SeasonDownloadQuality quality) {
  final target = quality.targetHeight;
  if (target == null) return height <= 0 ? 1 << 29 : -height;
  if (height <= 0) return 1 << 29;
  return (height - target).abs();
}

int _releaseAffinityRank(
  ReleaseCandidate release,
  SeasonDownloadAffinity affinity,
) {
  final sameSource =
      affinity.releaseSourceId != null &&
      release.sourceId == affinity.releaseSourceId;
  final sameProvider =
      affinity.releaseProvider != null &&
      release.provider?.toLowerCase() ==
          affinity.releaseProvider?.toLowerCase();
  final group = releaseGroupKey(release.releaseName);
  final sameGroup =
      affinity.releaseGroup != null && group == affinity.releaseGroup;
  if ((sameSource || sameProvider) && sameGroup) return 0;
  if (sameSource || sameProvider) return 1;
  if (sameGroup) return 2;
  return 3;
}

String _qualityLabel(String? label, int height) {
  final normalized = label?.trim();
  if (normalized != null && normalized.isNotEmpty) return normalized;
  return height > 0 ? '${height}p' : 'Auto';
}

bool _isHls(Uri uri, String title, String? contentType) =>
    uri.path.toLowerCase().endsWith('.m3u8') ||
    title.toLowerCase().contains('hls') ||
    const {
      'application/vnd.apple.mpegurl',
      'application/x-mpegurl',
      'application/mpegurl',
      'audio/mpegurl',
      'audio/x-mpegurl',
    }.contains(contentType?.split(';').first.trim().toLowerCase());

String? _safeVideoExtension(Uri uri) {
  final segment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = segment.lastIndexOf('.');
  if (dot < 0) return null;
  final extension = segment.substring(dot + 1).toLowerCase();
  return const {'mp4', 'mkv', 'webm', 'm4v', 'ts'}.contains(extension)
      ? extension
      : null;
}
