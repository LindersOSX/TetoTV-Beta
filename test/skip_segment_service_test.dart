import 'dart:async';

import 'package:anime_tv/features/player/application/skip_segment_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Web/HLS duration settling keeps valid skip markers', () {
    expect(
      skipSegmentDurationsCompatible(
        const Duration(minutes: 24),
        const Duration(minutes: 24, seconds: 12),
      ),
      isTrue,
    );
    expect(
      skipSegmentDurationsCompatible(
        const Duration(minutes: 24),
        const Duration(minutes: 27),
      ),
      isFalse,
    );
  });

  test('empty Web/HLS lookup notices smaller manifest corrections', () {
    expect(
      skipSegmentLookupDurationsEquivalent(
        const Duration(minutes: 24),
        const Duration(minutes: 24, seconds: 2),
      ),
      isTrue,
    );
    expect(
      skipSegmentLookupDurationsEquivalent(
        const Duration(minutes: 24),
        const Duration(minutes: 24, seconds: 10),
      ),
      isFalse,
    );
    expect(
      skipSegmentDurationsCompatible(
        const Duration(minutes: 24),
        const Duration(minutes: 24, seconds: 10),
      ),
      isTrue,
    );
  });

  test('empty Web/HLS lookups remain retryable while duration settles', () {
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: false,
        hasMarkers: false,
        attempts: 1,
      ),
      isFalse,
    );
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: false,
        hasMarkers: false,
        attempts: 4,
      ),
      isTrue,
    );
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: false,
        externalFailed: false,
        hasMarkers: false,
        attempts: 1,
      ),
      isTrue,
    );
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: false,
        hasMarkers: false,
        attempts: 1,
        runtimeProbesExhausted: true,
      ),
      isTrue,
    );
  });

  test('transient lookup failures receive only two deferred retries', () {
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: true,
        transientExternalFailure: true,
        hasMarkers: false,
        attempts: 1,
      ),
      isFalse,
    );
    expect(
      skipSegmentLookupRetryDelay(
        lookupComplete: false,
        transientExternalFailure: true,
        attempts: 1,
      ),
      const Duration(seconds: 15),
    );
    expect(
      skipSegmentLookupRetryDelay(
        lookupComplete: false,
        transientExternalFailure: true,
        attempts: 2,
      ),
      const Duration(seconds: 45),
    );
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: true,
        transientExternalFailure: true,
        hasMarkers: false,
        attempts: 3,
      ),
      isTrue,
    );
    expect(
      skipSegmentLookupRetryDelay(
        lookupComplete: true,
        transientExternalFailure: true,
        attempts: 3,
      ),
      isNull,
    );
  });

  test('duration updates cannot shorten a transient-failure backoff', () {
    var now = DateTime.utc(2026, 8, 29, 12);
    final gate = SkipSegmentRetryGate(clock: () => now);

    gate.defer(const Duration(seconds: 15));
    now = now.add(const Duration(seconds: 3));

    expect(
      gate.guard(const Duration(milliseconds: 1200)),
      const Duration(seconds: 12),
    );
    expect(
      gate.guard(const Duration(seconds: 20)),
      const Duration(seconds: 20),
    );

    gate.reset();
    expect(
      gate.guard(const Duration(milliseconds: 1200)),
      const Duration(milliseconds: 1200),
    );
  });

  test('embedded markers do not hide a transient community failure', () {
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: true,
        transientExternalFailure: true,
        hasMarkers: true,
        attempts: 2,
      ),
      isFalse,
    );
  });

  test('clean exhausted no-match never enters deferred retry', () {
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: false,
        hasMarkers: false,
        attempts: 1,
        runtimeProbesExhausted: true,
      ),
      isTrue,
    );
    expect(
      skipSegmentLookupRetryDelay(
        lookupComplete: true,
        transientExternalFailure: false,
        attempts: 1,
      ),
      isNull,
    );
  });

  test('recognizes safe embedded intro, recap, and outro chapters', () {
    final segments = skipSegmentsFromChapters(const [
      MediaChapter(title: 'Recap', start: Duration.zero),
      MediaChapter(title: 'Opening', start: Duration(seconds: 40)),
      MediaChapter(title: 'Episode', start: Duration(seconds: 130)),
      MediaChapter(title: 'Ending Credits', start: Duration(minutes: 21)),
    ], const Duration(minutes: 23));

    expect(segments, hasLength(3));
    expect(segments.map((segment) => segment.kind), [
      SkipSegmentKind.recap,
      SkipSegmentKind.opening,
      SkipSegmentKind.ending,
    ]);
    expect(segments[1].actionLabel, 'Skip intro');
    expect(segments[2].end, const Duration(minutes: 23));
  });

  test('embedded chapters win when AniSkip substantially overlaps', () {
    const embedded = SkipSegment(
      start: Duration(seconds: 30),
      end: Duration(seconds: 120),
      kind: SkipSegmentKind.opening,
      source: SkipSegmentSource.embeddedChapter,
    );
    const external = SkipSegment(
      start: Duration(seconds: 32),
      end: Duration(seconds: 118),
      kind: SkipSegmentKind.opening,
      source: SkipSegmentSource.aniSkip,
    );

    expect(mergeSkipSegments([embedded], [external]), [embedded]);
  });

  test('an overlapping intro never suppresses an outro marker', () {
    const embeddedIntro = SkipSegment(
      start: Duration(minutes: 20),
      end: Duration(minutes: 22),
      kind: SkipSegmentKind.opening,
      source: SkipSegmentSource.embeddedChapter,
    );
    const externalOutro = SkipSegment(
      start: Duration(minutes: 21),
      end: Duration(minutes: 22, seconds: 30),
      kind: SkipSegmentKind.ending,
      source: SkipSegmentSource.aniSkip,
    );

    final merged = mergeSkipSegments([embeddedIntro], [externalOutro]);

    expect(merged, hasLength(2));
    expect(merged.map((segment) => segment.kind), [
      SkipSegmentKind.opening,
      SkipSegmentKind.ending,
    ]);
  });

  test('recognizes numbered OP and ED chapter labels', () {
    final segments = skipSegmentsFromChapters(const [
      MediaChapter(title: 'OP1', start: Duration(seconds: 30)),
      MediaChapter(title: 'Episode', start: Duration(minutes: 2)),
      MediaChapter(title: 'ED2', start: Duration(minutes: 21)),
    ], const Duration(minutes: 23));

    expect(segments.map((segment) => segment.kind), [
      SkipSegmentKind.opening,
      SkipSegmentKind.ending,
    ]);
  });

  test(
    'AniSkip uses the current v2 query and rejects wrong runtimes',
    () async {
      final dio = Dio();
      Uri? requestedUri;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedUri = options.uri;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'found': true,
                  'results': [
                    {
                      'interval': {'startTime': 20, 'endTime': 110},
                      'skipType': 'op',
                      'episodeLength': 1440,
                    },
                    {
                      'interval': {'startTime': 1200, 'endTime': 1290},
                      'skipType': 'ed',
                      'episodeLength': 1200,
                    },
                  ],
                },
              ),
            );
          },
        ),
      );

      final segments = await AniSkipClient(dio: dio).segments(
        malMediaId: 21,
        episode: 1,
        episodeDuration: const Duration(minutes: 24),
      );

      expect(requestedUri?.path, '/v2/skip-times/21/1');
      expect(
        requestedUri?.queryParametersAll['types[]'],
        containsAll(['op', 'ed']),
      );
      expect(requestedUri?.queryParameters['episodeLength'], '1440.0');
      expect(segments, hasLength(1));
      expect(segments.single.kind, SkipSegmentKind.opening);
    },
  );

  test(
    'AniSkip accepts valid markers when reference runtime is omitted',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'found': true,
                'results': [
                  {
                    'interval': {'startTime': 18, 'endTime': 108},
                    'skipType': 'op',
                  },
                ],
              },
            ),
          ),
        ),
      );

      final segments = await AniSkipClient(dio: dio).segments(
        malMediaId: 21,
        episode: 2,
        episodeDuration: const Duration(minutes: 24),
      );

      expect(segments.single.kind, SkipSegmentKind.opening);
    },
  );

  test(
    'AniSkip keeps Web openings anchored to the start of the encode',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'found': true,
                'results': [
                  {
                    'interval': {'startTime': 60, 'endTime': 150},
                    'skipType': 'op',
                    'episodeLength': 1440,
                  },
                ],
              },
            ),
          ),
        ),
      );

      final segments = await AniSkipClient(dio: dio).segments(
        malMediaId: 21,
        episode: 2,
        episodeDuration: const Duration(minutes: 24, seconds: 24),
      );

      expect(segments, hasLength(1));
      expect(segments.single.start, const Duration(seconds: 60));
      expect(segments.single.end, const Duration(seconds: 150));
    },
  );

  test('AniSkip keeps Web endings anchored to the end of the encode', () async {
    final aligned = alignAniSkipInterval(
      startSeconds: 1320,
      endSeconds: 1422,
      referenceSeconds: 1422,
      actualSeconds: 1464,
      kind: SkipSegmentKind.ending,
    );

    expect(aligned.start, 1362);
    expect(aligned.end, 1464);
  });

  test('AniSkip probes a nearby Web runtime after an exact no-match', () async {
    final dio = Dio();
    final requestedLengths = <double>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final length = double.parse(
            options.uri.queryParameters['episodeLength']!,
          );
          requestedLengths.add(length);
          if (length == 1419) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'found': true,
                  'results': [
                    {
                      'interval': {'startTime': 90, 'endTime': 181.013},
                      'skipType': 'op',
                      'episodeLength': 1422,
                    },
                  ],
                },
              ),
            );
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 404,
              data: const <String, dynamic>{'found': false, 'results': []},
            ),
          );
        },
      ),
    );

    final result = await AniSkipClient(dio: dio).lookup(
      malMediaId: 1887,
      episode: 1,
      episodeDuration: const Duration(minutes: 24, seconds: 24),
      allowRuntimeFallback: true,
    );

    expect(requestedLengths, [1464, 1434, 1494, 1419]);
    expect(result.probeCount, 4);
    expect(result.usedDurationFallback, isTrue);
    expect(result.runtimeFallbackSearchComplete, isFalse);
    expect(result.segments.single.start, const Duration(seconds: 90));
    expect(
      activeSkipSegmentAt(
        segments: result.segments,
        position: const Duration(seconds: 100),
      ),
      same(result.segments.single),
    );
    expect(
      shouldAutomaticallySkipSegment(
        result.segments.single,
        autoSkipIntros: true,
        autoSkipOutros: false,
      ),
      isTrue,
    );
  });

  test('consumed Web markers cannot reactivate manual or automatic skip', () {
    const opening = SkipSegment(
      start: Duration(seconds: 20),
      end: Duration(seconds: 110),
      kind: SkipSegmentKind.opening,
      source: SkipSegmentSource.aniSkip,
    );

    expect(
      activeSkipSegmentAt(
        segments: const [opening],
        position: const Duration(seconds: 40),
        consumed: {skipSegmentKey(opening)},
      ),
      isNull,
    );
  });

  test('clean Web no-match completes after bounded runtime probes', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 404,
              data: const <String, dynamic>{'found': false, 'results': []},
            ),
          );
        },
      ),
    );

    final result = await AniSkipClient(dio: dio).lookup(
      malMediaId: 1887,
      episode: 18,
      episodeDuration: const Duration(minutes: 24),
      allowRuntimeFallback: true,
    );

    expect(result.segments, isEmpty);
    expect(requests, 5);
    expect(result.probeCount, 5);
    expect(result.runtimeFallbackSearchComplete, isTrue);
    expect(
      skipSegmentLookupIsComplete(
        isWebStream: true,
        externalFailed: false,
        hasMarkers: false,
        attempts: 1,
        runtimeProbesExhausted: result.runtimeFallbackSearchComplete,
      ),
      isTrue,
    );
  });

  test('AniSkip retries one transient transport failure', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          if (requests == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'temporary offline fixture',
              ),
            );
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'found': true,
                'results': [
                  {
                    'interval': {'startTime': 20, 'endTime': 110},
                    'skipType': 'op',
                  },
                ],
              },
            ),
          );
        },
      ),
    );

    final segments = await AniSkipClient(dio: dio, retryDelay: Duration.zero)
        .segments(
          malMediaId: 21,
          episode: 3,
          episodeDuration: const Duration(minutes: 24),
        );

    expect(requests, 2);
    expect(segments.single.kind, SkipSegmentKind.opening);
  });

  test('AniSkip treats a recovered retry as a clean no-match', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          if (requests == 1) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'temporary offline fixture',
              ),
            );
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 404,
              data: const <String, dynamic>{'found': false, 'results': []},
            ),
          );
        },
      ),
    );

    final result = await AniSkipClient(dio: dio, retryDelay: Duration.zero)
        .lookup(
          malMediaId: 1887,
          episode: 18,
          episodeDuration: const Duration(minutes: 24),
          allowRuntimeFallback: true,
        );

    expect(result.segments, isEmpty);
    expect(result.status, AniSkipLookupStatus.noMatch);
    expect(result.transientFailureCount, 1);
    expect(result.failureReason, AniSkipFailureReason.connectionError);
    expect(result.runtimeFallbackSearchComplete, isTrue);
    expect(result.hasTransientFailure, isFalse);
    expect(result.status.diagnosticCode, 'no_match');
    expect(result.failureReason?.diagnosticCode, 'connection_error');
  });

  test(
    'AniSkip stops nearby-runtime probes after an exhausted transport retry',
    () async {
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            if (requests <= 2) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'temporary offline fixture',
                ),
              );
              return;
            }
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 404,
                data: const <String, dynamic>{'found': false, 'results': []},
              ),
            );
          },
        ),
      );

      final result = await AniSkipClient(dio: dio, retryDelay: Duration.zero)
          .lookup(
            malMediaId: 1887,
            episode: 18,
            episodeDuration: const Duration(minutes: 24),
            allowRuntimeFallback: true,
          );

      expect(result.segments, isEmpty);
      expect(requests, 2);
      expect(result.status, AniSkipLookupStatus.transientFailure);
      expect(result.transientFailureCount, 2);
      expect(result.runtimeFallbackSearchComplete, isFalse);
      expect(result.hasTransientFailure, isTrue);
    },
  );

  test(
    'AniSkip defers accepted server errors without probing runtimes',
    () async {
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 503,
                data: const <String, dynamic>{'found': false, 'results': []},
              ),
            );
          },
        ),
      );

      final result = await AniSkipClient(dio: dio, retryDelay: Duration.zero)
          .lookup(
            malMediaId: 1887,
            episode: 18,
            episodeDuration: const Duration(minutes: 24),
            allowRuntimeFallback: true,
          );

      expect(requests, 1);
      expect(result.segments, isEmpty);
      expect(result.status, AniSkipLookupStatus.transientFailure);
      expect(result.runtimeFallbackSearchComplete, isFalse);
      expect(result.hasTransientFailure, isTrue);
      expect(result.failureReason, AniSkipFailureReason.serverError);
    },
  );

  test(
    'AniSkip serves validated fresh markers without a network request',
    () async {
      final store = _MemoryAniSkipCacheStore(fresh: _cachedMarkerPayload());
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            );
          },
        ),
      );

      final result = await AniSkipClient(dio: dio, cacheStore: store).lookup(
        malMediaId: 1887,
        episode: 18,
        episodeDuration: const Duration(minutes: 24),
        allowRuntimeFallback: true,
      );

      expect(requests, 0);
      expect(result.source, AniSkipLookupSource.freshCache);
      expect(result.usedCachedMarkers, isTrue);
      expect(result.segments.single.kind, SkipSegmentKind.opening);
    },
  );

  test('AniSkip coalesces concurrent lookups for the same episode', () async {
    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'found': true,
                'results': _cachedMarkerPayload()['results'],
              },
            ),
          );
        },
      ),
    );
    final client = AniSkipClient(dio: dio);

    final first = client.lookup(
      malMediaId: 1887,
      episode: 18,
      episodeDuration: const Duration(minutes: 24),
    );
    final second = client.lookup(
      malMediaId: 1887,
      episode: 18,
      episodeDuration: const Duration(minutes: 24),
    );
    final results = await Future.wait(<Future<AniSkipLookupResult>>[
      first,
      second,
    ]);

    expect(identical(first, second), isTrue);
    expect(requests, 1);
    expect(results.every((result) => result.segments.length == 1), isTrue);
  });

  test(
    'AniSkip falls back to safe stale markers during a server outage',
    () async {
      final store = _MemoryAniSkipCacheStore(stale: _cachedMarkerPayload());
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 503,
                data: const <String, dynamic>{'found': false, 'results': []},
              ),
            );
          },
        ),
      );

      final result = await AniSkipClient(dio: dio, cacheStore: store).lookup(
        malMediaId: 1887,
        episode: 18,
        episodeDuration: const Duration(minutes: 24),
        allowRuntimeFallback: true,
      );

      expect(requests, 1);
      expect(result.status, AniSkipLookupStatus.found);
      expect(result.source, AniSkipLookupSource.staleCache);
      expect(result.failureReason, AniSkipFailureReason.serverError);
      expect(result.transientFailureCount, 1);
      expect(result.segments.single.end, const Duration(seconds: 110));
    },
  );

  test('AniSkip rejects stale markers from an incompatible runtime', () async {
    final store = _MemoryAniSkipCacheStore(stale: _cachedMarkerPayload());
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 503,
            data: const <String, dynamic>{'found': false, 'results': []},
          ),
        ),
      ),
    );

    final result = await AniSkipClient(dio: dio, cacheStore: store).lookup(
      malMediaId: 1887,
      episode: 18,
      episodeDuration: const Duration(minutes: 48),
      allowRuntimeFallback: true,
    );

    expect(result.segments, isEmpty);
    expect(result.source, AniSkipLookupSource.network);
    expect(result.status, AniSkipLookupStatus.transientFailure);
  });

  test('AniSkip cache persistence never delays ready markers', () async {
    final writeBlocker = Completer<void>();
    final store = _MemoryAniSkipCacheStore(writeBlocker: writeBlocker);
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'found': true,
              'results': _cachedMarkerPayload()['results'],
            },
          ),
        ),
      ),
    );

    final result = await AniSkipClient(dio: dio, cacheStore: store)
        .lookup(
          malMediaId: 1887,
          episode: 18,
          episodeDuration: const Duration(minutes: 24),
        )
        .timeout(const Duration(seconds: 1));

    expect(result.segments, hasLength(1));
    expect(store.writeCount, 1);
    expect(writeBlocker.isCompleted, isFalse);
    writeBlocker.complete();
  });

  test(
    'AniSkip bounds a stalled cache read before using the network',
    () async {
      final readBlocker = Completer<Map<String, dynamic>?>();
      final store = _MemoryAniSkipCacheStore(readBlocker: readBlocker);
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'found': true,
                  'results': _cachedMarkerPayload()['results'],
                },
              ),
            );
          },
        ),
      );

      final result =
          await AniSkipClient(
                dio: dio,
                cacheStore: store,
                cacheReadTimeout: const Duration(milliseconds: 1),
              )
              .lookup(
                malMediaId: 1887,
                episode: 18,
                episodeDuration: const Duration(minutes: 24),
              )
              .timeout(const Duration(seconds: 1));

      expect(requests, 1);
      expect(result.segments, hasLength(1));
      expect(readBlocker.isCompleted, isFalse);
      readBlocker.complete();
    },
  );

  test('verified skip seek retries a command the player ignored', () async {
    var position = const Duration(seconds: 10);
    var seekCalls = 0;

    final result = await performVerifiedSkipSeek(
      target: const Duration(seconds: 100),
      seek: (target) async {
        seekCalls++;
        if (seekCalls == 2) position = target;
      },
      currentPosition: () => position,
      wait: (_) async {},
    );

    expect(result.verified, isTrue);
    expect(result.position, const Duration(seconds: 100));
    expect(result.attempts, 2);
    expect(seekCalls, 2);
  });

  test('verified skip seek stays failed after its bounded attempts', () async {
    var seekCalls = 0;

    final result = await performVerifiedSkipSeek(
      target: const Duration(seconds: 100),
      seek: (_) async => seekCalls++,
      currentPosition: () => const Duration(seconds: 10),
      wait: (_) async {},
    );

    expect(result.verified, isFalse);
    expect(result.position, const Duration(seconds: 10));
    expect(result.attempts, 3);
    expect(seekCalls, 3);
  });

  test('verified skip seek stops retrying after its source changes', () async {
    var sourceChanged = false;
    var seekCalls = 0;
    var position = const Duration(seconds: 10);

    final result = await performVerifiedSkipSeek(
      target: const Duration(seconds: 100),
      seek: (_) async => seekCalls++,
      currentPosition: () => position,
      wait: (_) async {
        sourceChanged = true;
        position = const Duration(seconds: 100);
      },
      isCanceled: () => sourceChanged,
    );

    expect(result.verified, isFalse);
    expect(result.attempts, 1);
    expect(seekCalls, 1);
  });

  test('verified skip seek times out instead of waiting forever', () async {
    final neverCompletes = Completer<void>();
    var seekCalls = 0;

    final result = await performVerifiedSkipSeek(
      target: const Duration(seconds: 100),
      seek: (_) {
        seekCalls++;
        return neverCompletes.future;
      },
      currentPosition: () => const Duration(seconds: 10),
      wait: (_) async {},
      operationTimeout: const Duration(milliseconds: 1),
    );

    expect(result.verified, isFalse);
    expect(result.position, const Duration(seconds: 10));
    expect(result.attempts, 1);
    expect(seekCalls, 1);
  });

  test('seek verification does not accept a nearby ignored position', () {
    expect(
      skipSeekTargetReached(
        target: const Duration(milliseconds: 191984),
        actual: const Duration(milliseconds: 190000),
      ),
      isFalse,
    );
    expect(
      skipSeekTargetReached(
        target: const Duration(milliseconds: 191984),
        actual: const Duration(milliseconds: 191800),
      ),
      isTrue,
    );
    expect(
      skipSeekTargetReached(
        target: const Duration(seconds: 100),
        actual: const Duration(minutes: 24),
      ),
      isFalse,
    );
  });
}

Map<String, dynamic> _cachedMarkerPayload() => <String, dynamic>{
  'schema': 1,
  'requested_duration_ms': const Duration(minutes: 24).inMilliseconds,
  'used_duration_fallback': false,
  'results': <Map<String, dynamic>>[
    <String, dynamic>{
      'interval': <String, dynamic>{'startTime': 20.0, 'endTime': 110.0},
      'skipType': 'op',
      'episodeLength': 1440.0,
    },
  ],
};

class _MemoryAniSkipCacheStore implements AniSkipCacheStore {
  _MemoryAniSkipCacheStore({
    this.fresh,
    this.stale,
    this.readBlocker,
    this.writeBlocker,
  });

  Map<String, dynamic>? fresh;
  final Map<String, dynamic>? stale;
  final Completer<Map<String, dynamic>?>? readBlocker;
  final Completer<void>? writeBlocker;
  int writeCount = 0;

  @override
  Future<Map<String, dynamic>?> read(
    String key, {
    bool allowExpired = false,
  }) async {
    final blocker = readBlocker;
    if (blocker != null) return blocker.future;
    return allowExpired ? stale ?? fresh : fresh;
  }

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> payload, {
    required Duration maxAge,
  }) async {
    writeCount++;
    fresh = payload;
    final blocker = writeBlocker;
    if (blocker != null) await blocker.future;
  }
}
