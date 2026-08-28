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
}
