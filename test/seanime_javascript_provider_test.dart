import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
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
  });

  test('duplicate Sub and Dub provider results merge into dual audio', () {
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

    expect(merged, hasLength(1));
    expect(merged.single['audioCapability'], 'sub_and_dub');
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
                {url: 'https://cdn.example.com/episode-3-en.vtt', language: 'English'}
              ]}
            ]};
          }
        }
      ''',
        enabled: true,
        installedAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      final results = await SeanimeJavascriptProvider(addon).streams(
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
      expect(results.single.subtitleLanguage, 'English');
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
    'all failed JavaScript search attempts are runtime failures',
    () async {
      final provider = SeanimeJavascriptProvider(
        _javascriptAddon(
          id: 'failed-search-provider',
          payload: r'''
            class Provider {
              getSettings() { return {}; }
              async search(input) { throw new Error('network connection failed'); }
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
