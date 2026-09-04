import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonicalizes safe manga Origin and Referer metadata', () {
    expect(
      canonicalMangaPageOriginHeader(' https://Reader.Example:443/ '),
      'https://reader.example',
    );
    expect(
      canonicalMangaPageOriginHeader('https://reader.example/path?secret=1'),
      'https://reader.example',
    );
    expect(
      canonicalMangaPageRefererHeader(
        'https://Reader.Example:443/chapter/1?capability=private',
      ),
      'https://reader.example/chapter/1?capability=private',
    );
    expect(
      canonicalMangaPageRefererHeader(
        'https://reader.example/chapter/1?capability=private',
        originOnly: true,
      ),
      'https://reader.example/',
    );
    expect(
      canonicalMangaPageRefererHeader('https://reader.example/#private'),
      isNull,
    );
  });

  test(
    'validates every redirect and strips credentials across origins',
    () async {
      final validated = <Uri>[];
      final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
        'https://pages.example/start': (_) => ResponseBody.fromBytes(
          const <int>[],
          HttpStatus.found,
          headers: <String, List<String>>{
            HttpHeaders.locationHeader: <String>[
              'https://cdn.example/page.png',
            ],
          },
        ),
        'https://cdn.example/page.png': (_) => ResponseBody.fromBytes(
          _pngBytes,
          HttpStatus.ok,
          headers: <String, List<String>>{
            HttpHeaders.contentTypeHeader: <String>['image/png'],
          },
        ),
      });
      final client = _client(
        adapter,
        validateTarget: (uri) async => validated.add(uri),
      );
      addTearDown(client.close);

      final bytes = await client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/start'),
          headers: const <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer protected',
            HttpHeaders.cookieHeader: 'session=private',
            'X-Api-Key': 'private-key',
            HttpHeaders.refererHeader:
                'https://reader.example/chapter/1?capability=private',
            'Origin': 'https://reader.example/private?capability=private',
            HttpHeaders.userAgentHeader: 'Manga extension agent',
          },
        ),
      );

      expect(bytes, _pngBytes);
      expect(validated, <Uri>[
        Uri.parse('https://pages.example/start'),
        Uri.parse('https://cdn.example/page.png'),
      ]);
      expect(
        adapter.requests.first.headers[HttpHeaders.authorizationHeader],
        'Bearer protected',
      );
      expect(
        adapter.requests.last.headers[HttpHeaders.authorizationHeader],
        isNull,
      );
      expect(adapter.requests.last.headers[HttpHeaders.cookieHeader], isNull);
      expect(adapter.requests.last.headers['X-Api-Key'], isNull);
      expect(
        adapter.requests.last.headers[HttpHeaders.refererHeader],
        'https://reader.example/',
      );
      expect(adapter.requests.last.headers['Origin'], 'https://reader.example');
      expect(
        adapter.requests.last.headers[HttpHeaders.userAgentHeader],
        'Manga extension agent',
      );
      expect(
        adapter.requests.last.headers[HttpHeaders.acceptHeader],
        isNotNull,
      );
      expect(
        adapter.requests.every((request) => !request.followRedirects),
        isTrue,
      );
    },
  );

  test(
    'adds bounded image request defaults without replacing provider values',
    () async {
      final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
        'https://pages.example/page.png': (_) =>
            ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
        'https://pages.example/custom.png': (_) =>
            ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
      });
      final client = _client(adapter);
      addTearDown(client.close);

      await client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/page.png'),
        ),
      );
      await client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/custom.png'),
          headers: const <String, String>{
            HttpHeaders.acceptHeader: 'image/png',
            HttpHeaders.userAgentHeader: 'Provider agent',
          },
        ),
      );

      expect(
        adapter.requests.first.headers[HttpHeaders.acceptHeader],
        contains('image/webp'),
      );
      expect(
        adapter.requests.first.headers[HttpHeaders.userAgentHeader],
        'TetoTV/2 Android manga',
      );
      expect(
        adapter.requests.last.headers[HttpHeaders.acceptHeader],
        'image/png',
      );
      expect(
        adapter.requests.last.headers[HttpHeaders.userAgentHeader],
        'Provider agent',
      );
    },
  );

  test('same-origin redirects retain provider credentials', () async {
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/start': (_) => ResponseBody.fromBytes(
        const <int>[],
        HttpStatus.found,
        headers: <String, List<String>>{
          HttpHeaders.locationHeader: <String>['/page.png'],
        },
      ),
      'https://pages.example/page.png': (_) =>
          ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
    });
    final client = _client(adapter);
    addTearDown(client.close);

    await client.fetch(
      MangaRemotePageResource(
        uri: Uri.parse('https://pages.example/start'),
        headers: const <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer same-origin',
          'X-Provider-Key': 'same-origin-key',
        },
      ),
    );

    expect(
      adapter.requests.last.headers[HttpHeaders.authorizationHeader],
      'Bearer same-origin',
    );
    expect(adapter.requests.last.headers['X-Provider-Key'], 'same-origin-key');
  });

  test('reports a bounded reason without request details', () async {
    final reported = Completer<MangaPageFetchException>();
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/forbidden': (_) =>
          ResponseBody.fromBytes(const <int>[], HttpStatus.forbidden),
    });
    final client = _client(
      adapter,
      reportFailure: (failure) {
        if (!reported.isCompleted) reported.complete(failure);
      },
    );
    addTearDown(client.close);

    await expectLater(
      client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/forbidden'),
          headers: const <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer private',
          },
        ),
      ),
      throwsA(isA<MangaPageFetchException>()),
    );
    final failure = await reported.future;

    expect(failure.reasonCode, 'http_forbidden');
    expect(failure.statusCode, HttpStatus.forbidden);
    expect(failure.toString(), isNot(contains('pages.example')));
    expect(failure.toString(), isNot(contains('private')));
  });

  test('reports privacy-safe redirect context without request URLs', () async {
    final reported = Completer<MangaPageFetchException>();
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/start': (_) => ResponseBody.fromBytes(
        const <int>[],
        HttpStatus.found,
        headers: <String, List<String>>{
          HttpHeaders.locationHeader: <String>[
            'https://cdn.example/private/page.png?capability=secret',
          ],
        },
      ),
      'https://cdn.example/private/page.png?capability=secret': (_) =>
          ResponseBody.fromBytes(const <int>[], HttpStatus.forbidden),
    });
    final client = _client(
      adapter,
      reportFailure: (failure) {
        if (!reported.isCompleted) reported.complete(failure);
      },
    );
    addTearDown(client.close);

    await expectLater(
      client.fetch(
        MangaRemotePageResource(uri: Uri.parse('https://pages.example/start')),
      ),
      throwsA(isA<MangaPageFetchException>()),
    );
    final failure = await reported.future;

    expect(failure.redirectCount, 1);
    expect(failure.crossOriginRedirect, isTrue);
    expect(failure.toString(), isNot(contains('cdn.example')));
    expect(failure.toString(), isNot(contains('secret')));
  });

  test('classifies common HTTP failures accurately', () async {
    final cases = <(int, String, String)>[
      (HttpStatus.unauthorized, 'http_unauthorized', 'access credential'),
      (HttpStatus.forbidden, 'http_forbidden', 'refused'),
      (HttpStatus.notFound, 'http_not_found', 'no longer available'),
      (HttpStatus.tooManyRequests, 'http_rate_limited', 'limiting requests'),
      (HttpStatus.serviceUnavailable, 'http_server_failure', 'unavailable'),
    ];
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      for (final (status, _, _) in cases)
        'https://pages.example/$status': (_) =>
            ResponseBody.fromBytes(const <int>[], status),
    });
    final client = _client(adapter);
    addTearDown(client.close);

    for (final (status, reasonCode, message) in cases) {
      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/$status'),
          ),
        ),
        throwsA(
          isA<MangaPageFetchException>()
              .having((failure) => failure.reasonCode, 'reason', reasonCode)
              .having(
                (failure) => failure.message,
                'message',
                contains(message),
              )
              .having((failure) => failure.statusCode, 'status', status),
        ),
      );
    }
  });

  test('drops unsafe cross-origin Referer and Origin values', () async {
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/start': (_) => ResponseBody.fromBytes(
        const <int>[],
        HttpStatus.found,
        headers: <String, List<String>>{
          HttpHeaders.locationHeader: <String>['https://cdn.example/page.png'],
        },
      ),
      'https://cdn.example/page.png': (_) =>
          ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
    });
    final client = _client(adapter);
    addTearDown(client.close);

    await client.fetch(
      MangaRemotePageResource(
        uri: Uri.parse('https://pages.example/start'),
        headers: const <String, String>{
          HttpHeaders.refererHeader: 'https://127.0.0.1/private?token=secret',
          'Origin': 'http://reader.example',
        },
      ),
    );

    expect(adapter.requests.last.headers[HttpHeaders.refererHeader], isNull);
    expect(adapter.requests.last.headers['Origin'], isNull);
  });

  test('does not report an expected cancellation', () async {
    final failures = <MangaPageFetchException>[];
    final adapter = _CancellationPageAdapter();
    final client = _client(adapter, reportFailure: failures.add);

    final future = client.fetch(
      MangaRemotePageResource(
        uri: Uri.parse('https://pages.example/cancelled.png'),
      ),
    );
    await adapter.started.future;
    client.close();

    await expectLater(future, throwsA(isA<MangaPageFetchException>()));
    await Future<void>.delayed(Duration.zero);
    expect(failures, isEmpty);
  });

  test('does not report a transport-level request cancellation', () async {
    final failures = <MangaPageFetchException>[];
    final adapter = _ImmediateCancellationPageAdapter();
    final client = _client(adapter, reportFailure: failures.add);
    addTearDown(client.close);

    await expectLater(
      client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/cancelled.png'),
        ),
      ),
      throwsA(
        isA<MangaPageFetchException>().having(
          (failure) => failure.reasonCode,
          'reason',
          'request_cancelled',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(failures, isEmpty);
  });

  test('closing marks active and queued page loads as loader_closed', () async {
    final failures = <MangaPageFetchException>[];
    final adapter = _CancellationPageAdapter();
    final client = _client(
      adapter,
      maximumConcurrentRequests: 1,
      maximumCacheEntries: 2,
      reportFailure: failures.add,
    );

    final active = client.fetch(
      MangaRemotePageResource(
        uri: Uri.parse('https://pages.example/active.png'),
      ),
    );
    await adapter.started.future;
    final queued = client.fetch(
      MangaRemotePageResource(
        uri: Uri.parse('https://pages.example/queued.png'),
      ),
    );
    client.close();

    final loaderClosed = isA<MangaPageFetchException>().having(
      (failure) => failure.reasonCode,
      'reason',
      'loader_closed',
    );
    await expectLater(active, throwsA(loaderClosed));
    await expectLater(queued, throwsA(loaderClosed));
    await Future<void>.delayed(Duration.zero);
    expect(failures, isEmpty);
  });

  test(
    'bounds streamed bytes and rejects a fake image without retrying',
    () async {
      Stream<Uint8List> oversized() async* {
        yield Uint8List.fromList(List<int>.filled(20, 1));
        yield Uint8List.fromList(List<int>.filled(20, 2));
      }

      final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
        'https://pages.example/large': (_) =>
            ResponseBody(oversized(), HttpStatus.ok),
        'https://pages.example/fake.png': (_) =>
            ResponseBody.fromString('not an image', HttpStatus.ok),
      });
      final client = _client(adapter, maximumPageBytes: 32);
      addTearDown(client.close);

      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/large'),
          ),
        ),
        throwsA(isA<MangaPageFetchException>()),
      );
      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/fake.png'),
          ),
        ),
        throwsA(isA<MangaPageFetchException>()),
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test('shares a bounded in-memory fetch for the same capability', () async {
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/page.png': (_) =>
          ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
    });
    final client = _client(adapter);
    addTearDown(client.close);
    final resource = MangaRemotePageResource(
      uri: Uri.parse('https://pages.example/page.png'),
    );

    final first = await client.fetch(resource);
    final second = await client.fetch(resource);

    expect(first, second);
    expect(adapter.requests, hasLength(1));
  });

  test('rejects an encoded dimension bomb before cache or decode', () async {
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/bomb.png': (_) => ResponseBody.fromBytes(
        _pngWithDimensions(maximumMangaImageWidth + 1, 1),
        HttpStatus.ok,
      ),
    });
    final client = _client(adapter);
    addTearDown(client.close);
    final resource = MangaRemotePageResource(
      uri: Uri.parse('https://pages.example/bomb.png'),
    );

    await expectLater(
      client.fetch(resource),
      throwsA(
        isA<MangaPageFetchException>().having(
          (error) => error.message,
          'message',
          contains('dimensions exceed'),
        ),
      ),
    );
    await expectLater(
      client.fetch(resource),
      throwsA(isA<MangaPageFetchException>()),
    );
    expect(adapter.requests, hasLength(2), reason: 'bombs must not be cached');
  });

  test('cancels unread redirect bodies without draining them', () async {
    var redirectCancelled = false;
    final redirectStream = StreamController<Uint8List>(
      onCancel: () {
        redirectCancelled = true;
      },
      sync: true,
    );
    addTearDown(redirectStream.close);
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/start': (_) => ResponseBody(
        redirectStream.stream,
        HttpStatus.found,
        headers: <String, List<String>>{
          HttpHeaders.locationHeader: <String>[
            'https://pages.example/page.png',
          ],
        },
      ),
      'https://pages.example/page.png': (_) =>
          ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
    });
    final client = _client(adapter);
    addTearDown(client.close);

    expect(
      await client.fetch(
        MangaRemotePageResource(uri: Uri.parse('https://pages.example/start')),
      ),
      _pngBytes,
    );
    expect(redirectCancelled, isTrue);
  });

  test('cancels rejected and oversized response bodies immediately', () async {
    final cancelled = <String>[];
    final listened = <String>[];
    StreamController<Uint8List> body(String label) =>
        StreamController<Uint8List>(
          onListen: () => listened.add(label),
          onCancel: () => cancelled.add(label),
          sync: true,
        );
    final forbidden = body('forbidden');
    final oversized = body('oversized');
    addTearDown(forbidden.close);
    addTearDown(oversized.close);
    final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
      'https://pages.example/forbidden': (_) =>
          ResponseBody(forbidden.stream, HttpStatus.forbidden),
      'https://pages.example/oversized': (_) => ResponseBody(
        oversized.stream,
        HttpStatus.ok,
        headers: <String, List<String>>{
          HttpHeaders.contentLengthHeader: <String>['33'],
        },
      ),
    });
    final client = _client(adapter, maximumPageBytes: 32);
    addTearDown(client.close);

    for (final path in const <String>['forbidden', 'oversized']) {
      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/$path'),
          ),
        ),
        throwsA(isA<MangaPageFetchException>()),
      );
    }
    expect(listened, <String>['forbidden', 'oversized']);
    expect(cancelled, <String>['forbidden', 'oversized']);
  });

  test(
    'bounds active requests and rejects overflow until a cache slot is free',
    () async {
      final adapter = _GatePageAdapter();
      final client = _client(
        adapter,
        maximumConcurrentRequests: 2,
        maximumCacheEntries: 4,
        requestDeadline: const Duration(seconds: 2),
      );
      addTearDown(client.close);

      final accepted = <Future<Uint8List>>[
        for (var index = 0; index < 4; index++)
          client.fetch(
            MangaRemotePageResource(
              uri: Uri.parse('https://pages.example/page-$index.png'),
            ),
          ),
      ];
      await _waitFor(() => adapter.requests.length == 2);

      expect(adapter.maximumActive, 2);
      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/overflow.png'),
          ),
        ),
        throwsA(
          isA<MangaPageFetchException>().having(
            (error) => error.message,
            'message',
            contains('already loading'),
          ),
        ),
      );

      adapter.release();
      final results = await Future.wait(accepted);
      expect(results, everyElement(_pngBytes));
      expect(adapter.requests, hasLength(4));
      expect(adapter.maximumActive, 2);

      expect(
        await client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/after-eviction.png'),
          ),
        ),
        _pngBytes,
      );
      expect(adapter.requests, hasLength(5));
      expect(adapter.maximumActive, 2);
    },
  );

  test('enforces one total wall-clock deadline for a dripping body', () async {
    final adapter = _DripPageAdapter();
    final client = _client(
      adapter,
      requestDeadline: const Duration(milliseconds: 60),
    );
    addTearDown(client.close);
    addTearDown(adapter.close);

    await expectLater(
      client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/never-finishes.png'),
        ),
      ),
      throwsA(
        isA<MangaPageFetchException>().having(
          (error) => error.message,
          'message',
          contains('too long'),
        ),
      ),
    );
    await _waitFor(() => adapter.cancelled);
    expect(adapter.cancelled, isTrue);
  });
}

MangaPageFetchClient _client(
  HttpClientAdapter adapter, {
  MangaPageTargetValidator? validateTarget,
  int maximumPageBytes = maximumMangaRemotePageBytes,
  int maximumConcurrentRequests = 8,
  int maximumCacheEntries = 64,
  Duration requestDeadline = const Duration(seconds: 45),
  MangaPageFailureReporter? reportFailure,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return MangaPageFetchClient(
    dio: dio,
    validateTarget: validateTarget ?? (_) async {},
    maximumPageBytes: maximumPageBytes,
    maximumCachedBytes: maximumPageBytes * 2,
    maximumConcurrentRequests: maximumConcurrentRequests,
    maximumCacheEntries: maximumCacheEntries,
    requestDeadline: requestDeadline,
    reportFailure: reportFailure,
  );
}

typedef _PageResponseFactory = ResponseBody Function(RequestOptions options);

class _PageRoutingAdapter implements HttpClientAdapter {
  _PageRoutingAdapter(this.routes);

  final Map<String, _PageResponseFactory> routes;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return routes[options.uri.toString()]?.call(options) ??
        ResponseBody.fromString('not found', HttpStatus.notFound);
  }

  @override
  void close({bool force = false}) {}
}

class _GatePageAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];
  final Completer<void> _gate = Completer<void>();
  int _active = 0;
  int maximumActive = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    _active++;
    if (_active > maximumActive) maximumActive = _active;
    return ResponseBody(_body(), HttpStatus.ok);
  }

  Stream<Uint8List> _body() async* {
    try {
      await _gate.future;
      yield _pngBytes;
    } finally {
      _active--;
    }
  }

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  void close({bool force = false}) => release();
}

class _CancellationPageAdapter implements HttpClientAdapter {
  final Completer<void> started = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!started.isCompleted) started.complete();
    await cancelFuture;
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      message: 'cancelled',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ImmediateCancellationPageAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => Future<ResponseBody>.error(
    DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      message: 'cancelled',
    ),
  );

  @override
  void close({bool force = false}) {}
}

class _DripPageAdapter implements HttpClientAdapter {
  StreamController<Uint8List>? _controller;
  Timer? _timer;
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>();
    _controller = controller;
    _timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => controller.add(Uint8List.fromList(const <int>[0])),
    );
    unawaited(
      cancelFuture?.whenComplete(() async {
            cancelled = true;
            _timer?.cancel();
            if (!controller.isClosed) await controller.close();
          }) ??
          Future<void>.value(),
    );
    return ResponseBody(controller.stream, HttpStatus.ok);
  }

  @override
  void close({bool force = false}) {
    _timer?.cancel();
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for the expected asynchronous state.');
}

final Uint8List _pngBytes = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x02,
  0x00,
  0x00,
  0x00,
  0x02,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
]);

Uint8List _pngWithDimensions(int width, int height) {
  final bytes = Uint8List.fromList(_pngBytes);
  for (var index = 0; index < 4; index++) {
    bytes[16 + index] = (width >> ((3 - index) * 8)) & 0xff;
    bytes[20 + index] = (height >> ((3 - index) * 8)) & 0xff;
  }
  return bytes;
}
