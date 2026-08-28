import 'package:anime_tv/features/streaming/application/debrid_resolver_factory.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/premiumize_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/torbox_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates a concrete resolver for every supported debrid service', () {
    final release = ReleaseCandidate(
      infoHash: 'hash',
      magnetUri: 'magnet:?xt=urn:btih:hash',
      releaseName: 'Release',
      seeders: 1,
      sourceId: 'test',
    );
    final source = SingleReleaseSource(release);

    expect(
      createDebridStreamResolver(
        service: DebridService.realDebrid,
        token: 'token',
        source: source,
      ),
      isA<RealDebridStreamResolver>(),
    );
    expect(
      createDebridStreamResolver(
        service: DebridService.torBox,
        token: 'token',
        source: source,
      ),
      isA<TorBoxStreamResolver>(),
    );
    expect(
      createDebridStreamResolver(
        service: DebridService.allDebrid,
        token: 'token',
        source: source,
      ),
      isA<AllDebridStreamResolver>(),
    );
    expect(
      createDebridStreamResolver(
        service: DebridService.premiumize,
        token: 'token',
        source: source,
      ),
      isA<PremiumizeStreamResolver>(),
    );
  });
}
