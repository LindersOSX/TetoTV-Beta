import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/data/manga_tracking_client.dart';
import 'package:anime_tv/features/manga/domain/manga_tracking_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  final bodies = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(
      body == null ? '' : utf8.decode(await body.expand((b) => b).toList()),
    );
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(
  Object value, {
  int status = 200,
  Map<String, List<String>>? headers,
}) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    'content-type': ['application/json'],
    ...?headers,
  },
);

OfficialMangaTrackingClient _client(
  TrackingProvider provider,
  _Adapter adapter,
) => OfficialMangaTrackingClient(
  provider: provider,
  accessToken: 'private-test-token',
  dio: Dio()..httpClientAdapter = adapter,
  lane: MangaTrackingRequestLane(minimumInterval: Duration.zero),
);

Map<String, Object> _aniRecord({int id = 42, String type = 'MANGA'}) => {
  'id': id,
  'type': type,
  'format': 'MANGA',
  'chapters': 100,
  'title': {'userPreferred': 'Chosen Manga'},
};

void main() {
  test(
    'AniList search is manga-only, bounded, and filters malformed rows',
    () async {
      final adapter = _Adapter(
        (_) => _json({
          'data': {
            'Page': {
              'media': [
                _aniRecord(),
                _aniRecord(id: 2, type: 'ANIME'),
                {..._aniRecord(id: 3), 'format': 33},
              ],
            },
          },
        }),
      );
      final client = _client(TrackingProvider.anilist, adapter);
      addTearDown(client.close);
      final results = await client.search('  Chosen Manga  ');
      expect(results.map((row) => row.mediaId), [42]);
      final request = adapter.requests.single;
      expect(request.uri.toString(), 'https://graphql.anilist.co/');
      expect(request.method, 'POST');
      final payload = jsonDecode(adapter.bodies.single) as Map;
      expect(payload['query'], contains('type: MANGA'));
      expect(payload['query'], contains('perPage: 20'));
      expect(payload['variables'], {'search': 'Chosen Manga'});
      expect(request.followRedirects, false);
    },
  );

  test('AniList uses exact record and changes only chapter progress', () async {
    final adapter = _Adapter((options) {
      final query = (options.data as Map)['query'] as String;
      return _json({
        'data': query.contains('SaveMediaListEntry')
            ? {
                'SaveMediaListEntry': {'mediaId': 42, 'progress': 8},
              }
            : query.contains('mediaListEntry')
            ? {
                'Media': {
                  'id': 42,
                  'type': 'MANGA',
                  'mediaListEntry': {'progress': 7},
                },
              }
            : {'Media': _aniRecord()},
      });
    });
    final client = _client(TrackingProvider.anilist, adapter);
    addTearDown(client.close);
    expect((await client.details(42)).mediaId, 42);
    expect(await client.currentProgress(42), 7);
    await client.updateProgress(42, 8);
    final mutation = jsonDecode(adapter.bodies.last) as Map;
    expect(mutation['variables'], {'id': 42, 'progress': 8});
    expect(mutation['query'], isNot(contains('status:')));
    expect(mutation['query'], isNot(contains('score:')));
    expect(mutation['query'], isNot(contains('progressVolumes:')));
  });

  test(
    'AniList rejects anime/mismatched selected record or progress identity',
    () async {
      final adapter = _Adapter(
        (_) => _json({
          'data': {'Media': _aniRecord(id: 12, type: 'ANIME')},
        }),
      );
      final client = _client(TrackingProvider.anilist, adapter);
      addTearDown(client.close);
      await expectLater(
        client.details(42),
        throwsA(isA<MangaTrackingException>()),
      );
      await expectLater(
        client.currentProgress(42),
        throwsA(isA<MangaTrackingException>()),
      );
    },
  );

  test(
    'MAL uses manga catalog and canonical PATCH form chapter-only update',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path.endsWith('/my_list_status')) {
          return _json({'num_chapters_read': 9});
        }
        if (request.uri.path.endsWith('/@me')) return _json({'id': 17});
        if (request.uri.path.endsWith('/manga')) {
          return _json({
            'data': [
              {
                'node': {
                  'id': 42,
                  'title': 'Chosen Manga',
                  'media_type': 'manga',
                  'num_chapters': 100,
                },
              },
            ],
          });
        }
        return _json({
          'id': 42,
          'title': 'Chosen Manga',
          'num_chapters': 100,
          'media_type': 'manga',
          'my_list_status': {'num_chapters_read': 8},
        });
      });
      final client = _client(TrackingProvider.myAnimeList, adapter);
      addTearDown(client.close);
      expect(await client.accountId(), '17');
      expect((await client.search('Chosen')).single.mediaId, 42);
      expect((await client.details(42)).totalChapters, 100);
      expect(await client.currentProgress(42), 8);
      await client.updateProgress(42, 9);
      expect(
        adapter.requests.every((r) => r.uri.host == 'api.myanimelist.net'),
        true,
      );
      expect(adapter.requests[1].uri.queryParameters['q'], 'Chosen');
      expect(adapter.requests.last.uri.path, '/v2/manga/42/my_list_status');
      expect(adapter.requests.last.method, 'PATCH');
      expect(adapter.bodies.last, 'num_chapters_read=9');
      expect(
        adapter.requests.last.contentType,
        Headers.formUrlEncodedContentType,
      );
    },
  );

  test(
    'account errors discard server body and never expose credentials',
    () async {
      final adapter = _Adapter(
        (_) => _json({'error': 'private-test-token echoed'}, status: 401),
      );
      final client = _client(TrackingProvider.anilist, adapter);
      addTearDown(client.close);
      await expectLater(
        client.accountId(),
        throwsA(
          isA<MangaTrackingException>()
              .having((e) => e.requiresReconnect, 'requires reconnect', true)
              .having(
                (e) => e.toString(),
                'safe message',
                isNot(contains('private-test-token')),
              ),
        ),
      );
    },
  );

  test('rate limit response preserves server retry delay', () async {
    final adapter = _Adapter(
      (_) => _json(
        {},
        status: 429,
        headers: {
          'retry-after': ['125'],
        },
      ),
    );
    final client = _client(TrackingProvider.myAnimeList, adapter);
    addTearDown(client.close);
    await expectLater(
      client.accountId(),
      throwsA(
        isA<MangaTrackingException>()
            .having((e) => e.retryable, 'retryable', true)
            .having(
              (e) => e.retryAfter,
              'server delay',
              const Duration(seconds: 125),
            ),
      ),
    );
  });

  test(
    'redirects cannot transfer a bearer token to another endpoint',
    () async {
      final adapter = _Adapter(
        (_) => _json(
          {},
          status: 302,
          headers: {
            'location': ['https://unrelated.invalid/collect'],
          },
        ),
      );
      final client = _client(TrackingProvider.myAnimeList, adapter);
      addTearDown(client.close);
      await expectLater(
        client.accountId(),
        throwsA(isA<MangaTrackingException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.followRedirects, false);
      expect(adapter.requests.single.maxRedirects, 0);
    },
  );

  test('oversized successful reply is rejected before parsing', () async {
    final adapter = _Adapter((_) => _json({'data': 'x' * (256 * 1024)}));
    final client = _client(TrackingProvider.anilist, adapter);
    addTearDown(client.close);
    await expectLater(
      client.accountId(),
      throwsA(isA<MangaTrackingException>()),
    );
  });

  test('shared request lane serializes clients and honors cooldown', () async {
    var now = DateTime.utc(2026);
    final waits = <Duration>[];
    final lane = MangaTrackingRequestLane(
      now: () => now,
      wait: (delay) async {
        waits.add(delay);
        now = now.add(delay);
      },
    );
    final gate = Completer<void>();
    final events = <String>[];
    final first = lane.run(() async {
      events.add('first');
      await gate.future;
    });
    final second = lane.run(() async {
      events.add('second');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['first']);
    lane.deferFor(const Duration(seconds: 9));
    gate.complete();
    await Future.wait([first, second]);
    expect(events, ['first', 'second']);
    expect(
      waits.fold(Duration.zero, (sum, delay) => sum + delay),
      const Duration(seconds: 9),
    );
  });

  test('SIMKL and invalid inputs do not issue a request', () async {
    final adapter = _Adapter((_) => _json({}));
    expect(
      () => _client(TrackingProvider.simkl, adapter),
      throwsA(isA<MangaTrackingException>()),
    );
    final client = _client(TrackingProvider.anilist, adapter);
    addTearDown(client.close);
    await expectLater(
      client.search('a'),
      throwsA(isA<MangaTrackingException>()),
    );
    await expectLater(
      client.updateProgress(-1, 3),
      throwsA(isA<FormatException>()),
    );
    expect(adapter.requests, isEmpty);
  });
}
