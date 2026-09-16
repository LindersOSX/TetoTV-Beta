import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_web_provider.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

const _episode = EpisodeReference(
  anilistMediaId: 1,
  title: 'Example Show Season 2',
  episode: 2,
  titleRomaji: 'Example Romaji Season 2',
  year: 2026,
);

class _Runtime {
  final calls = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> search = [
    {'url': '/show', 'title': 'Example Show Season 2'},
  ];
  Map<String, dynamic> details = {
    'url': '/show',
    'title': 'Example Show Season 2',
  };
  List<Map<String, dynamic>> seasons = [
    {
      'url': '/show/season-2',
      'title': 'Example Show Season 2',
      'seasonNumber': 2.0,
    },
  ];
  List<Map<String, dynamic>> chapters = [
    {'url': '/show/ep10', 'name': 'Episode 10', 'number': 10.0},
    {'url': '/show/ep2', 'name': 'Episode 2', 'number': 2.0},
  ];
  List<Map<String, dynamic>> videos = [
    {
      'url': 'https://video.example/ep2.m3u8',
      'quality': '1080p',
      'headers': {'Referer': 'https://source.example'},
      'subtitleTracks': [
        {'url': 'https://video.example/es.vtt', 'lang': 'Spanish'},
        {'url': 'https://video.example/en.vtt', 'lang': 'English'},
      ],
      'audioTracks': [],
    },
  ];

  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    calls.add(request);
    return switch (request['operation']) {
      'search' => {'items': search, 'hasNextPage': false},
      'details' => {'item': details},
      'seasons' => {'seasons': seasons},
      'episodes' => {'chapters': chapters},
      'videos' => {'videos': videos},
      _ => throw StateError('Unexpected operation'),
    };
  }

  AniyomiWebProvider provider({
    AniyomiRuntimeRequest? callback,
    AniyomiRuntimeRequestStarter? starter,
    Future<void> Function(Uri)? validate,
    Duration runtimeLimit = const Duration(seconds: 1),
    String preferred = 'eng',
    PlaybackAudioPreference preferredAudio = PlaybackAudioPreference.dub,
    String preferredAudioLanguage = 'auto',
    AniyomiProviderDiagnostic? onDiagnostic,
  }) => AniyomiWebProvider(
    extensionId: 'example-extension',
    sourceId: '9223372036854775807',
    name: 'Example native source',
    request: callback ?? request,
    startRequest: starter,
    validateResultTarget: validate ?? (_) async {},
    runtimeLimit: runtimeLimit,
    preferredSubtitleLanguage: preferred,
    preferredAudio: preferredAudio,
    preferredAudioLanguage: preferredAudioLanguage,
    onDiagnostic: onDiagnostic,
  );
}

void main() {
  test(
    'accepts nested generic maps returned by Android StandardMessageCodec',
    () async {
      final runtime = _Runtime();
      Object? codecShape(Object? value) {
        if (value is List) return value.map(codecShape).toList();
        if (value is Map) {
          return <Object?, Object?>{
            for (final entry in value.entries)
              entry.key: codecShape(entry.value),
          };
        }
        return value;
      }

      final result = await runtime
          .provider(
            callback: (arguments) async {
              final response = await runtime.request(arguments);
              return Map<String, dynamic>.from(codecShape(response) as Map);
            },
          )
          .streams(_episode);
      expect(result, hasLength(1));
      expect(result.single.subtitleLanguage, 'eng');
    },
  );

  test(
    'routes exact title/episode through agreed operations with exact source ID',
    () async {
      final runtime = _Runtime();
      final result = await runtime.provider().streams(_episode);
      expect(runtime.calls.map((call) => call['operation']), [
        'search',
        'details',
        'episodes',
        'videos',
      ]);
      for (final call in runtime.calls) {
        expect(call['sourceId'], '9223372036854775807');
        expect(call['extensionId'], 'example-extension');
        expect(call['timeoutMs'], inInclusiveRange(1, 10000));
        expect(call.containsKey('op'), isFalse);
      }
      final episodeCall = runtime.calls.singleWhere(
        (call) => call['operation'] == 'episodes',
      );
      expect(episodeCall['targetEpisode'], 2);
      expect(episodeCall['targetSeason'], 2);
      expect(runtime.calls.last['url'], '/show/ep2');
      expect(runtime.calls.last['resolveLazyHosters'], isTrue);
      expect(runtime.calls.last['lazyHosterLimit'], 8);
      expect(
        result.single.providerId,
        'aniyomi:anime:source:9223372036854775807',
      );
      expect(result.single.matchedEpisodeNumber, 2);
      expect(result.single.matchedSeasonNumber, 2);
      expect(result.single.matchedSeriesTitle, 'Example Show Season 2');
      expect(result.single.headers['Referer'], 'https://source.example');
      expect(result.single.quality, '1080p');
    },
  );

  test(
    'selects English captions without claiming English or dubbed audio',
    () async {
      final result = await _Runtime().provider().streams(_episode);
      expect(result.single.subtitleLanguage, 'eng');
      expect(result.single.subtitleUri!.path, '/en.vtt');
      expect(result.single.audioCapability, WebStreamAudioCapability.unknown);
      expect(result.single.audioLanguages, isEmpty);
      expect(result.single.isDubbed, isFalse);
    },
  );

  test('preserves only explicit Sub and Dub declarations in video labels', () {
    expect(
      aniyomiDeclaredAudioCapability('[SUBBED] Server:1080p'),
      WebStreamAudioCapability.sub,
    );
    expect(
      aniyomiDeclaredAudioCapability('[DUBBED] Server:1080p'),
      WebStreamAudioCapability.dub,
    );
    expect(
      aniyomiDeclaredAudioCapability('Sub / Dub 720p'),
      WebStreamAudioCapability.subAndDub,
    );
    for (final label in [
      null,
      '1080p',
      'English',
      'English subtitles',
      'Dubai server 720p',
    ]) {
      expect(
        aniyomiDeclaredAudioCapability(label),
        WebStreamAudioCapability.unknown,
        reason: '$label',
      );
    }
  });

  test('returned videos carry explicit provider audio declarations', () async {
    final runtime = _Runtime()
      ..videos = [
        {
          'url': 'https://video.example/sub.m3u8',
          'quality': '[SUBBED] Server:1080p',
        },
        {
          'url': 'https://video.example/dub.m3u8',
          'quality': '[DUBBED] Server:1080p',
        },
      ];

    final result = await runtime.provider().streams(_episode);

    expect(result.map((stream) => stream.effectiveAudioCapability), [
      WebStreamAudioCapability.sub,
      WebStreamAudioCapability.dub,
    ]);
  });

  test(
    'respects preferred subtitle language and falls back only to English',
    () async {
      final runtime = _Runtime();
      final preferred = await runtime
          .provider(preferred: 'spa')
          .streams(_episode);
      expect(preferred.single.subtitleLanguage, 'spa');
      final fallback = await runtime
          .provider(preferred: 'ita')
          .streams(_episode);
      expect(fallback.single.subtitleLanguage, 'eng');
      runtime.videos.single['subtitleTracks'] = [
        {'url': 'https://video.example/es.vtt', 'lang': 'Spanish'},
      ];
      final unknown = await runtime.provider().streams(_episode);
      expect(unknown.single.subtitleUri, isNull);
    },
  );

  test(
    'alternative catalog title matches exactly with case and whitespace normalization',
    () async {
      final runtime = _Runtime()
        ..search = [
          {'url': '/show', 'title': ' EXAMPLE Romaji Season 2 '},
        ]
        ..details = {'url': '/show', 'title': 'Example Romaji Season 2'};
      expect(await runtime.provider().streams(_episode), hasLength(1));
    },
  );

  test('title identity tolerates provider punctuation differences', () async {
    final runtime = _Runtime()
      ..search = [
        {'url': '/show', 'title': 'Example; Show — Season 2'},
      ]
      ..details = {'url': '/show', 'title': 'Example Show - Season 2'};

    expect(await runtime.provider().streams(_episode), hasLength(1));
  });

  test('accepts only known trailing catalog audio labels', () async {
    for (final decorated in [
      'Example Show Season 2 (Dub)',
      'Example Show Season 2 [English Dub]',
      'Example Show Season 2 — Dual Audio',
      'Example Show Season 2 [English] [Dubbed]',
    ]) {
      final runtime = _Runtime()
        ..search = [
          {'url': '/show', 'title': decorated},
        ]
        ..details = {'url': 'https://provider.example/show', 'title': '別名'};
      expect(
        await runtime.provider().streams(_episode),
        hasLength(1),
        reason: decorated,
      );
    }
  });

  test(
    'selects split base and Dub catalog variants from the audio preference',
    () async {
      for (final fixture
          in <
            ({
              PlaybackAudioPreference preference,
              String url,
              String title,
              WebStreamAudioCapability capability,
            })
          >[
            (
              preference: PlaybackAudioPreference.sub,
              url: '/show/sub',
              title: 'Example Show Season 2',
              capability: WebStreamAudioCapability.unknown,
            ),
            (
              preference: PlaybackAudioPreference.dub,
              url: '/show/dub',
              title: 'Example Show Season 2 (Dub)',
              capability: WebStreamAudioCapability.dub,
            ),
          ]) {
        final runtime = _Runtime()
          ..search = [
            {'url': '/show/sub', 'title': 'Example Show Season 2'},
            {'url': '/show/dub', 'title': 'Example Show Season 2 (Dub)'},
          ]
          ..details = {'url': fixture.url, 'title': fixture.title};

        final result = await runtime
            .provider(preferredAudio: fixture.preference)
            .streams(_episode);

        expect(result, hasLength(1));
        expect(result.single.audioCapability, fixture.capability);
        expect(
          runtime.calls.singleWhere(
            (call) => call['operation'] == 'details',
          )['url'],
          fixture.url,
        );
        expect(
          runtime.calls.where((call) => call['operation'] == 'search'),
          hasLength(1),
          reason: 'A split catalog response must not trigger duplicate search.',
        );
      }
    },
  );

  test(
    'KAA Chainsmoker Cat cut label matches exactly before native aliases',
    () async {
      const episode = EpisodeReference(
        anilistMediaId: 207141,
        title: 'Chainsmoker Cat',
        titleEnglish: 'Chainsmoker Cat',
        titleRomaji: 'Yani Neko',
        titleNative: 'ヤニねこ',
        alternativeTitles: ['แมวสาวอมควัน', '尼古喵喵'],
        episode: 2,
        year: 2026,
      );
      final runtime = _Runtime()
        ..details = {
          'url': '/yani-neko-f2ca',
          'title': 'Yani Neko  (Uncensored)',
        };
      final diagnostics = <Map<String, Object?>>[];
      final result = await runtime
          .provider(
            onDiagnostic: diagnostics.add,
            callback: (request) async {
              if (request['operation'] != 'search') {
                return runtime.request(request);
              }
              runtime.calls.add(request);
              // Exact live API title/locator shapes: the English query returns one
              // row, while romaji also returns the distinct mini-anime. The source's
              // default preference exposes `title`, not its alternate `title_en`.
              if (request['query'] == 'Chainsmoker Cat') {
                return {
                  'items': [
                    {
                      'url': '/yani-neko-f2ca',
                      'title': 'Yani Neko  (Uncensored)',
                    },
                  ],
                };
              }
              if (request['query'] == 'Yani Neko') {
                return {
                  'items': [
                    {
                      'url': '/yani-neko-f2ca',
                      'title': 'Yani Neko  (Uncensored)',
                    },
                    {
                      'url': '/yani-neko-mini-anime-d7d0',
                      'title': 'Yani Neko Mini Anime',
                    },
                  ],
                };
              }
              throw const AniyomiFailure(
                'extension_execution_failed',
                stage: 'source_search',
                cause: 'invalid_input',
              );
            },
          )
          .streams(episode);
      expect(result, hasLength(1));
      expect(
        runtime.calls
            .where((call) => call['operation'] == 'search')
            .map((call) => call['query']),
        ['Chainsmoker Cat'],
      );
      expect(
        runtime.calls.singleWhere(
          (call) => call['operation'] == 'details',
        )['url'],
        '/yani-neko-f2ca',
      );
      expect(result.single.matchedSeriesTitle, 'Yani Neko');
      expect(result.single.audioCapability, WebStreamAudioCapability.unknown);
      expect(result.single.audioLanguages, isEmpty);
      expect(diagnostics.single['exact_title_match_count'], 1);
      expect(diagnostics.single['search_query_count'], 1);
    },
  );

  test(
    'bracketed release cuts do not invent audio language or sub/dub evidence',
    () async {
      for (final suffix in [
        '(Uncensored)',
        '[Censored]',
        '[UNCENSORED]',
        '( censored )',
      ]) {
        final runtime = _Runtime()
          ..search = [
            {'url': '/show', 'title': '${_episode.title} $suffix'},
          ];
        final result = await runtime.provider().streams(_episode);
        expect(result, hasLength(1), reason: suffix);
        expect(result.single.audioCapability, WebStreamAudioCapability.unknown);
        expect(result.single.audioLanguages, isEmpty);
      }
    },
  );

  test(
    'release cuts and separate audio labels normalize in either order',
    () async {
      for (final suffix in [
        '(Uncensored) [English Dub]',
        '[English Dub] (Uncensored)',
      ]) {
        final runtime = _Runtime()
          ..search = [
            {'url': '/show', 'title': '${_episode.title} $suffix'},
          ];
        final result = await runtime.provider().streams(_episode);
        expect(result, hasLength(1), reason: suffix);
        expect(result.single.audioCapability, WebStreamAudioCapability.dub);
        expect(result.single.audioLanguages, ['eng']);
      }
    },
  );

  test(
    'cut labels never erase canonical terms or sequel season and year identity',
    () async {
      for (final title in [
        'Example Show Season 3 (Uncensored)',
        'Example Show Season 20 [Censored]',
        'Example Show Season 2 Mini Anime (Uncensored)',
        'Example Show Season 2 (2025) (Uncensored)',
        'Example Show Season 2 Uncensored',
        'Example Show Season 2 - Censored',
        'Example Show Season 2 (Uncensored Edition)',
        'Example Show Season 2 (Uncensored]',
        'Example Show Season 2 [Censored)',
      ]) {
        final runtime = _Runtime()
          ..search = [
            {'url': '/wrong', 'title': title},
          ];
        expect(
          await runtime.provider().streams(_episode),
          isEmpty,
          reason: title,
        );
        expect(
          runtime.calls.every((call) => call['operation'] == 'search'),
          isTrue,
        );
      }
    },
  );

  test(
    'cut normalization does not select the separate Yani Neko mini-anime',
    () async {
      final runtime = _Runtime()
        ..search = [
          {'url': '/mini', 'title': 'Yani Neko Mini Anime (Uncensored)'},
        ];
      expect(
        await runtime.provider().streams(
          const EpisodeReference(
            anilistMediaId: 207141,
            title: 'Chainsmoker Cat',
            titleRomaji: 'Yani Neko',
            episode: 2,
          ),
        ),
        isEmpty,
      );
      expect(
        runtime.calls.every((call) => call['operation'] == 'search'),
        isTrue,
      );
    },
  );

  test('distinct censored and uncensored URLs remain ambiguous', () async {
    final runtime = _Runtime()
      ..search = [
        {'url': '/censored', 'title': '${_episode.title} (Censored)'},
        {'url': '/uncensored', 'title': '${_episode.title} (Uncensored)'},
      ];
    expect(await runtime.provider().streams(_episode), isEmpty);
    expect(runtime.calls, hasLength(1));
  });

  test(
    'English and Japanese catalog labels select and describe exact audio variants',
    () async {
      for (final fixture
          in <
            ({
              PlaybackAudioPreference preference,
              String language,
              String url,
              String title,
              WebStreamAudioCapability capability,
            })
          >[
            (
              preference: PlaybackAudioPreference.dub,
              language: 'eng',
              url: '/show/english',
              title: 'Example Show Season 2 [English]',
              capability: WebStreamAudioCapability.dub,
            ),
            (
              preference: PlaybackAudioPreference.sub,
              language: 'jpn',
              url: '/show/japanese',
              title: 'Example Show Season 2 [Japanese]',
              capability: WebStreamAudioCapability.sub,
            ),
          ]) {
        final runtime = _Runtime()
          ..search = [
            {
              'url': '/show/english',
              'title': 'Example Show Season 2 [English]',
            },
            {
              'url': '/show/japanese',
              'title': 'Example Show Season 2 [Japanese]',
            },
          ]
          ..details = {'url': fixture.url, 'title': fixture.title};

        final result = await runtime
            .provider(
              preferredAudio: fixture.preference,
              preferredAudioLanguage: fixture.language,
            )
            .streams(_episode);

        expect(result, hasLength(1));
        expect(result.single.audioCapability, fixture.capability);
        expect(result.single.audioLanguages, [fixture.language]);
        expect(
          runtime.calls.singleWhere(
            (call) => call['operation'] == 'details',
          )['url'],
          fixture.url,
        );
      }
    },
  );

  test(
    'localized catalog labels select language without inventing a Dub mode',
    () async {
      final runtime = _Runtime()
        ..search = [
          {'url': '/show/spanish', 'title': 'Example Show Season 2 [Spanish]'},
          {
            'url': '/show/japanese',
            'title': 'Example Show Season 2 [Japanese]',
          },
        ]
        ..details = {
          'url': '/show/spanish',
          'title': 'Example Show Season 2 [Spanish]',
        };

      final result = await runtime
          .provider(
            preferredAudio: PlaybackAudioPreference.dub,
            preferredAudioLanguage: 'spa',
          )
          .streams(_episode);

      expect(result, hasLength(1));
      expect(result.single.audioCapability, WebStreamAudioCapability.unknown);
      expect(result.single.audioLanguages, ['spa']);
      expect(
        runtime.calls.singleWhere(
          (call) => call['operation'] == 'details',
        )['url'],
        '/show/spanish',
      );
    },
  );

  test('subtitle language suffix is not advertised as spoken audio', () async {
    final runtime = _Runtime()
      ..search = [
        {
          'url': '/show/spanish-sub',
          'title': 'Example Show Season 2 [Spanish Sub]',
        },
      ]
      ..details = {
        'url': '/show/spanish-sub',
        'title': 'Example Show Season 2 [Spanish Sub]',
      };

    final result = await runtime.provider().streams(_episode);

    expect(result, hasLength(1));
    expect(result.single.audioCapability, WebStreamAudioCapability.sub);
    expect(result.single.audioLanguages, isEmpty);
  });

  test('equally ranked decorated variants remain ambiguous', () async {
    final runtime = _Runtime()
      ..search = [
        {'url': '/show/dub-a', 'title': 'Example Show Season 2 (Dub)'},
        {'url': '/show/dub-b', 'title': 'Example Show Season 2 [Dubbed]'},
      ];

    expect(
      await runtime
          .provider(preferredAudio: PlaybackAudioPreference.dub)
          .streams(_episode),
      isEmpty,
    );
    expect(runtime.calls, hasLength(1));
  });

  test(
    'tries a bounded alternative query when the primary search has no match',
    () async {
      final runtime = _Runtime();
      final result = await runtime
          .provider(
            callback: (request) async {
              if (request['operation'] == 'search' &&
                  request['query'] == _episode.title) {
                runtime.calls.add(request);
                return {'items': <Map<String, dynamic>>[]};
              }
              return runtime.request(request);
            },
          )
          .streams(_episode);
      expect(result, hasLength(1));
      expect(runtime.calls.take(2).map((call) => call['query']), [
        _episode.title,
        _episode.titleRomaji,
      ]);
    },
  );

  test(
    'does not fuzzy-match sequels, numeric suffixes, or the first result',
    () async {
      for (final title in [
        'Example Show',
        'Example Show Season 3',
        'Example Show Season 20',
        'Other Show',
      ]) {
        final runtime = _Runtime()
          ..search = [
            {'url': '/wrong', 'title': title},
          ];
        expect(
          await runtime.provider().streams(_episode),
          isEmpty,
          reason: title,
        );
        expect(
          runtime.calls.every((call) => call['operation'] == 'search'),
          isTrue,
        );
      }
    },
  );

  test(
    'a rejected native alias does not prevent later exact catalog aliases',
    () async {
      final runtime = _Runtime();
      final diagnostics = <Map<String, Object?>>[];
      const episode = EpisodeReference(
        anilistMediaId: 1,
        title: 'Example Show Season 2',
        titleEnglish: 'EXAMPLE SHOW SEASON 2',
        titleRomaji: 'Example Romaji Season 2',
        titleNative: '日本語の題名',
        alternativeTitles: [
          'Example: Show Season 2',
          'Fourth Catalog Alias',
          'Fifth Catalog Alias',
        ],
        episode: 2,
        year: 2026,
      );
      final streams = await runtime
          .provider(
            onDiagnostic: diagnostics.add,
            callback: (request) async {
              if (request['operation'] != 'search') {
                return runtime.request(request);
              }
              runtime.calls.add(request);
              if (request['query'] == episode.titleNative) {
                throw const AniyomiFailure(
                  'extension_execution_failed',
                  stage: 'source_search',
                  cause: 'invalid_input',
                );
              }
              final matched = request['query'] == 'Fourth Catalog Alias';
              return {
                'items': matched ? runtime.search : <Map<String, dynamic>>[],
                'originalCount': matched ? 1 : 0,
                'returnedCount': matched ? 1 : 0,
                'broker_redirect_count': 0,
                'broker_response_size_bucket': 'lt64k',
                'broker_status_class': '2xx',
              };
            },
          )
          .streams(episode);
      expect(streams, hasLength(1));
      expect(
        runtime.calls
            .where((call) => call['operation'] == 'search')
            .map((call) => call['query']),
        [
          episode.title,
          episode.titleRomaji,
          episode.titleNative,
          'Fourth Catalog Alias',
        ],
      );
      expect(diagnostics.single['outcome'], 'success');
      expect(diagnostics.single['search_query_count'], 4);
      expect(diagnostics.single['search_original_count'], 1);
      expect(
        diagnostics.single.keys.any((key) => key.startsWith('native_')),
        isFalse,
      );
      // Videos did not make an HTTP request in this fixture. An alias's 2xx is
      // not the current operation's broker result.
      expect(
        diagnostics.single.keys.any((key) => key.startsWith('broker_')),
        isFalse,
      );
      expect(
        diagnostics.single.toString(),
        isNot(contains(episode.titleNative)),
      );
    },
  );

  test(
    'search caps five distinct aliases without dropping exact identity',
    () async {
      final runtime = _Runtime()..search = [];
      final diagnostics = <Map<String, Object?>>[];
      final result = await runtime
          .provider(onDiagnostic: diagnostics.add)
          .streams(
            const EpisodeReference(
              anilistMediaId: 1,
              title: 'Primary Title',
              titleEnglish: 'PRIMARY: TITLE',
              titleRomaji: 'Second Title',
              titleNative: 'Third Title',
              alternativeTitles: ['Fourth Title', 'Fifth Title', 'Sixth Title'],
              episode: 2,
            ),
          );
      expect(result, isEmpty);
      expect(runtime.calls.map((call) => call['query']), [
        'Primary Title',
        'Second Title',
        'Third Title',
        'Fourth Title',
        'Fifth Title',
      ]);
      expect(diagnostics.single['search_query_count'], 5);
    },
  );

  test(
    'failed alias diagnostics never inherit earlier or later HTTP success',
    () async {
      for (final failureFirst in [false, true]) {
        final runtime = _Runtime();
        final diagnostics = <Map<String, Object?>>[];
        final provider = runtime.provider(
          onDiagnostic: diagnostics.add,
          callback: (request) async {
            runtime.calls.add(request);
            if ((runtime.calls.length == 1) == failureFirst) {
              throw const AniyomiFailure(
                'extension_execution_failed',
                stage: 'source_search',
                cause: 'invalid_input',
              );
            }
            return {
              'items': <Map<String, dynamic>>[],
              'originalCount': 0,
              'returnedCount': 0,
              'broker_redirect_count': 0,
              'broker_response_size_bucket': 'lt64k',
              'broker_status_class': '2xx',
            };
          },
        );
        await expectLater(
          provider.streams(_episode),
          throwsA(isA<AniyomiWebProviderFailure>()),
        );
        expect(runtime.calls, hasLength(2));
        final fields = diagnostics.single;
        expect(fields['native_reason_code'], 'invalid_input');
        expect(fields['search_query_count'], 2);
        expect(fields.keys.any((key) => key.startsWith('broker_')), isFalse);
        expect(fields.containsKey('search_original_count'), isFalse);
        expect(fields.containsKey('search_returned_count'), isFalse);
      }
    },
  );

  test(
    'search alias recovery never retries approval or boundary failures',
    () async {
      for (final failure in [
        const AniyomiFailure('developer_access_revoked'),
        const AniyomiFailure('request_cancelled'),
        const AniyomiFailure('request_deadline_exceeded'),
        const AniyomiFailure('invalid_or_revoked_extension_result'),
        const AniyomiFailure('unsupported_extension_capability'),
        const AniyomiFailure('unsupported_extension_abi'),
        const AniyomiFailure('invalid_request'),
        const AniyomiFailure(
          'extension_execution_failed',
          stage: 'source_search',
          cause: 'security_denied',
        ),
        const AniyomiFailure(
          'extension_execution_failed',
          stage: 'source_search',
          cause: 'invalid_input',
          brokerFailure: 'invalid',
        ),
        const AniyomiFailure(
          'extension_execution_failed',
          stage: 'source_search',
          cause: 'invalid_input',
          brokerFailure: 'policy',
        ),
        const AniyomiFailure(
          'extension_execution_failed',
          stage: 'source_search',
          cause: 'invalid_input',
          brokerFailure: 'unsupported',
        ),
        const AniyomiFailure(
          'extension_execution_failed',
          stage: 'source_operation',
          cause: 'invalid_input',
        ),
      ]) {
        final runtime = _Runtime();
        await expectLater(
          runtime
              .provider(
                callback: (request) async {
                  runtime.calls.add(request);
                  throw failure;
                },
              )
              .streams(_episode),
          throwsA(isA<AniyomiWebProviderFailure>()),
        );
        expect(runtime.calls, hasLength(1), reason: failure.toString());
      }
    },
  );

  test('rejected aliases share the original workflow deadline', () async {
    final runtime = _Runtime();
    final pending = Completer<Map<String, dynamic>>();
    await expectLater(
      runtime
          .provider(
            runtimeLimit: const Duration(milliseconds: 40),
            callback: (request) async {
              runtime.calls.add(request);
              if (runtime.calls.length == 1) {
                await Future<void>.delayed(const Duration(milliseconds: 15));
                throw const AniyomiFailure(
                  'extension_execution_failed',
                  stage: 'source_search',
                  cause: 'invalid_input',
                );
              }
              return pending.future;
            },
          )
          .streams(_episode),
      throwsA(isA<TimeoutException>()),
    );
    expect(runtime.calls, hasLength(2));
    expect(
      runtime.calls.last['timeoutMs'],
      lessThan(runtime.calls.first['timeoutMs'] as int),
    );
    pending.complete({'items': runtime.search});
  });

  test(
    'same title at different source URLs is ambiguous and never auto-selected',
    () async {
      final runtime = _Runtime()
        ..search = [
          {'url': '/first', 'title': _episode.title},
          {'url': '/second', 'title': _episode.title},
        ];
      expect(await runtime.provider().streams(_episode), isEmpty);
      expect(runtime.calls, hasLength(1));
    },
  );

  test(
    'known different year is rejected while provider details are advisory',
    () async {
      final runtime = _Runtime()
        ..search = [
          {'url': '/show', 'title': _episode.title, 'year': 2025},
        ];
      expect(await runtime.provider().streams(_episode), isEmpty);
      runtime.search = [
        {'url': '/show', 'title': _episode.title},
      ];
      for (final details in <Map<String, dynamic>>[
        {'url': '/show', 'title': 'Other Show'},
        {'url': '/changed', 'title': _episode.title},
      ]) {
        runtime.details = details;
        expect(await runtime.provider().streams(_episode), hasLength(1));
      }
      runtime.details = {'url': '/show', 'title': _episode.title, 'year': 2025};
      expect(await runtime.provider().streams(_episode), isEmpty);
    },
  );

  test('episodes use the canonical locator returned by details', () async {
    final runtime = _Runtime()
      ..details = {'url': '/show/canonical', 'title': 'Example Show Season 2'};

    expect(await runtime.provider().streams(_episode), hasLength(1));

    expect(
      runtime.calls.singleWhere(
        (call) => call['operation'] == 'episodes',
      )['url'],
      '/show/canonical',
    );
  });

  test('opaque detail locator fragments survive into episode lookup', () async {
    final runtime = _Runtime()
      ..details = {
        'url': '/show/canonical#67',
        'title': 'Example Show Season 2',
      };

    expect(await runtime.provider().streams(_episode), hasLength(1));

    expect(
      runtime.calls.singleWhere(
        (call) => call['operation'] == 'episodes',
      )['url'],
      '/show/canonical#67',
    );
  });

  test(
    'season containers select only the exact requested season before episodes',
    () async {
      final runtime = _Runtime()
        ..details = {
          'url': '/show/canonical',
          'title': 'Example Show',
          'fetchType': 'seasons',
        }
        ..seasons = [
          {
            'url': '/show/season-1',
            'title': 'Example Show Season 1',
            'seasonNumber': 1.0,
          },
          {
            'url': '/show/season-2',
            'title': 'Example Show Season 2',
            'seasonNumber': 2.0,
          },
          {
            'url': '/show/misleading',
            'title': 'Example Show Season 2',
            'seasonNumber': 3.0,
          },
        ];

      final result = await runtime.provider().streams(_episode);

      expect(result, hasLength(1));
      expect(runtime.calls.map((call) => call['operation']), [
        'search',
        'details',
        'seasons',
        'episodes',
        'videos',
      ]);
      final seasonCall = runtime.calls.singleWhere(
        (call) => call['operation'] == 'seasons',
      );
      expect(seasonCall['url'], '/show/canonical');
      expect(seasonCall['targetSeason'], 2);
      expect(
        runtime.calls.singleWhere(
          (call) => call['operation'] == 'episodes',
        )['url'],
        '/show/season-2',
      );
    },
  );

  test(
    'search season marker survives details that omit container metadata',
    () async {
      final runtime = _Runtime()
        ..search = [
          {
            'url': '/show',
            'title': 'Example Show Season 2',
            'fetchType': 'seasons',
          },
        ]
        ..details = {
          'url': '/show/canonical',
          'title': 'Example Show Season 2',
        };

      final result = await runtime.provider().streams(_episode);

      expect(result, hasLength(1));
      expect(runtime.calls.map((call) => call['operation']), [
        'search',
        'details',
        'seasons',
        'episodes',
        'videos',
      ]);
      expect(
        runtime.calls.singleWhere(
          (call) => call['operation'] == 'seasons',
        )['url'],
        '/show/canonical',
      );
    },
  );

  test('ambiguous exact seasons fail closed before episode loading', () async {
    final runtime = _Runtime()
      ..details = {
        'url': '/show/canonical',
        'title': 'Example Show',
        'fetchType': 'seasons',
      }
      ..seasons = [
        {
          'url': '/show/season-2-a',
          'title': 'Example Show Season 2',
          'seasonNumber': 2.0,
        },
        {
          'url': '/show/season-2-b',
          'title': 'Example Show 2nd Season',
          'seasonNumber': 2.0,
        },
      ];

    expect(await runtime.provider().streams(_episode), isEmpty);
    expect(runtime.calls.last['operation'], 'seasons');
  });

  test(
    'uses strict numeric identity with a season-aware label fallback',
    () async {
      for (final accepted in <List<Map<String, dynamic>>>[
        [
          {'url': '/ep2', 'name': 'Episode 2', 'number': -1.0},
        ],
        [
          {'url': '/ep2', 'name': 'S02E02', 'number': 'missing'},
        ],
      ]) {
        final runtime = _Runtime()..chapters = accepted;
        expect(
          await runtime.provider().streams(_episode),
          hasLength(1),
          reason: '$accepted',
        );
      }
      for (final rejected in <List<Map<String, dynamic>>>[
        [
          {'url': '/ep10', 'name': 'Episode 10', 'number': 10.0},
        ],
        [
          {'url': '/ep2', 'name': 'Chapter Two', 'number': -1.0},
        ],
        [
          {'url': '/ep2', 'name': 'Episode 2', 'number': 2.5},
        ],
        [
          {'url': '/ep2', 'name': 'Episode 3', 'number': 2.0},
        ],
        [
          {'url': '/ep2', 'name': 'S03E02', 'number': 2.0},
        ],
        [
          {'url': '/one', 'name': 'Episode 2', 'number': 2.0},
          {'url': '/two', 'name': 'Episode 2', 'number': 2.0},
        ],
      ]) {
        final runtime = _Runtime()..chapters = rejected;
        expect(
          await runtime.provider().streams(_episode),
          isEmpty,
          reason: '$rejected',
        );
        expect(runtime.calls.last['operation'], 'episodes');
      }
    },
  );

  test(
    'skips unsafe stream URLs and failed public-address validation',
    () async {
      final runtime = _Runtime();
      runtime.videos = [
        {'url': 'http://video.example/a'},
        {'url': 'https://127.0.0.1/a'},
        {'url': 'file:///data/a'},
        {'url': 'https://user:pass@video.example/a'},
        {'url': 'https://rebind.example/a'},
        runtime.videos.single,
      ];
      final validated = <Uri>[];
      final result = await runtime
          .provider(
            validate: (uri) async {
              validated.add(uri);
              if (uri.host == 'rebind.example') {
                throw const FormatException('Nonpublic address');
              }
            },
          )
          .streams(_episode);
      expect(result, hasLength(1));
      expect(validated.any((uri) => uri.host == '127.0.0.1'), isFalse);
    },
  );

  test('unsafe subtitles do not hide an otherwise safe video', () async {
    final runtime = _Runtime();
    runtime.videos.single['subtitleTracks'] = [
      {'url': 'https://localhost/en.vtt', 'lang': 'English'},
      {'url': 'https://bad.example/en.vtt', 'lang': 'English'},
    ];
    final result = await runtime
        .provider(
          validate: (uri) async {
            if (uri.host == 'bad.example') {
              throw const FormatException('Nonpublic address');
            }
          },
        )
        .streams(_episode);
    expect(result, hasLength(1));
    expect(result.single.subtitleUri, isNull);
  });

  test(
    'sanitizes framing/control headers and deduplicates returned video URLs',
    () async {
      final runtime = _Runtime();
      runtime.videos.single['headers'] = {
        'Host': 'localhost',
        'Content-Length': '12',
        'X-Unsafe': 'a\r\nb',
        'User-Agent': 'Extension/1',
      };
      runtime.videos.add(Map.of(runtime.videos.single));
      final result = await runtime.provider().streams(_episode);
      expect(result, hasLength(1));
      expect(result.single.headers, {'User-Agent': 'Extension/1'});
    },
  );

  test(
    'preserves bounded KickAssAnime fetch metadata playback headers',
    () async {
      final runtime = _Runtime();
      runtime.videos.single['headers'] = {
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Origin': 'https://media.example',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
        'User-Agent': 'Mozilla/5.0 fixture',
      };

      final result = await runtime.provider().streams(_episode);

      expect(result, hasLength(1));
      expect(result.single.headers, {
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Origin': 'https://media.example',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
        'User-Agent': 'Mozilla/5.0 fixture',
      });
    },
  );

  test('preserves same-URL videos with distinct request headers', () async {
    final runtime = _Runtime();
    runtime.videos.add({
      ...runtime.videos.single,
      'headers': {'Referer': 'https://second-source.example'},
    });

    final result = await runtime.provider().streams(_episode);

    expect(result, hasLength(2));
    expect(result.map((stream) => stream.headers['Referer']).toSet(), {
      'https://source.example',
      'https://second-source.example',
    });
  });

  test(
    'retains bounded external audio but rejects native-player options',
    () async {
      final externalAudio = _Runtime();
      externalAudio.videos.single['headers'] = {
        'Referer': 'https://source.example',
        'Authorization': 'Bearer private-video-token',
      };
      externalAudio.videos.single['audioTracks'] = [
        {'url': 'https://audio.example/dub.aac', 'lang': 'English'},
      ];
      final retained = await externalAudio.provider().streams(_episode);
      expect(retained, hasLength(1));
      expect(retained.single.audioLanguages, ['eng']);
      expect(retained.single.effectiveAudioCapability.supportsDub, isTrue);
      expect(retained.single.externalAudioTracks, hasLength(1));
      expect(
        retained.single.externalAudioTracks.single.uri,
        Uri.parse('https://audio.example/dub.aac'),
      );
      expect(retained.single.externalAudioTracks.single.language, 'eng');
      expect(retained.single.externalAudioTracks.single.label, 'English');
      expect(retained.single.externalAudioTracks.single.headers, {
        'Referer': 'https://source.example',
      });

      for (final key in ['mpvArgs', 'ffmpegStreamArgs', 'ffmpegVideoArgs']) {
        final runtime = _Runtime();
        runtime.videos.single[key] = [
          {'url': 'https://audio.example/dub.aac', 'lang': 'English'},
        ];
        await expectLater(
          runtime.provider().streams(_episode),
          throwsA(
            isA<AniyomiWebProviderFailure>()
                .having(
                  (failure) => failure.stage,
                  'stage',
                  'stream_extraction',
                )
                .having((failure) => failure.reason, 'reason', 'empty_sources'),
          ),
        );
      }
    },
  );

  test(
    'diagnostics retain only bounded stage counts and fixed codes',
    () async {
      final runtime = _Runtime();
      final diagnostics = <Map<String, Object?>>[];

      final streams = await runtime
          .provider(onDiagnostic: diagnostics.add)
          .streams(_episode);

      expect(streams, hasLength(1));
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, {
        'event': 'provider_attempt',
        'outcome': 'success',
        'stage': 'complete',
        'reason_code': 'streams_returned',
        'title_alias_count': 2,
        'search_query_count': 1,
        'search_result_count': 1,
        'exact_title_match_count': 1,
        'episode_count': 2,
        'exact_episode_match_count': 1,
        'episode_label_fallback_count': 0,
        'details_metadata_mismatch_count': 0,
        'raw_video_count': 1,
        'playable_video_count': 1,
        'rejected_unsupported_playback_count': 0,
        'ignored_external_audio_count': 0,
        'external_audio_track_count': 0,
        'rejected_external_audio_count': 0,
        'rejected_invalid_media_url_count': 0,
        'rejected_unsafe_media_target_count': 0,
      });
      final serialized = diagnostics.single.toString();
      expect(serialized, isNot(contains(_episode.title)));
      expect(serialized, isNot(contains('video.example')));
      expect(serialized, isNot(contains('source.example')));
    },
  );

  test(
    'successful native list and broker metadata is recorded without payload data',
    () async {
      final runtime = _Runtime();
      final diagnostics = <Map<String, Object?>>[];
      final streams = await runtime
          .provider(
            onDiagnostic: diagnostics.add,
            callback: (request) async {
              final response = await runtime.request(request);
              switch (request['operation']) {
                case 'search':
                  response.addAll({
                    'originalCount': 1,
                    'returnedCount': 1,
                    'truncatedCount': 0,
                    'broker_redirect_count': 1,
                    'broker_response_size_bucket': 'lt64k',
                    'broker_status_class': '5xx',
                  });
                  break;
                case 'episodes':
                  response.addAll({
                    'originalCount': 5000,
                    'returnedCount': 2,
                    'filteredCount': 4998,
                    'truncatedCount': 0,
                  });
                  break;
                case 'videos':
                  response.addAll({
                    'broker_redirect_count': 0,
                    'broker_response_size_bucket': '64to128k',
                    'broker_status_class': '2xx',
                    'originalCount': 262144,
                    'returnedCount': 1,
                    'discardedVideoCount': 0,
                    'truncatedCount': 262143,
                    'originalHosterCount': 6,
                    'visitedHosterCount': 5,
                    'lazyHosterCount': 3,
                    'attemptedLazyHosterCount': 2,
                    'resolvedLazyHosterCount': 1,
                    'failedLazyHosterCount': 1,
                    'deferredHosterCount': 1,
                    'discardedHosterCount': 2,
                    'truncatedHosterCount': 1,
                    'discardedTrackCount': 3,
                    'localHlsBridgeCount': 1,
                  });
                  break;
              }
              return response;
            },
          )
          .streams(_episode);

      expect(streams, hasLength(1));
      final fields = diagnostics.single;
      expect(fields['broker_redirect_count'], 0);
      expect(fields['broker_response_size_bucket'], '64to128k');
      expect(fields['broker_status_class'], '2xx');
      expect(fields['search_original_count'], 1);
      expect(fields['search_returned_count'], 1);
      expect(fields['episode_original_count'], 5000);
      expect(fields['episode_filtered_count'], 4998);
      expect(fields['video_original_count'], 262144);
      expect(fields['video_discarded_count'], 0);
      expect(fields['video_truncated_count'], 262143);
      expect(fields['video_original_hoster_count'], 6);
      expect(fields['video_visited_hoster_count'], 5);
      expect(fields['video_lazy_hoster_count'], 3);
      expect(fields['video_attempted_lazy_hoster_count'], 2);
      expect(fields['video_resolved_lazy_hoster_count'], 1);
      expect(fields['video_failed_lazy_hoster_count'], 1);
      expect(fields['video_deferred_hoster_count'], 1);
      expect(fields['video_discarded_hoster_count'], 2);
      expect(fields['video_truncated_hoster_count'], 1);
      expect(fields['video_discarded_track_count'], 3);
      expect(fields['video_local_hls_bridge_count'], 1);
      final serialized = fields.toString();
      expect(serialized, isNot(contains(_episode.title)));
      expect(serialized, isNot(contains('video.example')));
    },
  );

  test('empty videos retain provider-caught HTTP failure evidence', () async {
    final runtime = _Runtime()..videos = [];
    final diagnostics = <Map<String, Object?>>[];
    await expectLater(
      runtime
          .provider(
            onDiagnostic: diagnostics.add,
            callback: (request) async {
              final response = await runtime.request(request);
              if (request['operation'] == 'videos') {
                response['httpDiagnostics'] = {
                  'requestCount': 16,
                  'requestLimit': 16,
                  'failureCount': 3,
                  'requestLimitHit': true,
                  'lastFailure': 'unsupported',
                };
              }
              return response;
            },
          )
          .streams(_episode),
      throwsA(
        isA<AniyomiWebProviderFailure>().having(
          (failure) => failure.reason,
          'reason',
          'empty_sources',
        ),
      ),
    );
    final fields = diagnostics.single;
    expect(fields['outcome'], 'failure');
    expect(fields['reason_code'], 'empty_sources');
    expect(fields['raw_video_count'], 0);
    expect(fields['video_http_request_count'], 16);
    expect(fields['video_http_request_limit'], 16);
    expect(fields['video_http_failure_count'], 3);
    expect(fields['video_http_request_limit_hit'], isTrue);
    expect(fields['video_http_last_failure'], 'unsupported');
    expect(fields.keys.any((key) => key.startsWith('native_')), isFalse);
  });

  test(
    'successful HTTP evidence uses independent operation prefixes',
    () async {
      final runtime = _Runtime();
      final diagnostics = <Map<String, Object?>>[];
      final streams = await runtime
          .provider(
            onDiagnostic: diagnostics.add,
            callback: (request) async {
              final response = await runtime.request(request);
              final count = switch (request['operation']) {
                'search' => 1,
                'episodes' => 2,
                'videos' => 3,
                _ => 4,
              };
              response['httpDiagnostics'] = {
                'requestCount': count,
                'requestLimit': 16,
                'failureCount': 0,
                'requestLimitHit': false,
                'lastFailure': 'none',
                'requestUrl': 'https://PRIVATE_HTTP_CANARY.example/path',
                'headers': {'Authorization': 'PRIVATE_HTTP_CANARY'},
              };
              return response;
            },
          )
          .streams(_episode);
      expect(streams, hasLength(1));
      final fields = diagnostics.single;
      for (final (prefix, count) in [
        ('search', 1),
        ('episode', 2),
        ('video', 3),
      ]) {
        expect(fields['${prefix}_http_request_count'], count);
        expect(fields['${prefix}_http_request_limit'], 16);
        expect(fields['${prefix}_http_failure_count'], 0);
        expect(fields['${prefix}_http_request_limit_hit'], isFalse);
        expect(fields['${prefix}_http_last_failure'], 'none');
      }
      expect(fields.keys.where((key) => key.contains('_http_')), hasLength(15));
      expect(fields.toString(), isNot(contains('PRIVATE_HTTP_CANARY')));
      expect(fields['outcome'], 'success');
    },
  );

  test(
    'HTTP diagnostics clamp counts and reject unrecognized values',
    () async {
      for (final (http, expected) in <(Object?, Map<String, Object?>)>[
        (
          {
            'requestCount': 100000,
            'requestLimit': 100000,
            'failureCount': 100000,
            'requestLimitHit': 'PRIVATE_HTTP_CANARY',
            'lastFailure': 'PRIVATE_HTTP_CANARY',
            'PRIVATE_HTTP_CANARY': 'PRIVATE_HTTP_CANARY',
          },
          {'video_http_request_count': 16, 'video_http_failure_count': 64},
        ),
        (
          {
            'requestCount': -1,
            'requestLimit': 16.5,
            'failureCount': 1.5,
            'requestLimitHit': 1,
            'lastFailure': 'NETWORK',
          },
          {},
        ),
        (
          {
            'requestCount': '16',
            'requestLimit': '16',
            'failureCount': -9,
            'requestLimitHit': null,
            'lastFailure': ['network'],
          },
          {},
        ),
        ('PRIVATE_HTTP_CANARY', {}),
        (['PRIVATE_HTTP_CANARY'], {}),
        (null, {}),
      ]) {
        final runtime = _Runtime();
        final diagnostics = <Map<String, Object?>>[];
        final streams = await runtime
            .provider(
              onDiagnostic: diagnostics.add,
              callback: (request) async {
                final response = await runtime.request(request);
                if (request['operation'] == 'videos') {
                  response['httpDiagnostics'] = http;
                }
                return response;
              },
            )
            .streams(_episode);
        expect(streams, hasLength(1));
        final fields = diagnostics.single;
        expect({
          for (final entry in fields.entries)
            if (entry.key.contains('_http_')) entry.key: entry.value,
        }, expected);
        expect(fields.toString(), isNot(contains('PRIVATE_HTTP_CANARY')));
      }
    },
  );

  test('HTTP last failure accepts only the closed host reason set', () async {
    for (final reason in [
      'policy',
      'network',
      'unsupported',
      'invalid',
      'none',
    ]) {
      final runtime = _Runtime();
      final diagnostics = <Map<String, Object?>>[];
      final streams = await runtime
          .provider(
            onDiagnostic: diagnostics.add,
            callback: (request) async {
              final response = await runtime.request(request);
              if (request['operation'] == 'videos') {
                response['httpDiagnostics'] = {'lastFailure': reason};
              }
              return response;
            },
          )
          .streams(_episode);
      expect(streams, hasLength(1));
      expect(diagnostics.single['video_http_last_failure'], reason);
      // A caught broker error is supporting evidence, not a replacement for
      // the adapter's success, cancellation, or native-failure classification.
      expect(diagnostics.single['outcome'], 'success');
    }
  });

  test(
    'a later alias never inherits earlier HTTP diagnostic counters',
    () async {
      for (final nativeFailure in [false, true]) {
        final runtime = _Runtime();
        final diagnostics = <Map<String, Object?>>[];
        final work = runtime
            .provider(
              onDiagnostic: diagnostics.add,
              callback: (request) async {
                if (request['operation'] != 'search') {
                  return runtime.request(request);
                }
                runtime.calls.add(request);
                if (runtime.calls.length == 1) {
                  return {
                    'items': <Map<String, Object?>>[],
                    'httpDiagnostics': {
                      'requestCount': 16,
                      'requestLimit': 16,
                      'failureCount': 9,
                      'requestLimitHit': true,
                      'lastFailure': 'network',
                    },
                  };
                }
                if (nativeFailure) {
                  throw const AniyomiFailure(
                    'extension_execution_failed',
                    stage: 'source_search',
                    cause: 'invalid_input',
                  );
                }
                return {'items': runtime.search};
              },
            )
            .streams(_episode);
        if (nativeFailure) {
          await expectLater(work, throwsA(isA<AniyomiWebProviderFailure>()));
        } else {
          expect(await work, hasLength(1));
        }
        final fields = diagnostics.single;
        expect(fields.keys.any((key) => key.contains('_http_')), isFalse);
        if (nativeFailure) {
          expect(fields['native_reason_code'], 'invalid_input');
        }
      }
    },
  );

  test('diagnostics distinguish title no-match from rejected videos', () async {
    final noMatchRuntime = _Runtime()
      ..search = [
        {'url': '/wrong', 'title': 'A different show'},
      ];
    final noMatchDiagnostics = <Map<String, Object?>>[];
    expect(
      await noMatchRuntime
          .provider(onDiagnostic: noMatchDiagnostics.add)
          .streams(_episode),
      isEmpty,
    );
    expect(noMatchDiagnostics.single['outcome'], 'no_match');
    expect(noMatchDiagnostics.single['stage'], 'title_matching');
    expect(noMatchDiagnostics.single['reason_code'], 'no_exact_title_match');
    expect(noMatchDiagnostics.single['search_query_count'], 2);
    expect(noMatchDiagnostics.single['search_result_count'], 2);

    final rejectedRuntime = _Runtime()
      ..videos = [
        {'url': 'http://insecure.example/video.m3u8'},
        {
          'url': 'https://video.example/external-audio.m3u8',
          'audioTracks': [
            {'url': 'https://audio.example/dub.aac', 'lang': 'English'},
          ],
        },
      ];
    final rejectedDiagnostics = <Map<String, Object?>>[];
    final retained = await rejectedRuntime
        .provider(onDiagnostic: rejectedDiagnostics.add)
        .streams(_episode);
    expect(retained, hasLength(1));
    expect(rejectedDiagnostics.single['outcome'], 'success');
    expect(rejectedDiagnostics.single['stage'], 'complete');
    expect(rejectedDiagnostics.single['reason_code'], 'streams_returned');
    expect(rejectedDiagnostics.single['raw_video_count'], 2);
    expect(rejectedDiagnostics.single['playable_video_count'], 1);
    expect(
      rejectedDiagnostics.single['rejected_unsupported_playback_count'],
      0,
    );
    expect(rejectedDiagnostics.single['ignored_external_audio_count'], 0);
    expect(rejectedDiagnostics.single['external_audio_track_count'], 1);
    expect(rejectedDiagnostics.single['rejected_external_audio_count'], 0);
    expect(rejectedDiagnostics.single['rejected_invalid_media_url_count'], 1);
  });

  test('unsafe external audio is dropped without hiding safe video', () async {
    final runtime = _Runtime();
    runtime.videos.single['audioTracks'] = [
      {'url': 'https://audio.example/private.aac', 'lang': 'English'},
      {'url': 'http://insecure.example/audio.aac', 'lang': 'Japanese'},
    ];
    final diagnostics = <Map<String, Object?>>[];

    final streams = await runtime
        .provider(
          validate: (uri) async {
            if (uri.host == 'audio.example') {
              throw const FormatException('blocked target');
            }
          },
          onDiagnostic: diagnostics.add,
        )
        .streams(_episode);

    expect(streams, hasLength(1));
    expect(streams.single.externalAudioTracks, isEmpty);
    expect(diagnostics.single['external_audio_track_count'], 2);
    expect(diagnostics.single['rejected_external_audio_count'], 2);
    expect(diagnostics.single['ignored_external_audio_count'], 2);
  });

  test('cancellation before start dispatches no native requests', () async {
    final runtime = _Runtime();
    final cancellation = WebProviderCancellation()..cancel();
    await expectLater(
      runtime.provider().streams(_episode, cancellation: cancellation),
      throwsA(isA<WebProviderSearchCancelled>()),
    );
    expect(runtime.calls, isEmpty);
  });

  test(
    'cancellation while awaiting native work prevents subsequent operations',
    () async {
      final runtime = _Runtime();
      final pending = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final cancellation = WebProviderCancellation();
      final work = runtime
          .provider(
            callback: (request) {
              runtime.calls.add(request);
              started.complete();
              return pending.future;
            },
          )
          .streams(_episode, cancellation: cancellation);
      await started.future;
      final checked = expectLater(
        work,
        throwsA(isA<WebProviderSearchCancelled>()),
      );
      cancellation.cancel();
      await checked;
      pending.complete({'items': runtime.search});
      await Future<void>.delayed(Duration.zero);
      expect(runtime.calls, hasLength(1));
    },
  );

  test('cancellation awaits its request-scoped native cancel handle', () async {
    final runtime = _Runtime();
    final pending = Completer<Map<String, dynamic>>();
    final cancelStarted = Completer<void>();
    final releaseCancel = Completer<void>();
    final cancellation = WebProviderCancellation();
    var settled = false;
    final work = runtime
        .provider(
          starter: (request) {
            runtime.calls.add(request);
            return AniyomiRequestHandle(
              result: pending.future,
              cancel: () async {
                cancelStarted.complete();
                await releaseCancel.future;
              },
            );
          },
        )
        .streams(_episode, cancellation: cancellation)
        .whenComplete(() => settled = true);

    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    await cancelStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    releaseCancel.complete();
    await expectLater(work, throwsA(isA<WebProviderSearchCancelled>()));
    expect(runtime.calls, hasLength(1));
    pending.complete({'items': runtime.search});
  });

  test(
    'overall deadline bounds native wait and late response cannot resume search',
    () async {
      final runtime = _Runtime();
      final pending = Completer<Map<String, dynamic>>();
      final provider = runtime.provider(
        runtimeLimit: const Duration(milliseconds: 25),
        callback: (request) {
          runtime.calls.add(request);
          return pending.future;
        },
      );
      await expectLater(
        provider.streams(_episode),
        throwsA(isA<TimeoutException>()),
      );
      pending.complete({'items': runtime.search});
      await Future<void>.delayed(Duration.zero);
      expect(runtime.calls, hasLength(1));
      expect(runtime.calls.single['timeoutMs'], lessThanOrEqualTo(25));
    },
  );

  test('local proxy incompatibility reaches the stream picker clearly', () {
    final native = AniyomiFailure.fromNative({
      'error': 'extension_local_proxy_required',
      'stage': 'source_videos',
      'cause': 'unsupported_capability',
      'message': 'PRIVATE_PROVIDER_CANARY',
    });
    final failure = AniyomiWebProviderFailure.fromNative(
      operation: 'videos',
      failure: native,
    );
    expect(native.code, 'extension_local_proxy_required');
    expect(failure.reason, 'runtime_api');
    expect(
      seanimeProviderFailureMessage(failure),
      'This extension requires its own local streaming server, which '
      'TetoTV does not support yet. Try another extension.',
    );
    expect(failure.toString(), isNot(contains('PRIVATE_PROVIDER_CANARY')));
  });

  test(
    'native failures retain only bounded operation stage and reason metadata',
    () async {
      for (final fixture
          in <
            ({
              String operation,
              AniyomiFailure failure,
              String stage,
              String reason,
            })
          >[
            (
              operation: 'search',
              failure: const AniyomiFailure('invalid_request'),
              stage: 'search',
              reason: 'invalid_payload',
            ),
            (
              operation: 'details',
              failure: const AniyomiFailure(
                'extension_execution_failed',
                cause: 'io',
              ),
              stage: 'title_matching',
              reason: 'network',
            ),
            (
              operation: 'episodes',
              failure: const AniyomiFailure('request_deadline_exceeded'),
              stage: 'episode_lookup',
              reason: 'timeout',
            ),
            (
              operation: 'videos',
              failure: const AniyomiFailure(
                'extension_hoster_timeout',
                stage: 'source_videos',
                cause: 'timeout',
              ),
              stage: 'stream_extraction',
              reason: 'timeout',
            ),
            (
              operation: 'videos',
              failure: const AniyomiFailure(
                'unsupported_extension_abi',
                stage: 'source_operation',
                cause: 'method_missing',
              ),
              stage: 'stream_extraction',
              reason: 'runtime_api',
            ),
            (
              operation: 'search',
              failure: const AniyomiFailure(
                'unsupported_extension_capability',
                stage: 'source_operation',
                cause: 'security_denied',
              ),
              stage: 'search',
              reason: 'unsafe_target',
            ),
            (
              operation: 'search',
              failure: const AniyomiFailure(
                'extension_execution_failed',
                stage: 'source_search',
                cause: 'execution',
                brokerFailure: 'invalid',
                brokerRedirectCount: 1,
                brokerResponseSizeBucket: 'lt64k',
                brokerStatusClass: '2xx',
              ),
              stage: 'search',
              reason: 'invalid_response',
            ),
          ]) {
        final runtime = _Runtime();
        final diagnostics = <Map<String, Object?>>[];
        final provider = runtime.provider(
          onDiagnostic: diagnostics.add,
          callback: (request) async {
            if (request['operation'] == fixture.operation) {
              throw fixture.failure;
            }
            return runtime.request(request);
          },
        );
        try {
          await provider.streams(_episode);
          fail('Expected ${fixture.operation} to fail.');
        } on AniyomiWebProviderFailure catch (error) {
          expect(error.stage, fixture.stage);
          expect(error.reason, fixture.reason);
          expect(error.toString(), isNot(contains('method_missing')));
          expect(
            error.toString(),
            contains('[stage=${fixture.stage}; reason=${fixture.reason}]'),
          );
          expect(diagnostics, hasLength(1));
          expect(diagnostics.single['native_code'], fixture.failure.code);
          expect(
            diagnostics.single['native_stage'],
            fixture.failure.stage ?? 'unknown',
          );
          expect(
            diagnostics.single['native_reason_code'],
            fixture.failure.cause ?? 'execution',
          );
          if (fixture.failure.brokerFailure != null) {
            expect(
              diagnostics.single['broker_failure'],
              fixture.failure.brokerFailure,
            );
            expect(diagnostics.single['broker_redirect_count'], 1);
            expect(diagnostics.single['broker_response_size_bucket'], 'lt64k');
            expect(diagnostics.single['broker_status_class'], '2xx');
          }
        }
      }
    },
  );

  test(
    'public-network validation is also cancellation and deadline bounded',
    () async {
      final runtime = _Runtime();
      final pending = Completer<void>();
      await expectLater(
        runtime
            .provider(
              runtimeLimit: const Duration(milliseconds: 25),
              validate: (_) => pending.future,
            )
            .streams(_episode),
        throwsA(isA<TimeoutException>()),
      );
      pending.complete();
    },
  );

  test(
    'one host lookup timeout rejects only its stream, not validated siblings',
    () async {
      final runtime = _Runtime()
        ..videos = [
          {'url': 'https://first.example/ep2.m3u8'},
          {'url': 'https://timeout.example/ep2.m3u8'},
          {'url': 'https://last.example/ep2.m3u8'},
        ];
      final checked = <String>[];
      final diagnostics = <Map<String, Object?>>[];
      final streams = await runtime
          .provider(
            onDiagnostic: diagnostics.add,
            validate: (uri) async {
              checked.add(uri.host);
              if (uri.host == 'timeout.example') {
                throw TimeoutException('PRIVATE_TARGET_CANARY');
              }
            },
          )
          .streams(_episode);
      expect(checked, ['first.example', 'timeout.example', 'last.example']);
      expect(streams.map((stream) => stream.uri.host), [
        'first.example',
        'last.example',
      ]);
      expect(diagnostics.single['raw_video_count'], 3);
      expect(diagnostics.single['playable_video_count'], 2);
      expect(diagnostics.single['rejected_unsafe_media_target_count'], 1);
      expect(
        diagnostics.single.toString(),
        isNot(contains('PRIVATE_TARGET_CANARY')),
      );
    },
  );

  test(
    'optional track lookup timeouts preserve validated video and safe tracks',
    () async {
      final runtime = _Runtime()
        ..videos = [
          {
            'url': 'https://video.example/ep2.m3u8',
            'subtitleTracks': [
              {'url': 'https://timeout.example/en.vtt', 'lang': 'English'},
              {'url': 'https://video.example/en.vtt', 'lang': 'English'},
            ],
            'audioTracks': [
              {'url': 'https://timeout.example/en.m3u8', 'lang': 'English'},
              {'url': 'https://video.example/en.m3u8', 'lang': 'English'},
            ],
          },
        ];
      final streams = await runtime
          .provider(
            validate: (uri) async {
              if (uri.host == 'timeout.example') {
                throw TimeoutException('lookup');
              }
            },
          )
          .streams(_episode);
      expect(streams, hasLength(1));
      expect(streams.single.subtitleUri!.host, 'video.example');
      expect(streams.single.externalAudioTracks, hasLength(1));
      expect(
        streams.single.externalAudioTracks.single.uri.host,
        'video.example',
      );
    },
  );

  test(
    'host validation cancellation remains fatal even with a safe sibling',
    () async {
      final runtime = _Runtime()
        ..videos = [
          {'url': 'https://first.example/ep2.m3u8'},
          {'url': 'https://cancel.example/ep2.m3u8'},
          {'url': 'https://last.example/ep2.m3u8'},
        ];
      final checked = <String>[];
      final cancellation = WebProviderCancellation();
      await expectLater(
        runtime
            .provider(
              validate: (uri) async {
                checked.add(uri.host);
                if (uri.host == 'cancel.example') {
                  cancellation.cancel();
                  throw TimeoutException('lookup');
                }
              },
            )
            .streams(_episode, cancellation: cancellation),
        throwsA(isA<WebProviderSearchCancelled>()),
      );
      expect(checked, ['first.example', 'cancel.example']);
    },
  );

  test(
    'workflow expiry remains fatal after validating an earlier stream',
    () async {
      final runtime = _Runtime()
        ..videos = [
          {'url': 'https://first.example/ep2.m3u8'},
          {'url': 'https://pending.example/ep2.m3u8'},
          {'url': 'https://last.example/ep2.m3u8'},
        ];
      final checked = <String>[];
      final pending = Completer<void>();
      await expectLater(
        runtime
            .provider(
              runtimeLimit: const Duration(milliseconds: 30),
              validate: (uri) async {
                checked.add(uri.host);
                if (uri.host == 'pending.example') await pending.future;
              },
            )
            .streams(_episode),
        throwsA(isA<TimeoutException>()),
      );
      expect(checked, ['first.example', 'pending.example']);
      pending.complete();
    },
  );

  test(
    'rejects malformed, deeply nested and oversized native response data',
    () async {
      var deeplyNested = <String, dynamic>{};
      for (var depth = 0; depth < 18; depth++) {
        deeplyNested = {'nested': deeplyNested};
      }
      for (final response in <Map<String, dynamic>>[
        {'items': 'not a list'},
        {
          'items': [null],
        },
        {'items': List.filled(101, <String, dynamic>{})},
        {'items': [], 'unknown': 'x' * 4097},
        {'items': [], 'unknown': double.nan},
        {'items': [], 'unknown': deeplyNested},
      ]) {
        await expectLater(
          _Runtime()
              .provider(callback: (_) async => response)
              .streams(_episode),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test('rejects invalid source IDs without native dispatch', () async {
    final runtime = _Runtime();
    for (final sourceId in ['01', '1.0', '-0', '9223372036854775808']) {
      final provider = AniyomiWebProvider(
        extensionId: 'example',
        sourceId: sourceId,
        name: 'Example',
        request: runtime.request,
      );
      await expectLater(
        provider.streams(_episode),
        throwsA(isA<FormatException>()),
      );
    }
    expect(runtime.calls, isEmpty);
  });

  test('returned stream list is immutable', () async {
    final result = await _Runtime().provider().streams(_episode);
    expect(() => result.clear(), throwsUnsupportedError);
  });
}
