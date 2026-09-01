import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/manga_source_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('manga catalog client', () {
    const storage = FlutterSecureStorage();

    setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));
    tearDown(
      () => FlutterSecureStorage.setMockInitialValues(<String, String>{}),
    );

    test('auto-detects OPDS 2 and a declarative repository manifest', () async {
      final adapter = _RoutingAdapter(<String, _ResponseFactory>{
        'https://catalog.example/opds': (_) =>
            ResponseBody.fromString(_opds2Feed, HttpStatus.ok),
        'https://catalog.example/repository.json': (_) =>
            ResponseBody.fromString(_repositoryManifest, HttpStatus.ok),
      });
      final client = _client(adapter, storage: storage);

      final feed = await client.fetch(
        Uri.parse('https://catalog.example/opds'),
      );
      final repository = await client.fetch(
        Uri.parse('https://catalog.example/repository.json'),
      );

      expect(feed, isA<MangaFetchedFeed>());
      expect((feed as MangaFetchedFeed).feed.title, 'Library');
      expect(repository, isA<MangaFetchedRepository>());
      expect(
        (repository as MangaFetchedRepository)
            .repository
            .sources
            .single
            .protocol,
        MangaSourceProtocol.opds2,
      );
      expect(adapter.requests, hasLength(2));
    });

    test(
      'manually follows and validates redirects without automatic retry',
      () async {
        final validated = <Uri>[];
        final adapter = _RoutingAdapter(<String, _ResponseFactory>{
          'https://catalog.example/start': (_) => ResponseBody.fromBytes(
            const <int>[],
            HttpStatus.found,
            headers: <String, List<String>>{
              HttpHeaders.locationHeader: <String>['/final.json'],
            },
          ),
          'https://catalog.example/final.json': (_) =>
              ResponseBody.fromString(_opds2Feed, HttpStatus.ok),
          'https://catalog.example/failure': (_) =>
              ResponseBody.fromString('unavailable', HttpStatus.badGateway),
        });
        final client = _client(
          adapter,
          storage: storage,
          validateTarget: (uri) async => validated.add(uri),
        );

        final result = await client.fetch(
          Uri.parse('https://catalog.example/start'),
        );
        expect(
          result.finalUri.toString(),
          'https://catalog.example/final.json',
        );
        expect(
          validated,
          containsAll(<Uri>[
            Uri.parse('https://catalog.example/start'),
            Uri.parse('https://catalog.example/final.json'),
          ]),
        );

        await expectLater(
          client.fetch(Uri.parse('https://catalog.example/failure')),
          throwsA(
            isA<MangaCatalogHttpException>().having(
              (error) => error.statusCode,
              'statusCode',
              HttpStatus.badGateway,
            ),
          ),
        );
        expect(
          adapter.requests
              .where((request) => request.uri.path == '/failure')
              .length,
          1,
        );
        expect(
          adapter.requests.every((request) => !request.followRedirects),
          isTrue,
        );
      },
    );

    test(
      'keeps auth in secure storage and blocks cross-origin credential leaks',
      () async {
        final credentials = MangaSourceCredentialStore(storage);
        await credentials.write(
          'secure.source',
          MangaSourceCredential.basic(username: 'reader', password: 'secret'),
        );
        final stored = await storage.readAll();
        expect(stored.keys.single, startsWith('manga_source_credential_v1_'));
        expect(stored.values.single, isNot(contains('Authorization')));

        final adapter = _RoutingAdapter(<String, _ResponseFactory>{
          'https://catalog.example/private': (_) => ResponseBody.fromBytes(
            const <int>[],
            HttpStatus.found,
            headers: <String, List<String>>{
              HttpHeaders.locationHeader: <String>[
                'https://other.example/catalog',
              ],
            },
          ),
        });
        final client = MangaCatalogClient(
          credentials: credentials,
          dio: _dio(adapter),
          validateTarget: (_) async {},
        );

        await expectLater(
          client.fetch(
            Uri.parse('https://catalog.example/private'),
            sourceId: 'secure.source',
          ),
          throwsFormatException,
        );
        expect(adapter.requests, hasLength(1));
        expect(
          adapter.requests.single.headers[HttpHeaders.authorizationHeader],
          'Basic ${base64Encode(utf8.encode('reader:secret'))}',
        );
      },
    );

    test('caps streamed responses after decompression-sized chunks', () async {
      Stream<Uint8List> oversized() async* {
        yield Uint8List.fromList(List<int>.filled(40, 65));
        yield Uint8List.fromList(List<int>.filled(40, 66));
      }

      final adapter = _RoutingAdapter(<String, _ResponseFactory>{
        'https://catalog.example/large': (_) =>
            ResponseBody(oversized(), HttpStatus.ok),
      });
      final client = MangaCatalogClient(
        credentials: MangaSourceCredentialStore(storage),
        dio: _dio(adapter),
        validateTarget: (_) async {},
        maximumResponseBytes: 64,
      );

      await expectLater(
        client.fetch(Uri.parse('https://catalog.example/large')),
        throwsFormatException,
      );
      expect(adapter.requests, hasLength(1));
    });
  });

  group('manga store', () {
    late Database database;
    late MangaStore store;
    const storage = FlutterSecureStorage();
    final now = DateTime.utc(2026, 9, 1, 12);

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      sqfliteFfiInit();
      database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: configureTetoTvDatabase,
          onCreate: (db, _) => createMangaTables(db),
        ),
      );
      store = MangaStore(
        databaseProvider: () async => database,
        credentials: MangaSourceCredentialStore(storage),
      );
    });

    tearDown(() async {
      await database.close();
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });

    test('CRUDs sources and normalized cache without secret columns', () async {
      final source = StoredMangaSource(
        id: 'example.source',
        uri: Uri.parse('https://catalog.example/opds'),
        name: 'Example',
        kind: StoredMangaSourceKind.opds2,
        updatedAt: now,
      );
      await store.upsertSource(source);
      await store.putCache(
        MangaCatalogCacheRecord(
          sourceId: source.id,
          payload: <String, Object?>{
            'title': 'Cached library',
            'items': <Object?>[
              <String, Object?>{'id': 'one', 'title': 'Volume One'},
            ],
          },
          fetchedAt: now,
        ),
      );

      expect((await store.source(source.id))!.uri, source.uri);
      expect((await store.sources()).single.name, 'Example');
      expect(
        (await store.cache(source.id))!.payload['title'],
        'Cached library',
      );

      await store.upsertSource(
        StoredMangaSource(
          id: source.id,
          uri: source.uri,
          name: 'Renamed',
          kind: source.kind,
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      );
      expect((await store.cache(source.id))!.payload, isNotEmpty);

      final columns = await database.rawQuery(
        'PRAGMA table_info(manga_sources)',
      );
      final names = columns.map((row) => row['name']).toSet();
      expect(
        names,
        isNot(containsAll(<String>['headers', 'token', 'password', 'api_key'])),
      );

      await MangaSourceCredentialStore(
        storage,
      ).write(source.id, MangaSourceCredential.bearer('protected'));
      await store.deleteSource(source.id);
      expect(await store.source(source.id), isNull);
      expect(await MangaSourceCredentialStore(storage).read(source.id), isNull);
    });

    test('CRUDs library and reading progress with bounded metadata', () async {
      final entry = MangaLibraryEntry(
        ownerKey: 'profile-1',
        sourceId: 'example.source',
        entryId: 'series-1',
        title: 'Series One',
        metadata: <String, Object?>{
          'authors': <String>['Writer'],
          'genres': <String>['Fantasy'],
          'catalogPath': <String>[
            'https://catalog.example/opds',
            'https://catalog.example/shelf/fantasy',
          ],
        },
        coverUri: Uri.parse('https://images.example/cover.jpg'),
        updatedAt: now,
      );
      await store.upsertLibraryEntry(entry);
      await store.upsertProgress(
        MangaReadingProgress(
          ownerKey: entry.ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
          chapterId: 'chapter-4',
          chapterNumber: 4,
          pageIndex: 12,
          pageOffset: 0.25,
          pageCount: 40,
          completed: false,
          updatedAt: now,
        ),
      );

      expect(
        (await store.libraryEntries('profile-1')).single.title,
        'Series One',
      );
      expect(
        (await store.libraryEntries(
          'profile-1',
        )).single.metadata['catalogPath'],
        <String>[
          'https://catalog.example/opds',
          'https://catalog.example/shelf/fantasy',
        ],
      );
      expect(
        (await store.progress(
          ownerKey: 'profile-1',
          sourceId: 'example.source',
          entryId: 'series-1',
        ))!.pageIndex,
        12,
      );

      await store.deleteProgress(
        ownerKey: 'profile-1',
        sourceId: 'example.source',
        entryId: 'series-1',
      );
      await store.deleteLibraryEntry(
        ownerKey: 'profile-1',
        sourceId: 'example.source',
        entryId: 'series-1',
      );
      expect(await store.libraryEntries('profile-1'), isEmpty);
      expect(await store.recentProgress('profile-1'), isEmpty);
    });

    test(
      'rejects headers and page URLs hidden in raw persistent maps',
      () async {
        await store.upsertSource(
          StoredMangaSource(
            id: 'example.source',
            uri: Uri.parse('https://catalog.example/opds'),
            name: 'Example',
            kind: StoredMangaSourceKind.opds2,
            updatedAt: now,
          ),
        );
        for (final payload in <Map<String, Object?>>[
          <String, Object?>{
            'requestHeaders': <String, String>{'Authorization': 'secret'},
          },
          <String, Object?>{
            'pages': <String>['https://cdn.example/page-1.jpg'],
          },
          <String, Object?>{'pageUrl': 'https://cdn.example/page-1.jpg'},
        ]) {
          await expectLater(
            store.putCache(
              MangaCatalogCacheRecord(
                sourceId: 'example.source',
                payload: payload,
                fetchedAt: now,
              ),
            ),
            throwsFormatException,
            reason: payload.toString(),
          );
        }
        expect(await database.query('manga_source_cache'), isEmpty);
      },
    );

    test(
      'CRUDs jobs and local page records without remote capabilities',
      () async {
        final job = MangaDownloadJob(
          id: 'job-1',
          sourceId: 'example.source',
          entryId: 'series-1',
          chapterId: 'chapter-1',
          seriesTitle: 'Series One',
          chapterLabel: 'Chapter 1',
          status: MangaDownloadJobStatus.queued,
          relativeDirectory: 'example.source/series-1/chapter-1',
          pageCount: 1,
          completedPages: 0,
          receivedBytes: 0,
          queuePosition: 0,
          retryCount: 0,
          createdAt: now,
          updatedAt: now,
        );
        await store.upsertDownloadJob(job);
        await store.upsertDownloadPage(
          MangaDownloadPage(
            jobId: job.id,
            pageIndex: 0,
            stableKeyHash: 'b' * 64,
            relativePath: '${job.relativeDirectory}/0000.webp',
            mimeType: 'image/webp',
            byteLength: 123,
            sha256: 'a' * 64,
          ),
        );

        expect((await store.downloadJobs()).single.id, job.id);
        expect((await store.downloadPages(job.id)).single.byteLength, 123);

        final columns = await database.rawQuery(
          'PRAGMA table_info(manga_download_pages)',
        );
        final names = columns.map((row) => row['name']).toSet();
        expect(names, isNot(contains('url')));
        expect(names, isNot(contains('headers')));

        await store.deleteDownloadPage(job.id, 0);
        expect(await store.downloadPages(job.id), isEmpty);
        await store.deleteDownloadJob(job.id);
        expect(await store.downloadJob(job.id), isNull);
      },
    );

    test(
      'rejects unsafe URLs, paths, hashes, and inconsistent progress',
      () async {
        await expectLater(
          store.upsertSource(
            StoredMangaSource(
              id: 'unsafe.source',
              uri: Uri.parse('http://catalog.example/opds'),
              name: 'Unsafe',
              kind: StoredMangaSourceKind.opds2,
              updatedAt: now,
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          store.upsertProgress(
            MangaReadingProgress(
              ownerKey: 'profile-1',
              sourceId: 'example.source',
              entryId: 'series-1',
              chapterId: 'chapter-1',
              pageIndex: 10,
              pageOffset: 0,
              pageCount: 10,
              completed: false,
              updatedAt: now,
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          store.upsertDownloadPage(
            const MangaDownloadPage(
              jobId: 'job-1',
              pageIndex: 0,
              relativePath: '../outside.webp',
              mimeType: 'image/webp',
              byteLength: 1,
              sha256: 'bad',
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          store.upsertLibraryEntry(
            MangaLibraryEntry(
              ownerKey: 'profile-1',
              sourceId: 'example.source',
              entryId: 'credential-path',
              title: 'Credential path',
              metadata: const <String, Object?>{
                'catalogPath': <String>[
                  'https://catalog.example/opds?access_token=secret',
                ],
              },
              updatedAt: now,
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          store.upsertLibraryEntry(
            MangaLibraryEntry(
              ownerKey: 'profile-1',
              sourceId: 'example.source',
              entryId: 'credential-cover',
              title: 'Credential cover',
              metadata: const <String, Object?>{},
              coverUri: Uri.parse(
                'https://images.example/cover.jpg?X-Amz-Signature=secret',
              ),
              updatedAt: now,
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          store.upsertDownloadPage(
            MangaDownloadPage(
              jobId: 'job-1',
              pageIndex: 0,
              relativePath: 'jobs/job-1/0000.avif',
              mimeType: 'image/avif',
              byteLength: 1,
              sha256: 'a' * 64,
            ),
          ),
          throwsFormatException,
        );
      },
    );
  });
}

MangaCatalogClient _client(
  HttpClientAdapter adapter, {
  required FlutterSecureStorage storage,
  MangaPublicTargetValidator? validateTarget,
}) => MangaCatalogClient(
  credentials: MangaSourceCredentialStore(storage),
  dio: _dio(adapter),
  validateTarget: validateTarget ?? (_) async {},
);

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

typedef _ResponseFactory = ResponseBody Function(RequestOptions options);

class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  final Map<String, _ResponseFactory> routes;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final factory = routes[options.uri.toString()];
    if (factory == null) {
      return ResponseBody.fromString('not found', HttpStatus.notFound);
    }
    return factory(options);
  }

  @override
  void close({bool force = false}) {}
}

final String _opds2Feed = jsonEncode(<String, Object?>{
  'metadata': <String, Object?>{'title': 'Library'},
  'publications': <Object?>[],
  'navigation': <Object?>[],
});

final String _repositoryManifest = jsonEncode(<String, Object?>{
  'format': 'tetotv-manga-repository',
  'schemaVersion': 1,
  'id': 'example.repo',
  'name': 'Example repository',
  'sources': <Object?>[
    <String, Object?>{
      'id': 'example.source',
      'name': 'Example OPDS',
      'protocol': 'opds2',
      'entryPoint': './opds',
    },
  ],
});
