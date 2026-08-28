import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tetotv-dio-download-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('resumes a partial file with a validated byte range', () async {
    final adapter = _RangeAdapter(List<int>.generate(10, (index) => index));
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([0, 1, 2, 3, 4]);
    await _writeEtagValidator(partial, '"v1"');

    final result = await client.download(
      job: _job(),
      partialFile: partial,
      cancellation: DownloadCancellationToken(),
      onProgress: (_) {},
    );

    expect(adapter.ranges, ['bytes=5-']);
    expect(adapter.ifRanges, ['"v1"']);
    expect(
      await partial.readAsBytes(),
      List<int>.generate(10, (index) => index),
    );
    expect(result.totalBytes, 10);
    expect(result.receivedBytes, 10);
    expect(await _validatorFile(partial).exists(), isFalse);
  });

  test('restarts from zero when a server ignores Range', () async {
    final adapter = _IgnoreRangeAdapter(List<int>.filled(8, 9));
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([1, 2, 3]);
    await _writeEtagValidator(partial, '"v1"');

    final result = await client.download(
      job: _job(),
      partialFile: partial,
      cancellation: DownloadCancellationToken(),
      onProgress: (_) {},
    );

    expect(adapter.ranges, ['bytes=3-', null]);
    expect(await partial.length(), 8);
    expect(result.receivedBytes, 8);
    expect(await _validatorFile(partial).exists(), isFalse);
  });

  test('restarts safely when a partial has no stored validator', () async {
    final adapter = _IgnoreRangeAdapter(List<int>.filled(6, 7));
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([1, 2, 3]);

    final result = await client.download(
      job: _job(),
      partialFile: partial,
      cancellation: DownloadCancellationToken(),
      onProgress: (_) {},
    );

    expect(adapter.ranges, [null]);
    expect(await partial.readAsBytes(), List<int>.filled(6, 7));
    expect(result.receivedBytes, 6);
  });

  test('restarts safely when a resumed object changed ETag', () async {
    final adapter = _ChangedEtagAdapter(List<int>.filled(7, 4));
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([1, 2, 3]);
    await _writeEtagValidator(partial, '"old"');

    final result = await client.download(
      job: _job(),
      partialFile: partial,
      cancellation: DownloadCancellationToken(),
      onProgress: (_) {},
    );

    expect(adapter.ranges, ['bytes=3-', null]);
    expect(adapter.ifRanges, ['"old"', null]);
    expect(await partial.readAsBytes(), List<int>.filled(7, 4));
    expect(result.receivedBytes, 7);
  });

  test(
    'resumes with Last-Modified when a strong ETag is unavailable',
    () async {
      const modified = 'Sun, 23 Aug 2026 18:00:00 GMT';
      final adapter = _LastModifiedRangeAdapter(
        List<int>.generate(9, (index) => index),
        modified,
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = DioDownloadTransferClient(dio: dio);
      final partial = File(
        '${temporary.path}${Platform.pathSeparator}video.part',
      );
      await partial.writeAsBytes([0, 1, 2, 3]);
      await _writeLastModifiedValidator(partial, modified);

      await client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );

      expect(adapter.ranges, ['bytes=4-']);
      expect(adapter.ifRanges, [modified]);
      expect(
        await partial.readAsBytes(),
        List<int>.generate(9, (index) => index),
      );
    },
  );

  test('rejects a resumed 206 with an unknown total size', () async {
    final adapter = _PartialContentAdapter(
      body: const [4, 5, 6],
      contentRange: 'bytes 3-5/*',
      contentLength: 3,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([1, 2, 3]);
    await _writeEtagValidator(partial, '"v1"');

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_content_range',
        ),
      ),
    );
    expect(await partial.exists(), isFalse);
    expect(await _validatorFile(partial).exists(), isFalse);
  });

  test('rejects an invalid Content-Range end', () async {
    final adapter = _PartialContentAdapter(
      body: const [4],
      contentRange: 'bytes 3-2/10',
      contentLength: 1,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([1, 2, 3]);
    await _writeEtagValidator(partial, '"v1"');

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_content_range',
        ),
      ),
    );
  });

  test('rejects Content-Length inconsistent with Content-Range', () async {
    final adapter = _PartialContentAdapter(
      body: const [4, 5],
      contentRange: 'bytes 3-5/6',
      contentLength: 2,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );
    await partial.writeAsBytes([1, 2, 3]);
    await _writeEtagValidator(partial, '"v1"');

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_content_range',
        ),
      ),
    );
  });

  test('rejects an unsolicited 206 with unknown total size', () async {
    final adapter = _PartialContentAdapter(
      body: const [1, 2],
      contentRange: 'bytes 0-2/*',
      contentLength: 3,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_content_range',
        ),
      ),
    );
  });

  test('rejects an advertised body larger than the configured limit', () async {
    final adapter = _StaticResponseAdapter(
      bytes: const [1, 2],
      contentLength: 11,
      mimeType: 'video/mp4',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio, maximumBytes: 10);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'download_too_large',
        ),
      ),
    );
    expect(await partial.exists(), isFalse);
    expect(await _validatorFile(partial).exists(), isFalse);
  });

  test('aborts a chunked body when streamed bytes exceed the limit', () async {
    final adapter = _StaticResponseAdapter(
      bytes: const [1, 2, 3, 4],
      mimeType: 'application/octet-stream',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio, maximumBytes: 3);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'download_too_large',
        ),
      ),
    );
    expect(await partial.exists(), isFalse);
  });

  test('rejects an HTML content type without keeping a partial', () async {
    final adapter = _StaticResponseAdapter(
      bytes: utf8.encode('<html>login</html>'),
      mimeType: 'text/html; charset=utf-8',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_media_response',
        ),
      ),
    );
    expect(await partial.exists(), isFalse);
  });

  test('rejects JSON and XML API responses as non-media', () async {
    for (final mimeType in const [
      'application/json',
      'application/problem+json',
      'application/xml',
      'application/xhtml+xml',
    ]) {
      final adapter = _StaticResponseAdapter(
        bytes: const [1, 2, 3],
        mimeType: mimeType,
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = DioDownloadTransferClient(dio: dio);
      final partial = File(
        '${temporary.path}${Platform.pathSeparator}'
        '${mimeType.replaceAll('/', '_')}.part',
      );

      await expectLater(
        client.download(
          job: _job(),
          partialFile: partial,
          cancellation: DownloadCancellationToken(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadTransferException>().having(
            (error) => error.code,
            'code',
            'invalid_media_response',
          ),
        ),
        reason: mimeType,
      );
      expect(await partial.exists(), isFalse, reason: mimeType);
    }
  });

  test('rejects an obvious HTML body disguised as octet-stream', () async {
    final adapter = _StaticResponseAdapter(
      bytes: utf8.encode('  <!doctype html><html>login</html>'),
      mimeType: 'application/octet-stream',
      etag: '"login"',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_media_response',
        ),
      ),
    );
    expect(await partial.exists(), isFalse);
    expect(await _validatorFile(partial).exists(), isFalse);
  });

  test('allows binary application/octet-stream responses', () async {
    final adapter = _StaticResponseAdapter(
      bytes: const [0x1a, 0x45, 0xdf, 0xa3],
      mimeType: 'application/octet-stream',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    final result = await client.download(
      job: _job(),
      partialFile: partial,
      cancellation: DownloadCancellationToken(),
      onProgress: (_) {},
    );

    expect(result.receivedBytes, 4);
    expect(await partial.readAsBytes(), const [0x1a, 0x45, 0xdf, 0xa3]);
  });

  test('keeps a partial and validator after an interrupted body', () async {
    final adapter = _StaticResponseAdapter(
      bytes: const [1, 2],
      contentLength: 4,
      mimeType: 'video/mp4',
      etag: '"v1"',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await expectLater(
      client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'incomplete_body',
        ),
      ),
    );
    expect(await partial.readAsBytes(), const [1, 2]);
    expect(await _validatorFile(partial).exists(), isTrue);
  });

  test('rejects redirect downgrade before following it', () async {
    final dio = Dio()..httpClientAdapter = _DowngradeRedirectAdapter();
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    expect(
      () => client.download(
        job: _job(),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'unsafe_redirect',
        ),
      ),
    );
  });

  test('rejects private network targets before opening a connection', () async {
    final dio = Dio()..httpClientAdapter = _DowngradeRedirectAdapter();
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    expect(
      () => client.download(
        job: _job(sourceUri: Uri.parse('https://127.0.0.1/video.mkv')),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_source',
        ),
      ),
    );
  });

  test('strips credentials before following a cross-origin redirect', () async {
    final adapter = _CrossOriginRedirectAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioDownloadTransferClient(dio: dio);
    final partial = File(
      '${temporary.path}${Platform.pathSeparator}video.part',
    );

    await client.download(
      job: _job(),
      partialFile: partial,
      cancellation: DownloadCancellationToken(),
      requestHeaders: const {
        'Authorization': 'Bearer secret',
        'Cookie': 'session=secret',
        'X-Api-Key': 'secret',
        'Referer': 'https://private.example.test/watch?token=secret',
        'User-Agent': 'TetoTV-Test',
        'Accept-Language': 'en-US',
      },
      onProgress: (_) {},
    );

    expect(adapter.requests, hasLength(2));
    expect(_header(adapter.requests.first, 'authorization'), 'Bearer secret');
    expect(_header(adapter.requests.last, 'authorization'), isNull);
    expect(_header(adapter.requests.last, 'cookie'), isNull);
    expect(_header(adapter.requests.last, 'x-api-key'), isNull);
    expect(
      _header(adapter.requests.first, 'referer'),
      contains('token=secret'),
    );
    expect(_header(adapter.requests.last, 'referer'), isNull);
    expect(_header(adapter.requests.last, 'user-agent'), 'TetoTV-Test');
    expect(_header(adapter.requests.last, 'accept-language'), 'en-US');
  });
}

String? _header(RequestOptions options, String name) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == name) return '${entry.value}';
  }
  return null;
}

File _validatorFile(File partial) => File('${partial.path}.validator');

Future<void> _writeEtagValidator(File partial, String value) => _validatorFile(
  partial,
).writeAsString(jsonEncode({'kind': 'etag', 'value': value}));

Future<void> _writeLastModifiedValidator(File partial, String value) =>
    _validatorFile(
      partial,
    ).writeAsString(jsonEncode({'kind': 'lastModified', 'value': value}));

DownloadJob _job({Uri? sourceUri}) {
  final now = DateTime.utc(2026, 8, 24);
  return DownloadJob(
    id: 'job',
    anilistMediaId: 1,
    episode: 1,
    seriesTitle: 'Example',
    sourceLabel: 'Debrid',
    transport: DownloadTransport.https,
    status: DownloadJobStatus.downloading,
    sourceUri: sourceUri ?? Uri.parse('https://cdn.example.test/video.mkv'),
    relativePath: '1/video.mkv',
    queuePosition: 0,
    createdAt: now,
    updatedAt: now,
  );
}

class _RangeAdapter implements HttpClientAdapter {
  _RangeAdapter(this.bytes);

  final List<int> bytes;
  final List<String?> ranges = [];
  final List<String?> ifRanges = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final range = options.headers[HttpHeaders.rangeHeader] as String?;
    ranges.add(range);
    ifRanges.add(_header(options, 'if-range'));
    final offset = int.parse(
      RegExp(r'bytes=(\d+)-').firstMatch(range!)!.group(1)!,
    );
    final body = bytes.sublist(offset);
    return ResponseBody.fromBytes(
      body,
      HttpStatus.partialContent,
      headers: {
        HttpHeaders.contentRangeHeader: [
          'bytes $offset-${bytes.length - 1}/${bytes.length}',
        ],
        HttpHeaders.contentLengthHeader: ['${body.length}'],
        HttpHeaders.contentTypeHeader: ['video/x-matroska'],
        HttpHeaders.etagHeader: ['"v1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _IgnoreRangeAdapter implements HttpClientAdapter {
  _IgnoreRangeAdapter(this.bytes);

  final List<int> bytes;
  final List<String?> ranges = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    ranges.add(options.headers[HttpHeaders.rangeHeader] as String?);
    return ResponseBody.fromBytes(
      bytes,
      HttpStatus.ok,
      headers: {
        HttpHeaders.contentLengthHeader: ['${bytes.length}'],
        HttpHeaders.contentTypeHeader: ['video/x-matroska'],
        HttpHeaders.etagHeader: ['"v1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ChangedEtagAdapter implements HttpClientAdapter {
  _ChangedEtagAdapter(this.bytes);

  final List<int> bytes;
  final List<String?> ranges = [];
  final List<String?> ifRanges = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final range = _header(options, 'range');
    ranges.add(range);
    ifRanges.add(_header(options, 'if-range'));
    if (range != null) {
      final offset = int.parse(
        RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
      );
      final body = bytes.sublist(offset);
      return ResponseBody.fromBytes(
        body,
        HttpStatus.partialContent,
        headers: {
          HttpHeaders.contentRangeHeader: [
            'bytes $offset-${bytes.length - 1}/${bytes.length}',
          ],
          HttpHeaders.contentLengthHeader: ['${body.length}'],
          HttpHeaders.contentTypeHeader: ['video/x-matroska'],
          HttpHeaders.etagHeader: ['"new"'],
        },
      );
    }
    return ResponseBody.fromBytes(
      bytes,
      HttpStatus.ok,
      headers: {
        HttpHeaders.contentLengthHeader: ['${bytes.length}'],
        HttpHeaders.contentTypeHeader: ['video/x-matroska'],
        HttpHeaders.etagHeader: ['"new"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _LastModifiedRangeAdapter implements HttpClientAdapter {
  _LastModifiedRangeAdapter(this.bytes, this.lastModified);

  final List<int> bytes;
  final String lastModified;
  final List<String?> ranges = [];
  final List<String?> ifRanges = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final range = _header(options, 'range');
    ranges.add(range);
    ifRanges.add(_header(options, 'if-range'));
    final offset = int.parse(
      RegExp(r'bytes=(\d+)-').firstMatch(range!)!.group(1)!,
    );
    final body = bytes.sublist(offset);
    return ResponseBody.fromBytes(
      body,
      HttpStatus.partialContent,
      headers: {
        HttpHeaders.contentRangeHeader: [
          'bytes $offset-${bytes.length - 1}/${bytes.length}',
        ],
        HttpHeaders.contentLengthHeader: ['${body.length}'],
        HttpHeaders.contentTypeHeader: ['video/x-matroska'],
        HttpHeaders.lastModifiedHeader: [lastModified],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PartialContentAdapter implements HttpClientAdapter {
  _PartialContentAdapter({
    required this.body,
    required this.contentRange,
    required this.contentLength,
  });

  final List<int> body;
  final String contentRange;
  final int contentLength;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    body,
    HttpStatus.partialContent,
    headers: {
      HttpHeaders.contentRangeHeader: [contentRange],
      HttpHeaders.contentLengthHeader: ['$contentLength'],
      HttpHeaders.contentTypeHeader: ['video/x-matroska'],
      HttpHeaders.etagHeader: ['"v1"'],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _StaticResponseAdapter implements HttpClientAdapter {
  _StaticResponseAdapter({
    required this.bytes,
    required this.mimeType,
    this.contentLength,
    this.etag,
  });

  final List<int> bytes;
  final String mimeType;
  final int? contentLength;
  final String? etag;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    bytes,
    HttpStatus.ok,
    headers: {
      if (contentLength != null)
        HttpHeaders.contentLengthHeader: ['$contentLength'],
      HttpHeaders.contentTypeHeader: [mimeType],
      if (etag != null) HttpHeaders.etagHeader: [etag!],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _DowngradeRedirectAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      const [],
      HttpStatus.found,
      headers: {
        HttpHeaders.locationHeader: ['http://insecure.example.test/video'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CrossOriginRedirectAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1) {
      return ResponseBody.fromBytes(
        const [],
        HttpStatus.found,
        headers: {
          HttpHeaders.locationHeader: ['https://media.example.test/video.mkv'],
        },
      );
    }
    return ResponseBody.fromBytes(
      const [1, 2, 3],
      HttpStatus.ok,
      headers: {
        HttpHeaders.contentLengthHeader: ['3'],
        HttpHeaders.contentTypeHeader: ['video/x-matroska'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
