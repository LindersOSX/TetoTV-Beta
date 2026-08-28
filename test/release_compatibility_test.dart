import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/streaming/presentation/resolve_episode_screen.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

ReleaseCandidate release({
  required String codec,
  String quality = '1080p',
  bool hdr = false,
  int seeders = 10,
}) => ReleaseCandidate(
  infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  magnetUri: 'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  releaseName: '$codec $quality',
  seeders: seeders,
  sourceId: 'test',
  codec: codec,
  quality: quality,
  isHdr: hdr,
);

void main() {
  test('ranks H.264 SDR streams ahead of demanding TV codecs', () {
    final h264 = release(codec: 'H.264');
    final hevc = release(codec: 'HEVC');
    final av1 = release(codec: 'AV1');

    expect(
      tvPlaybackCompatibilityRank(h264),
      lessThan(tvPlaybackCompatibilityRank(hevc)),
    );
    expect(
      tvPlaybackCompatibilityRank(hevc),
      lessThan(tvPlaybackCompatibilityRank(av1)),
    );
    expect(isTvSafeRelease(h264), isTrue);
  });

  test('penalizes H.264 Hi10P streams that require software decoding', () {
    final ordinary = release(codec: 'H.264');
    const hi10 = ReleaseCandidate(
      infoHash: '0000000000000000000000000000000000000001',
      magnetUri: 'magnet:?xt=urn:btih:0000000000000000000000000000000000000001',
      releaseName: 'Anime 01 1080p Hi10P x264',
      seeders: 10,
      sourceId: 'test',
      codec: 'H.264',
      quality: '1080p',
    );

    expect(releaseRequiresSoftwareDecoder(hi10), isTrue);
    expect(
      tvPlaybackCompatibilityRank(hi10),
      greaterThan(tvPlaybackCompatibilityRank(ordinary)),
    );
    expect(isTvSafeRelease(hi10), isFalse);
  });

  test('penalizes HDR and 4K for lower-power TV devices', () {
    final sdr1080 = release(codec: 'H.264');
    final hdr4k = release(codec: 'H.264', quality: '4K', hdr: true);

    expect(
      tvPlaybackCompatibilityRank(sdr1080),
      lessThan(tvPlaybackCompatibilityRank(hdr4k)),
    );
    expect(isTvSafeRelease(hdr4k), isFalse);
  });

  test('uses the physical TV codec profile and prior failures', () {
    const profile = TvDeviceProfile(
      manufacturer: 'Amazon',
      model: 'Fire TV',
      sdk: 30,
      abis: ['armeabi-v7a'],
      displayModes: [],
      hdrTypes: [],
      codecs: [
        TvCodecCapability(
          name: 'hardware-avc',
          mime: 'video/avc',
          hardware: true,
        ),
      ],
      audioOutputs: [],
    );
    final h264 = release(codec: 'H.264');
    final av1 = release(codec: 'AV1');

    expect(
      tvPlaybackCompatibilityRank(h264, device: profile),
      lessThan(tvPlaybackCompatibilityRank(av1, device: profile)),
    );
    expect(
      tvPlaybackCompatibilityRank(h264, device: profile, previousFailures: 3),
      greaterThan(tvPlaybackCompatibilityRank(h264, device: profile)),
    );
  });
}
