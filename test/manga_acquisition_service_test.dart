import 'dart:async';
import 'dart:io';

import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/manga/application/manga_acquisition_controller.dart';
import 'package:anime_tv/features/manga/data/manga_acquisition_service.dart';
import 'package:anime_tv/features/manga/data/manga_archive_service.dart';
import 'package:anime_tv/features/manga/data/manga_image_safety.dart'
    show maximumMangaImageWidth;
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_acquisition_models.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('MangaAcquisitionService', () {
    test(
      'downloads a CBZ into app-owned storage and returns a reader request',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final archive = Archive()
          ..add(ArchiveFile.bytes('page10.jpg', _jpegBytes))
          ..add(ArchiveFile.bytes('page2.png', _pngBytes));
        final zip = ZipEncoder().encodeBytes(archive);
        final uri = Uri.parse('https://catalog.example/chapter.cbz');
        fixture.transport.enqueue(
          uri,
          (_) => _response(zip, contentType: 'application/vnd.comicbook+zip'),
        );

        final operation = fixture.service.start(
          MangaAcquisitionRequest.fromCbzSelection(
            jobId: 'chapter-job',
            selection: _FakeCbzSelection(
              sourceId: 'test.source',
              publicationId: 'publication-1',
              uri: uri,
              mediaType: 'application/vnd.comicbook+zip',
              headers: const <String, String>{
                HttpHeaders.authorizationHeader: 'Bearer secret',
              },
            ),
            chapterId: 'chapter-1',
            seriesTitle: 'Test Series',
            chapterTitle: 'Chapter 1',
          ),
        );
        final progress = <MangaAcquisitionProgress>[];
        final subscription = operation.progress.listen(progress.add);
        final result = await operation.completed;
        await subscription.cancel();

        expect(result.pages, hasLength(2));
        expect(
          result.pages.map((page) => page.resource),
          everyElement(isA<MangaTrustedLocalPageResource>()),
        );
        for (final page in result.pages) {
          final resource = page.resource as MangaTrustedLocalPageResource;
          expect(resource.area, MangaLocalStorageArea.downloadedPages);
          expect(await fixture.roots.resolvePage(resource).exists(), isTrue);
        }
        expect(
          progress.map((event) => event.phase),
          containsAllInOrder(<MangaAcquisitionPhase>[
            MangaAcquisitionPhase.resolving,
            MangaAcquisitionPhase.downloading,
            MangaAcquisitionPhase.extracting,
            MangaAcquisitionPhase.completed,
          ]),
        );
        expect(fixture.keepAlive.acquired, 1);
        expect(fixture.keepAlive.released, 1);
        expect(
          fixture.persistence.jobs['chapter-job']!.status,
          MangaDownloadJobStatus.completed,
        );
        expect(fixture.persistence.pageRows('chapter-job'), hasLength(2));
        expect(fixture.transport.requests.single.headers, <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer secret',
        });
        expect(await _partFiles(fixture.roots.downloadedPages), isEmpty);
        expect(await _partFiles(fixture.roots.extractedArchives), isEmpty);
      },
    );

    test(
      'downloads reading order and never persists URLs or headers',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final first = Uri.parse('https://catalog.example/pages/1.png');
        final second = Uri.parse('https://cdn.example/pages/2.jpg');
        fixture.transport.enqueue(
          first,
          (_) => _response(_pngBytes, contentType: 'image/png'),
        );
        fixture.transport.enqueue(
          second,
          (_) => _response(_jpegBytes, contentType: 'image/jpeg'),
        );
        final request = _request(
          acquisition: MangaReadingOrderAcquisition(<MangaReadingOrderPage>[
            MangaReadingOrderPage(
              uri: first,
              pixelWidth: 800,
              pixelHeight: 1200,
              isCover: true,
            ),
            MangaReadingOrderPage(uri: second),
          ]),
          credentialOrigin: Uri.parse('https://catalog.example/feed'),
        );

        final result = await fixture.service.start(request).completed;

        expect(result.pages, hasLength(2));
        expect(result.pages.first.pixelWidth, 800);
        expect(result.pages.first.pixelHeight, 1200);
        expect(result.pages.first.isCover, isTrue);
        expect(fixture.transport.requests[0].headers, <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer secret',
        });
        expect(fixture.transport.requests[1].headers, isEmpty);
        final storedPages = fixture.persistence.pageRows('chapter-job');
        expect(storedPages, hasLength(2));
        for (final page in storedPages) {
          expect(page.relativePath, isNot(contains('http')));
          expect(page.relativePath, isNot(contains('secret')));
          expect(page.stableKeyHash, isNull);
        }
        final storedJob = fixture.persistence.jobs['chapter-job']!;
        expect(storedJob.manifestFingerprint, isNull);
        expect(storedJob.relativeDirectory, isNot(contains('http')));
        expect(storedJob.errorMessage, isNull);
      },
    );

    test('uses extension page headers only on the page origin', () async {
      final fixture = await _AcquisitionFixture.create();
      addTearDown(fixture.dispose);
      final initial = Uri.parse('https://images.example/pages/1.png');
      final redirected = Uri.parse('https://cdn.example/pages/1.png');
      fixture.transport.enqueue(
        initial,
        (_) => MangaAcquisitionHttpResponse(
          statusCode: HttpStatus.found,
          headers: <String, String>{
            HttpHeaders.locationHeader: redirected.toString(),
          },
          body: const Stream<List<int>>.empty(),
        ),
      );
      fixture.transport.enqueue(
        redirected,
        (_) => _response(_pngBytes, contentType: 'image/png'),
      );
      final request = _request(
        acquisition: MangaReadingOrderAcquisition(<MangaReadingOrderPage>[
          MangaReadingOrderPage(
            uri: initial,
            headers: const <String, String>{
              HttpHeaders.refererHeader: 'https://reader.example/chapter/1',
              HttpHeaders.userAgentHeader: 'Seanime fixture',
              HttpHeaders.cookieHeader: 'source_session=fixture',
            },
          ),
        ]),
      );

      final result = await fixture.service.start(request).completed;

      expect(result.pages, hasLength(1));
      expect(fixture.transport.requests, hasLength(2));
      expect(fixture.transport.requests.first.headers, <String, String>{
        HttpHeaders.refererHeader: 'https://reader.example/chapter/1',
        HttpHeaders.userAgentHeader: 'Seanime fixture',
        HttpHeaders.cookieHeader: 'source_session=fixture',
      });
      expect(fixture.transport.requests.last.headers, isEmpty);
      expect(fixture.persistence.pageRows('chapter-job'), hasLength(1));
    });

    test('blocks authenticated cross-origin redirects', () async {
      final fixture = await _AcquisitionFixture.create();
      addTearDown(fixture.dispose);
      final initial = Uri.parse('https://catalog.example/chapter.cbz');
      var discarded = 0;
      fixture.transport.enqueue(
        initial,
        (_) => MangaAcquisitionHttpResponse(
          statusCode: HttpStatus.found,
          headers: const <String, String>{
            HttpHeaders.locationHeader: 'https://cdn.example/chapter.cbz',
          },
          body: const Stream<List<int>>.empty(),
          discard: () async => discarded++,
        ),
      );

      await expectLater(
        fixture.service
            .start(
              _request(
                acquisition: MangaCbzDownloadAcquisition(initial),
                credentialOrigin: Uri.parse('https://catalog.example/feed'),
              ),
            )
            .completed,
        throwsA(
          isA<MangaAcquisitionException>().having(
            (error) => error.code,
            'code',
            MangaAcquisitionFailureCode.redirectRejected,
          ),
        ),
      );

      expect(discarded, 1);
      expect(fixture.transport.requests, hasLength(1));
      expect(
        fixture.transport.requests.single.headers,
        contains(HttpHeaders.authorizationHeader),
      );
      expect(
        fixture.persistence.jobs['chapter-job']!.status,
        MangaDownloadJobStatus.failed,
      );
      expect(fixture.keepAlive.released, 1);
    });

    test('validates every target before issuing a request', () async {
      final fixture = await _AcquisitionFixture.create(
        validateTarget: (uri) async {
          if (uri.host == 'blocked.example') {
            throw const FormatException('private target');
          }
        },
      );
      addTearDown(fixture.dispose);
      final blocked = Uri.parse('https://blocked.example/page.png');

      await expectLater(
        fixture.service
            .start(
              _request(
                acquisition: MangaReadingOrderAcquisition(
                  <MangaReadingOrderPage>[MangaReadingOrderPage(uri: blocked)],
                ),
              ),
            )
            .completed,
        throwsA(
          isA<MangaAcquisitionException>().having(
            (error) => error.code,
            'code',
            MangaAcquisitionFailureCode.unsafeTarget,
          ),
        ),
      );

      expect(fixture.transport.requests, isEmpty);
      expect(fixture.persistence.pageRows('chapter-job'), isEmpty);
      expect(await fixture.roots.downloadedPages.list().toList(), isEmpty);
    });

    test('rejects oversized responses before reading their body', () async {
      final fixture = await _AcquisitionFixture.create();
      addTearDown(fixture.dispose);
      final uri = Uri.parse('https://cdn.example/page.png');
      var listened = false;
      fixture.transport.enqueue(
        uri,
        (_) => MangaAcquisitionHttpResponse(
          statusCode: HttpStatus.ok,
          headers: <String, String>{
            HttpHeaders.contentTypeHeader: 'image/png',
            HttpHeaders.contentLengthHeader:
                '${maximumMangaArchivePageBytes + 1}',
          },
          body: Stream<List<int>>.multi((controller) {
            listened = true;
            controller.add(_pngBytes);
            controller.close();
          }),
        ),
      );

      await expectLater(
        fixture.service
            .start(
              _request(
                acquisition: MangaReadingOrderAcquisition(
                  <MangaReadingOrderPage>[MangaReadingOrderPage(uri: uri)],
                ),
              ),
            )
            .completed,
        throwsA(
          isA<MangaAcquisitionException>().having(
            (error) => error.code,
            'code',
            MangaAcquisitionFailureCode.responseTooLarge,
          ),
        ),
      );

      expect(listened, isFalse);
      expect(await _partFiles(fixture.roots.downloadedPages), isEmpty);
    });

    test(
      'rejects unsafe reading-order image dimensions before persistence',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final uri = Uri.parse('https://cdn.example/dimension-bomb.png');
        fixture.transport.enqueue(
          uri,
          (_) => _response(
            _pngHeader(width: maximumMangaImageWidth + 1, height: 1),
            contentType: 'image/png',
          ),
        );

        await expectLater(
          fixture.service
              .start(
                _request(
                  acquisition: MangaReadingOrderAcquisition(
                    <MangaReadingOrderPage>[MangaReadingOrderPage(uri: uri)],
                  ),
                ),
              )
              .completed,
          throwsA(
            isA<MangaAcquisitionException>().having(
              (error) => error.code,
              'code',
              MangaAcquisitionFailureCode.unsupportedContent,
            ),
          ),
        );

        expect(fixture.persistence.pageRows('chapter-job'), isEmpty);
        expect(await fixture.roots.downloadedPages.list().toList(), isEmpty);
      },
    );

    test(
      'cancel stops the transfer, cleans staging, and releases keep-alive',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final uri = Uri.parse('https://cdn.example/page.png');
        fixture.transport.enqueue(uri, (call) {
          final controller = StreamController<List<int>>();
          final remove = call.cancellation.onCancel(() {
            controller.addError(
              const MangaAcquisitionException(
                MangaAcquisitionFailureCode.cancelled,
                'The manga download was cancelled.',
              ),
            );
            unawaited(controller.close());
          });
          scheduleMicrotask(() => controller.add(_pngBytes));
          return MangaAcquisitionHttpResponse(
            statusCode: HttpStatus.ok,
            headers: const <String, String>{
              HttpHeaders.contentTypeHeader: 'image/png',
            },
            body: controller.stream,
            release: remove,
          );
        });
        final operation = fixture.service.start(
          _request(
            acquisition: MangaReadingOrderAcquisition(<MangaReadingOrderPage>[
              MangaReadingOrderPage(uri: uri),
            ]),
          ),
        );
        final firstBytes = Completer<void>();
        final phases = <MangaAcquisitionPhase>[];
        final subscription = operation.progress.listen((event) {
          phases.add(event.phase);
          if (event.receivedBytes > 0 && !firstBytes.isCompleted) {
            firstBytes.complete();
          }
        });
        final completion = expectLater(
          operation.completed,
          throwsA(
            isA<MangaAcquisitionException>().having(
              (error) => error.code,
              'code',
              MangaAcquisitionFailureCode.cancelled,
            ),
          ),
        );

        await firstBytes.future;
        await operation.cancel();
        await completion;
        await subscription.cancel();

        expect(phases, contains(MangaAcquisitionPhase.cancelled));
        expect(
          fixture.persistence.jobs['chapter-job']!.status,
          MangaDownloadJobStatus.cancelled,
        );
        expect(fixture.keepAlive.acquired, 1);
        expect(fixture.keepAlive.released, 1);
        expect(await fixture.roots.downloadedPages.list().toList(), isEmpty);
      },
    );

    test('cancel interrupts CBZ extraction and records cancellation', () async {
      final fixture = await _AcquisitionFixture.create(
        archiveService: const MangaArchiveService(
          workerStartDelay: Duration(seconds: 1),
        ),
      );
      addTearDown(fixture.dispose);
      final archive = Archive()..add(ArchiveFile.bytes('page.png', _pngBytes));
      final uri = Uri.parse('https://catalog.example/slow-chapter.cbz');
      fixture.transport.enqueue(
        uri,
        (_) => _response(
          ZipEncoder().encodeBytes(archive),
          contentType: 'application/vnd.comicbook+zip',
        ),
      );
      final operation = fixture.service.start(
        _request(acquisition: MangaCbzDownloadAcquisition(uri)),
      );
      final extracting = Completer<void>();
      final subscription = operation.progress.listen((progress) {
        if (progress.phase == MangaAcquisitionPhase.extracting &&
            !extracting.isCompleted) {
          extracting.complete();
        }
      });
      addTearDown(subscription.cancel);

      await extracting.future.timeout(const Duration(seconds: 2));
      await operation.cancel();

      await expectLater(
        operation.completed,
        throwsA(
          isA<MangaAcquisitionException>().having(
            (error) => error.code,
            'code',
            MangaAcquisitionFailureCode.cancelled,
          ),
        ),
      );
      expect(
        fixture.persistence.jobs['chapter-job']!.status,
        MangaDownloadJobStatus.cancelled,
      );
      expect(await fixture.roots.downloadedPages.list().toList(), isEmpty);
      expect(fixture.keepAlive.released, 1);
    });

    test(
      'source cleanup cancels an active repository child and removes its files and row',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final uri = Uri.parse('https://cdn.example/active-child.png');
        final bodyStarted = Completer<void>();
        fixture.transport.enqueue(uri, (call) {
          final body = StreamController<List<int>>();
          final remove = call.cancellation.onCancel(() {
            body.addError(
              const MangaAcquisitionException(
                MangaAcquisitionFailureCode.cancelled,
                'The manga download was cancelled.',
              ),
            );
            unawaited(body.close());
          });
          scheduleMicrotask(() {
            body.add(_pngBytes);
            bodyStarted.complete();
          });
          return MangaAcquisitionHttpResponse(
            statusCode: HttpStatus.ok,
            headers: const <String, String>{
              HttpHeaders.contentTypeHeader: 'image/png',
            },
            body: body.stream,
            release: remove,
          );
        });
        final operation = fixture.service.start(
          MangaAcquisitionRequest(
            jobId: 'active-child-job',
            sourceId: 'repository.root.child.removed',
            publicationId: 'publication-active',
            chapterId: 'chapter-active',
            seriesTitle: 'Active child title',
            chapterTitle: 'Chapter 1',
            acquisition: MangaReadingOrderAcquisition(<MangaReadingOrderPage>[
              MangaReadingOrderPage(uri: uri),
            ]),
          ),
        );
        final completion = expectLater(
          operation.completed,
          throwsA(
            isA<MangaAcquisitionException>().having(
              (error) => error.code,
              'code',
              MangaAcquisitionFailureCode.cancelled,
            ),
          ),
        );
        await bodyStarted.future.timeout(const Duration(seconds: 2));

        final removed = await fixture.service.deleteDownloadsForSource(
          'repository.root.child.removed',
        );
        await completion;

        expect(removed, 1);
        expect(fixture.service.activeOperation('active-child-job'), isNull);
        expect(fixture.persistence.jobs, isEmpty);
        expect(fixture.persistence.pageRows('active-child-job'), isEmpty);
        expect(await fixture.roots.downloadedPages.list().toList(), isEmpty);
        expect(fixture.keepAlive.acquired, 1);
        expect(fixture.keepAlive.released, 1);
      },
    );

    test('retry increments durable retry count and can complete', () async {
      final fixture = await _AcquisitionFixture.create();
      addTearDown(fixture.dispose);
      final uri = Uri.parse('https://cdn.example/page.png');
      fixture.transport.enqueue(
        uri,
        (_) => MangaAcquisitionHttpResponse(
          statusCode: HttpStatus.internalServerError,
          headers: const <String, String>{},
          body: const Stream<List<int>>.empty(),
        ),
      );
      fixture.transport.enqueue(
        uri,
        (_) => _response(_pngBytes, contentType: 'image/png'),
      );
      final request = _request(
        acquisition: MangaReadingOrderAcquisition(<MangaReadingOrderPage>[
          MangaReadingOrderPage(uri: uri),
        ]),
      );

      await expectLater(
        fixture.service.start(request).completed,
        throwsA(isA<MangaAcquisitionException>()),
      );
      expect(fixture.persistence.jobs['chapter-job']!.retryCount, 0);

      final result = await fixture.service.retry(request).completed;

      expect(result.pages, hasLength(1));
      expect(fixture.persistence.jobs['chapter-job']!.retryCount, 1);
      expect(
        fixture.persistence.jobs['chapter-job']!.status,
        MangaDownloadJobStatus.completed,
      );
      expect(fixture.keepAlive.acquired, 2);
      expect(fixture.keepAlive.released, 2);
    });

    test(
      'reopens and deletes a completed local chapter without URLs',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final uri = Uri.parse('https://cdn.example/page.png');
        fixture.transport.enqueue(
          uri,
          (_) => _response(_pngBytes, contentType: 'image/png'),
        );
        await fixture.service
            .start(
              _request(
                acquisition: MangaReadingOrderAcquisition(
                  <MangaReadingOrderPage>[MangaReadingOrderPage(uri: uri)],
                ),
              ),
            )
            .completed;

        final reopened = await fixture.service.openCompleted('chapter-job');

        expect(reopened, isNotNull);
        expect(reopened!.pages, hasLength(1));
        expect(
          reopened.pages.single.resource,
          isA<MangaTrustedLocalPageResource>(),
        );
        final now = DateTime.utc(2026, 9, 1, 12);
        fixture.persistence.jobs['child-job'] = _storedJob(
          id: 'child-job',
          sourceId: 'test.source.child.abc',
          relativeDirectory: 'jobs/child-job',
          now: now,
        );
        fixture.persistence.jobs['unrelated-job'] = _storedJob(
          id: 'unrelated-job',
          sourceId: 'another.source',
          relativeDirectory: 'jobs/unrelated-job',
          now: now,
        );
        final childDirectory = await Directory(
          path.join(fixture.roots.downloadedPages.path, 'jobs', 'child-job'),
        ).create(recursive: true);
        await File(
          path.join(childDirectory.path, 'partial.part'),
        ).writeAsBytes(_pngBytes);

        final removed = await fixture.service.deleteDownloadsForSource(
          'test.source',
        );

        expect(removed, 2);
        expect(fixture.persistence.jobs.keys, <String>['unrelated-job']);
        expect(fixture.persistence.pageRows('chapter-job'), isEmpty);
        expect(await childDirectory.exists(), isFalse);
      },
    );

    test(
      'startup recovery removes partial files and requests reauthorization',
      () async {
        final fixture = await _AcquisitionFixture.create();
        addTearDown(fixture.dispose);
        final now = DateTime.utc(2026, 9, 1, 11);
        fixture.persistence.jobs['stale-job'] = MangaDownloadJob(
          id: 'stale-job',
          sourceId: 'test.source',
          entryId: 'publication-1',
          chapterId: 'chapter-1',
          seriesTitle: 'Test Series',
          chapterLabel: 'Chapter 1',
          status: MangaDownloadJobStatus.downloading,
          relativeDirectory: 'jobs/stale-job',
          pageCount: 1,
          completedPages: 1,
          receivedBytes: _pngBytes.length,
          queuePosition: 0,
          retryCount: 0,
          createdAt: now,
          updatedAt: now,
        );
        final staleDirectory = await Directory(
          path.join(fixture.roots.downloadedPages.path, 'jobs', 'stale-job'),
        ).create(recursive: true);
        final staleFile = File(path.join(staleDirectory.path, '0001.png'));
        await staleFile.writeAsBytes(_pngBytes);
        await fixture.persistence.putPage(
          MangaDownloadPage(
            jobId: 'stale-job',
            pageIndex: 0,
            relativePath: 'jobs/stale-job/0001.png',
            mimeType: 'image/png',
            byteLength: _pngBytes.length,
            sha256: List<String>.filled(64, '0').join(),
          ),
        );

        final jobs = await fixture.service.recoverStaleJobs();

        expect(jobs.single.status, MangaDownloadJobStatus.needsReauthorization);
        expect(jobs.single.completedPages, 0);
        expect(jobs.single.receivedBytes, 0);
        expect(jobs.single.errorCode, 'interrupted');
        expect(fixture.persistence.pageRows('stale-job'), isEmpty);
        expect(await staleDirectory.exists(), isFalse);
      },
    );

    test('rejects unsafe ephemeral acquisition headers before networking', () {
      expect(
        () => MangaCbzDownloadAcquisition(
          Uri.parse('https://catalog.example/chapter.cbz'),
          headers: const <String, String>{HttpHeaders.hostHeader: 'evil.test'},
        ),
        throwsFormatException,
      );
      expect(
        () => MangaCbzDownloadAcquisition(
          Uri.parse('https://catalog.example/chapter.cbz'),
          headers: const <String, String>{'X-Api-Key': 'value\r\ninjected'},
        ),
        throwsFormatException,
      );
      expect(
        () => MangaReadingOrderPage(
          uri: Uri.parse('https://catalog.example/page.jpg'),
          headers: const <String, String>{HttpHeaders.hostHeader: 'evil.test'},
        ),
        throwsFormatException,
      );
      expect(
        () => MangaReadingOrderPage(
          uri: Uri.parse('https://catalog.example/page.jpg'),
          headers: const <String, String>{
            'Origin': 'http://reader.example',
          },
        ),
        throwsFormatException,
      );
    });
  });

  group('MangaAcquisitionController', () {
    test('observes a transfer and exposes open and delete actions', () async {
      final fixture = await _AcquisitionFixture.create();
      addTearDown(fixture.dispose);
      final controller = MangaAcquisitionController(
        service: Future<MangaAcquisitionService>.value(fixture.service),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final uri = Uri.parse('https://cdn.example/page.png');
      final body = StreamController<List<int>>();
      fixture.transport.enqueue(
        uri,
        (_) => MangaAcquisitionHttpResponse(
          statusCode: HttpStatus.ok,
          headers: const <String, String>{
            HttpHeaders.contentTypeHeader: 'image/png',
          },
          body: body.stream,
        ),
      );
      final becameVisible = Completer<void>();
      final removeListener = controller.addListener((state) {
        if (state.job('chapter-job') != null && !becameVisible.isCompleted) {
          becameVisible.complete();
        }
      });
      addTearDown(removeListener);

      final operation = await controller.start(
        _request(
          acquisition: MangaReadingOrderAcquisition(<MangaReadingOrderPage>[
            MangaReadingOrderPage(uri: uri),
          ]),
        ),
      );
      await becameVisible.future.timeout(const Duration(seconds: 2));
      expect(
        operation.currentProgress.phase,
        isNot(MangaAcquisitionPhase.queued),
      );
      expect(
        controller.state.job('chapter-job')?.status,
        MangaDownloadJobStatus.resolving,
      );
      body.add(_pngBytes);
      await body.close();
      await operation.completed;
      await controller.refresh();

      expect(controller.state.isInitializing, isFalse);
      expect(
        controller.state.job('chapter-job')?.status,
        MangaDownloadJobStatus.completed,
      );
      expect(
        controller.state.progress['chapter-job']?.phase,
        MangaAcquisitionPhase.completed,
      );
      expect(await controller.openCompleted('chapter-job'), isNotNull);

      await controller.delete('chapter-job');

      expect(controller.state.job('chapter-job'), isNull);
      expect(controller.state.progress, isNot(contains('chapter-job')));
    });
  });
}

class _AcquisitionFixture {
  _AcquisitionFixture({
    required this.root,
    required this.roots,
    required this.persistence,
    required this.transport,
    required this.keepAlive,
    required this.service,
  });

  final Directory root;
  final MangaStorageRoots roots;
  final _MemoryPersistence persistence;
  final _FakeTransport transport;
  final _RecordingKeepAlive keepAlive;
  final MangaAcquisitionService service;

  static Future<_AcquisitionFixture> create({
    MangaAcquisitionTargetValidator? validateTarget,
    MangaArchiveService archiveService = const MangaArchiveService(),
  }) async {
    final root = await Directory.systemTemp.createTemp('tetotv-manga-get-');
    final roots = MangaStorageRoots(
      downloadedPages: await Directory(
        path.join(root.path, 'downloaded'),
      ).create(),
      extractedArchives: await Directory(
        path.join(root.path, 'extracted'),
      ).create(),
    );
    final persistence = _MemoryPersistence();
    final transport = _FakeTransport();
    final keepAlive = _RecordingKeepAlive();
    final service = MangaAcquisitionService.withDependencies(
      persistence: persistence,
      storageRoots: roots,
      credentialHeaders: (_) async => <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer secret',
      },
      archiveService: archiveService,
      transport: transport,
      validateTarget: validateTarget ?? (_) async {},
      keepAlive: keepAlive,
      clock: () => DateTime.utc(2026, 9, 1, 12),
    );
    return _AcquisitionFixture(
      root: root,
      roots: roots,
      persistence: persistence,
      transport: transport,
      keepAlive: keepAlive,
      service: service,
    );
  }

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _FakeCbzSelection implements MangaCbzAcquisitionSource {
  const _FakeCbzSelection({
    required this.sourceId,
    required this.publicationId,
    required this.uri,
    required this.mediaType,
    this.headers = const <String, String>{},
  });

  @override
  final String sourceId;
  @override
  final String publicationId;
  @override
  final Uri uri;
  @override
  final String mediaType;
  @override
  final Map<String, String> headers;
}

class _MemoryPersistence implements MangaAcquisitionPersistence {
  final Map<String, MangaDownloadJob> jobs = <String, MangaDownloadJob>{};
  final Map<String, Map<int, MangaDownloadPage>> pageData =
      <String, Map<int, MangaDownloadPage>>{};
  final List<MangaDownloadJob> jobHistory = <MangaDownloadJob>[];

  @override
  Future<void> clearPages(String jobId) async => pageData.remove(jobId);

  @override
  Future<MangaDownloadJob?> job(String jobId) async => jobs[jobId];

  @override
  Future<List<MangaDownloadJob>> listJobs() async =>
      jobs.values.toList(growable: false);

  @override
  Future<List<MangaDownloadPage>> pages(String jobId) async => pageRows(jobId);

  List<MangaDownloadPage> pageRows(String jobId) {
    final values = pageData[jobId]?.values.toList() ?? <MangaDownloadPage>[];
    values.sort((left, right) => left.pageIndex.compareTo(right.pageIndex));
    return values;
  }

  @override
  Future<void> putJob(MangaDownloadJob job) async {
    jobs[job.id] = job;
    jobHistory.add(job);
  }

  @override
  Future<void> putPage(MangaDownloadPage page) async {
    pageData.putIfAbsent(
      page.jobId,
      () => <int, MangaDownloadPage>{},
    )[page.pageIndex] = page;
  }

  @override
  Future<void> deleteJob(String jobId) async => jobs.remove(jobId);
}

class _TransportCall {
  const _TransportCall({
    required this.uri,
    required this.headers,
    required this.cancellation,
  });

  final Uri uri;
  final Map<String, String> headers;
  final MangaAcquisitionCancellationToken cancellation;
}

typedef _ResponseFactory =
    MangaAcquisitionHttpResponse Function(_TransportCall call);

class _FakeTransport implements MangaAcquisitionTransport {
  final Map<String, List<_ResponseFactory>> _responses =
      <String, List<_ResponseFactory>>{};
  final List<_TransportCall> requests = <_TransportCall>[];

  void enqueue(Uri uri, _ResponseFactory response) {
    _responses
        .putIfAbsent(uri.toString(), () => <_ResponseFactory>[])
        .add(response);
  }

  @override
  Future<MangaAcquisitionHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required MangaAcquisitionCancellationToken cancellation,
  }) async {
    final call = _TransportCall(
      uri: uri,
      headers: Map<String, String>.of(headers),
      cancellation: cancellation,
    );
    requests.add(call);
    final queue = _responses[uri.toString()];
    if (queue == null || queue.isEmpty) {
      throw StateError('No fake response for $uri');
    }
    return queue.removeAt(0)(call);
  }
}

class _RecordingKeepAlive implements OfflineDownloadKeepAlive {
  int acquired = 0;
  int released = 0;

  @override
  Future<OfflineDownloadKeepAliveLease> acquire() async {
    acquired++;
    return _RecordingLease(() => released++);
  }
}

class _RecordingLease implements OfflineDownloadKeepAliveLease {
  _RecordingLease(this.onRelease);

  final void Function() onRelease;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    onRelease();
  }
}

MangaAcquisitionRequest _request({
  required MangaChapterAcquisition acquisition,
  Uri? credentialOrigin,
}) => MangaAcquisitionRequest(
  jobId: 'chapter-job',
  sourceId: 'test.source',
  publicationId: 'publication-1',
  chapterId: 'chapter-1',
  seriesTitle: 'Test Series',
  chapterTitle: 'Chapter 1',
  acquisition: acquisition,
  credentialOrigin: credentialOrigin,
);

MangaDownloadJob _storedJob({
  required String id,
  required String sourceId,
  required String relativeDirectory,
  required DateTime now,
}) => MangaDownloadJob(
  id: id,
  sourceId: sourceId,
  entryId: 'publication-1',
  chapterId: 'chapter-1',
  seriesTitle: 'Test Series',
  chapterLabel: 'Chapter 1',
  status: MangaDownloadJobStatus.failed,
  relativeDirectory: relativeDirectory,
  completedPages: 0,
  receivedBytes: 0,
  queuePosition: 0,
  retryCount: 0,
  createdAt: now,
  updatedAt: now,
);

MangaAcquisitionHttpResponse _response(
  List<int> bytes, {
  required String contentType,
}) => MangaAcquisitionHttpResponse(
  statusCode: HttpStatus.ok,
  headers: <String, String>{
    HttpHeaders.contentTypeHeader: contentType,
    HttpHeaders.contentLengthHeader: '${bytes.length}',
  },
  body: Stream<List<int>>.value(bytes),
);

Future<List<File>> _partFiles(Directory root) async {
  if (!await root.exists()) return <File>[];
  return root
      .list(recursive: true)
      .where((entity) => entity is File && entity.path.endsWith('.part'))
      .cast<File>()
      .toList();
}

// Minimal dimension-bearing image headers. The acquisition path deliberately
// validates dimensions before persisting untrusted reader bytes.
const List<int> _jpegBytes = <int>[
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
  0xff,
  0xd9,
];
const List<int> _pngBytes = <int>[
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
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
];

List<int> _pngHeader({required int width, required int height}) => <int>[
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
  (width >> 24) & 0xff,
  (width >> 16) & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 24) & 0xff,
  (height >> 16) & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
];
