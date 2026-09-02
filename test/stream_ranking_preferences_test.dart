import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ReleaseCandidate release({
    required String id,
    required String quality,
    required int seeders,
    required String size,
    bool dubbed = true,
    String? name,
  }) => ReleaseCandidate(
    infoHash: id.padRight(40, id),
    magnetUri: 'magnet:?xt=urn:btih:${id.padRight(40, id)}',
    releaseName: name ?? '$quality release $id',
    seeders: seeders,
    sourceId: 'source',
    quality: quality,
    sizeLabel: size,
    isDubbed: dubbed,
  );

  WebStreamResult web({
    required String id,
    required String quality,
    bool dubbed = true,
    WebStreamAudioCapability? audioCapability,
    List<String> audioLanguages = const [],
  }) => WebStreamResult(
    providerId: 'provider-$id',
    providerName: 'Provider $id',
    title: '$quality stream $id',
    uri: Uri.parse('https://example.com/$id.m3u8'),
    quality: quality,
    isDubbed: dubbed,
    audioCapability: audioCapability,
    audioLanguages: audioLanguages,
  );

  ReleaseCandidate codecRelease({
    required String id,
    required String name,
    String? codec,
    String? quality = '1080p',
  }) => ReleaseCandidate(
    infoHash: id.padRight(40, id),
    magnetUri: 'magnet:?xt=urn:btih:${id.padRight(40, id)}',
    releaseName: name,
    seeders: 10,
    sourceId: 'codec-source',
    quality: quality,
    codec: codec,
    isDubbed: true,
  );

  const avcOnlyDevice = TvDeviceProfile(
    manufacturer: 'Test',
    model: 'AVC only',
    sdk: 34,
    abis: ['arm64-v8a'],
    displayModes: [],
    hdrTypes: [],
    codecs: [
      TvCodecCapability(
        name: 'hardware.avc.decoder',
        mime: 'video/avc',
        hardware: true,
      ),
    ],
    audioOutputs: [],
  );

  const av1Device = TvDeviceProfile(
    manufacturer: 'Test',
    model: 'AV1 capable',
    sdk: 34,
    abis: ['arm64-v8a'],
    displayModes: [],
    hdrTypes: [],
    codecs: [
      TvCodecCapability(
        name: 'hardware.avc.decoder',
        mime: 'video/avc',
        hardware: true,
      ),
      TvCodecCapability(
        name: 'hardware.av1.decoder',
        mime: 'video/av01',
        hardware: true,
        maxWidth: 3840,
        maxHeight: 2160,
      ),
    ],
    audioOutputs: [],
  );

  test(
    'codec compatibility is device-specific and fails open when unknown',
    () {
      final av1 = codecRelease(id: 'a', name: 'Example 1080p', codec: 'AV1');
      final av01FromName = codecRelease(
        id: 'b',
        name: 'Example S01E01 1080p AV01',
      );
      final unknown = codecRelease(
        id: 'c',
        name: 'Example S01E01 1080p WEB-DL',
      );

      expect(
        releaseCodecCompatibility(av1, device: avcOnlyDevice),
        ReleaseCodecCompatibility.unsupported,
      );
      expect(
        releaseCodecCompatibility(av01FromName, device: avcOnlyDevice),
        ReleaseCodecCompatibility.unsupported,
      );
      expect(
        releaseCodecCompatibility(av1, device: av1Device),
        ReleaseCodecCompatibility.supported,
      );
      expect(
        releaseCodecCompatibility(av1, device: const TvDeviceProfile.unknown()),
        ReleaseCodecCompatibility.unknown,
      );
      expect(
        releaseCodecCompatibility(unknown, device: avcOnlyDevice),
        ReleaseCodecCompatibility.unknown,
      );
      expect(
        releaseCodecIsPlayableOnDevice(unknown, device: avcOnlyDevice),
        isTrue,
      );
    },
  );

  test('a software-only AV1 decoder is not advertised as playable', () {
    final av1 = codecRelease(id: 'a', name: 'Example 1080p AV1', codec: 'AV1');
    const softwareAv1Device = TvDeviceProfile(
      manufacturer: 'Test',
      model: 'Software AV1 only',
      sdk: 34,
      abis: ['arm64-v8a'],
      displayModes: [],
      hdrTypes: [],
      codecs: [
        TvCodecCapability(
          name: 'c2.android.av1.decoder',
          mime: 'video/av01',
          hardware: false,
        ),
      ],
      audioOutputs: [],
    );

    expect(
      releaseCodecCompatibility(av1, device: softwareAv1Device),
      ReleaseCodecCompatibility.unsupported,
    );
  });

  test('decoder dimensions reject only known oversized releases', () {
    final av1p2160 = codecRelease(
      id: 'a',
      name: 'Example 2160p AV1',
      codec: 'AV1',
      quality: '2160p',
    );
    final av1p1080 = codecRelease(
      id: 'b',
      name: 'Example 1080p AV1',
      codec: 'AV1',
    );
    final av1UnknownResolution = codecRelease(
      id: 'c',
      name: 'Example AV1 WEB-DL',
      codec: 'AV1',
      quality: null,
    );
    const cappedAv1Device = TvDeviceProfile(
      manufacturer: 'Test',
      model: '1080p AV1',
      sdk: 34,
      abis: ['arm64-v8a'],
      displayModes: [],
      hdrTypes: [],
      codecs: [
        TvCodecCapability(
          name: 'hardware.av1.decoder',
          mime: 'video/av01',
          hardware: true,
          maxWidth: 1920,
          maxHeight: 1080,
        ),
      ],
      audioOutputs: [],
    );

    expect(
      releaseCodecCompatibility(av1p2160, device: cappedAv1Device),
      ReleaseCodecCompatibility.unsupported,
    );
    expect(
      releaseCodecCompatibility(av1p1080, device: cappedAv1Device),
      ReleaseCodecCompatibility.supported,
    );
    expect(
      releaseCodecCompatibility(av1UnknownResolution, device: cappedAv1Device),
      ReleaseCodecCompatibility.supported,
    );
  });

  test('unknown decoder dimensions fail open for known resolutions', () {
    final av1p2160 = codecRelease(
      id: 'a',
      name: 'Example 2160p AV1',
      codec: 'AV1',
      quality: '2160p',
    );
    const dimensionsUnknown = TvDeviceProfile(
      manufacturer: 'Test',
      model: 'Unknown AV1 limits',
      sdk: 34,
      abis: ['arm64-v8a'],
      displayModes: [],
      hdrTypes: [],
      codecs: [
        TvCodecCapability(
          name: 'hardware.av1.decoder',
          mime: 'video/av01',
          hardware: true,
        ),
      ],
      audioOutputs: [],
    );

    expect(
      releaseCodecCompatibility(av1p2160, device: dimensionsUnknown),
      ReleaseCodecCompatibility.unknown,
    );
    expect(
      releaseCodecIsPlayableOnDevice(av1p2160, device: dimensionsUnknown),
      isTrue,
    );
  });

  test('automatic release pools omit only codecs known unsupported', () {
    final av1 = codecRelease(id: 'a', name: 'Example 1080p AV1', codec: 'AV1');
    final h264 = codecRelease(
      id: 'b',
      name: 'Example 1080p x264',
      codec: 'H.264',
    );
    final unknown = codecRelease(id: 'c', name: 'Example 1080p WEB-DL');

    List<ReleaseCandidate> rankFor(TvDeviceProfile device) =>
        rankAutomaticAutoplayReleases(
          [av1, h264, unknown],
          language: 'dub',
          quality: 'any',
          codec: 'any',
          hdr: 'any',
          allowBatch: true,
          preferredAudio: PlaybackAudioPreference.dub,
          rankingPreference: DebridStreamSort.bestQuality,
          device: device,
        );

    expect(rankFor(avcOnlyDevice), containsAll([h264, unknown]));
    expect(rankFor(avcOnlyDevice), isNot(contains(av1)));
    expect(rankFor(av1Device), containsAll([av1, h264, unknown]));
    expect(
      rankFor(const TvDeviceProfile.unknown()),
      containsAll([av1, h264, unknown]),
    );
  });

  test(
    'debrid modes rank quality, seeders, and known size deterministically',
    () {
      final small1080 = release(
        id: 'a',
        quality: '1080p',
        seeders: 50,
        size: '800 MB',
      );
      final large4k = release(id: 'b', quality: '4K', seeders: 2, size: '8 GB');
      final popular720 = release(
        id: 'c',
        quality: '720p',
        seeders: 500,
        size: '1.5 GB',
      );
      final candidates = [small1080, large4k, popular720];

      expect(
        rankReleaseCandidates(
          candidates,
          sort: DebridStreamSort.bestQuality,
          preferredAudio: PlaybackAudioPreference.dub,
        ).first,
        same(large4k),
      );
      expect(
        rankReleaseCandidates(
          candidates,
          sort: DebridStreamSort.mostSeeded,
          preferredAudio: PlaybackAudioPreference.dub,
        ).first,
        same(popular720),
      );
      expect(
        rankReleaseCandidates(
          candidates,
          sort: DebridStreamSort.largestSize,
          preferredAudio: PlaybackAudioPreference.dub,
        ).first,
        same(large4k),
      );
      expect(
        rankReleaseCandidates(
          candidates,
          sort: DebridStreamSort.smallestSize,
          preferredAudio: PlaybackAudioPreference.dub,
        ).first,
        same(small1080),
      );
    },
  );

  test('unknown release sizes stay after known sizes in either size mode', () {
    final known = release(id: 'a', quality: '720p', seeders: 1, size: '700 MB');
    final unknown = release(
      id: 'b',
      quality: '4K',
      seeders: 999,
      size: 'Unknown',
    );

    for (final mode in [
      DebridStreamSort.largestSize,
      DebridStreamSort.smallestSize,
    ]) {
      expect(
        rankReleaseCandidates(
          [unknown, known],
          sort: mode,
          preferredAudio: PlaybackAudioPreference.dub,
        ),
        [known, unknown],
      );
    }
  });

  test('audio safety remains ahead of every debrid ranking preference', () {
    final dub = release(id: 'd', quality: '480p', seeders: 1, size: '200 MB');
    final sub = release(
      id: 's',
      quality: '4K',
      seeders: 10000,
      size: '20 GB',
      dubbed: false,
    );

    for (final mode in DebridStreamSort.values) {
      expect(
        rankReleaseCandidates(
          [sub, dub],
          sort: mode,
          preferredAudio: PlaybackAudioPreference.dub,
        ).first,
        same(dub),
      );
    }
  });

  test(
    'preferred Web quality is exact-first without filtering alternatives',
    () {
      final p4k = web(id: '4k', quality: '2160p');
      final p1080 = web(id: '1080', quality: '1080p');
      final p720 = web(id: '720', quality: '720p');
      final ranked = rankWebStreamCandidates(
        [p4k, p720, p1080],
        quality: WebStreamQualityPreference.p1080,
        preferredAudio: PlaybackAudioPreference.dub,
      );

      expect(ranked.first, same(p1080));
      expect(ranked, hasLength(3));
    },
  );

  test('Web audio safety outranks a closer quality preference', () {
    final dub720 = web(id: 'dub', quality: '720p');
    final sub1080 = web(id: 'sub', quality: '1080p', dubbed: false);

    expect(
      rankWebStreamCandidates(
        [sub1080, dub720],
        quality: WebStreamQualityPreference.p1080,
        preferredAudio: PlaybackAudioPreference.dub,
      ).first,
      same(dub720),
    );
  });

  test('structured Web audio language outranks Dub/Sub fallback', () {
    final spanish = web(
      id: 'spanish',
      quality: '720p',
      audioCapability: WebStreamAudioCapability.unknown,
      audioLanguages: const ['es-MX'],
    );
    final english = web(
      id: 'english',
      quality: '2160p',
      audioCapability: WebStreamAudioCapability.dub,
      audioLanguages: const ['eng'],
    );
    final unknown = web(
      id: 'unknown-language',
      quality: '1080p',
      audioCapability: WebStreamAudioCapability.dub,
    );

    final ranked = rankWebStreamCandidates(
      [english, unknown, spanish],
      quality: WebStreamQualityPreference.bestAvailable,
      preferredAudio: PlaybackAudioPreference.dub,
      preferredAudioLanguage: 'spa',
    );

    expect(ranked, [spanish, unknown, english]);
  });

  test('dual Web audio matches Sub and Dub while unknown stays All-only', () {
    final dual = web(
      id: 'dual',
      quality: '1080p',
      audioCapability: WebStreamAudioCapability.subAndDub,
    );
    final sub = web(
      id: 'sub-only',
      quality: '1080p',
      dubbed: false,
      audioCapability: WebStreamAudioCapability.sub,
    );
    final dub = web(
      id: 'dub-only',
      quality: '1080p',
      audioCapability: WebStreamAudioCapability.dub,
    );
    final unknown = web(
      id: 'unknown',
      quality: '1080p',
      audioCapability: WebStreamAudioCapability.unknown,
    );

    expect(
      automaticWebStreamMatchesFilters(dual, language: 'dub', quality: 'any'),
      isTrue,
    );
    expect(
      automaticWebStreamMatchesFilters(dual, language: 'sub', quality: 'any'),
      isTrue,
    );
    expect(
      automaticWebStreamMatchesFilters(
        unknown,
        language: 'dub',
        quality: 'any',
      ),
      isFalse,
    );
    expect(
      automaticWebStreamMatchesFilters(
        unknown,
        language: 'sub',
        quality: 'any',
      ),
      isFalse,
    );
    expect(
      automaticWebStreamMatchesFilters(
        unknown,
        language: 'any',
        quality: 'any',
      ),
      isTrue,
    );
    expect(webStreamMatchesAudioFilter(dual, 'all'), isTrue);
    expect(webStreamMatchesAudioFilter(dual, 'sub'), isTrue);
    expect(webStreamMatchesAudioFilter(dual, 'dub'), isTrue);
    expect(webStreamMatchesAudioFilter(sub, 'sub'), isTrue);
    expect(webStreamMatchesAudioFilter(sub, 'dub'), isFalse);
    expect(webStreamMatchesAudioFilter(dub, 'dub'), isTrue);
    expect(webStreamMatchesAudioFilter(dub, 'sub'), isFalse);
  });

  test(
    'Web audio capability union preserves duplicate Sub and Dub evidence',
    () {
      expect(
        mergeWebStreamAudioCapabilities(
          WebStreamAudioCapability.sub,
          WebStreamAudioCapability.dub,
        ),
        WebStreamAudioCapability.subAndDub,
      );
      expect(
        mergeWebStreamAudioCapabilities(
          WebStreamAudioCapability.unknown,
          WebStreamAudioCapability.dub,
        ),
        WebStreamAudioCapability.dub,
      );
    },
  );

  test(
    'known preferred Web audio ranks ahead of unknown and opposite audio',
    () {
      final dub = web(id: 'dub', quality: '720p');
      final unknown = web(
        id: 'unknown',
        quality: '1080p',
        audioCapability: WebStreamAudioCapability.unknown,
      );
      final sub = web(
        id: 'sub',
        quality: '2160p',
        dubbed: false,
        audioCapability: WebStreamAudioCapability.sub,
      );

      expect(webStreamAudioPreferenceRank(dub, PlaybackAudioPreference.dub), 0);
      expect(
        webStreamAudioPreferenceRank(unknown, PlaybackAudioPreference.dub),
        1,
      );
      expect(webStreamAudioPreferenceRank(sub, PlaybackAudioPreference.dub), 2);
    },
  );

  test(
    'automatic fallback keeps the current normalized quality without filtering',
    () {
      final p4k = release(
        id: 'f',
        quality: '2160p',
        seeders: 1000,
        size: '8 GB',
      );
      final p1080 = release(
        id: 'e',
        quality: 'Full HD',
        seeders: 1,
        size: '1 GB',
      );
      final p720 = release(
        id: 's',
        quality: '720p',
        seeders: 2000,
        size: '800 MB',
      );
      final ranked = rankAutomaticAutoplayReleases(
        [p4k, p720, p1080],
        language: 'dub',
        quality: 'any',
        codec: 'any',
        hdr: 'any',
        allowBatch: true,
        preferredAudio: PlaybackAudioPreference.dub,
        rankingPreference: DebridStreamSort.bestQuality,
        preferredQualityHeight: 1080,
      );

      expect(ranked.first, same(p1080));
      expect(ranked, containsAll([p4k, p1080, p720]));
    },
  );

  test('Web fallback shares exact-quality-first and fail-open behavior', () {
    final p4k = web(id: '4k', quality: '2160p');
    final p1080 = web(id: '1080', quality: 'Full HD');
    final p720 = web(id: '720', quality: '720p');
    final ranked = rankAutomaticAutoplayWebStreams(
      [p4k, p720, p1080],
      language: 'dub',
      quality: 'any',
      preferredAudio: PlaybackAudioPreference.dub,
      qualityPreference: WebStreamQualityPreference.bestAvailable,
      preferredWebProviderId: p4k.providerId,
      preferredQualityHeight: 1080,
    );

    expect(ranked.first, same(p1080));
    expect(ranked, containsAll([p4k, p1080, p720]));
  });

  test('device safety stays ahead of current-quality affinity', () {
    final unsafe1080 = ReleaseCandidate(
      infoHash: 'unsafe'.padRight(40, '0'),
      magnetUri: 'magnet:?xt=urn:btih:${'unsafe'.padRight(40, '0')}',
      releaseName: 'Unsafe 1080p AV1',
      seeders: 1000,
      sourceId: 'unsafe',
      quality: '1080p',
      codec: 'AV1',
      isDubbed: true,
    );
    final safe720 = ReleaseCandidate(
      infoHash: 'safe'.padRight(40, '0'),
      magnetUri: 'magnet:?xt=urn:btih:${'safe'.padRight(40, '0')}',
      releaseName: 'Safe 720p H.264',
      seeders: 1,
      sourceId: 'safe',
      quality: '720p',
      codec: 'H.264',
      isDubbed: true,
    );
    final ranked = rankAutomaticAutoplayReleases(
      [unsafe1080, safe720],
      language: 'dub',
      quality: 'any',
      codec: 'any',
      hdr: 'any',
      allowBatch: true,
      preferredAudio: PlaybackAudioPreference.dub,
      rankingPreference: DebridStreamSort.bestQuality,
      preferredQualityHeight: 1080,
      device: const TvDeviceProfile(
        manufacturer: 'Test',
        model: 'AVC only',
        sdk: 36,
        abis: ['arm64-v8a'],
        displayModes: [],
        hdrTypes: [],
        codecs: [
          TvCodecCapability(
            name: 'AVC decoder',
            mime: 'video/avc',
            hardware: true,
          ),
        ],
        audioOutputs: [],
      ),
    );

    expect(ranked.first, same(safe720));
  });

  test('source class preference is explicit and reversible', () {
    expect(
      compareStreamSourceClasses(
        StreamSourceClass.web,
        StreamSourceClass.debrid,
        StreamSourcePriority.webFirst,
      ),
      lessThan(0),
    );
    expect(
      compareStreamSourceClasses(
        StreamSourceClass.web,
        StreamSourceClass.debrid,
        StreamSourcePriority.debridFirst,
      ),
      greaterThan(0),
    );
    expect(
      compareStreamSourceClasses(
        StreamSourceClass.web,
        StreamSourceClass.debrid,
        StreamSourcePriority.webFirst,
        leftAudioRank: 2,
        rightAudioRank: 0,
      ),
      greaterThan(0),
      reason: 'source priority cannot override the preferred audio class',
    );
  });
}
