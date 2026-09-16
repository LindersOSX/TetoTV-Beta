import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sanitizes untrusted addon request and playback headers', () {
    final headers = sanitizeAddonHeaders({
      'Referer': 'https://example.com/',
      'Origin': 'https://media.example.com',
      'Host': 'internal.example',
      'Content-Length': '999',
      'X-Injected': 'safe\r\nAuthorization: hidden',
      'Authorization': 'Bearer provider-session',
      'X-Api-Key': 'provider-api-secret',
      'X-Auth-Token': 'provider-auth-secret',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-site',
    });

    expect(headers['Referer'], 'https://example.com/');
    expect(headers['Authorization'], 'Bearer provider-session');
    expect(headers, isNot(contains('Host')));
    expect(headers, isNot(contains('Content-Length')));
    expect(headers, isNot(contains('X-Injected')));

    final redirected = sanitizeAddonHeaders(headers, stripCredentials: true);
    expect(redirected, isNot(contains('Authorization')));
    expect(redirected, isNot(contains('X-Api-Key')));
    expect(redirected, isNot(contains('X-Auth-Token')));
    expect(redirected['Referer'], 'https://example.com/');
    expect(redirected['Origin'], 'https://media.example.com');
    expect(redirected['Sec-Fetch-Dest'], 'empty');
    expect(redirected['Sec-Fetch-Mode'], 'cors');
    expect(redirected['Sec-Fetch-Site'], 'same-site');

    for (final invalidFetchMetadata in const {
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'websocket',
      'Sec-Fetch-Site': 'provider-secret',
    }.entries) {
      expect(
        sanitizeAddonHeaders({
          invalidFetchMetadata.key: invalidFetchMetadata.value,
        }),
        isNot(contains(invalidFetchMetadata.key)),
      );
    }
    expect(sanitizeAddonHeaders(const {'Sec-Fetch-Dest': 'VIDEO'}), const {
      'Sec-Fetch-Dest': 'video',
    });

    for (final unsafeOrigin in const [
      'http://media.example.com',
      'https://user:secret@media.example.com',
      'https://127.0.0.1',
      'https://media.example.com/private/path',
    ]) {
      expect(
        sanitizeAddonHeaders({'Origin': unsafeOrigin}, stripCredentials: true),
        isNot(contains('Origin')),
      );
    }
  });

  test('preserves bounded multi-value response headers', () {
    final headers = sanitizeAddonResponseHeaders({
      'Content-Type': ['application/json', 'text/plain'],
      'Set-Cookie': ['session=one', 'theme=dark'],
      'Bad\r\nHeader': ['hidden'],
      'X-Injected': ['safe\r\nhidden'],
    });

    expect(headers['Content-Type'], ['application/json', 'text/plain']);
    expect(headers['Set-Cookie'], ['session=one', 'theme=dark']);
    expect(headers, isNot(contains('Bad\r\nHeader')));
    expect(headers, isNot(contains('X-Injected')));
  });

  test(
    'parses valid response cookies after malformed and oversized values',
    () {
      final cookies = parseAddonResponseCookies([
        'oversized=${List.filled(9000, 'x').join()}',
        'bad name=hidden',
        'session=fixture-cookie; Path=/; HttpOnly',
        'theme=dark; Secure; SameSite=Lax',
      ]);

      expect(cookies, {'session': 'fixture-cookie', 'theme': 'dark'});
    },
  );

  test('runtime cookies accept safe parent domains with RFC path matching', () {
    final jar = AddonRuntimeCookieJar();
    jar.capture(
      Uri.parse('https://api.media.example.com/foo/login'),
      Headers.fromMap({
        HttpHeaders.setCookieHeader: [
          'session=parent; Domain=.example.com; Path=/foo; Secure',
          'host_only=private; Path=/',
          'unrelated=blocked; Domain=attacker.example; Path=/',
        ],
      }),
    );

    final sibling = <String, String>{};
    jar.apply(Uri.parse('https://cdn.example.com/foo/episode'), sibling);
    expect(
      sibling,
      isNot(contains(HttpHeaders.cookieHeader)),
      reason: 'domain cookies cannot widen to siblings without a PSL',
    );

    final originalPath = <String, String>{};
    jar.apply(
      Uri.parse('https://api.media.example.com/foo/episode'),
      originalPath,
    );
    expect(
      originalPath[HttpHeaders.cookieHeader],
      'session=parent; host_only=private',
    );

    final falsePrefix = <String, String>{};
    jar.apply(Uri.parse('https://api.media.example.com/foobar'), falsePrefix);
    expect(falsePrefix[HttpHeaders.cookieHeader], 'host_only=private');

    final originalHost = <String, String>{};
    jar.apply(Uri.parse('https://api.media.example.com/'), originalHost);
    expect(originalHost[HttpHeaders.cookieHeader], 'host_only=private');

    final unrelated = <String, String>{};
    jar.apply(Uri.parse('https://example.com.attacker.test/foo'), unrelated);
    expect(unrelated, isNot(contains(HttpHeaders.cookieHeader)));

    final insecure = <String, String>{};
    jar.apply(Uri.parse('http://api.media.example.com/foo'), insecure);
    expect(insecure, isNot(contains(HttpHeaders.cookieHeader)));

    final publicSuffixJar = AddonRuntimeCookieJar();
    publicSuffixJar.capture(
      Uri.parse('https://a.co.uk/login'),
      Headers.fromMap({
        HttpHeaders.setCookieHeader: ['unsafe=secret; Domain=co.uk; Path=/'],
      }),
    );
    final publicSuffixSibling = <String, String>{};
    publicSuffixJar.apply(
      Uri.parse('https://b.co.uk/redirect'),
      publicSuffixSibling,
    );
    expect(publicSuffixSibling, isNot(contains(HttpHeaders.cookieHeader)));
  });

  test('cookie domain and path helpers reject lookalike boundaries', () {
    expect(
      addonRuntimeCookieDomainMatches('video.example.com', '.example.com'),
      isTrue,
    );
    expect(
      addonRuntimeCookieDomainMatches('example.com', 'example.com'),
      isTrue,
    );
    expect(
      addonRuntimeCookieDomainMatches('notexample.com', 'example.com'),
      isFalse,
    );
    expect(
      addonRuntimeCookieDomainMatches(
        'example.com.attacker.test',
        'example.com',
      ),
      isFalse,
    );
    expect(addonRuntimeCookieDomainMatches('example.com', 'com'), isFalse);
    expect(addonRuntimeCookiePathMatches('/foo', '/foo'), isTrue);
    expect(addonRuntimeCookiePathMatches('/foo/bar', '/foo'), isTrue);
    expect(addonRuntimeCookiePathMatches('/foobar', '/foo'), isFalse);
  });

  test(
    'runtime response wire preserves arbitrary bounded bytes and text',
    () async {
      final bytes = Uint8List.fromList([0, 255, 128, 65, 10]);
      final body = await readBoundedAddonRuntimeResponseBody(
        ResponseBody(Stream.value(bytes), 200),
        16,
      );
      final wire = addonRuntimeResponseBodyWireFields(body);

      expect(body.bytes, bytes);
      expect(base64Decode(wire['bodyBase64']! as String), bytes);
      expect(wire['bodyByteLength'], bytes.length);
      expect(wire['body'], body.text);

      await expectLater(
        readBoundedAddonRuntimeResponseBody(
          ResponseBody(Stream.value(bytes), 200),
          bytes.length - 1,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'runtime classification distinguishes host gaps from payload TypeErrors',
    () {
      for (final message in [
        'TypeError: Cannot read properties of undefined (reading map)',
        'TypeError: undefined is not a function',
        'ReferenceError: providerLocalHelper is not defined',
        'Upstream payload was undefined',
      ]) {
        expect(
          classifySeanimeProviderFailureReason(message),
          'provider_error',
          reason: message,
        );
      }
      for (final message in [
        'ReferenceError: fetch is not defined',
        'ReferenceError: Buffer is not defined',
        r'ReferenceError: $sleep is not defined',
        'TypeError: TextEncoder is not a function',
      ]) {
        expect(
          classifySeanimeProviderFailureReason(message),
          'runtime_api',
          reason: message,
        );
      }
    },
  );

  test(
    'bounds addon network concurrency, request count, and responses',
    () async {
      final budget = AddonRuntimeNetworkBudget(
        maximumRequests: 4,
        maximumConcurrentRequests: 1,
        maximumResponseBytes: 8,
      );
      await budget.acquire();
      var secondStarted = false;
      final second = budget.acquire().then((_) => secondStarted = true);
      await Future<void>.delayed(Duration.zero);
      expect(secondStarted, isFalse);
      budget.release();
      await second;
      budget.recordResponse('1234');
      budget.release();

      await budget.acquire();
      expect(
        () => budget.recordResponse('56789'),
        throwsA(isA<FormatException>()),
      );
      budget.release();
      await expectLater(budget.acquire(), throwsA(isA<FormatException>()));

      final byteBudget = AddonRuntimeNetworkBudget(maximumResponseBytes: 4);
      byteBudget.recordResponseBytes(4);
      expect(
        () => byteBudget.recordResponseBytes(1),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => byteBudget.recordResponseBytes(-1),
        throwsA(isA<FormatException>()),
      );

      final requestBudget = AddonRuntimeNetworkBudget(
        maximumRequests: 1,
        maximumConcurrentRequests: 1,
      );
      await requestBudget.acquire();
      requestBudget.release();
      await expectLater(
        requestBudget.acquire(),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('no-match provider outcomes are not treated as runtime failures', () {
    expect(
      isSeanimeProviderNoMatch(
        StateError('NO_MATCH: This provider has no matching title.'),
      ),
      isTrue,
    );
    expect(
      isSeanimeProviderNoMatch(
        StateError(
          'NO_MATCH: This provider has no matching title. '
          '[stage=search; reason=empty_result]',
        ),
      ),
      isTrue,
    );
    expect(
      isSeanimeProviderNoMatch(
        StateError(
          'NO_MATCH: This provider has no matching title. '
          '[stage=search; reason=network]',
        ),
      ),
      isFalse,
      reason: 'an upstream failure must not masquerade as a real no-match',
    );
    expect(
      isSeanimeProviderNoMatch(
        StateError('NO_STREAM: The provider returned no compatible stream.'),
      ),
      isFalse,
    );
    expect(
      isSeanimeProviderNoMatch(
        StateError(
          'NO_STREAM: Provider search could not complete. '
          '[stage=search; reason=empty_result]',
        ),
      ),
      isTrue,
      reason: 'provider-declared empty search results are normal availability',
    );
    expect(
      isSeanimeProviderNoMatch(
        StateError(
          'NO_STREAM: Provider episode lookup returned no sources. '
          '[stage=episode_lookup; reason=empty_sources]',
        ),
      ),
      isTrue,
    );
    expect(
      isSeanimeProviderNoMatch(
        StateError(
          'NO_STREAM: Stream extraction returned no sources. '
          '[stage=stream_extraction; reason=empty_sources]',
        ),
      ),
      isFalse,
      reason: 'a post-resolution extraction failure remains actionable',
    );
  });

  test('searches dedicated English and Romaji titles for legacy providers', () {
    expect(
      seanimeProviderSearchTitles(
        const EpisodeReference(
          anilistMediaId: 1,
          title: 'English Display',
          titleEnglish: 'English Display',
          titleRomaji: 'Dedicated Romaji',
          alternativeTitles: ['English Display', 'Alternate'],
          episode: 1,
        ),
      ),
      ['English Display', 'Dedicated Romaji', 'Alternate'],
    );
  });

  test('preserves native-script titles as searchable provider aliases', () {
    const episode = EpisodeReference(
      anilistMediaId: 1,
      title: 'Frieren: Beyond Journey’s End',
      titleEnglish: 'Frieren: Beyond Journey’s End',
      titleRomaji: 'Sousou no Frieren',
      titleNative: '葬送のフリーレン',
      episode: 1,
    );

    expect(
      seanimeProviderSearchTitles(episode),
      containsAllInOrder([
        'Frieren: Beyond Journey’s End',
        'Frieren Beyond Journey s End',
        'Sousou no Frieren',
        '葬送のフリーレン',
      ]),
    );
    expect(seanimeProviderMediaSynonyms(episode), contains('葬送のフリーレン'));
  });

  test('adds punctuation-safe aliases without losing canonical titles', () {
    expect(
      seanimeProviderSearchTitles(
        const EpisodeReference(
          anilistMediaId: 1,
          title: 'Lucky☆Star',
          titleEnglish: 'Lucky☆Star',
          titleRomaji: 'Lucky☆Star',
          alternativeTitles: ['Steins;Gate'],
          episode: 1,
        ),
      ),
      ['Lucky☆Star', 'Lucky Star', 'Steins;Gate', 'Steins Gate'],
    );
  });

  test(
    'tries a punctuation-specific alias before an ambiguous plain alias',
    () {
      expect(
        seanimeProviderSearchTitles(
          const EpisodeReference(
            anilistMediaId: 1887,
            title: 'Lucky☆Star',
            titleEnglish: 'Lucky Star',
            titleRomaji: 'Lucky☆Star',
            alternativeTitles: ['Lucky Star'],
            episode: 1,
          ),
        ),
        ['Lucky☆Star', 'Lucky Star'],
      );

      expect(
        seanimeProviderSearchTitles(
          const EpisodeReference(
            anilistMediaId: 16498,
            title: 'Attack on Titan',
            titleEnglish: 'Attack on Titan',
            titleRomaji: 'Shingeki no Kyojin',
            episode: 1,
          ),
        ).take(2),
        ['Attack on Titan', 'Shingeki no Kyojin'],
        reason: 'distinct English and Romaji titles remain English-first',
      );
    },
  );

  test(
    'classifies explicit Web audio capabilities without guessing unknown',
    () {
      expect(
        webStreamAudioCapabilityFromWire('sub_and_dub'),
        WebStreamAudioCapability.subAndDub,
      );
      expect(
        webStreamAudioCapabilityFromWire('dual audio'),
        WebStreamAudioCapability.subAndDub,
      );
      expect(
        webStreamAudioCapabilityFromWire('both'),
        WebStreamAudioCapability.subAndDub,
      );
      expect(
        webStreamAudioCapabilityFromWire('English'),
        WebStreamAudioCapability.dub,
      );
      expect(
        webStreamAudioCapabilityFromWire('not reported'),
        WebStreamAudioCapability.unknown,
      );
      expect(
        webStreamAudioCapabilityFromWire({
          'availableAudioTracks': [
            {'language': 'ja'},
            {'language': 'en'},
          ],
        }),
        WebStreamAudioCapability.subAndDub,
      );
      expect(
        webStreamAudioCapabilityFromWire({'dub': true}),
        WebStreamAudioCapability.dub,
      );
      expect(
        webStreamAudioCapabilityFromWire({
          'tracks': [
            {'kind': 'subtitles', 'language': 'en'},
          ],
        }),
        WebStreamAudioCapability.unknown,
        reason: 'English subtitle tracks must never imply dubbed audio',
      );
    },
  );

  test('audio language metadata ignores subtitle-only fields', () {
    expect(
      webStreamAudioLanguagesFromWire({
        'audioLanguages': ['es-MX'],
        'audioTracks': [
          {'language': 'it', 'kind': 'audio'},
        ],
        'subtitles': [
          {'language': 'en'},
        ],
      }),
      ['spa', 'ita'],
    );
    expect(
      webStreamAudioLanguagesFromWire({
        'tracks': [
          {'kind': 'subtitles', 'language': 'en'},
        ],
      }),
      isEmpty,
    );
  });

  test(
    'Seanime external audio uses public targets and origin-scoped headers',
    () async {
      final checked = <Uri>[];
      final tracks = await normalizeSeanimeExternalAudioTracks(
        [
          {
            'url': 'https://video.example/audio-ja.m4a',
            'label': ' Japanese \u202eAudio ',
            'language': 'Japanese',
            'headers': {
              'authorization': 'Bearer track-token',
              'Host': 'blocked.example',
            },
          },
          {
            'url': 'https://audio.example/audio-es.aac',
            'label': 'Latino',
            'language': 'es-MX',
            'requestHeaders': {
              'Authorization': 'Bearer audio-token',
              'X-Audio-Key': 'audio-secret',
              'Content-Length': '99',
            },
          },
          {'url': 'http://insecure.example/audio.aac', 'language': 'English'},
          {'url': 'https://blocked.example/audio.aac', 'language': 'English'},
          {
            'url': 'https://video.example/audio-ja.m4a',
            'label': ' Japanese \u202eAudio ',
            'language': 'Japanese',
            'headers': {
              'authorization': 'Bearer track-token',
              'Host': 'blocked.example',
            },
          },
        ],
        primaryUri: Uri.parse('https://video.example/main.m3u8'),
        primaryHeaders: const {
          'Authorization': 'Bearer video-token',
          'X-Video-Key': 'video-secret',
          'Referer': 'https://catalog.example/watch',
        },
        isAllowed: (uri) async {
          checked.add(uri);
          return uri.host != 'blocked.example';
        },
      );

      expect(tracks, hasLength(2));
      expect(checked.map((uri) => uri.host), [
        'video.example',
        'audio.example',
        'blocked.example',
      ]);
      expect(tracks.first.label, 'Japanese Audio');
      expect(tracks.first.language, 'jpn');
      expect(tracks.first.headers, {
        'authorization': 'Bearer track-token',
        'X-Video-Key': 'video-secret',
        'Referer': 'https://catalog.example/watch',
      });
      expect(tracks.last.language, 'spa');
      expect(tracks.last.headers, {
        'Referer': 'https://catalog.example/watch',
        'Authorization': 'Bearer audio-token',
        'X-Audio-Key': 'audio-secret',
      });
    },
  );

  test(
    'Seanime external audio is bounded and independently salvageable',
    () async {
      var validationCount = 0;
      final tracks = await normalizeSeanimeExternalAudioTracks(
        List.generate(
          12,
          (index) => {
            'url': 'https://audio$index.example/track.aac',
            'language': index.isEven ? 'English' : 'Japanese',
          },
        ),
        primaryUri: Uri.parse('https://video.example/main.mp4'),
        primaryHeaders: const {},
        isAllowed: (uri) async {
          validationCount++;
          if (uri.host == 'audio1.example') {
            throw const FormatException('blocked target');
          }
          return uri.host != 'audio2.example';
        },
      );

      expect(validationCount, seanimeMaximumExternalAudioTracks);
      expect(tracks, hasLength(6));
      expect(
        tracks.map((track) => track.uri.host),
        isNot(containsAll(['audio1.example', 'audio2.example'])),
      );
    },
  );

  test('HLS inspection detects language tracks used by the master', () {
    const playlist = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Japanese",LANGUAGE="jpn",URI="ja.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="eng",URI="en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="unused",NAME="French",LANGUAGE="fr",URI="fr.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="audio"
video-1080.m3u8
''';
    final master = Uri.parse('https://cdn.example.com/master.m3u8');
    final inspection = inspectHlsMasterPlaylist(playlist, master);

    expect(inspection.audioCapability, WebStreamAudioCapability.subAndDub);
    expect(inspection.hasAlternateAudio, isTrue);
    expect(inspection.audioLanguages, ['jpn', 'eng']);
    expect(inspection.variants.single.quality, '1080p');

    final expanded = expandHlsResultVariants(
      {
        'url': master.toString(),
        'title': 'Auto',
        'quality': 'Auto',
        'audioCapability': 'sub',
      },
      playlist,
      master,
    );
    expect(expanded, hasLength(1));
    expect(expanded.single['url'], master.toString());
    expect(expanded.single['audioCapability'], 'sub_and_dub');
    expect(expanded.single['audioLanguages'], ['jpn', 'eng']);
  });

  test('HLS keeps alternate audio masters beyond English and Japanese', () {
    const playlist = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Español",LANGUAGE="es-MX",URI="es.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Italiano",LANGUAGE="it",URI="it.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,AUDIO="audio"
video.m3u8
''';
    final master = Uri.parse('https://cdn.example.com/multi.m3u8');
    final inspection = inspectHlsMasterPlaylist(playlist, master);
    final expanded = expandHlsResultVariants(
      {'url': master.toString(), 'title': 'Auto'},
      playlist,
      master,
    );

    expect(inspection.audioCapability, WebStreamAudioCapability.unknown);
    expect(inspection.audioLanguages, ['spa', 'ita']);
    expect(expanded, hasLength(1));
    expect(expanded.single['url'], master.toString());
    expect(expanded.single['audioLanguages'], ['spa', 'ita']);
  });

  test('HLS inspection does not guess from unrelated audio groups', () {
    const playlist = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="unused",NAME="English",LANGUAGE="en",URI="en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="main"
video-720.m3u8
''';
    final inspection = inspectHlsMasterPlaylist(
      playlist,
      Uri.parse('https://cdn.example.com/master.m3u8'),
    );
    expect(inspection.audioCapability, WebStreamAudioCapability.unknown);
  });

  test('concrete-quality HLS results are still inspected for dual audio', () {
    expect(
      isHlsInspectionCandidate({
        'url': 'https://cdn.example.com/master-1080p.m3u8',
        'quality': '1080p',
      }),
      isTrue,
    );
    expect(
      isHlsInspectionCandidate({
        'url': 'https://cdn.example.com/video-1080p.mp4',
        'quality': '1080p',
      }),
      isFalse,
    );
    expect(
      isHlsInspectionCandidate({
        'url': 'https://cdn.example.com/signed-playback?id=fixture',
        'streamType': 'hls',
      }),
      isTrue,
      reason: 'an explicit provider type must preserve extensionless masters',
    );
    expect(
      isHlsInspectionCandidate({
        'url': 'https://cdn.example.com/signed-playback?id=fixture',
        'type': 'application/vnd.apple.mpegurl',
      }),
      isTrue,
    );
  });

  test('HLS metadata inspection deduplicates and bounds optional probes', () {
    final selected = selectHlsInspectionCandidates([
      {'url': 'https://cdn.example/one.m3u8', 'quality': 'Auto'},
      {
        'url': 'https://cdn.example/one.m3u8',
        'quality': '1080p',
        'streamType': 'hls',
      },
      {'url': 'https://cdn.example/two', 'streamType': 'hls'},
      {'url': 'https://cdn.example/three.m3u8'},
      {'url': 'https://cdn.example/four.m3u8'},
      {'url': 'https://cdn.example/five.m3u8'},
      {'url': 'http://127.0.0.1/private.m3u8'},
      {'url': 'https://cdn.example/not-hls.mp4'},
    ]);

    expect(selected, hasLength(4));
    expect(selected.map((item) => item['url']), [
      'https://cdn.example/one.m3u8',
      'https://cdn.example/two',
      'https://cdn.example/three.m3u8',
      'https://cdn.example/four.m3u8',
    ]);
    expect(
      selectHlsInspectionCandidates([
        {'url': 'https://cdn.example/one.m3u8'},
      ], maximum: 0),
      isEmpty,
    );
  });

  test('HLS inspection preserves same URL with distinct request headers', () {
    final selected = selectHlsInspectionCandidates([
      {
        'url': 'https://cdn.example/one.m3u8',
        'headers': {'Referer': 'https://first.example/'},
      },
      {
        'url': 'https://cdn.example/one.m3u8',
        'headers': {'Referer': 'https://second.example/'},
      },
    ]);

    expect(selected, hasLength(2));
  });

  test('HLS inspection preserves same URL with distinct audio sidecars', () {
    final selected = selectHlsInspectionCandidates([
      {
        'url': 'https://cdn.example/master.m3u8',
        'externalAudioTracks': [
          {'url': 'https://audio.example/japanese.aac', 'language': 'ja'},
        ],
      },
      {
        'url': 'https://cdn.example/master.m3u8',
        'externalAudioTracks': [
          {'url': 'https://audio.example/english.aac', 'language': 'en'},
        ],
      },
    ]);

    expect(selected, hasLength(2));
  });

  test(
    'optional HLS enrichment times out fail-open with raw streams',
    () async {
      final cancellationObserved = Completer<void>();
      final raw = [
        {
          'url': 'https://cdn.example/master.m3u8',
          'quality': 'Auto',
          'audioCapability': 'sub',
        },
      ];

      final result = await expandHlsVariantsWithinBudget(
        raw,
        null,
        budget: const Duration(milliseconds: 10),
        inspectItem: (_, cancellation) {
          cancellation!.addListener(() {
            if (!cancellationObserved.isCompleted) {
              cancellationObserved.complete();
            }
          });
          return Completer<List<Map<String, dynamic>>>().future;
        },
      );

      expect(result, raw);
      await expectLater(
        cancellationObserved.future.timeout(const Duration(seconds: 1)),
        completes,
      );
    },
  );

  test(
    'HLS enrichment replaces metadata while preserving audio sidecars',
    () async {
      final sidecars = [
        {'url': 'https://audio.example/english.aac', 'language': 'English'},
      ];
      final raw = [
        {
          'url': 'https://cdn.example/master.m3u8',
          'quality': 'Auto',
          'audioCapability': 'sub',
          'externalAudioTracks': sidecars,
        },
      ];

      final enriched = await expandHlsVariantsWithinBudget(
        raw,
        null,
        inspectItem: (item, _) async => [
          {
            ...item,
            'audioCapability': 'sub_and_dub',
            'audioLanguages': ['jpn', 'eng'],
          },
        ],
      );

      expect(enriched, hasLength(1));
      expect(enriched.single['audioCapability'], 'sub_and_dub');
      expect(enriched.single['externalAudioTracks'], sidecars);
    },
  );

  test('parent cancellation still stops optional HLS enrichment', () async {
    final parent = WebProviderCancellation();
    final pending = expandHlsVariantsWithinBudget(
      [
        {'url': 'https://cdn.example/master.m3u8'},
      ],
      parent,
      budget: const Duration(seconds: 1),
      inspectItem: (_, cancellation) => cancellation!.whenCancelled.then(
        (_) => throw const WebProviderSearchCancelled(),
      ),
    );

    await Future<void>.delayed(Duration.zero);
    parent.cancel();
    await expectLater(pending, throwsA(isA<WebProviderSearchCancelled>()));
  });

  test('HLS inspection retries one transient response and timeout', () async {
    var responseAttempts = 0;
    final status = await runHlsInspectionWithTransientRetry<int>(
      (_) async {
        responseAttempts++;
        return responseAttempts == 1 ? 503 : 200;
      },
      shouldRetryResult: (value) => value >= 500,
      retryDelay: Duration.zero,
    );
    expect(status, 200);
    expect(responseAttempts, 2);

    var timeoutAttempts = 0;
    final recovered = await runHlsInspectionWithTransientRetry<int>(
      (_) async {
        timeoutAttempts++;
        if (timeoutAttempts == 1) throw TimeoutException('fixture timeout');
        return 204;
      },
      shouldRetryResult: (_) => false,
      retryDelay: Duration.zero,
    );
    expect(recovered, 204);
    expect(timeoutAttempts, 2);
  });

  test(
    'HLS inspection does not retry permanent errors or cancellation',
    () async {
      var permanentAttempts = 0;
      await expectLater(
        runHlsInspectionWithTransientRetry<int>(
          (_) async {
            permanentAttempts++;
            throw const FormatException('invalid playlist request');
          },
          shouldRetryResult: (_) => false,
          retryDelay: Duration.zero,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(permanentAttempts, 1);

      final cancellation = WebProviderCancellation();
      var cancellationAttempts = 0;
      final pending = runHlsInspectionWithTransientRetry<int>(
        (_) async {
          cancellationAttempts++;
          return 503;
        },
        shouldRetryResult: (_) => true,
        cancellation: cancellation,
        retryDelay: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      await expectLater(pending, throwsA(isA<WebProviderSearchCancelled>()));
      expect(cancellationAttempts, 1);
    },
  );

  test('same URL does not turn exclusive Sub and Dub into dual audio', () {
    final merged = mergeDuplicateWebStreamItems([
      {
        'url': 'https://cdn.example.com/shared.m3u8',
        'quality': '1080p',
        'title': 'SUB / 1080p',
        'audioCapability': 'sub',
      },
      {
        'url': 'https://cdn.example.com/shared.m3u8',
        'quality': '1080p',
        'title': 'DUB / 1080p',
        'audioCapability': 'dub',
      },
    ]);

    expect(merged, hasLength(2));
    expect(merged.map((item) => item['audioCapability']).toSet(), {
      'sub',
      'dub',
    });
  });

  test('legacy same-URL Sub and Dub evidence remains mode-distinct', () {
    final merged = mergeDuplicateWebStreamItems([
      {
        'url': 'https://cdn.example.com/shared.mp4',
        'quality': '1080p',
        'subOrDub': 'sub',
      },
      {
        'url': 'https://cdn.example.com/shared.mp4',
        'quality': '1080p',
        'subOrDub': 'dub',
      },
    ]);

    expect(merged, hasLength(2));
  });

  test('duplicate independently dual-audio results still deduplicate', () {
    final merged = mergeDuplicateWebStreamItems([
      {
        'url': 'https://cdn.example.com/shared.m3u8',
        'quality': '1080p',
        'audioCapability': 'sub_and_dub',
        'audioLanguages': ['jpn'],
      },
      {
        'url': 'https://cdn.example.com/shared.m3u8',
        'quality': '1080p',
        'audioCapability': 'both',
        'audioLanguages': ['eng'],
      },
    ]);

    expect(merged, hasLength(1));
    expect(merged.single['audioCapability'], 'sub_and_dub');
    expect(merged.single['audioLanguages'], containsAll(['jpn', 'eng']));
  });

  test('same video with different external audio remains mode-distinct', () {
    final merged = mergeDuplicateWebStreamItems([
      {
        'url': 'https://cdn.example.com/shared.mp4',
        'quality': '1080p',
        'audioCapability': 'sub_and_dub',
        'externalAudioTracks': [
          {'url': 'https://audio.example/japanese.aac', 'language': 'ja'},
        ],
      },
      {
        'url': 'https://cdn.example.com/shared.mp4',
        'quality': '1080p',
        'audioCapability': 'sub_and_dub',
        'externalAudioTracks': [
          {'url': 'https://audio.example/english.aac', 'language': 'en'},
        ],
      },
      {
        'url': 'https://cdn.example.com/shared.mp4',
        'quality': '1080p',
        'audioCapability': 'both',
        'externalAudioTracks': [
          {'url': 'https://audio.example/english.aac', 'language': 'English'},
        ],
      },
    ]);

    expect(merged, hasLength(2));
    expect(
      merged
          .map((item) => (item['externalAudioTracks']! as List).single['url'])
          .toSet(),
      {
        'https://audio.example/japanese.aac',
        'https://audio.example/english.aac',
      },
    );
  });

  test('keeps all bounded media synonyms beyond the search-attempt cap', () {
    final episode = EpisodeReference(
      anilistMediaId: 1,
      title: 'Primary',
      titleEnglish: 'English',
      titleRomaji: 'Romaji',
      alternativeTitles: [
        'Alias 1',
        'Alias 2',
        'Alias 3',
        'Alias 4',
        'Site-specific alias',
      ],
      episode: 1,
    );

    expect(seanimeProviderSearchTitles(episode), hasLength(8));
    expect(
      seanimeProviderMediaSynonyms(episode),
      contains('Site-specific alias'),
    );
    expect(seanimeProviderMediaSynonyms(episode), isNot(contains('Primary')));
  });

  test('provider stream errors are actionable and hide Dart prefixes', () {
    final message = seanimeProviderFailureMessage(
      StateError(
        'NO_STREAM: The provider found the episode but returned no compatible stream.',
      ),
    );

    expect(
      isSeanimeProviderNoStream(StateError('NO_STREAM: unavailable')),
      isTrue,
    );
    expect(message, contains('provider found the episode'));
    expect(message, isNot(contains('Bad state')));
    expect(message, isNot(contains('NO_STREAM')));

    final workerMessage = seanimeProviderFailureMessage(
      StateError(
        'Bad state: NO_STREAM: The provider found the episode but returned no compatible stream.',
      ),
    );
    expect(workerMessage, contains('provider found the episode'));
    expect(workerMessage, isNot(contains('Bad state')));
    expect(workerMessage, isNot(contains('NO_STREAM')));
  });

  test('marker-backed no-match runtime failures use failure copy', () {
    final message = seanimeProviderFailureMessage(
      StateError(
        'NO_MATCH: private upstream detail '
        '[stage=search; reason=network]',
      ),
    );

    expect(message, contains('could not complete its search request'));
    expect(message, contains('could not reach its upstream service'));
    expect(message, isNot(contains('no matching title')));
    expect(message, isNot(contains('private upstream detail')));
  });

  test('provider failure markers expose only bounded stage and reason', () {
    final error = StateError(
      'Bad state: NO_STREAM: https://media.example/private?token=secret '
      '[stage=server; reason=http_403]',
    );
    final details = seanimeProviderFailureDetails(error);
    final message = seanimeProviderFailureMessage(error);

    expect(details?.stage, 'server');
    expect(details?.reason, 'http_403');
    expect(message, contains('HTTP 403'));
    expect(message, isNot(contains('token')));
    expect(message, isNot(contains('media.example')));
    expect(
      seanimeProviderFailureDetails(
        StateError('[stage=arbitrary; reason=raw_secret]'),
      ),
      isNull,
    );
  });

  test('compatibility failures expose each user-facing provider stage', () {
    const stages = [
      'search',
      'title_matching',
      'episode_lookup',
      'server_lookup',
      'stream_extraction',
    ];

    for (final stage in stages) {
      final error = StateError(
        'NO_STREAM: hidden upstream detail '
        '[stage=$stage; reason=empty_result]',
      );
      expect(seanimeProviderFailureDetails(error)?.stage, stage);
      expect(seanimeProviderFailureMessage(error), isNot(contains('hidden')));
    }
  });

  test('provider diagnostics include provenance without full URLs', () {
    final manifest = MarketplaceAddon.tryParse({
      'id': 'fixture-provider',
      'name': 'Fixture Provider',
      'manifestURI': 'https://code.example/providers/manifest.json?secret=one',
      'payloadURI': 'https://cdn.example/provider.js?secret=two',
      'version': '1.2.3',
      'type': 'onlinestream-provider',
      'language': 'javascript',
    }, repositoryUrl: 'https://catalog.example/main.json?secret=three')!;
    final provider = SeanimeJavascriptProvider(
      InstalledStreamingAddon(
        manifest: manifest,
        payload: 'class Provider {}',
        enabled: true,
        installedAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );

    final message = seanimeProviderDiagnosticMessage(
      provider,
      StateError(
        'NO_STREAM: token=hidden [stage=server; reason=empty_sources]',
      ),
    );

    expect(message, contains('provider=fixture-provider'));
    expect(message, contains('version=1.2.3'));
    expect(message, contains('repositoryHost=catalog.example'));
    expect(message, contains('executableHost=cdn.example'));
    expect(message, contains('stage=server'));
    expect(message, contains('reason=empty_sources'));
    expect(message, isNot(contains('hidden')));
    expect(message, isNot(contains('?')));
  });

  test('bounds Seanime request timeouts to the remaining runtime', () {
    final serializedAbortSignal = jsonDecode(
      jsonEncode({'__tetoTimeoutMilliseconds': 8000, 'aborted': false}),
    );
    expect(
      addonRuntimeAbortSignalTimeoutMilliseconds(serializedAbortSignal),
      8000,
    );
    expect(addonRequestTimeout(0.05), const Duration(milliseconds: 100));
    expect(addonRequestTimeout(2), const Duration(seconds: 2));
    expect(
      addonRequestTimeout(30, maximum: const Duration(seconds: 4)),
      const Duration(seconds: 4),
    );
    expect(
      addonRequestTimeout(null, maximum: const Duration(seconds: 3)),
      const Duration(seconds: 3),
    );
    expect(
      addonRequestTimeout(30, maximum: const Duration(seconds: 6)),
      const Duration(seconds: 6),
      reason: 'one dead host must leave time for provider fallback endpoints',
    );
    expect(
      addonRequestTimeout(
        10,
        abortSignal: const {'__tetoTimeoutMilliseconds': 500, 'aborted': false},
      ),
      const Duration(milliseconds: 500),
    );
    expect(
      addonRequestTimeout(
        null,
        abortSignal: const {'__tetoTimeoutMilliseconds': 8000},
        maximum: const Duration(seconds: 6),
      ),
      const Duration(seconds: 6),
      reason: 'the Dart hard ceiling remains authoritative',
    );
    expect(
      addonRequestTimeout(
        10,
        abortSignal: const {'__tetoTimeoutMilliseconds': 25},
      ),
      const Duration(milliseconds: 100),
    );
    expect(addonRuntimeAbortSignalIsAborted(const {'aborted': true}), isTrue);
  });

  test('bounds Seanime sleep without extending the runtime deadline', () {
    expect(
      addonSleepDuration(200, remaining: const Duration(seconds: 5)),
      const Duration(milliseconds: 200),
    );
    expect(
      addonSleepDuration(5000, remaining: const Duration(seconds: 5)),
      const Duration(seconds: 1),
    );
    expect(
      addonSleepDuration(500, remaining: const Duration(milliseconds: 75)),
      const Duration(milliseconds: 75),
    );
    expect(
      addonSleepDuration(
        double.infinity,
        remaining: const Duration(seconds: 5),
      ),
      Duration.zero,
    );
    expect(
      addonSleepDuration(-1, remaining: const Duration(seconds: 5)),
      Duration.zero,
    );
  });

  test(
    'runtime provides bounded timers and AbortSignal compatibility',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'timer-abort-signal-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture'], supportsDub: false}; }
              async search(input) {
                const binary = __tetoCreateFetchResponse({
                  status: 200,
                  body: 'legacy text projection',
                  bodyBase64: 'AP+AQQo=',
                  bodyByteLength: 5,
                });
                const bytes = Uint8Array.from(binary.body);
                if (bytes.length !== 5 || bytes[0] !== 0 ||
                    bytes[1] !== 255 || bytes[2] !== 128 ||
                    bytes[3] !== 65 || bytes[4] !== 10 ||
                    binary.text() !== 'legacy text projection' ||
                    String(binary.body) !== 'legacy text projection') {
                  throw new Error('binary FetchResponse bridge is invalid');
                }
                const signal = AbortSignal.timeout(8000);
                if (signal.__tetoTimeoutMilliseconds !== 8000 || signal.aborted) {
                  throw new Error('AbortSignal timeout bridge is invalid');
                }
                const controller = new AbortController();
                controller.abort();
                if (!controller.signal.aborted) {
                  throw new Error('AbortController bridge is invalid');
                }
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                let cancelledTimerFired = false;
                const cancelled = setTimeout(() => { cancelledTimerFired = true; }, 1);
                clearTimeout(cancelled);
                await new Promise(resolve => setTimeout(resolve, 20));
                if (cancelledTimerFired) throw new Error('clearTimeout failed');
                return {server, sources: [{url: 'https://cdn.example.com/timer.mp4'}]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 101,
          title: 'Timer Fixture',
          episode: 1,
        ),
      );

      expect(results.single.uri.path, '/timer.mp4');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'payload undefined TypeError remains retryable provider_error',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'payload-type-error-provider',
          payload: r'''
            class Provider {
              getSettings() { return {supportsDub: false}; }
              async search(input) {
                throw new TypeError("Cannot read properties of undefined (reading 'map')");
              }
            }
          ''',
        ),
      );

      Object? failure;
      try {
        await provider.streams(
          const EpisodeReference(
            anilistMediaId: 102,
            title: 'Payload Error Fixture',
            episode: 1,
          ),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(seanimeProviderFailureDetails(failure!)?.reason, 'provider_error');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'isolated JavaScript provider resolves a typed web stream',
    () async {
      final manifest = MarketplaceAddon.tryParse({
        'id': 'fixture-provider',
        'name': 'Fixture Provider',
        'description': 'Test provider',
        'author': 'TetoTV',
        'manifestURI': 'https://example.com/manifest.json',
        'payloadURI': 'https://example.com/provider.js',
        'version': '1.0.0',
        'type': 'onlinestream-provider',
        'language': 'javascript',
        'lang': 'en',
      }, repositoryUrl: 'https://example.com/catalog.json')!;
      final addon = InstalledStreamingAddon(
        manifest: manifest,
        payload: r'''
        class Provider {
          getSettings() { return {episodeServers: ['Fixture'], supportsDub: false}; }
          async search(input) { return [{id: 'show', title: input.query, subOrDub: 'sub'}]; }
          async findEpisodes(id) { return [{id: 'episode', number: 3, url: 'episode'}]; }
          async findEpisodeServer(episode, server) {
            return {server, headers: {Referer: 'https://example.com/'}, videoSources: [
              {url: 'https://cdn.example.com/episode-3.m3u8', quality: '1080p', subtitles: [
                {url: 'https://cdn.example.com/episode-3-en.vtt', language: 'English'},
                {url: 'https://cdn.example.com/episode-3-es.vtt', language: 'es-MX'}
              ]}
            ]};
          }
        }
      ''',
        enabled: true,
        installedAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      final results =
          await SeanimeJavascriptProvider(
            addon,
            preferredSubtitleLanguage: 'spa',
          ).streams(
            const EpisodeReference(
              anilistMediaId: 1,
              title: 'Fixture Anime',
              episode: 3,
            ),
          );

      expect(results, hasLength(1));
      expect(results.single.providerName, 'Fixture Provider');
      expect(results.single.uri.host, 'cdn.example.com');
      expect(results.single.quality, '1080p');
      expect(results.single.headers['Referer'], 'https://example.com/');
      expect(results.single.subtitleUri?.path, '/episode-3-es.vtt');
      expect(results.single.subtitleLanguage, 'es-MX');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'isolated provider carries explicit audio sidecars without mixing CC',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'external-audio-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Fixture'], supportsDub: false};
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                return {
                  server,
                  baseUrl: 'https://video.example/assets/',
                  headers: {
                    Referer: 'https://catalog.example/watch',
                    Authorization: 'Bearer video-token'
                  },
                  audioStreams: {items: [{
                    src: '/shared/spanish.aac',
                    name: 'Spanish',
                    locale: 'es-MX'
                  }]},
                  videoSources: [{
                    url: 'https://video.example/assets/episode.mp4',
                    audioTracks: [],
                    availableAudioTracks: [{
                      file: 'japanese.m4a',
                      label: 'Japanese',
                      lang: 'ja'
                    }],
                    tracks: [
                      {
                        kind: 'subtitles',
                        file: 'english.vtt',
                        language: 'English'
                      },
                      {
                        kind: 'audio',
                        url: 'https://audio.example/english.aac',
                        label: 'English Dub',
                        language: 'en',
                        headers: {'X-Audio-Key': 'audio-token'}
                      }
                    ]
                  }]
                };
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 77,
          title: 'External Audio Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      final stream = results.single;
      expect(stream.subtitleUri?.path, '/assets/english.vtt');
      expect(stream.externalAudioTracks, hasLength(3));
      expect(stream.externalAudioTracks.map((track) => track.language), [
        'jpn',
        'eng',
        'spa',
      ]);
      expect(
        stream.externalAudioTracks.first.headers['Authorization'],
        'Bearer video-token',
      );
      expect(stream.externalAudioTracks[1].headers, {
        'Referer': 'https://catalog.example/watch',
        'X-Audio-Key': 'audio-token',
      });
      expect(
        stream.externalAudioTracks.last.headers['Authorization'],
        'Bearer video-token',
      );
      expect(
        stream.effectiveAudioCapability,
        WebStreamAudioCapability.subAndDub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'provider subOrDub both remains visible in Sub and Dub filters',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'dual-audio-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Fixture'], supportsDub: false};
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'both'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/dual-audio.m3u8',
                  quality: '1080p'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 1,
          title: 'Dual Audio Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.subAndDub,
      );
      expect(results.single.supportsSubAudio, isTrue);
      expect(results.single.supportsDubAudio, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'resolved dual audio metadata wins over a generic source label',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'resolved-dual-audio-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Fixture'], supportsDub: false};
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                return {
                  server,
                  audioCapability: 'both',
                  videoSources: [{
                    url: 'https://cdn.example.com/resolved-dual.m3u8',
                    label: '1080p'
                  }]
                };
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 2,
          title: 'Resolved Dual Audio Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.subAndDub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'truthy string supportsDub runs both provider search modes',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'truthy-dub-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Fixture'], supportsDub: 'yes'};
              }
              async search(input) {
                return [{
                  id: input.dub ? 'show-dub' : 'show-sub',
                  title: input.query,
                  subOrDub: input.dub ? 'dub' : 'sub'
                }];
              }
              async findEpisodes(id) {
                return [{id, number: 1, url: id}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/' + episode.url + '.mp4',
                  quality: '1080p'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 3,
          title: 'Truthy Dub Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(2));
      expect(results.map((item) => item.effectiveAudioCapability).toSet(), {
        WebStreamAudioCapability.sub,
        WebStreamAudioCapability.dub,
      });
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'explicit supportsDubAudio setting runs both provider search modes',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'explicit-dub-audio-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Fixture'], supportsDubAudio: true};
              }
              async search(input) {
                return [{
                  id: input.dub ? 'show-dub' : 'show-sub',
                  title: input.query,
                  subOrDub: input.dub ? 'dub' : 'sub'
                }];
              }
              async findEpisodes(id) {
                return [{id, number: 1, url: id}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/' + episode.url + '.mp4',
                  quality: '1080p'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 31,
          title: 'Explicit Dub Audio Fixture',
          episode: 1,
        ),
      );

      expect(results.map((item) => item.effectiveAudioCapability).toSet(), {
        WebStreamAudioCapability.sub,
        WebStreamAudioCapability.dub,
      });
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'undeclared Dub support gets one evidence-gated best-alias probe',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'undeclared-dub-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture']}; }
              async search(input) {
                if (input.dub && input.query !== 'Undeclared Dub Fixture') {
                  throw new Error('Dub probe used more than the best alias');
                }
                return [{
                  id: input.dub ? 'show-dub' : 'show-sub',
                  title: input.query,
                  subOrDub: input.dub ? 'dub' : 'sub'
                }];
              }
              async findEpisodes(id) {
                return [{id, number: 1, url: id}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/' + episode.url + '.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 32,
          title: 'Undeclared Dub Fixture',
          titleRomaji: 'Unused second alias',
          episode: 1,
        ),
      );

      expect(results, hasLength(2));
      expect(results.map((item) => item.effectiveAudioCapability).toSet(), {
        WebStreamAudioCapability.sub,
        WebStreamAudioCapability.dub,
      });
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'undeclared probe never labels a provider that ignores the Dub flag',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'ignored-dub-flag-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture']}; }
              async search(input) {
                return [{id: 'show', title: input.query}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/same-sub-feed.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 34,
          title: 'Ignored Dub Flag Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.sub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'an explicit supportsDub false declaration disables compatibility probing',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'explicit-no-dub-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Fixture'], supportsDub: false};
              }
              async search(input) {
                return [{
                  id: input.dub ? 'unexpected-dub' : 'show-sub',
                  title: input.query,
                  subOrDub: input.dub ? 'dub' : 'sub'
                }];
              }
              async findEpisodes(id) {
                return [{id, number: 1, url: id}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/' + episode.url + '.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 35,
          title: 'Explicit No Dub Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.uri.path, endsWith('/show-sub.mp4'));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.sub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'native-only provider result matches the catalog native title',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'native-title-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture']}; }
              async search(input) {
                if (input.query !== '葬送のフリーレン') return [];
                return [{id: 'native-show', title: '葬送のフリーレン'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1, title: 'Episode 1'}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/native-title.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 154587,
          title: 'Frieren: Beyond Journey’s End',
          titleEnglish: 'Frieren: Beyond Journey’s End',
          titleRomaji: 'Sousou no Frieren',
          titleNative: '葬送のフリーレン',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.matchedSeriesTitle, '葬送のフリーレン');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'passes a trusted absolute episode offset to Seanime media options',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'absolute-season-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture'], supportsDub: false}; }
              async search(input) {
                if (input.media.absoluteSeasonOffset !== 24) return [];
                return [{id: 'named-sequel', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/named-sequel.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 36,
          title: 'Example: New Arc',
          episode: 1,
          absoluteSeasonOffset: 24,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.uri.path, endsWith('/named-sequel.mp4'));
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'explicit Dub server overrides a stale Sub search label',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'server-labelled-dub-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['SUB', 'DUB'], supportsDub: false};
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/' + server.toLowerCase() + '.mp4',
                  quality: '1080p'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 4,
          title: 'Server Dub Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(2));
      expect(results.map((item) => item.effectiveAudioCapability).toSet(), {
        WebStreamAudioCapability.sub,
        WebStreamAudioCapability.dub,
      });
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'resolved fallback server overrides the requested AnimeGG-style mode',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'resolved-fallback-server-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {
                  episodeServers: ['GG-SUB', 'GG-DUB'],
                  supportsDub: true
                };
              }
              async search(input) {
                return [{
                  id: 'show',
                  title: input.query,
                  subOrDub: input.dub ? 'dub' : 'sub'
                }];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                if (server !== 'GG-DUB') return null;
                return {
                  server: 'GG-SUB',
                  videoSources: [{
                    url: 'https://cdn.example.com/fallback-sub.mp4',
                    quality: '1080p'
                  }]
                };
              }
            }
          ''',
        ),
        preferredAudio: PlaybackAudioPreference.dub,
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 41,
          title: 'Fallback Server Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.sub,
      );
      expect(results.single.title, startsWith('GG-SUB'));
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'aggregate both result keeps locale-labelled child streams exclusive',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'locale-labelled-audio-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Default'], supportsDub: true};
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'both'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                return {
                  server,
                  videoSources: [
                    {
                      url: 'https://cdn.example.com/japanese.m3u8',
                      quality: 'ja-JP (No Subs)'
                    },
                    {
                      url: 'https://cdn.example.com/english.m3u8',
                      quality: 'en-US'
                    }
                  ]
                };
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 42,
          title: 'Locale Audio Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(2));
      expect(results.map((item) => item.effectiveAudioCapability).toSet(), {
        WebStreamAudioCapability.sub,
        WebStreamAudioCapability.dub,
      });
      expect(
        results.expand((item) => item.audioLanguages).toSet(),
        containsAll(<String>{'jpn', 'eng'}),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'Dual Audio server label produces one dual-audio result',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'server-labelled-dual-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {episodeServers: ['Dual Audio'], supportsDub: false};
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode', number: 1, url: 'episode'}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/dual.mp4',
                  quality: '1080p'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 5,
          title: 'Server Dual Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.subAndDub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'all failed JavaScript search attempts are runtime failures',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'failed-search-provider',
          payload: r'''
            class Provider {
              getSettings() { return {supportsDub: false}; }
              async search(input) {
                if (typeof input === 'string') {
                  return [{id: 'must-not-run', title: input}];
                }
                throw new Error('network connection failed');
              }
              async findEpisodes(id) { return []; }
              async findEpisodeServer(episode, server) { return null; }
            }
          ''',
        ),
      );

      Object? failure;
      try {
        await provider.streams(
          const EpisodeReference(
            anilistMediaId: 2,
            title: 'Private query must not escape',
            episode: 1,
          ),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(isSeanimeProviderNoMatch(failure!), isFalse);
      expect(seanimeProviderFailureDetails(failure)?.stage, 'search');
      expect(seanimeProviderFailureDetails(failure)?.reason, 'network');
      expect(
        seanimeProviderFailureMessage(failure),
        contains('could not complete its title search'),
      );
      expect(
        seanimeProviderFailureMessage(failure),
        isNot(contains('Private query must not escape')),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'JavaScript provider rejects mismatched seasons even with a claimed ID',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'wrong-season-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) {
                return [{id: 'wrong', anilistId: 77, title: 'Example Season 2', year: 2024}];
              }
              async findEpisodes(id) { return [{id: 'episode-1', number: 1}]; }
              async findEpisodeServer(episode, server) {
                return {sources: [{url: 'https://cdn.example.com/wrong.m3u8'}]};
              }
            }
          ''',
        ),
      );

      await expectLater(
        provider.streams(
          const EpisodeReference(
            anilistMediaId: 77,
            title: 'Example',
            titleEnglish: 'Example',
            titleRomaji: 'Example',
            year: 2024,
            episode: 1,
          ),
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                isSeanimeProviderNoMatch(error) &&
                seanimeProviderFailureDetails(error)?.stage == 'title_matching',
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'JavaScript provider rejects an explicitly mismatched catalog year',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'wrong-year-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) {
                return [{id: 'wrong', title: 'Remake Example', startDate: {year: 2004}}];
              }
              async findEpisodes(id) { return [{id: 'episode-1', number: 1}]; }
              async findEpisodeServer(episode, server) {
                return {sources: [{url: 'https://cdn.example.com/wrong.m3u8'}]};
              }
            }
          ''',
        ),
      );

      await expectLater(
        provider.streams(
          const EpisodeReference(
            anilistMediaId: 88,
            title: 'Remake Example',
            titleEnglish: 'Remake Example',
            titleRomaji: 'Remake Example',
            year: 2024,
            episode: 1,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'exact title alone cannot cross a one-year catalog boundary',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'one-year-remake-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) {
                return [{id: 'wrong-year', title: input.query, year: 2023}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/wrong-year.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      await expectLater(
        provider.streams(
          const EpisodeReference(
            anilistMediaId: 89,
            title: 'One Year Remake Fixture',
            year: 2024,
            episode: 1,
          ),
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                isSeanimeProviderNoMatch(error) &&
                seanimeProviderFailureDetails(error)?.stage == 'title_matching',
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'explicit Dub metadata can corroborate a one-year release difference',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'dub-release-year-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) {
                return [{
                  id: 'dub-release',
                  title: input.query,
                  year: 2025,
                  subOrDub: 'dub'
                }];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/dub-release-year.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 90,
          title: 'Dub Release Year Fixture',
          year: 2024,
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.dub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'numbered season survives a provider franchise-year mismatch',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'franchise-year-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture']}; }
              async search(input) {
                return [{
                  id: 'season-four',
                  title: 'My Hero Academia Season 4',
                  year: 2016
                }];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1, title: 'Episode 1'}];
              }
              async findEpisodeServer(episode, server) {
                return {server, videoSources: [{
                  url: 'https://cdn.example.com/season-four-episode-one.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 38408,
          title: 'My Hero Academia Season 4',
          titleEnglish: 'My Hero Academia Season 4',
          titleRomaji: 'Boku no Hero Academia 4th Season',
          year: 2019,
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.matchedSeriesTitle, 'My Hero Academia Season 4');
      expect(results.single.matchedEpisodeNumber, 1);
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'bare aliases cannot bypass a numbered catalog season',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'bare-season-alias-provider',
          payload: r'''
            class Provider {
              getSettings() { return {supportsDub: false}; }
              async search(input) {
                return [{id: 'bare-show', title: 'Show'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/wrong-season.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      await expectLater(
        provider.streams(
          const EpisodeReference(
            anilistMediaId: 4004,
            title: 'Show Season 4',
            titleEnglish: 'Show Season 4',
            titleRomaji: 'Show 4th Season',
            titleNative: 'ショー',
            alternativeTitles: ['Show'],
            episode: 1,
          ),
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                isSeanimeProviderNoMatch(error) &&
                seanimeProviderFailureDetails(error)?.stage == 'title_matching',
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'provider slug can corroborate a bare title for the requested season',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'slug-season-provider',
          payload: r'''
            class Provider {
              getSettings() { return {supportsDub: false}; }
              async search(input) {
                return [{id: 'show-season-4', slug: 'show-season-4', title: 'Show'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{url: 'https://cdn.example.com/season-4.mp4'}]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 4004,
          title: 'Show Season 4',
          titleEnglish: 'Show Season 4',
          alternativeTitles: ['Show'],
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.uri.path, endsWith('/season-4.mp4'));
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'successful legacy empty search remains a genuine no-match',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'legacy-empty-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) {
                if (typeof input === 'object') throw new TypeError('expected string');
                return [];
              }
              async findEpisodes(id) { return []; }
              async findEpisodeServer(episode, server) { return null; }
            }
          ''',
        ),
      );

      Object? failure;
      try {
        await provider.streams(
          const EpisodeReference(
            anilistMediaId: 3,
            title: 'Legacy no match',
            episode: 1,
          ),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(isSeanimeProviderNoMatch(failure!), isTrue);
      expect(seanimeProviderFailureDetails(failure)?.reason, 'empty_result');
      expect(
        seanimeProviderFailureMessage(failure),
        contains('no matching title'),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'canonical clean-empty aliases get one bounded legacy string probe',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'canonical-empty-provider',
          payload: r'''
            class Provider {
              getSettings() { return {supportsDub: false}; }
              async search(input) {
                if (typeof input === 'object') return [];
                return [{id: 'legacy-only', title: input}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/should-not-be-returned.mp4'
                }]};
              }
            }
          ''',
        ),
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 33,
          title: 'Canonical empty fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.matchedSeriesTitle, 'Canonical empty fixture');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'legacy clean-empty Sub does not consume the bounded Dub probe',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'legacy-dub-only-provider',
          payload: r'''
            class Provider {
              getSettings() { return {supportsDub: true}; }
              async search(input, options) {
                if (typeof input === 'object') return [];
                if (!options || !options.dub) return [];
                return [{
                  id: 'legacy-dub',
                  title: input,
                  subOrDub: 'dub'
                }];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/legacy-dub-only.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 36,
          title: 'Legacy Dub Only Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.dub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'community provider no-result phrases remain genuine no-matches',
    () async {
      for (final message in [
        'No anime found',
        'No results found',
        'No episodes found',
      ]) {
        final provider = SeanimeJavascriptProvider(
          _javascriptAddon(
            id: 'empty-phrase-provider',
            payload:
                '''
              class Provider {
                getSettings() { return {}; }
                async search(input) { throw new Error(${jsonEncode(message)}); }
                async findEpisodes(id) { return []; }
                async findEpisodeServer(episode, server) { return null; }
              }
            ''',
          ),
        );

        Object? failure;
        try {
          await provider.streams(
            const EpisodeReference(
              anilistMediaId: 6,
              title: 'No match fixture',
              episode: 1,
            ),
          );
        } catch (error) {
          failure = error;
        }

        expect(failure, isNotNull, reason: message);
        expect(isSeanimeProviderNoMatch(failure!), isTrue, reason: message);
        expect(
          seanimeProviderFailureDetails(failure)?.reason,
          'empty_result',
          reason: message,
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'missing configured episode server is source availability, not runtime failure',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'missing-server-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture']}; }
              async search(input) {
                return [{id: 'show', title: 'Missing server fixture'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1}];
              }
              async findEpisodeServer(episode, server) {
                throw new Error('ERROR: server not found');
              }
            }
          ''',
        ),
      );

      Object? failure;
      try {
        await provider.streams(
          const EpisodeReference(
            anilistMediaId: 7,
            title: 'Missing server fixture',
            episode: 1,
          ),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(seanimeProviderFailureDetails(failure!)?.stage, 'server_lookup');
      expect(seanimeProviderFailureDetails(failure)?.reason, 'empty_sources');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'finds episodes beyond the old 200-item compatibility prefix',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'long-episode-list-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture'], supportsDub: false}; }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) {
                return Array.from({length: 600}, (_, index) => ({
                  id: 'episode-' + (index + 1),
                  number: index + 1,
                }));
              }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/' + episode.id + '.mp4'
                }]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 500,
          title: 'Long Episode Fixture',
          episode: 500,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.uri.path, endsWith('/episode-500.mp4'));
      expect(results.single.matchedEpisodeNumber, 500);
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'continues past six configured servers to find a working server',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'long-server-list-provider',
          payload: r'''
            class Provider {
              getSettings() {
                return {
                  episodeServers: Array.from(
                    {length: 8}, (_, index) => 'Server ' + (index + 1)
                  ),
                  supportsDub: false
                };
              }
              async search(input) {
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) { return [{id: 'episode-1', number: 1}]; }
              async findEpisodeServer(episode, server) {
                if (server !== 'Server 8') return null;
                return {sources: [{url: 'https://cdn.example.com/server-8.mp4'}]};
              }
            }
          ''',
        ),
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 8,
          title: 'Server List Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(results.single.uri.path, endsWith('/server-8.mp4'));
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'preferred Dub runs first and explicit dual audio skips duplicate mode work',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'preferred-dub-provider',
          payload: r'''
            class Provider {
              searchCalls = 0;
              getSettings() { return {episodeServers: ['Dual Audio'], supportsDub: true}; }
              async search(input) {
                this.searchCalls += 1;
                if (!input.dub || !input.opts.dub || this.searchCalls !== 1) {
                  throw new Error('unexpected duplicate or Sub-first search');
                }
                return [{id: 'show', title: input.query, subOrDub: 'both'}];
              }
              async findEpisodes(id) { return [{id: 'episode-1', number: 1}]; }
              async findEpisodeServer(episode, server) {
                return {sources: [{
                  url: 'https://cdn.example.com/dual.m3u8',
                  audioCapability: 'both'
                }]};
              }
            }
          ''',
        ),
        preferredAudio: PlaybackAudioPreference.dub,
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 9,
          title: 'Preferred Dub Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.subAndDub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'preferred Sub does not perform an undeclared Dub compatibility probe',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'preferred-sub-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['Fixture']}; }
              async search(input) {
                if (input.dub) throw new Error('unexpected Dub probe');
                return [{id: 'show', title: input.query, subOrDub: 'sub'}];
              }
              async findEpisodes(id) { return [{id: 'episode-1', number: 1}]; }
              async findEpisodeServer(episode, server) {
                return {sources: [{url: 'https://cdn.example.com/sub.mp4'}]};
              }
            }
          ''',
        ),
        preferredAudio: PlaybackAudioPreference.sub,
        validateResultTarget: (_) async {},
      );

      final results = await provider.streams(
        const EpisodeReference(
          anilistMediaId: 10,
          title: 'Preferred Sub Fixture',
          episode: 1,
        ),
      );

      expect(results, hasLength(1));
      expect(
        results.single.effectiveAudioCapability,
        WebStreamAudioCapability.sub,
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'all failed episode lookups are runtime failures',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'failed-episode-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) {
                return [{id: 'show', title: 'Episode lookup fixture'}];
              }
              async findEpisodes(id) { throw new Error('network connection failed'); }
              async findEpisodeServer(episode, server) { return null; }
            }
          ''',
        ),
      );

      Object? failure;
      try {
        await provider.streams(
          const EpisodeReference(
            anilistMediaId: 4,
            title: 'Episode lookup fixture',
            episode: 2,
          ),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(isSeanimeProviderNoMatch(failure!), isFalse);
      expect(seanimeProviderFailureDetails(failure)?.stage, 'episodes');
      expect(seanimeProviderFailureDetails(failure)?.reason, 'network');
      expect(
        seanimeProviderFailureMessage(failure),
        contains('could not load its episodes'),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );

  test(
    'a resolved server keeps an empty result at stream extraction stage',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'multi-server-stage-provider',
          payload: r'''
            class Provider {
              getSettings() { return {episodeServers: ['ok', 'broken']}; }
              async search(input) {
                return [{id: 'show', title: 'Multi server fixture'}];
              }
              async findEpisodes(id) {
                return [{id: 'episode-1', number: 1, title: 'Episode 1'}];
              }
              async findEpisodeServer(episode, server) {
                if (String(server).includes('broken')) {
                  throw new Error('network connection failed');
                }
                return {sources: []};
              }
            }
          ''',
        ),
      );

      Object? failure;
      try {
        await provider.streams(
          const EpisodeReference(
            anilistMediaId: 5,
            title: 'Multi server fixture',
            episode: 1,
          ),
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(
        seanimeProviderFailureDetails(failure!)?.stage,
        'stream_extraction',
      );
      expect(seanimeProviderFailureDetails(failure)?.reason, 'empty_result');
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.isWindows
        ? 'flutter_js loads its bridge from the packaged Windows app.'
        : false,
  );
}

InstalledStreamingAddon _javascriptAddon({
  required String id,
  required String payload,
}) {
  final manifest = MarketplaceAddon.tryParse({
    'id': id,
    'name': id,
    'manifestURI': 'https://example.com/$id/manifest.json',
    'payloadURI': 'https://example.com/$id/provider.js',
    'type': 'onlinestream-provider',
    'language': 'javascript',
  }, repositoryUrl: 'https://example.com/catalog.json')!;
  return InstalledStreamingAddon(
    manifest: manifest,
    payload: payload,
    enabled: true,
    installedAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
}
