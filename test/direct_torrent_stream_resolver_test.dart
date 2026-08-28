import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/streaming/data/direct_torrent_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const episode = EpisodeReference(
    anilistMediaId: 1,
    title: 'Example',
    episode: 7,
  );

  test('mocked HTTP range session stays owned until lease closes', () async {
    final server = await _RangeServer.start();
    final platform = _FakePlatform(
      startCallback: (_) async => server.session,
      stopCallback: (_) => server.close(),
    );
    final resolver = DirectTorrentStreamResolver(
      const _ReleaseSource(),
      platform: platform,
    );

    final ready = await resolver
        .resolve(episode)
        .where((resolution) => resolution is StreamReady)
        .cast<StreamReady>()
        .first;
    expect(ready.isDirectTorrent, isTrue);
    expect(ready.isWebStream, isFalse);
    expect(ready.displayName, '[Group] Selected Example S01E07.mkv');
    expect(DirectTorrentPlaybackRegistry.instance.ownsUri(ready.uri), isTrue);

    final client = HttpClient();
    final headRequest = await client.headUrl(ready.uri);
    final head = await headRequest.close();
    expect(head.statusCode, HttpStatus.ok);
    expect(head.contentLength, 10);

    final rangeRequest = await client.getUrl(ready.uri);
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
    final range = await rangeRequest.close();
    expect(range.statusCode, HttpStatus.partialContent);
    expect(range.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-5/10');
    expect(
      await range.fold<List<int>>(<int>[], (all, data) => all..addAll(data)),
      [2, 3, 4, 5],
    );
    client.close(force: true);

    await ready.playbackLease!.close();
    await ready.playbackLease!.close();
    expect(platform.stoppedSessionIds, ['session-1']);
    expect(DirectTorrentPlaybackRegistry.instance.ownsUri(ready.uri), isFalse);
    expect(server.closed, isTrue);
  });

  test('later-season identity is passed to the native selector', () async {
    const seasonEpisode = EpisodeReference(
      anilistMediaId: 4,
      title: 'Example Season 4',
      episode: 25,
    );
    const seasonRelease = ReleaseCandidate(
      infoHash: '1123456789abcdef0123456789abcdef01234567',
      magnetUri: 'magnet:?xt=urn:btih:1123456789abcdef0123456789abcdef01234567',
      releaseName: 'Example Season 4 - 25.mkv',
      seeders: 8,
      sourceId: 'test',
      preferredFileIndex: 88,
    );
    final platform = _FakePlatform(
      expectedEpisode: 25,
      expectedPreferredFileIndex: 88,
      expectedMagnet: seasonRelease.magnetUri,
      startCallback: (_) async => DirectTorrentNativeSession(
        sessionId: 'season-session',
        uri: Uri.parse('http://127.0.0.1:45321/${_repeat('e', 64)}'),
        size: 1,
        mimeType: 'video/mp4',
        selectedBasename: 'Example.S04E25.mkv',
      ),
    );

    final ready =
        await DirectTorrentStreamResolver(
              const _StaticReleaseSource(seasonRelease),
              platform: platform,
            )
            .resolve(seasonEpisode)
            .where((resolution) => resolution is StreamReady)
            .cast<StreamReady>()
            .first;

    expect(platform.lastRequestedSeason, 4);
    await ready.playbackLease!.close();
    expect(platform.stoppedSessionIds, ['season-session']);
  });

  test(
    'cancelling while release search is pending starts no native session',
    () async {
      final releases = Completer<List<ReleaseCandidate>>();
      final source = _PendingReleaseSource(releases.future);
      final platform = _FakePlatform();
      final subscription = DirectTorrentStreamResolver(
        source,
        platform: platform,
      ).resolve(episode).listen((_) {});

      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      releases.complete(const [_release]);
      await Future<void>.delayed(Duration.zero);

      expect(platform.startCount, 0);
      expect(platform.cancelledRequestIds, isEmpty);
      expect(platform.stoppedSessionIds, isEmpty);
    },
  );

  test(
    'pending native start is cancelled and a late lease is stopped',
    () async {
      final started = Completer<void>();
      final native = Completer<DirectTorrentNativeSession>();
      final platform = _FakePlatform(
        startCallback: (_) {
          started.complete();
          return native.future;
        },
      );
      final subscription = DirectTorrentStreamResolver(
        const _ReleaseSource(),
        platform: platform,
      ).resolve(episode).listen((_) {});

      await started.future;
      await subscription.cancel();
      expect(platform.cancelledRequestIds, hasLength(1));

      native.complete(
        DirectTorrentNativeSession(
          sessionId: 'late-session',
          uri: Uri.parse('http://127.0.0.1:45321/${_repeat('b', 64)}'),
          size: 1,
          mimeType: 'video/mp4',
          selectedBasename: 'Example - 07.mkv',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(platform.stoppedSessionIds, ['late-session']);
    },
  );

  test('unsupported capability fails before release or native start', () async {
    final source = _CountingReleaseSource();
    final platform = _FakePlatform(supported: false);

    await expectLater(
      DirectTorrentStreamResolver(source, platform: platform).resolve(episode),
      emitsError(isA<StateError>()),
    );

    expect(source.searchCount, 0);
    expect(platform.startCount, 0);
  });

  test(
    'confirmed selected-file mismatch is blocked and lease closes',
    () async {
      final platform = _FakePlatform(
        startCallback: (_) async => DirectTorrentNativeSession(
          sessionId: 'wrong-episode',
          uri: Uri.parse('http://127.0.0.1:45321/${_repeat('c', 64)}'),
          size: 1,
          mimeType: 'video/mp4',
          selectedBasename: 'Example - 08.mkv',
        ),
      );

      await expectLater(
        DirectTorrentStreamResolver(
          const _ReleaseSource(),
          platform: platform,
        ).resolve(episode),
        emitsError(isA<EpisodeIdentityMismatchException>()),
      );

      expect(platform.stoppedSessionIds, ['wrong-episode']);
    },
  );

  test('native session map requires a bounded basename without paths', () {
    final valid = DirectTorrentNativeSession.fromMap(<Object?, Object?>{
      'sessionId': 'session',
      'url': 'http://127.0.0.1:45321/${_repeat('d', 64)}',
      'size': 1,
      'mimeType': 'video/mp4',
      'selectedBasename': 'Example - 07.mkv',
    });
    expect(valid.selectedBasename, 'Example - 07.mkv');

    for (final basename in <String>[
      '',
      '../Example - 07.mkv',
      'folder\\Example - 07.mkv',
      '${_repeat('a', 513)}.mkv',
    ]) {
      expect(
        () => DirectTorrentNativeSession.fromMap(<Object?, Object?>{
          'sessionId': 'session',
          'url': 'http://127.0.0.1:45321/${_repeat('d', 64)}',
          'size': 1,
          'mimeType': 'video/mp4',
          'selectedBasename': basename,
        }),
        throwsFormatException,
        reason: basename.length < 100 ? basename : 'overlong basename',
      );
    }
  });
}

const _release = ReleaseCandidate(
  infoHash: '0123456789abcdef0123456789abcdef01234567',
  magnetUri: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
  releaseName: 'Example - 07.mkv',
  seeders: 12,
  sourceId: 'test',
  preferredFileIndex: 2,
);

class _ReleaseSource implements ReleaseSource {
  const _ReleaseSource();

  @override
  String get id => 'test';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async =>
      const [_release];
}

class _StaticReleaseSource implements ReleaseSource {
  const _StaticReleaseSource(this.release);

  final ReleaseCandidate release;

  @override
  String get id => 'static';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async => [
    release,
  ];
}

class _PendingReleaseSource implements ReleaseSource {
  const _PendingReleaseSource(this.future);

  final Future<List<ReleaseCandidate>> future;

  @override
  String get id => 'pending';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) => future;
}

class _CountingReleaseSource implements ReleaseSource {
  int searchCount = 0;

  @override
  String get id => 'counting';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async {
    searchCount++;
    return const [_release];
  }
}

class _FakePlatform implements DirectTorrentPlatformClient {
  _FakePlatform({
    this.supported = true,
    this.startCallback,
    this.stopCallback,
    this.expectedEpisode = 7,
    this.expectedPreferredFileIndex = 2,
    String? expectedMagnet,
  }) : expectedMagnet = expectedMagnet ?? _release.magnetUri;

  final bool supported;
  final Future<DirectTorrentNativeSession> Function(String requestId)?
  startCallback;
  final Future<void> Function(String sessionId)? stopCallback;
  final int expectedEpisode;
  final int? expectedPreferredFileIndex;
  final String expectedMagnet;
  final List<String> cancelledRequestIds = [];
  final List<String> stoppedSessionIds = [];
  int startCount = 0;
  int? lastRequestedSeason;

  @override
  Future<DirectTorrentCapability> capability() async => DirectTorrentCapability(
    supported: supported,
    engine: supported ? 'test' : 'unavailable',
    maximumFileBytes: supported ? 1024 : 0,
    supportsSeeking: supported,
    temporaryStorage: supported,
  );

  @override
  Future<DirectTorrentNativeSession> start({
    required String requestId,
    required String magnet,
    required int episode,
    int? season,
    int? preferredFileIndex,
  }) {
    startCount++;
    lastRequestedSeason = season;
    expect(magnet, expectedMagnet);
    expect(episode, expectedEpisode);
    expect(preferredFileIndex, expectedPreferredFileIndex);
    final callback = startCallback;
    if (callback == null) {
      return Future.error(StateError('No fake native session configured.'));
    }
    return callback(requestId);
  }

  @override
  Future<bool> cancelStart(String requestId) async {
    cancelledRequestIds.add(requestId);
    return true;
  }

  @override
  Future<bool> stop(String sessionId) async {
    stoppedSessionIds.add(sessionId);
    await stopCallback?.call(sessionId);
    return true;
  }
}

class _RangeServer {
  _RangeServer._(this._server, this._subscription, this.session);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;
  final DirectTorrentNativeSession session;
  bool closed = false;

  static Future<_RangeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final path = '/${_repeat('a', 64)}';
    late final StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((request) async {
      if (request.uri.path != path) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      const bytes = <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
      final rawRange = request.headers.value(HttpHeaders.rangeHeader);
      if (rawRange == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rawRange)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
      }
      await request.response.close();
    });
    return _RangeServer._(
      server,
      subscription,
      DirectTorrentNativeSession(
        sessionId: 'session-1',
        uri: Uri.parse('http://127.0.0.1:${server.port}$path'),
        size: 10,
        mimeType: 'video/mp4',
        selectedBasename: '[Group] Selected Example S01E07.mkv',
      ),
    );
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

String _repeat(String value, int count) => List.filled(count, value).join();
