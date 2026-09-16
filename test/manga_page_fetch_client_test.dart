import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MangaRemotePageResource page(String name) => MangaRemotePageResource(
    uri: Uri.parse('https://pages.example/$name.png'),
  );

  test(
    'opaque images are coalesced and validated without a Dart URL',
    () async {
      final adapter = _GatePageAdapter();
      final client = _client(adapter);
      addTearDown(client.close);
      var loads = 0;
      final identity = Object();
      final firstResource = MangaOpaquePageResource(
        cacheIdentity: identity,
        loadImage: () async {
          loads++;
          return _pngBytes;
        },
      );
      final secondResource = MangaOpaquePageResource(
        cacheIdentity: identity,
        loadImage: () async {
          loads++;
          return _pngBytes;
        },
      );

      final first = client.fetch(firstResource);
      final second = client.fetch(secondResource);
      expect(await first, _pngBytes);
      expect(await second, _pngBytes);
      expect(loads, 1);
      expect(adapter.requests, isEmpty);
      expect(firstResource.toString(), isNot(contains('http')));
    },
  );

  test('opaque image bytes retain reader size and image validation', () async {
    final client = _client(_GatePageAdapter(), maximumPageBytes: 64);
    addTearDown(client.close);
    final malformed = MangaOpaquePageResource(
      cacheIdentity: Object(),
      loadImage: () async =>
          Uint8List.fromList(utf8.encode('<html>secret</html>')),
    );
    await expectLater(
      client.fetch(malformed),
      throwsA(
        isA<MangaPageFetchException>().having(
          (error) => error.reasonCode,
          'reasonCode',
          'unsupported_image',
        ),
      ),
    );

    final oversized = MangaOpaquePageResource(
      cacheIdentity: Object(),
      loadImage: () async => Uint8List(65),
    );
    await expectLater(
      client.fetch(oversized),
      throwsA(
        isA<MangaPageFetchException>().having(
          (error) => error.reasonCode,
          'reasonCode',
          'size_limit',
        ),
      ),
    );
  });

  test('visible loads use a reserved slot ahead of speculative work', () async {
    final adapter = _GatePageAdapter();
    final client = _client(adapter, maximumConcurrentRequests: 2);
    addTearDown(client.close);
    final owner = Object();
    final first = client.prefetch(page('first'), owner: owner);
    final second = client.prefetch(page('second'), owner: owner);
    final visible = client.fetch(page('visible'));
    await _waitFor(() => adapter.requests.length == 2);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/first.png',
      '/visible.png',
    ]);
    adapter.release();
    await Future.wait([first, second, visible]);
    expect(adapter.maximumActive, 2);
  });

  test(
    'a visible consumer promotes a queued prefetch without duplicating it',
    () async {
      final adapter = _GatePageAdapter();
      final client = _client(adapter, maximumConcurrentRequests: 1);
      addTearDown(client.close);
      final owner = Object();
      final active = client.fetch(page('active'));
      final first = client.prefetch(page('first'), owner: owner);
      final second = client.prefetch(page('second'), owner: owner);
      final promoted = client.fetch(page('second'));
      expect(promoted, same(second));
      await _waitFor(() => adapter.requests.length == 1);
      adapter.release();
      await Future.wait([active, first, second, promoted]);
      expect(adapter.requests.map((request) => request.uri.path), [
        '/active.png',
        '/second.png',
        '/first.png',
      ]);
    },
  );

  test(
    'stale prefetch cancellation never cancels a claimed visible page',
    () async {
      final adapter = _ControlledPageAdapter();
      final reports = <MangaPageFetchException>[];
      final client = _client(
        adapter,
        maximumConcurrentRequests: 2,
        reportFailure: reports.add,
      );
      addTearDown(client.close);
      final owner = Object();
      final stale = client.prefetch(page('stale'), owner: owner);
      final staleResult = expectLater(
        stale,
        throwsA(
          isA<MangaPageFetchException>().having(
            (error) => error.reasonCode,
            'code',
            'request_cancelled',
          ),
        ),
      );
      final promoted = client.prefetch(page('shared'), owner: owner);
      final visible = client.fetch(page('shared'));
      expect(visible, same(promoted));
      await _waitFor(() => adapter.requests.length == 2);
      client.cancelPrefetches(owner);
      await staleResult;
      expect(adapter.cancelled, ['/stale.png']);
      adapter.complete('/shared.png');
      expect(await visible, _pngBytes);
      expect(reports, isEmpty);
    },
  );

  test(
    'prefetch shared by another reader survives one owner leaving',
    () async {
      final adapter = _ControlledPageAdapter();
      final client = _client(adapter);
      addTearDown(client.close);
      final firstOwner = Object();
      final secondOwner = Object();
      final first = client.prefetch(page('shared'), owner: firstOwner);
      expect(client.prefetch(page('shared'), owner: secondOwner), same(first));
      await _waitFor(() => adapter.requests.isNotEmpty);
      client.cancelPrefetches(firstOwner);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.cancelled, isEmpty);
      adapter.complete('/shared.png');
      expect(await first, _pngBytes);
    },
  );

  test(
    'visible request can replace saturated speculative cache work',
    () async {
      final adapter = _ControlledPageAdapter();
      final client = _client(
        adapter,
        maximumConcurrentRequests: 1,
        maximumCacheEntries: 2,
      );
      addTearDown(client.close);
      final owner = Object();
      final first = client.prefetch(page('first'), owner: owner);
      final cancelled = expectLater(
        first,
        throwsA(isA<MangaPageFetchException>()),
      );
      final second = client.prefetch(page('second'), owner: owner);
      final secondCancelled = expectLater(
        second,
        throwsA(isA<MangaPageFetchException>()),
      );
      await _waitFor(() => adapter.requests.length == 1);
      final visible = client.fetch(page('visible'));
      await cancelled;
      await _waitFor(() => adapter.requests.length == 2);
      expect(adapter.requests.last.uri.path, '/visible.png');
      client.cancelPrefetches(owner);
      await secondCancelled;
      adapter.complete('/visible.png');
      expect(await visible, _pngBytes);
    },
  );

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

  for (final accept in [
    'image/avif,image/webp,image/*,*/*;q=0.8',
    'IMAGE/AVIF ;q=1, image/png;q=0.8',
    'image/heif,image/heic-sequence',
  ]) {
    test(
      'unsupported Accept is narrowed without changing credentials: $accept',
      () async {
        final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
          'https://pages.example/start': (_) => ResponseBody.fromBytes(
            const [],
            HttpStatus.found,
            headers: {
              HttpHeaders.locationHeader: ['/same-origin'],
            },
          ),
          'https://pages.example/same-origin': (_) => ResponseBody.fromBytes(
            const [],
            HttpStatus.found,
            headers: {
              HttpHeaders.locationHeader: ['https://cdn.example/page'],
            },
          ),
          'https://cdn.example/page': (_) =>
              ResponseBody.fromBytes(_pngBytes, HttpStatus.ok),
        });
        final client = _client(adapter);
        addTearDown(client.close);
        await client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/start'),
            headers: {
              'Accept': accept,
              HttpHeaders.authorizationHeader: 'Bearer credential-canary',
              HttpHeaders.cookieHeader: 'session=cookie-canary',
              'X-Provider-Key': 'key-canary',
              HttpHeaders.userAgentHeader: 'Agent canary',
            },
          ),
        );
        for (final request in adapter.requests) {
          expect(
            request.headers[HttpHeaders.acceptHeader],
            'image/jpeg,image/png,image/webp,image/gif;q=0.9',
          );
          expect(request.headers[HttpHeaders.userAgentHeader], 'Agent canary');
        }
        for (final request in adapter.requests.take(2)) {
          expect(
            request.headers[HttpHeaders.authorizationHeader],
            'Bearer credential-canary',
          );
          expect(
            request.headers[HttpHeaders.cookieHeader],
            'session=cookie-canary',
          );
          expect(request.headers['X-Provider-Key'], 'key-canary');
        }
        expect(
          adapter.requests.last.headers[HttpHeaders.authorizationHeader],
          isNull,
        );
        expect(adapter.requests.last.headers[HttpHeaders.cookieHeader], isNull);
        expect(adapter.requests.last.headers['X-Provider-Key'], isNull);
      },
    );
  }

  test(
    'recognized AVIF is transcoded only for opted-in cover artwork',
    () async {
      final encoded = Uint8List.fromList(_ftypBytes('avif'));
      final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
        'https://pages.example/reader': (_) =>
            ResponseBody.fromBytes(encoded, HttpStatus.ok),
        'https://pages.example/cover': (_) =>
            ResponseBody.fromBytes(encoded, HttpStatus.ok),
      });
      var transcodes = 0;
      final client = _client(
        adapter,
        transcodeUnsupportedArtwork: (value) async {
          transcodes++;
          expect(value, encoded);
          return _pngBytes;
        },
      );
      addTearDown(client.close);

      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/reader'),
          ),
        ),
        throwsA(
          isA<MangaPageFetchException>().having(
            (failure) => failure.reasonCode,
            'reason',
            'unsupported_image',
          ),
        ),
      );
      expect(transcodes, 0);

      final recovered = await client.fetch(
        MangaRemotePageResource(
          uri: Uri.parse('https://pages.example/cover'),
          allowPlatformArtworkTranscode: true,
        ),
      );
      expect(recovered, _pngBytes);
      expect(transcodes, 1);
    },
  );

  test(
    'invalid native artwork output stays on the safe failure path',
    () async {
      final encoded = Uint8List.fromList(_ftypBytes('heic'));
      final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
        'https://pages.example/cover': (_) =>
            ResponseBody.fromBytes(encoded, HttpStatus.ok),
      });
      final client = _client(
        adapter,
        transcodeUnsupportedArtwork: (_) async => Uint8List.fromList(<int>[1]),
      );
      addTearDown(client.close);

      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/cover'),
            allowPlatformArtworkTranscode: true,
          ),
        ),
        throwsA(
          isA<MangaPageFetchException>().having(
            (failure) => failure.reasonCode,
            'reason',
            'unsupported_image',
          ),
        ),
      );
    },
  );

  final malformedFormats =
      <(String, List<int>, MangaPageResponseFormat, String)>[
        (
          'jpeg',
          [0xff, 0xd8, 0xff],
          MangaPageResponseFormat.jpeg,
          'malformed_image',
        ),
        (
          'png',
          _pngBytes.take(8).toList(),
          MangaPageResponseFormat.png,
          'malformed_image',
        ),
        (
          'gif',
          ascii.encode('GIF89a'),
          MangaPageResponseFormat.gif,
          'malformed_image',
        ),
        (
          'webp',
          [...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP')],
          MangaPageResponseFormat.webp,
          'malformed_image',
        ),
        (
          'avif',
          _ftypBytes('avif'),
          MangaPageResponseFormat.avif,
          'unsupported_image',
        ),
        (
          'avif-compatible',
          _ftypBytes('mif1', compatible: ['avif']),
          MangaPageResponseFormat.avif,
          'unsupported_image',
        ),
        (
          'heif',
          _ftypBytes('heic'),
          MangaPageResponseFormat.heif,
          'unsupported_image',
        ),
        (
          'html',
          utf8.encode(
            '\ufeff \r\n<!DoCtYpE HTML><html>private-body-canary</html>',
          ),
          MangaPageResponseFormat.html,
          'unsupported_image',
        ),
        (
          'html-tag',
          ascii.encode('<HTML lang="en">private-body-canary</HTML>'),
          MangaPageResponseFormat.html,
          'unsupported_image',
        ),
        (
          'unknown',
          ascii.encode('private-body-canary image/avif'),
          MangaPageResponseFormat.unknown,
          'unsupported_image',
        ),
        (
          'false-html',
          ascii.encode('<htmlish>private-body-canary'),
          MangaPageResponseFormat.unknown,
          'unsupported_image',
        ),
        (
          'truncated-ftyp',
          _ftypBytes('avif').take(12).toList(),
          MangaPageResponseFormat.unknown,
          'unsupported_image',
        ),
        (
          'unbranded-ftyp',
          _ftypBytes('xxxx'),
          MangaPageResponseFormat.unknown,
          'unsupported_image',
        ),
        ('empty', [], MangaPageResponseFormat.empty, 'empty_response'),
        (
          'png-dimensions',
          _pngWithDimensions(maximumMangaImageWidth + 1, 1),
          MangaPageResponseFormat.png,
          'image_dimensions_exceeded',
        ),
      ];
  for (final (name, bytes, format, reason) in malformedFormats) {
    test(
      'failure preserves observed $name format/status/byte count after redirect and export',
      () async {
        final failures = <MangaPageFetchException>[];
        final adapter = _PageRoutingAdapter(<String, _PageResponseFactory>{
          'https://pages.example/start': (_) => ResponseBody.fromBytes(
            const [],
            HttpStatus.found,
            headers: {
              HttpHeaders.locationHeader: [
                'https://cdn.example/private-path-canary?credential=url-secret-canary',
              ],
            },
          ),
          'https://cdn.example/private-path-canary?credential=url-secret-canary':
              (_) => ResponseBody.fromBytes(
                bytes,
                HttpStatus.ok,
                headers: {
                  // Deliberately false metadata must not determine the response format.
                  HttpHeaders.contentTypeHeader: [
                    'image/avif; private-header-canary',
                  ],
                  'x-private-header': ['response-header-canary'],
                },
              ),
        });
        final client = _client(adapter, reportFailure: failures.add);
        addTearDown(client.close);
        await expectLater(
          client.fetch(
            MangaRemotePageResource(
              uri: Uri.parse('https://pages.example/start'),
              headers: const {
                HttpHeaders.authorizationHeader: 'Bearer request-secret-canary',
              },
            ),
          ),
          throwsA(isA<MangaPageFetchException>()),
        );
        expect(failures, hasLength(1));
        final failure = failures.single;
        expect(failure.reasonCode, reason);
        expect(failure.statusCode, HttpStatus.ok);
        expect(failure.responseFormat, format);
        expect(failure.encodedByteCount, bytes.length);
        expect(failure.redirectCount, 1);
        expect(failure.crossOriginRedirect, isTrue);
        final expectedMessage =
            'format=${format.name} encoded_byte_count=${bytes.length} '
            'redirect_hops=1 changed_site=true';
        expect(failure.diagnosticDetails, {
          'reason_code': reason,
          'status': HttpStatus.ok,
          'message': expectedMessage,
        });
        final copied = failure.withRedirectContext(
          redirectCount: 2,
          crossOriginRedirect: true,
        );
        expect(copied.statusCode, failure.statusCode);
        expect(copied.responseFormat, failure.responseFormat);
        expect(copied.encodedByteCount, failure.encodedByteCount);
        final persisted = sanitizeDiagnosticContext(failure.diagnosticDetails);
        expect(persisted, failure.diagnosticDetails);
        final export = ExplicitDiagnosticsReport.fromSnapshot(
          version: const AppVersionInfo(name: '2.0.74', code: 410051),
          profile: const TvDeviceProfile(
            manufacturer: 'Example',
            model: 'TV',
            sdk: 30,
            abis: ['arm64-v8a'],
            displayModes: [],
            hdrTypes: [],
            codecs: [],
            audioOutputs: [],
          ),
          isTelevision: true,
          diagnostics: {
            'diagnosticEvents': [
              {
                'category': 'manga-reader',
                'severity': 'warning',
                'message': 'Manga page fetch failed',
                'context': persisted,
              },
            ],
          },
        );
        final report = jsonDecode(export.report) as Map<String, dynamic>;
        final event =
            (report['diagnostics']['diagnosticEvents'] as List).single as Map;
        expect(event['context'], failure.diagnosticDetails);
        expect(export.report, contains(expectedMessage));
        expect(jsonEncode(export.toWireJson()), isNot(contains('canary')));
        expect(export.report, isNot(contains('pages.example')));
        expect(export.report, isNot(contains('cdn.example')));
        expect(adapter.requests, hasLength(2)); // No retry or relaxed decoder.
      },
    );
  }

  test(
    'stream failure keeps actual received count and current response status',
    () async {
      Stream<Uint8List> interrupted() async* {
        yield Uint8List.fromList([1, 2, 3]);
        throw const SocketException('private-transport-canary');
      }

      final adapter = _PageRoutingAdapter({
        'https://pages.example/page': (_) =>
            ResponseBody(interrupted(), HttpStatus.ok),
      });
      final failures = <MangaPageFetchException>[];
      final client = _client(adapter, reportFailure: failures.add);
      addTearDown(client.close);
      await expectLater(
        client.fetch(
          MangaRemotePageResource(uri: Uri.parse('https://pages.example/page')),
        ),
        throwsA(isA<MangaPageFetchException>()),
      );
      expect(failures.single.statusCode, HttpStatus.ok);
      expect(failures.single.encodedByteCount, 3);
      expect(failures.single.responseFormat, MangaPageResponseFormat.unknown);
      expect(
        jsonEncode(failures.single.diagnosticDetails),
        isNot(contains('canary')),
      );
    },
  );

  test(
    'failed redirect target does not inherit the previous response status',
    () async {
      final adapter = _PageRoutingAdapter({
        'https://pages.example/start': (_) => ResponseBody.fromBytes(
          const [],
          HttpStatus.found,
          headers: {
            HttpHeaders.locationHeader: ['https://cdn.example/page'],
          },
        ),
      });
      final failures = <MangaPageFetchException>[];
      final client = _client(
        adapter,
        reportFailure: failures.add,
        validateTarget: (uri) async {
          if (uri.host == 'cdn.example') {
            throw const SocketException('private-dns-canary');
          }
        },
      );
      addTearDown(client.close);
      await expectLater(
        client.fetch(
          MangaRemotePageResource(
            uri: Uri.parse('https://pages.example/start'),
          ),
        ),
        throwsA(isA<MangaPageFetchException>()),
      );
      expect(failures.single.statusCode, isNull);
      expect(failures.single.encodedByteCount, 0);
      expect(failures.single.redirectCount, 1);
      expect(failures.single.crossOriginRedirect, isTrue);
      expect(
        jsonEncode(failures.single.diagnosticDetails),
        isNot(contains('canary')),
      );
    },
  );

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
  MangaUnsupportedArtworkTranscoder? transcodeUnsupportedArtwork,
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
    transcodeUnsupportedArtwork: transcodeUnsupportedArtwork,
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

class _ControlledPageAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<String> cancelled = [];
  final Map<String, Completer<ResponseBody>> pending = {};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final completer = pending.putIfAbsent(
      options.uri.path,
      Completer<ResponseBody>.new,
    );
    cancelFuture?.then((_) {
      if (completer.isCompleted) return;
      cancelled.add(options.uri.path);
      completer.completeError(
        DioException(requestOptions: options, type: DioExceptionType.cancel),
      );
    });
    return completer.future;
  }

  void complete(String path) =>
      pending[path]!.complete(ResponseBody.fromBytes(_pngBytes, HttpStatus.ok));
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

List<int> _ftypBytes(String major, {List<String> compatible = const []}) {
  final size = 16 + compatible.length * 4;
  return [
    0,
    0,
    0,
    size,
    ...ascii.encode('ftyp'),
    ...ascii.encode(major),
    0,
    0,
    0,
    0,
    for (final brand in compatible) ...ascii.encode(brand),
  ];
}

Uint8List _pngWithDimensions(int width, int height) {
  final bytes = Uint8List.fromList(_pngBytes);
  for (var index = 0; index < 4; index++) {
    bytes[16 + index] = (width >> ((3 - index) * 8)) & 0xff;
    bytes[20 + index] = (height >> ((3 - index) * 8)) & 0xff;
  }
  return bytes;
}
