import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/application/season_download_source_resolver.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quality and audio lead while release affinity breaks close ties', () {
    const affinity = SeasonDownloadAffinity(
      releaseSourceId: 'preferred-source',
      releaseGroup: 'group',
    );
    final ranked = rankSeasonReleaseCandidates(
      const [
        ReleaseCandidate(
          infoHash: '1',
          magnetUri: 'magnet:?xt=urn:btih:1',
          releaseName: '[Other] Show 01 [1080p]',
          seeders: 100,
          sourceId: 'other',
          quality: '1080p',
          isDubbed: true,
        ),
        ReleaseCandidate(
          infoHash: '2',
          magnetUri: 'magnet:?xt=urn:btih:2',
          releaseName: '[Group] Show 01 [1080p]',
          seeders: 5,
          sourceId: 'preferred-source',
          quality: '1080p',
          isDubbed: true,
        ),
        ReleaseCandidate(
          infoHash: '3',
          magnetUri: 'magnet:?xt=urn:btih:3',
          releaseName: '[Group] Show 01 [720p]',
          seeders: 500,
          sourceId: 'preferred-source',
          quality: '720p',
          isDubbed: true,
        ),
      ],
      quality: SeasonDownloadQuality.p1080,
      preferredAudio: PlaybackAudioPreference.dub,
      affinity: affinity,
    );

    expect(ranked.map((release) => release.infoHash), ['2', '1', '3']);
  });

  test('Web ranking keeps the same provider after audio and quality', () {
    final ranked = rankSeasonWebCandidates(
      [
        _web('other', 'https://video.example/a.mp4'),
        _web('same', 'https://video.example/b.mp4'),
      ],
      quality: SeasonDownloadQuality.p1080,
      preferredAudio: PlaybackAudioPreference.dub,
      affinity: const SeasonDownloadAffinity(webProviderId: 'same'),
    );

    expect(ranked.first.providerId, 'same');
  });

  test(
    'automatic season download stops Debrid fanout and falls back to Web on rate limit',
    () async {
      var resolverCalls = 0;
      var webSearchCalls = 0;
      final resolver = _rateLimitedSeasonResolver(
        onResolver: () => resolverCalls++,
        onWebSearch: () => webSearchCalls++,
      );

      final resolved = await resolver.resolve(
        plan: SeasonDownloadPlan(
          anime: _anime,
          episodeCount: 1,
          quality: SeasonDownloadQuality.p1080,
          sourcePolicy: SeasonDownloadSourcePolicy.automatic,
          preferredAudio: PlaybackAudioPreference.dub,
        ),
        episode: const EpisodeReference(
          anilistMediaId: 10,
          title: 'Example',
          episode: 1,
        ),
        affinity: const SeasonDownloadAffinity(),
      );

      expect(resolverCalls, 1);
      expect(webSearchCalls, 1);
      expect(resolved?.request.providerId, 'web-fallback');
      expect(resolved?.request.transport, DownloadTransport.https);
    },
  );

  test(
    'explicit Debrid season download preserves the rate-limit failure',
    () async {
      var resolverCalls = 0;
      var webSearchCalls = 0;
      final resolver = _rateLimitedSeasonResolver(
        onResolver: () => resolverCalls++,
        onWebSearch: () => webSearchCalls++,
      );

      await expectLater(
        resolver.resolve(
          plan: SeasonDownloadPlan(
            anime: _anime,
            episodeCount: 1,
            quality: SeasonDownloadQuality.p1080,
            sourcePolicy: SeasonDownloadSourcePolicy.debrid,
            preferredAudio: PlaybackAudioPreference.dub,
          ),
          episode: const EpisodeReference(
            anilistMediaId: 10,
            title: 'Example',
            episode: 1,
          ),
          affinity: const SeasonDownloadAffinity(),
        ),
        throwsA(
          isA<RealDebridException>().having(
            (error) => error.kind,
            'kind',
            RealDebridFailureKind.rateLimited,
          ),
        ),
      );
      expect(resolverCalls, 1);
      expect(webSearchCalls, 0);
    },
  );

  test(
    'direct season request keeps its magnet process-local and redacted',
    () async {
      const magnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';
      final resolver = CatalogSeasonEpisodeDownloadResolver(
        releaseSearch: (_) => Stream.value(
          const ReleaseSearchProgress(
            candidates: [
              ReleaseCandidate(
                infoHash: '0123456789abcdef0123456789abcdef01234567',
                magnetUri: magnet,
                releaseName: '[Group] Example - 01 [1080p] [Dual Audio]',
                seeders: 8,
                sourceId: 'repo',
                quality: '1080p',
                audioIntent: ReleaseAudioIntent.multi,
              ),
            ],
            completedSources: 1,
            totalSources: 1,
          ),
        ),
        webSearch: (_) => Stream.value(const WebStreamSearchProgress()),
        readToken: (_) async => null,
        readSettings: () => const SettingsPreferences(
          directTorrentStreamingEnabled: true,
          loaded: true,
        ),
        readDirectCapability: () async => const DirectTorrentCapability(
          supported: true,
          engine: 'test',
          maximumFileBytes: 1000000,
          supportsSeeking: true,
          temporaryStorage: true,
        ),
      );
      final plan = SeasonDownloadPlan(
        anime: _anime,
        episodeCount: 1,
        quality: SeasonDownloadQuality.p1080,
        sourcePolicy: SeasonDownloadSourcePolicy.directTorrent,
        preferredAudio: PlaybackAudioPreference.dub,
      );

      final resolved = await resolver.resolve(
        plan: plan,
        episode: const EpisodeReference(
          anilistMediaId: 10,
          title: 'Example',
          episode: 1,
        ),
        affinity: const SeasonDownloadAffinity(),
      );

      expect(resolved, isNotNull);
      expect(resolved!.request.transport, DownloadTransport.directPeer);
      expect(resolved.request.audioLabel, 'SUB / DUB');
      expect(resolved.request.sourceUri, isNull);
      expect(
        resolved.request.directPeerCapability.toString(),
        contains('redacted'),
      );
      expect(
        resolved.request.directPeerCapability.toString(),
        isNot(contains(magnet)),
      );
      expect(resolved.request.sourceLabel, isNot(contains('Group')));
    },
  );

  test('Web season jobs retain original HTTPS and mark probed HLS', () async {
    final original = Uri.parse('https://video.example.test/watch?id=42');
    final resolver = CatalogSeasonEpisodeDownloadResolver(
      releaseSearch: (_) => Stream.value(const ReleaseSearchProgress()),
      webSearch: (_) => Stream.value(
        WebStreamSearchProgress(
          aggregation: WebStreamAggregation(
            streams: [
              WebStreamResult(
                providerId: 'web',
                providerName: 'Web',
                title: 'DUB / 1080p',
                uri: original,
                quality: '1080p',
                headers: const {'Referer': 'https://video.example.test/'},
                audioCapability: WebStreamAudioCapability.subAndDub,
              ),
            ],
          ),
          completedProviders: 1,
          totalProviders: 1,
        ),
      ),
      readToken: (_) async => null,
      readSettings: () => const SettingsPreferences(loaded: true),
      readDirectCapability: () async =>
          const DirectTorrentCapability.unsupported(),
      webPreflight: (uri, headers, {subtitleUri}) async => ValidatedWebStream(
        uri: Uri.parse('http://127.0.0.1:1234/session'),
        headers: const {},
        contentType: 'application/vnd.apple.mpegurl',
      ),
    );
    final resolved = await resolver.resolve(
      plan: SeasonDownloadPlan(
        anime: _anime,
        episodeCount: 1,
        quality: SeasonDownloadQuality.p1080,
        sourcePolicy: SeasonDownloadSourcePolicy.web,
        preferredAudio: PlaybackAudioPreference.dub,
      ),
      episode: const EpisodeReference(
        anilistMediaId: 10,
        title: 'Example',
        episode: 1,
      ),
      affinity: const SeasonDownloadAffinity(),
    );

    expect(resolved?.request.sourceUri, original);
    expect(resolved?.request.fileExtension, 'm3u8');
    expect(resolved?.request.mimeType, 'application/vnd.apple.mpegurl');
    expect(resolved?.request.audioLabel, 'SUB / DUB');
    expect(resolved?.request.requestHeaders['Referer'], isNotNull);
  });

  test('Web season jobs skip sources with external caption sidecars', () async {
    final captioned = Uri.parse('https://video.example.test/captioned.m3u8');
    final fallback = Uri.parse('https://video.example.test/fallback.mp4');
    final preflightUris = <Uri>[];
    final resolver = CatalogSeasonEpisodeDownloadResolver(
      releaseSearch: (_) => Stream.value(const ReleaseSearchProgress()),
      webSearch: (_) => Stream.value(
        WebStreamSearchProgress(
          aggregation: WebStreamAggregation(
            streams: [
              WebStreamResult(
                providerId: 'captioned',
                providerName: 'Captioned',
                title: 'SUB / 1080p',
                uri: captioned,
                subtitleUri: Uri.parse(
                  'https://video.example.test/captions.vtt',
                ),
                quality: '1080p',
                audioCapability: WebStreamAudioCapability.sub,
              ),
              WebStreamResult(
                providerId: 'fallback',
                providerName: 'Fallback',
                title: 'SUB / 720p',
                uri: fallback,
                quality: '720p',
                audioCapability: WebStreamAudioCapability.sub,
              ),
            ],
          ),
          completedProviders: 2,
          totalProviders: 2,
        ),
      ),
      readToken: (_) async => null,
      readSettings: () => const SettingsPreferences(loaded: true),
      readDirectCapability: () async =>
          const DirectTorrentCapability.unsupported(),
      webPreflight: (uri, headers, {subtitleUri}) async {
        preflightUris.add(uri);
        return ValidatedWebStream(
          uri: Uri.parse('http://127.0.0.1:1234/session'),
          headers: const {},
          contentType: 'video/mp4',
        );
      },
    );

    final resolved = await resolver.resolve(
      plan: SeasonDownloadPlan(
        anime: _anime,
        episodeCount: 1,
        quality: SeasonDownloadQuality.p1080,
        sourcePolicy: SeasonDownloadSourcePolicy.web,
        preferredAudio: PlaybackAudioPreference.sub,
      ),
      episode: const EpisodeReference(
        anilistMediaId: 10,
        title: 'Example',
        episode: 1,
      ),
      affinity: const SeasonDownloadAffinity(),
    );

    expect(preflightUris, [fallback]);
    expect(resolved?.request.sourceUri, fallback);
  });

  test('season jobs keep fallback source audio instead of preference', () async {
    final resolver = CatalogSeasonEpisodeDownloadResolver(
      releaseSearch: (_) => Stream.value(
        const ReleaseSearchProgress(
          candidates: [
            ReleaseCandidate(
              infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              magnetUri:
                  'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              releaseName: '[Group] Example - 01 [1080p] [SUB]',
              seeders: 1,
              sourceId: 'repo',
              quality: '1080p',
              audioIntent: ReleaseAudioIntent.sub,
            ),
          ],
          completedSources: 1,
          totalSources: 1,
        ),
      ),
      webSearch: (_) => Stream.value(const WebStreamSearchProgress()),
      readToken: (_) async => null,
      readSettings: () => const SettingsPreferences(
        directTorrentStreamingEnabled: true,
        loaded: true,
      ),
      readDirectCapability: () async => const DirectTorrentCapability(
        supported: true,
        engine: 'test',
        maximumFileBytes: 1000000,
        supportsSeeking: true,
        temporaryStorage: true,
      ),
    );

    final resolved = await resolver.resolve(
      plan: SeasonDownloadPlan(
        anime: _anime,
        episodeCount: 1,
        quality: SeasonDownloadQuality.p1080,
        sourcePolicy: SeasonDownloadSourcePolicy.directTorrent,
        preferredAudio: PlaybackAudioPreference.dub,
      ),
      episode: const EpisodeReference(
        anilistMediaId: 10,
        title: 'Example',
        episode: 1,
      ),
      affinity: const SeasonDownloadAffinity(),
    );

    expect(resolved?.request.audioLabel, 'SUB');
  });
}

WebStreamResult _web(String provider, String url) => WebStreamResult(
  providerId: provider,
  providerName: provider,
  title: 'DUB / 1080p',
  uri: Uri.parse(url),
  quality: '1080p',
  audioCapability: WebStreamAudioCapability.subAndDub,
);

CatalogSeasonEpisodeDownloadResolver _rateLimitedSeasonResolver({
  required void Function() onResolver,
  required void Function() onWebSearch,
}) => CatalogSeasonEpisodeDownloadResolver(
  releaseSearch: (_) => Stream.value(
    const ReleaseSearchProgress(
      candidates: [
        ReleaseCandidate(
          infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          magnetUri:
              'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          releaseName: 'Example 01 1080p',
          seeders: 10,
          sourceId: 'torrent-one',
          quality: '1080p',
        ),
        ReleaseCandidate(
          infoHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          magnetUri:
              'magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          releaseName: 'Example 01 alternate 1080p',
          seeders: 9,
          sourceId: 'torrent-two',
          quality: '1080p',
        ),
      ],
      completedSources: 1,
      totalSources: 1,
    ),
  ),
  webSearch: (_) {
    onWebSearch();
    return Stream.value(
      WebStreamSearchProgress(
        aggregation: WebStreamAggregation(
          streams: [
            WebStreamResult(
              providerId: 'web-fallback',
              providerName: 'Web fallback',
              title: 'DUB / 1080p',
              uri: Uri.parse('https://video.example.test/fallback.mp4'),
              quality: '1080p',
              audioCapability: WebStreamAudioCapability.dub,
            ),
          ],
        ),
        completedProviders: 1,
        totalProviders: 1,
      ),
    );
  },
  readToken: (_) async => 'token',
  readSettings: () => const SettingsPreferences(loaded: true),
  readDirectCapability: () async => const DirectTorrentCapability.unsupported(),
  resolverFactory: ({required service, required token, required source}) {
    onResolver();
    return const _RateLimitedResolver();
  },
  webPreflight: (uri, headers, {subtitleUri}) async => ValidatedWebStream(
    uri: Uri.parse('http://127.0.0.1:1234/session'),
    headers: const {},
    contentType: 'video/mp4',
  ),
);

class _RateLimitedResolver implements StreamResolver {
  const _RateLimitedResolver();

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    throw RealDebridException.fromApi(
      code: 34,
      retryAfter: const Duration(seconds: 30),
    );
  }
}

const _anime = AnimeSummary(
  id: 10,
  title: 'Example',
  description: '',
  episodes: 1,
  score: null,
);
