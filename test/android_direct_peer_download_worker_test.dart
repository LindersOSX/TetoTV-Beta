import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/downloads/data/android_direct_peer_download_worker.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _magnet =
    'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=episode';
const _token =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('DirectPeerDownloadCapability', () {
    test('validates its inputs and redacts the magnet', () {
      final capability = DirectPeerDownloadCapability(
        magnet: _magnet,
        episode: 3,
        preferredFileIndex: 8,
      );

      expect(capability.episode, 3);
      expect(capability.preferredFileIndex, 8);
      expect(capability.toString(), isNot(contains('magnet:')));
      expect(capability.toString(), isNot(contains('012345')));
    });

    test('rejects malformed magnets without echoing them', () {
      const secret = 'https://private.invalid/a-secret-value';

      Object? thrown;
      try {
        DirectPeerDownloadCapability(magnet: secret, episode: 1);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ArgumentError>());
      expect(thrown.toString(), isNot(contains('a-secret-value')));
    });
  });

  group('AndroidDirectPeerDownloadWorker', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'tetotv-direct-peer-test-',
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('downloads through the authenticated loopback session', () async {
      final body = List<int>.generate(16, (index) => index);
      final server = await _LoopbackFixture.start(
        body,
        chunkDelay: const Duration(milliseconds: 280),
      );
      addTearDown(server.close);
      final platform = _FakePlatform(session: server.session);
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);
      final partial = File('${temporaryDirectory.path}/episode.part');
      final progress = <DownloadTransferProgress>[];

      final result = await worker.download(
        job: _job(),
        capability: DirectPeerDownloadCapability(
          magnet: _magnet,
          episode: 4,
          preferredFileIndex: 2,
        ),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: progress.add,
      );

      expect(await partial.readAsBytes(), body);
      expect(result.receivedBytes, body.length);
      expect(result.totalBytes, body.length);
      expect(result.mimeType, 'video/x-matroska');
      expect(progress.last.receivedBytes, body.length);
      expect(progress.last.speedBytesPerSecond, 0);
      expect(progress.any((event) => event.speedBytesPerSecond > 0), isTrue);
      expect(platform.startedEpisode, 4);
      expect(platform.startedFileIndex, 2);
      expect(platform.startedMagnet, _magnet);
      expect(platform.stoppedSessionIds, [server.session.sessionId]);
      expect(server.ranges, [null]);
    });

    test('resumes an existing part file with an exact byte range', () async {
      final body = <int>[10, 11, 12, 13, 14, 15];
      final server = await _LoopbackFixture.start(body);
      addTearDown(server.close);
      final platform = _FakePlatform(session: server.session);
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);
      final partial = File('${temporaryDirectory.path}/episode.part');
      await partial.writeAsBytes(body.take(3).toList());

      final result = await worker.download(
        job: _job(),
        capability: DirectPeerDownloadCapability(magnet: _magnet, episode: 1),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );

      expect(await partial.readAsBytes(), body);
      expect(result.receivedBytes, body.length);
      expect(server.ranges, ['bytes=3-']);
      expect(platform.stoppedSessionIds, [server.session.sessionId]);
    });

    test('rejects non-loopback native state and still stops it', () async {
      final session = DirectTorrentNativeSession(
        sessionId: 'bad-session',
        uri: Uri(
          scheme: 'http',
          host: 'localhost',
          port: 1234,
          path: '/$_token',
        ),
        size: 4,
        mimeType: 'video/mp4',
        selectedBasename: 'Example - 01.mkv',
      );
      final platform = _FakePlatform(session: session);
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);

      await expectLater(
        worker.download(
          job: _job(),
          capability: DirectPeerDownloadCapability(magnet: _magnet, episode: 1),
          partialFile: File('${temporaryDirectory.path}/episode.part'),
          cancellation: DownloadCancellationToken(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadTransferException>().having(
            (error) => error.code,
            'code',
            'invalid_direct_peer_session',
          ),
        ),
      );

      expect(platform.stoppedSessionIds, ['bad-session']);
    });

    test('rejects an invalid resumed range and stops the session', () async {
      final body = <int>[1, 2, 3, 4, 5, 6];
      final server = await _LoopbackFixture.start(
        body,
        invalidRangeStart: true,
      );
      addTearDown(server.close);
      final platform = _FakePlatform(session: server.session);
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);
      final partial = File('${temporaryDirectory.path}/episode.part');
      await partial.writeAsBytes(body.take(2).toList());

      await expectLater(
        worker.download(
          job: _job(),
          capability: DirectPeerDownloadCapability(magnet: _magnet, episode: 1),
          partialFile: partial,
          cancellation: DownloadCancellationToken(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadTransferException>().having(
            (error) => error.code,
            'code',
            'invalid_direct_peer_range',
          ),
        ),
      );

      expect(await partial.readAsBytes(), body.take(2));
      expect(platform.stoppedSessionIds, [server.session.sessionId]);
    });

    test('cancels a pending native start distinctly', () async {
      final started = Completer<void>();
      final nativeStart = Completer<DirectTorrentNativeSession>();
      final platform = _FakePlatform(
        startOverride:
            ({
              required requestId,
              required magnet,
              required episode,
              preferredFileIndex,
            }) {
              started.complete();
              return nativeStart.future;
            },
        cancelStartOverride: (requestId) async {
          if (!nativeStart.isCompleted) {
            nativeStart.completeError(
              PlatformException(code: 'DIRECT_TORRENT_CANCELLED'),
            );
          }
          return true;
        },
      );
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);
      final cancellation = DownloadCancellationToken();
      final transfer = worker.download(
        job: _job(),
        capability: DirectPeerDownloadCapability(magnet: _magnet, episode: 1),
        partialFile: File('${temporaryDirectory.path}/episode.part'),
        cancellation: cancellation,
        onProgress: (_) {},
      );

      await started.future;
      cancellation.cancel();

      await expectLater(transfer, throwsA(isA<DownloadTransferCancelled>()));
      expect(platform.cancelledRequestIds, hasLength(1));
      expect(platform.stoppedSessionIds, isEmpty);
    });

    test('cancels an active loopback transfer and stops it once', () async {
      final body = List<int>.generate(32, (index) => index);
      final server = await _LoopbackFixture.start(
        body,
        chunkDelay: const Duration(milliseconds: 500),
      );
      addTearDown(server.close);
      final platform = _FakePlatform(session: server.session);
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);
      final cancellation = DownloadCancellationToken();
      final transfer = worker.download(
        job: _job(),
        capability: DirectPeerDownloadCapability(magnet: _magnet, episode: 1),
        partialFile: File('${temporaryDirectory.path}/episode.part'),
        cancellation: cancellation,
        onProgress: (_) {},
      );

      await server.firstRequest;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cancellation.cancel();

      await expectLater(transfer, throwsA(isA<DownloadTransferCancelled>()));
      expect(platform.stoppedSessionIds, [server.session.sessionId]);
    });

    test('rejects a foreign capability before touching native state', () async {
      final platform = _FakePlatform();
      final worker = AndroidDirectPeerDownloadWorker(platform: platform);

      await expectLater(
        worker.download(
          job: _job(),
          capability: Object(),
          partialFile: File('${temporaryDirectory.path}/episode.part'),
          cancellation: DownloadCancellationToken(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadTransferException>().having(
            (error) => error.code,
            'code',
            'invalid_direct_peer_capability',
          ),
        ),
      );

      expect(platform.capabilityCalls, 0);
      expect(platform.startCalls, 0);
    });
  });
}

DownloadJob _job() {
  final now = DateTime.utc(2026, 8, 24);
  return DownloadJob(
    id: 'direct-peer-test',
    anilistMediaId: 1,
    episode: 1,
    seriesTitle: 'Test series',
    sourceLabel: 'Test release',
    transport: DownloadTransport.directPeer,
    status: DownloadJobStatus.downloading,
    relativePath: 'test/episode.mkv',
    queuePosition: 0,
    createdAt: now,
    updatedAt: now,
  );
}

typedef _StartOverride =
    Future<DirectTorrentNativeSession> Function({
      required String requestId,
      required String magnet,
      required int episode,
      int? preferredFileIndex,
    });

class _FakePlatform implements DirectPeerNativePlatform {
  _FakePlatform({this.session, this.startOverride, this.cancelStartOverride});

  final DirectTorrentNativeSession? session;
  final _StartOverride? startOverride;
  final Future<bool> Function(String requestId)? cancelStartOverride;

  int capabilityCalls = 0;
  int startCalls = 0;
  String? startedMagnet;
  int? startedEpisode;
  int? startedFileIndex;
  final List<String> cancelledRequestIds = [];
  final List<String> stoppedSessionIds = [];

  @override
  bool get isAvailable => true;

  @override
  Future<DirectTorrentCapability> capability() async {
    capabilityCalls += 1;
    return const DirectTorrentCapability(
      supported: true,
      engine: 'test',
      maximumFileBytes: 1024 * 1024,
      supportsSeeking: true,
      temporaryStorage: true,
    );
  }

  @override
  Future<DirectTorrentNativeSession> start({
    required String requestId,
    required String magnet,
    required int episode,
    int? preferredFileIndex,
  }) {
    startCalls += 1;
    startedMagnet = magnet;
    startedEpisode = episode;
    startedFileIndex = preferredFileIndex;
    final override = startOverride;
    if (override != null) {
      return override(
        requestId: requestId,
        magnet: magnet,
        episode: episode,
        preferredFileIndex: preferredFileIndex,
      );
    }
    return Future.value(
      session ??
          DirectTorrentNativeSession(
            sessionId: 'default-session',
            uri: Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: 1,
              path: '/$_token',
            ),
            size: 1,
            mimeType: 'video/mp4',
            selectedBasename: 'Example - 01.mkv',
          ),
    );
  }

  @override
  Future<bool> cancelStart(String requestId) async {
    cancelledRequestIds.add(requestId);
    return await cancelStartOverride?.call(requestId) ?? true;
  }

  @override
  Future<bool> stop(String sessionId) async {
    stoppedSessionIds.add(sessionId);
    return true;
  }
}

class _LoopbackFixture {
  _LoopbackFixture._({
    required this.server,
    required this.session,
    required this.ranges,
    required this.firstRequest,
  });

  final HttpServer server;
  final DirectTorrentNativeSession session;
  final List<String?> ranges;
  final Future<void> firstRequest;

  static Future<_LoopbackFixture> start(
    List<int> body, {
    Duration chunkDelay = Duration.zero,
    bool invalidRangeStart = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ranges = <String?>[];
    final firstRequest = Completer<void>();
    server.listen((request) async {
      if (!firstRequest.isCompleted) firstRequest.complete();
      try {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final requestedOffset = range == null
            ? 0
            : int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!);
        final responseOffset = invalidRangeStart && requestedOffset > 0
            ? requestedOffset - 1
            : requestedOffset;
        if (range != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $responseOffset-${body.length - 1}/${body.length}',
          );
        }
        final responseBody = body.sublist(requestedOffset);
        request.response
          ..contentLength = responseBody.length
          ..headers.contentType = ContentType('video', 'x-matroska')
          ..bufferOutput = false;
        if (chunkDelay > Duration.zero && responseBody.length > 1) {
          final split = responseBody.length ~/ 2;
          request.response.add(responseBody.take(split).toList());
          await request.response.flush();
          await Future<void>.delayed(chunkDelay);
          request.response.add(responseBody.skip(split).toList());
        } else {
          request.response.add(responseBody);
        }
        await request.response.close();
      } catch (_) {
        // Expected when a cancellation force-closes the authenticated client.
      }
    });
    return _LoopbackFixture._(
      server: server,
      ranges: ranges,
      firstRequest: firstRequest.future,
      session: DirectTorrentNativeSession(
        sessionId: 'session-${server.port}',
        uri: Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
          path: '/$_token',
        ),
        size: body.length,
        mimeType: 'video/x-matroska',
        selectedBasename: 'Example - 01.mkv',
      ),
    );
  }

  Future<void> close() => server.close(force: true);
}
