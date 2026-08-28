import 'package:anime_tv/features/local_media/data/plex_client.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Plex server address policy', () {
    test('accepts private HTTP and HTTPS while preserving a base path', () {
      expect(
        normalizePlexServerUri(' 192.168.1.25:32400/plex/// '),
        Uri.parse('http://192.168.1.25:32400/plex'),
      );
      expect(
        normalizePlexServerUri('HTTP://LOCALHOST:32400/'),
        Uri.parse('http://localhost:32400'),
      );
      expect(
        normalizePlexServerUri('http://[fd12:3456::7]:32400/'),
        Uri.parse('http://[fd12:3456::7]:32400'),
      );
      expect(
        normalizePlexServerUri('HTTPS://Plex.Example.COM/base/'),
        Uri.parse('https://plex.example.com/base'),
      );
    });

    test('rejects URL state, public HTTP, and named HTTP hosts', () {
      for (final value in const [
        '',
        'ftp://192.168.1.25/video',
        'http://user:secret@192.168.1.25:32400',
        'http://192.168.1.25:32400?X-Plex-Token=secret',
        'http://192.168.1.25:32400/#fragment',
        'http://192.168.1.25:32400/../admin',
        'http://192.168.1.25:32400/%2e%2e%2fadmin',
        'http://8.8.8.8:32400',
        'http://plex:32400',
        'http://plex.local:32400',
        'http://192.168.1.25:0',
        'http://192.168.1.25:not-a-port',
        'http://192.168.1.25:70000',
      ]) {
        expect(normalizePlexServerUri(value), isNull, reason: value);
      }
    });

    test('recognizes private numeric address boundaries', () {
      for (final host in const [
        'localhost',
        '10.0.0.1',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.50.2',
        '127.0.0.1',
        '169.254.1.2',
        'fd12:3456::7',
        'fe80::1',
        '::ffff:192.168.1.2',
      ]) {
        expect(isPrivatePlexHost(host), isTrue, reason: host);
      }
      for (final host in const [
        '8.8.8.8',
        '172.15.255.255',
        '172.32.0.1',
        '192.167.1.1',
        'example.com',
        'plex.local',
        '224.0.0.1',
        'ff02::1',
      ]) {
        expect(isPrivatePlexHost(host), isFalse, reason: host);
      }
    });
  });

  group('Plex XML client', () {
    test('reads server identity and supported library sections', () async {
      final requests = <RequestOptions>[];
      final client = PlexClient(
        _stubDio((request) {
          requests.add(request);
          if (request.uri.path == '/plex') {
            return _xml(
              request,
              '<MediaContainer friendlyName="Living Room" '
              'machineIdentifier="machine-123" version="1.41.4"/>',
            );
          }
          return _xml(request, '''
<MediaContainer size="3">
  <Directory key="1" type="movie" title="Movies &amp; Shorts"
      uuid="movie-uuid" thumb="/:/resources/movie.png"
      art="/:/resources/movie-fanart.jpg" />
  <Directory key="2" type="show" title="TV Shows" uuid="show-uuid" />
  <Directory key="3" type="artist" title="Music" />
</MediaContainer>
''');
        }),
      );

      final identity = await client.serverIdentity(_connection());
      final libraries = await client.libraries(_connection());

      expect(identity.name, 'Living Room');
      expect(identity.machineIdentifier, 'machine-123');
      expect(identity.version, '1.41.4');
      expect(libraries, hasLength(2));
      expect(libraries[0].title, 'Movies & Shorts');
      expect(libraries[0].isMovieLibrary, isTrue);
      expect(libraries[1].isShowLibrary, isTrue);
      expect(requests[1].uri.path, '/plex/library/sections');
      expect(requests[1].uri.query, isEmpty);
      expect(requests[1].headers['Accept'], 'application/xml');
      expect(requests[1].headers['X-Plex-Token'], _token);
      expect(requests[1].headers['X-Plex-Client-Identifier'], _clientId);
      expect(requests[1].followRedirects, isFalse);
      expect(requests[1].maxRedirects, 0);
      expect(requests[1].uri.toString(), isNot(contains(_token)));
    });

    test('browses shows, seasons, and episodes using response keys', () async {
      final requests = <RequestOptions>[];
      final client = PlexClient(
        _stubDio((request) {
          requests.add(request);
          switch (request.uri.path) {
            case '/plex/library/sections/2/all':
              return _xml(request, '''
<MediaContainer size="1" totalSize="14" offset="5">
  <Directory ratingKey="100" key="/library/metadata/100/children"
      type="show" title="Example Show" summary="A show"
      thumb="/library/metadata/100/thumb/1"
      art="/library/metadata/100/art/1">
    <Guid id="myanimelist://339?lang=en" />
    <Guid id="tmdb://1234" />
  </Directory>
</MediaContainer>
''');
            case '/plex/library/metadata/100/children':
              return _xml(request, '''
<MediaContainer size="1" totalSize="1">
  <Directory ratingKey="101" key="/library/metadata/101/children"
      type="season" title="Season 1" parentTitle="Example Show" index="1" />
</MediaContainer>
''');
            case '/plex/library/metadata/101/children':
              return _xml(request, '''
<MediaContainer size="1" totalSize="1">
  <Video ratingKey="102" key="/library/metadata/102" type="episode"
      title="A New Start" grandparentTitle="Example &amp; Co"
      parentTitle="Season 1" parentIndex="1" index="3"
      duration="1440000" viewOffset="45000"
      thumb="/library/metadata/102/thumb/1"
      grandparentThumb="/library/metadata/100/thumb/1">
    <Media id="media-1" container="mkv" videoCodec="hevc"
        audioCodec="aac" width="1920" videoResolution="1080">
      <Part id="part-1" key="/library/parts/500/file.mkv"
          file="/media/example.mkv" duration="1440000" size="1234567" />
    </Media>
  </Video>
</MediaContainer>
''');
          }
          throw StateError('Unexpected request: ${request.uri}');
        }),
      );
      const library = PlexLibrary(
        key: '2',
        title: 'TV Shows',
        type: PlexMediaType.show,
      );

      final shows = await client.libraryItems(
        _connection(),
        library,
        start: 5,
        size: 500,
      );
      final seasons = await client.children(_connection(), shows.items.single);
      final episodes = await client.children(
        _connection(),
        seasons.items.single,
      );
      final episode = episodes.items.single;

      expect(shows.offset, 5);
      expect(shows.nextOffset, 6);
      expect(shows.totalCount, 14);
      expect(shows.items.single.type, PlexMediaType.show);
      expect(shows.items.single.providerIds, {
        'myanimelist': '339',
        'tmdb': '1234',
      });
      expect(seasons.items.single.type, PlexMediaType.season);
      expect(episode.type, PlexMediaType.episode);
      expect(episode.grandparentTitle, 'Example & Co');
      expect(episode.index, 3);
      expect(episode.parentIndex, 1);
      expect(episode.viewOffsetMilliseconds, 45000);
      expect(episode.displayTitle, 'E03 · A New Start');
      expect(episode.parts, hasLength(1));
      expect(episode.parts.single.container, 'mkv');
      expect(episode.parts.single.sizeBytes, 1234567);
      expect(episode.parts.single.videoCodec, 'hevc');
      expect(episode.parts.single.audioCodec, 'aac');
      expect(episode.parts.single.videoWidth, 1920);
      expect(episode.parts.single.videoHeight, 1080);
      expect(requests[0].headers['X-Plex-Container-Start'], '5');
      expect(requests[0].headers['X-Plex-Container-Size'], '100');
      expect(requests[1].uri.path, '/plex/library/metadata/100/children');
      expect(requests[2].uri.path, '/plex/library/metadata/101/children');

      final playback = client.playbackUri(_connection(), episode);
      final image = client.imageUri(_connection(), episode);
      expect(playback.path, '/plex/library/parts/500/file.mkv');
      expect(image?.path, '/plex/library/metadata/102/thumb/1');
      expect(playback.query, isEmpty);
      expect(playback.toString(), isNot(contains(_token)));
      expect(image.toString(), isNot(contains(_token)));
      expect(
        client.authenticatedHeaders(_connection())['X-Plex-Token'],
        _token,
      );
      expect(
        client.authenticatedHeaders(_connection()),
        isNot(contains('Accept')),
      );
    });

    test('builds a token-free H.264/AAC Plex compatibility stream', () {
      const item = PlexMediaItem(
        ratingKey: 'episode-123',
        key: '/library/metadata/episode-123',
        title: 'Episode',
        type: PlexMediaType.episode,
        parts: [PlexMediaPart(key: '/library/parts/episode-123/file.mkv')],
      );
      final client = PlexClient();

      final uri = client.compatibilityPlaybackUri(
        _connection(),
        item,
        sessionId: 'session_1234567890abcdef',
      );

      expect(uri.path, '/plex/video/:/transcode/universal/start.m3u8');
      expect(uri.queryParameters['path'], '/library/metadata/episode-123');
      expect(uri.queryParameters['directPlay'], '0');
      expect(uri.queryParameters['directStream'], '0');
      expect(uri.queryParameters['videoCodec'], 'h264');
      expect(uri.queryParameters['audioCodec'], 'aac');
      expect(uri.queryParameters, isNot(contains('X-Plex-Token')));
      expect(uri.toString(), isNot(contains(_token)));
      expect(
        client.authenticatedHeaders(_connection())['X-Plex-Token'],
        _token,
      );
    });

    test('advances pagination past malformed records', () async {
      final client = PlexClient(
        _stubDio(
          (request) => _xml(request, '''
<MediaContainer size="2" totalSize="9" offset="4">
  <Directory type="show" title="Missing keys" />
  <Directory ratingKey="301" key="/library/metadata/301/children"
      type="show" title="Usable Show" />
</MediaContainer>
'''),
        ),
      );
      const library = PlexLibrary(
        key: '2',
        title: 'TV Shows',
        type: PlexMediaType.show,
      );

      final page = await client.libraryItems(_connection(), library, start: 4);

      expect(page.items.single.title, 'Usable Show');
      expect(page.offset, 4);
      expect(page.nextOffset, 6);
      expect(page.totalCount, 9);
    });

    test(
      'uses official Plex pagination response headers as fallback',
      () async {
        final client = PlexClient(
          _stubDio(
            (request) => _xml(
              request,
              '''
<MediaContainer size="1">
  <Directory ratingKey="401" key="/library/metadata/401/children"
      type="show" title="Header Page" />
</MediaContainer>
''',
              headers: Headers.fromMap({
                'X-Plex-Container-Start': ['8'],
                'X-Plex-Container-Total-Size': ['40'],
              }),
            ),
          ),
        );
        const library = PlexLibrary(
          key: '2',
          title: 'TV Shows',
          type: PlexMediaType.show,
        );

        final page = await client.libraryItems(_connection(), library);

        expect(page.offset, 8);
        expect(page.nextOffset, 9);
        expect(page.totalCount, 40);
      },
    );

    test('browses movies and parses every official Media Part', () async {
      final client = PlexClient(
        _stubDio(
          (request) => _xml(request, '''
<MediaContainer size="1" totalSize="1">
  <Video ratingKey="200" key="/library/metadata/200" type="movie"
      title="Example Movie" year="2025" duration="7200000">
    <Media id="m1" container="mp4">
      <Part id="p1" key="/library/parts/201/file.mp4" />
      <Part id="p2" key="/library/parts/202/file.mp4" container="mkv" />
    </Media>
  </Video>
</MediaContainer>
'''),
        ),
      );
      const library = PlexLibrary(
        key: '1',
        title: 'Movies',
        type: PlexMediaType.movie,
      );

      final page = await client.libraryItems(_connection(), library);
      final movie = page.items.single;

      expect(movie.type, PlexMediaType.movie);
      expect(movie.year, 2025);
      expect(movie.isPlayable, isTrue);
      expect(movie.parts, hasLength(2));
      expect(movie.parts[0].container, 'mp4');
      expect(movie.parts[1].container, 'mkv');
      expect(
        client.playbackUri(_connection(), movie, part: movie.parts[1]).path,
        '/plex/library/parts/202/file.mp4',
      );
    });

    test(
      'authenticated image bytes never follow redirects and stay bounded',
      () async {
        RequestOptions? imageRequest;
        final client = PlexClient(
          _stubDio((request) {
            imageRequest = request;
            return _binary(
              requestOptions: request,
              statusCode: 200,
              bytes: const [1, 2, 3, 4],
            );
          }),
        );
        final imageUri = Uri.parse(
          'http://192.168.1.25:32400/plex/library/metadata/102/thumb/1',
        );

        expect(await client.imageBytes(_connection(), imageUri), [1, 2, 3, 4]);
        expect(imageRequest?.followRedirects, isFalse);
        expect(imageRequest?.maxRedirects, 0);
        expect(imageRequest?.headers['X-Plex-Token'], _token);
        expect(imageRequest?.uri.toString(), isNot(contains(_token)));

        final redirected = PlexClient(
          _stubDio(
            (request) => _binary(
              requestOptions: request,
              statusCode: 302,
              bytes: const [],
              headers: Headers.fromMap({
                'location': ['https://attacker.example/collect'],
              }),
            ),
          ),
        );
        await expectLater(
          redirected.imageBytes(_connection(), imageUri),
          throwsA(
            isA<PlexException>().having(
              (error) => error.message,
              'message',
              contains('redirected'),
            ),
          ),
        );

        final oversized = PlexClient(
          _stubDio(
            (request) => _binary(
              requestOptions: request,
              statusCode: 200,
              bytes: const [1],
              headers: Headers.fromMap({
                Headers.contentLengthHeader: ['8388609'],
              }),
            ),
          ),
        );
        await expectLater(
          oversized.imageBytes(_connection(), imageUri),
          throwsA(
            isA<PlexException>().having(
              (error) => error.message,
              'message',
              contains('oversized'),
            ),
          ),
        );
      },
    );

    test('never follows redirects carrying the Plex token', () async {
      RequestOptions? captured;
      final client = PlexClient(
        _stubDio((request) {
          captured = request;
          return _raw(
            requestOptions: request,
            statusCode: 302,
            body: '',
            headers: Headers.fromMap({
              'location': ['https://attacker.example/collect'],
            }),
          );
        }),
      );

      await expectLater(
        client.libraries(_connection()),
        throwsA(
          isA<PlexException>().having(
            (error) => error.message,
            'message',
            contains('redirected'),
          ),
        ),
      );

      expect(captured?.followRedirects, isFalse);
      expect(captured?.maxRedirects, 0);
      expect(captured?.headers['X-Plex-Token'], _token);
      expect(captured?.uri.host, '192.168.1.25');
      expect(captured?.uri.toString(), isNot(contains(_token)));
    });

    test('rejects cross-origin and token-bearing resource keys', () {
      const externalPart = PlexMediaPart(
        key: 'https://attacker.example/collect',
      );
      const tokenPart = PlexMediaPart(
        key: '/library/parts/1?X-Plex-Token=$_token',
      );
      const item = PlexMediaItem(
        ratingKey: '1',
        key: '/library/metadata/1',
        title: 'Unsafe',
        type: PlexMediaType.movie,
        parts: [externalPart],
      );

      expect(
        () => PlexClient().playbackUri(_connection(), item),
        throwsA(isA<PlexException>()),
      );
      expect(
        () => PlexClient().playbackUri(_connection(), item, part: tokenPart),
        throwsA(
          isA<PlexException>().having(
            (error) => error.toString(),
            'sanitized error',
            isNot(contains(_token)),
          ),
        ),
      );
    });

    test('bounds streamed XML and maps malformed XML safely', () async {
      final oversized = PlexClient(
        _stubDio(
          (request) => _xml(
            request,
            '<MediaContainer padding="'
            '${List<String>.filled(4 * 1024 * 1024 + 1, 'x').join()}"/>',
          ),
        ),
      );
      await expectLater(
        oversized.libraries(_connection()),
        throwsA(
          isA<PlexException>().having(
            (error) => error.message,
            'message',
            contains('too much data'),
          ),
        ),
      );

      final malformed = PlexClient(
        _stubDio((request) => _xml(request, '<MediaContainer><Video>')),
      );
      await expectLater(
        malformed.libraries(_connection()),
        throwsA(
          isA<PlexException>()
              .having(
                (error) => error.message,
                'message',
                contains('invalid XML'),
              )
              .having(
                (error) => error.toString(),
                'sanitized error',
                isNot(contains(_token)),
              ),
        ),
      );

      final entityDocument = PlexClient(
        _stubDio(
          (request) => _xml(
            request,
            '<!DOCTYPE MediaContainer [<!ENTITY x "expanded">]>'
            '<MediaContainer title="&x;"/>',
          ),
        ),
      );
      await expectLater(
        entityDocument.libraries(_connection()),
        throwsA(
          isA<PlexException>().having(
            (error) => error.message,
            'message',
            contains('unsupported XML'),
          ),
        ),
      );
    });

    test('rejects invalid connection headers before making a request', () {
      final injected = _connection().copyWith(
        accessToken: 'valid-token\r\nInjected: yes',
      );
      expect(
        () => PlexClient().authenticatedHeaders(injected),
        throwsA(isA<PlexException>()),
      );
      expect(_connection().toString(), isNot(contains(_token)));
    });

    test('searches nested Plex hubs and deduplicates server results', () async {
      RequestOptions? captured;
      final client = PlexClient(
        _stubDio((request) {
          captured = request;
          return _xml(request, '''
<MediaContainer size="3">
  <Hub type="movie">
    <Video ratingKey="200" key="/library/metadata/200" type="movie"
        title="Search Movie" viewOffset="30000">
      <Media container="mkv">
        <Part key="/library/parts/200/file.mkv" />
      </Media>
    </Video>
  </Hub>
  <Hub type="movie">
    <Video ratingKey="200" key="/library/metadata/200" type="movie"
        title="Search Movie Duplicate" />
  </Hub>
  <Hub type="show">
    <Directory ratingKey="300" key="/library/metadata/300/children"
        type="show" title="Search Show" />
  </Hub>
</MediaContainer>
''');
        }),
      );

      final results = await client.search(_connection(), ' Search ');

      expect(results.map((item) => item.title), [
        'Search Movie',
        'Search Show',
      ]);
      expect(results.first.isPlayable, isTrue);
      expect(results.last.isFolder, isTrue);
      expect(captured?.uri.path, '/plex/hubs/search');
      expect(captured?.uri.queryParameters['query'], 'Search');
      expect(captured?.headers['X-Plex-Token'], _token);
      expect(captured?.uri.toString(), isNot(contains(_token)));
    });

    test('reports timeline state with token only in request headers', () async {
      RequestOptions? captured;
      final client = PlexClient(
        _stubDio((request) {
          captured = request;
          return _raw(requestOptions: request, statusCode: 200, body: '');
        }),
      );
      const item = PlexMediaItem(
        ratingKey: 'episode-123',
        key: '/library/metadata/episode-123',
        title: 'Episode',
        type: PlexMediaType.episode,
        durationMilliseconds: 1_440_000,
      );

      await client.reportTimeline(
        _connection(),
        item,
        position: const Duration(seconds: 75),
        playing: false,
      );

      expect(captured?.uri.path, '/plex/:/timeline');
      expect(captured?.uri.queryParameters['ratingKey'], 'episode-123');
      expect(captured?.uri.queryParameters['time'], '75000');
      expect(captured?.uri.queryParameters['state'], 'stopped');
      expect(captured?.headers['X-Plex-Token'], _token);
      expect(captured?.uri.toString(), isNot(contains(_token)));
    });
  });
}

const _token = 'plex-access-token-123456';
const _clientId = 'tetotv-client-123456';

PlexConnection _connection() => PlexConnection(
  baseUri: Uri.parse('http://192.168.1.25:32400/plex'),
  accessToken: _token,
  clientIdentifier: _clientId,
);

Dio _stubDio(Response<dynamic> Function(RequestOptions request) responder) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(responder(request)),
    ),
  );
  return dio;
}

Response<ResponseBody> _xml(
  RequestOptions request,
  String body, {
  Headers? headers,
}) => _raw(
  requestOptions: request,
  statusCode: 200,
  body: body,
  headers: headers,
);

Response<ResponseBody> _raw({
  required RequestOptions requestOptions,
  required int statusCode,
  required String body,
  Headers? headers,
}) => Response<ResponseBody>(
  requestOptions: requestOptions,
  statusCode: statusCode,
  headers: headers ?? Headers(),
  data: ResponseBody.fromString(
    body,
    statusCode,
    headers: const {
      Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
    },
  ),
);

Response<ResponseBody> _binary({
  required RequestOptions requestOptions,
  required int statusCode,
  required List<int> bytes,
  Headers? headers,
}) => Response<ResponseBody>(
  requestOptions: requestOptions,
  statusCode: statusCode,
  headers: headers ?? Headers(),
  data: ResponseBody.fromBytes(bytes, statusCode),
);
