import 'dart:async';
import 'dart:io';

import 'package:anime_tv/features/manga/data/manga_archive_service.dart';
import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('MangaArchiveService', () {
    test('extracts supported images through atomic staging files', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.directory('chapter/'),
        ArchiveFile.bytes('chapter/001.jpeg', _jpegBytes),
        ArchiveFile.bytes('chapter/002.png', _pngBytes),
        ArchiveFile.bytes('chapter/003.webp', _webpBytes),
        ArchiveFile.bytes('chapter/004.gif', _gifBytes),
      ]);

      final result = await const MangaArchiveService().extract(
        archiveFile: archive,
        stagingDirectory: fixture.staging,
      );

      expect(result.directory.parent.path, fixture.staging.path);
      expect(result.pages, hasLength(4));
      expect(result.pages.map((page) => page.originalPath), <String>[
        'chapter/001.jpeg',
        'chapter/002.png',
        'chapter/003.webp',
        'chapter/004.gif',
      ]);
      expect(result.pages.map((page) => page.mimeType), <String>[
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/gif',
      ]);
      expect(
        result.totalUncompressedBytes,
        _jpegBytes.length +
            _pngBytes.length +
            _webpBytes.length +
            _gifBytes.length,
      );
      expect(
        result.pages.map((page) => path.basename(page.file.path)),
        <String>['0001.jpg', '0002.png', '0003.webp', '0004.gif'],
      );
      for (final page in result.pages) {
        expect(await page.file.exists(), isTrue);
      }
      final stagedNames = await result.directory
          .list()
          .map((entity) => path.basename(entity.path))
          .toList();
      expect(stagedNames.where((name) => name.endsWith('.part')), isEmpty);
    });

    test('parsing and decompression never block the UI isolate', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page.png', _pngBytes),
      ]);
      const service = MangaArchiveService(
        workerStartDelay: Duration(milliseconds: 120),
      );
      var heartbeats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => heartbeats += 1,
      );
      addTearDown(timer.cancel);

      final extraction = service.extract(
        archiveFile: archive,
        stagingDirectory: fixture.staging,
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(heartbeats, greaterThanOrEqualTo(3));
      expect((await extraction).pages, hasLength(1));
    });

    test('cancellation kills the worker and cleans partial staging', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page.png', _pngBytes),
      ]);
      final cancelled = Completer<void>();
      const service = MangaArchiveService(
        workerStartDelay: Duration(seconds: 5),
      );

      final extraction = service.extract(
        archiveFile: archive,
        stagingDirectory: fixture.staging,
        cancellation: cancelled.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      cancelled.complete();

      await expectLater(
        extraction,
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.cancelled,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects encoded image dimension bombs before persistence', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes(
          'page.png',
          _pngWithDimensions(maximumMangaImageWidth + 1, 1),
        ),
      ]);

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.unsafeImageDimensions,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('orders page paths naturally instead of lexicographically', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('pages/page10.jpg', _jpegBytes),
        ArchiveFile.bytes('pages/page2.jpg', _jpegBytes),
        ArchiveFile.bytes('pages/page1.jpg', _jpegBytes),
      ]);

      final result = await const MangaArchiveService().extract(
        archiveFile: archive,
        stagingDirectory: fixture.staging,
      );

      expect(result.pages.map((page) => page.originalPath), <String>[
        'pages/page1.jpg',
        'pages/page2.jpg',
        'pages/page10.jpg',
      ]);
      expect(
        compareMangaArchivePagePathsNaturally('page9.jpg', 'page10.jpg'),
        lessThan(0),
      );
    });

    test('rejects zip-slip paths without writing outside staging', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('../escaped.jpg', _jpegBytes),
      ]);
      final escaped = File(path.join(fixture.root.path, 'escaped.jpg'));

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.unsafeEntryPath,
          ),
        ),
      );

      expect(await escaped.exists(), isFalse);
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects absolute, drive-prefixed, and NUL paths', () async {
      for (final unsafeName in <String>[
        '/absolute.jpg',
        'C:/drive.jpg',
        'page\u0000.jpg',
      ]) {
        final fixture = await _ArchiveFixture.create();
        addTearDown(fixture.dispose);
        final archive = await fixture.writeArchive(<ArchiveFile>[
          ArchiveFile.bytes(unsafeName, _jpegBytes),
        ]);

        await expectLater(
          const MangaArchiveService().extract(
            archiveFile: archive,
            stagingDirectory: fixture.staging,
          ),
          throwsA(
            isA<MangaArchiveException>().having(
              (error) => error.code,
              'code',
              MangaArchiveFailureCode.unsafeEntryPath,
            ),
          ),
          reason: unsafeName,
        );
      }
    });

    test('rejects backslashes encoded directly in a ZIP path', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('folder/page.jpg', _jpegBytes),
      ]);
      final bytes = await archive.readAsBytes();
      // ZipEncoder correctly normalizes paths, so patch both the local and
      // central names to model an archive produced by an unsafe writer.
      for (var index = 0; index < bytes.length; index++) {
        if (bytes[index] == 0x2f) bytes[index] = 0x5c;
      }
      await archive.writeAsBytes(bytes, flush: true);

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.unsafeEntryPath,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects pages above the configured size limit', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page.png', _pngBytes),
      ]);
      const service = MangaArchiveService(
        limits: MangaArchiveLimits(
          maximumPageBytes: 7,
          maximumUncompressedBytes: 100,
        ),
      );

      await expectLater(
        service.extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.pageTooLarge,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects archives above the total uncompressed limit', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page1.png', _pngBytes),
        ArchiveFile.bytes('page2.png', _pngBytes),
      ]);
      const service = MangaArchiveService(
        limits: MangaArchiveLimits(
          maximumPageBytes: 128,
          maximumUncompressedBytes: 50,
        ),
      );

      await expectLater(
        service.extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.archiveTooLarge,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects archives above the page-count limit', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page1.jpg', _jpegBytes),
        ArchiveFile.bytes('page2.jpg', _jpegBytes),
        ArchiveFile.bytes('page3.jpg', _jpegBytes),
      ]);
      const service = MangaArchiveService(
        limits: MangaArchiveLimits(
          maximumPages: 2,
          maximumPageBytes: 128,
          maximumUncompressedBytes: 256,
        ),
      );

      await expectLater(
        service.extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.tooManyPages,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects non-image entries instead of extracting them', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.string('ComicInfo.xml', '<comic/>'),
        ArchiveFile.bytes('page.jpg', _jpegBytes),
      ]);

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.unsupportedEntry,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects image extensions whose bytes have another type', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page.png', _jpegBytes),
      ]);

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.invalidImage,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects suspicious compression ratios before extraction', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final compressedPage = <int>[..._pngBytes, ...List<int>.filled(4096, 0)];
      final archive = await fixture.writeArchive(<ArchiveFile>[
        ArchiveFile.bytes('page.png', compressedPage),
      ]);
      const service = MangaArchiveService(
        limits: MangaArchiveLimits(
          maximumPageBytes: 8192,
          maximumUncompressedBytes: 8192,
          maximumCompressionRatio: 2,
        ),
      );

      await expectLater(
        service.extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.suspiciousCompression,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects symbolic links before reading their content', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final link = ArchiveFile.bytes('linked.jpg', _jpegBytes)..mode = 0xa1ff;
      final archive = await fixture.writeArchive(<ArchiveFile>[link]);

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.symbolicLink,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });

    test('rejects corrupt archives and cleans partial staging', () async {
      final fixture = await _ArchiveFixture.create();
      addTearDown(fixture.dispose);
      final archive = File(path.join(fixture.root.path, 'corrupt.cbz'));
      await archive.writeAsBytes(<int>[
        0x50,
        0x4b,
        0x03,
        0x04,
        0x00,
        0x01,
        0x02,
        0x03,
      ]);

      await expectLater(
        const MangaArchiveService().extract(
          archiveFile: archive,
          stagingDirectory: fixture.staging,
        ),
        throwsA(
          isA<MangaArchiveException>().having(
            (error) => error.code,
            'code',
            MangaArchiveFailureCode.invalidArchive,
          ),
        ),
      );
      expect(await fixture.staging.list().toList(), isEmpty);
    });
  });
}

class _ArchiveFixture {
  const _ArchiveFixture({required this.root, required this.staging});

  final Directory root;
  final Directory staging;

  static Future<_ArchiveFixture> create() async {
    final root = await Directory.systemTemp.createTemp('tetotv-cbz-test-');
    final staging = await Directory(path.join(root.path, 'staging')).create();
    return _ArchiveFixture(root: root, staging: staging);
  }

  Future<File> writeArchive(List<ArchiveFile> entries) async {
    final archive = Archive();
    for (final entry in entries) {
      archive.add(entry);
    }
    final file = File(path.join(root.path, 'test.cbz'));
    await file.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
    return file;
  }

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

const List<int> _jpegBytes = <int>[
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x02,
  0x00,
  0x02,
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
];
const List<int> _gifBytes = <int>[
  0x47,
  0x49,
  0x46,
  0x38,
  0x39,
  0x61,
  0x02,
  0x00,
  0x02,
  0x00,
];
const List<int> _webpBytes = <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x16,
  0x00,
  0x00,
  0x00,
  0x57,
  0x45,
  0x42,
  0x50,
  0x56,
  0x50,
  0x38,
  0x58,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
];

List<int> _pngWithDimensions(int width, int height) {
  final bytes = List<int>.of(_pngBytes);
  for (var index = 0; index < 4; index++) {
    bytes[16 + index] = (width >> ((3 - index) * 8)) & 0xff;
    bytes[20 + index] = (height >> ((3 - index) * 8)) & 0xff;
  }
  return bytes;
}
