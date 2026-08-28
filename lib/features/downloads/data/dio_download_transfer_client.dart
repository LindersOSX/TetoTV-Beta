import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class DownloadTransferException implements Exception {
  const DownloadTransferException(
    this.code,
    this.message, {
    this.retryable = true,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'DownloadTransferException($code, $message)';
}

class DownloadTransferCancelled extends DownloadTransferException {
  const DownloadTransferCancelled()
    : super('cancelled', 'The transfer was cancelled.', retryable: true);
}

class DownloadCancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void whenCancelled(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

class DownloadTransferProgress {
  const DownloadTransferProgress({
    required this.receivedBytes,
    required this.speedBytesPerSecond,
    this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;
  final int speedBytesPerSecond;
}

class DownloadTransferResult {
  const DownloadTransferResult({
    required this.receivedBytes,
    this.totalBytes,
    this.mimeType,
  });

  final int receivedBytes;
  final int? totalBytes;
  final String? mimeType;
}

abstract interface class DownloadTransferClient {
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  });
}

/// Injectable native/direct-peer backend.
///
/// [capability] is deliberately process-local and untyped at this boundary so
/// a future Android implementation can wrap an authenticated loopback URI and
/// playback lease without persisting its magnet or bearer capability. The
/// worker owns closing that capability on success, failure, and cancellation.
abstract interface class DirectPeerDownloadWorker {
  bool get isAvailable;

  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required Object capability,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
  });
}

class UnsupportedDirectPeerDownloadWorker implements DirectPeerDownloadWorker {
  const UnsupportedDirectPeerDownloadWorker();

  @override
  bool get isAvailable => false;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required Object capability,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
  }) => throw const DownloadTransferException(
    'direct_peer_worker_unavailable',
    'Direct torrent downloads are unavailable in this build.',
    retryable: false,
  );
}

/// HTTPS streaming downloader with range-based process-restart resume.
class DioDownloadTransferClient implements DownloadTransferClient {
  DioDownloadTransferClient({
    Dio? dio,
    this.maximumBytes = _defaultMaximumDownloadBytes,
  }) : assert(maximumBytes > 0),
       _dio = dio ?? _publicDownloadDio();

  final Dio _dio;
  final int maximumBytes;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) async {
    final uri = job.sourceUri;
    if (uri == null || !_isSafeHttps(uri)) {
      throw const DownloadTransferException(
        'invalid_source',
        'The download does not have a valid HTTPS source.',
        retryable: false,
      );
    }
    if (cancellation.isCancelled) throw const DownloadTransferCancelled();
    if (!await partialFile.parent.exists()) {
      await partialFile.parent.create(recursive: true);
    }

    final dioCancellation = CancelToken();
    cancellation.whenCancelled(
      () => dioCancellation.cancel('offline download cancelled'),
    );

    try {
      final validatorFile = _resumeValidatorFile(partialFile);
      var offset = await partialFile.exists() ? await partialFile.length() : 0;
      _ResumeValidator? resumeValidator;
      if (offset > maximumBytes) {
        await _discardPartialDownload(partialFile);
        throw _downloadTooLarge();
      }
      if (offset > 0) {
        resumeValidator = await _readResumeValidator(validatorFile);
        if (resumeValidator == null) {
          // A byte count alone cannot prove that a partial file still belongs
          // to the remote object. Restart rather than risk joining two files.
          await _discardPartialDownload(partialFile);
          offset = 0;
        }
      } else {
        await _deleteResumeValidator(validatorFile);
      }

      var response = await _open(
        uri,
        offset: offset,
        ifRange: resumeValidator?.value,
        headers: requestHeaders,
        cancellation: dioCancellation,
      );

      var restartFromZero = false;
      if (offset > 0 &&
          response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        final remoteTotal = _unsatisfiedRangeTotal(response);
        if (remoteTotal != null &&
            remoteTotal == offset &&
            _responseMatchesValidator(response, resumeValidator!)) {
          if (remoteTotal > maximumBytes) {
            await _discardBody(response);
            await _discardPartialDownload(partialFile);
            throw _downloadTooLarge();
          }
          await _discardBody(response);
          await _deleteResumeValidator(validatorFile);
          return DownloadTransferResult(
            receivedBytes: offset,
            totalBytes: remoteTotal,
            mimeType: response.headers.value(Headers.contentTypeHeader),
          );
        }
        restartFromZero = true;
      }

      // A server may ignore Range. Restart from zero rather than append a
      // second complete file to the partial one.
      if (offset > 0 && response.statusCode == HttpStatus.ok) {
        restartFromZero = true;
      }
      // Even a syntactically valid 206 is unsafe if the server did not echo
      // the strong ETag or Last-Modified value that guarded the partial file.
      if (offset > 0 &&
          response.statusCode == HttpStatus.partialContent &&
          !_responseMatchesValidator(response, resumeValidator!)) {
        restartFromZero = true;
      }

      if (restartFromZero) {
        await _discardBody(response);
        await _discardPartialDownload(partialFile);
        offset = 0;
        resumeValidator = null;
        response = await _open(
          uri,
          offset: 0,
          ifRange: null,
          headers: requestHeaders,
          cancellation: dioCancellation,
        );
      }

      final status = response.statusCode ?? 0;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        await _discardBody(response);
        throw DownloadTransferException(
          'http_$status',
          'The download server returned HTTP $status.',
          retryable: status >= 500 || status == 408 || status == 429,
        );
      }

      final contentLengthHeader = response.headers.value(
        Headers.contentLengthHeader,
      );
      final contentLength = contentLengthHeader == null
          ? null
          : int.tryParse(contentLengthHeader.trim());
      final invalidContentLength =
          contentLengthHeader != null &&
          (contentLength == null || contentLength < 0);
      final range = _contentRange(response);
      if (status == HttpStatus.partialContent &&
          (range == null ||
              range.start != offset ||
              range.total == null ||
              invalidContentLength ||
              (contentLength != null && contentLength != range.length))) {
        await _discardBody(response);
        await _discardPartialDownload(partialFile);
        throw const DownloadTransferException(
          'invalid_content_range',
          'The download server returned an invalid resume range.',
        );
      }
      if (invalidContentLength) {
        await _discardBody(response);
        await _discardPartialDownload(partialFile);
        throw const DownloadTransferException(
          'invalid_content_length',
          'The download server returned an invalid content length.',
        );
      }
      final totalBytes = status == HttpStatus.partialContent
          ? range!.total
          : contentLength;
      if ((totalBytes != null && totalBytes > maximumBytes) ||
          (range != null && range.end + 1 > maximumBytes)) {
        await _discardBody(response);
        await _discardPartialDownload(partialFile);
        throw _downloadTooLarge();
      }
      final mimeType = response.headers.value(Headers.contentTypeHeader);
      if (_isKnownNonMediaMimeType(mimeType)) {
        await _discardBody(response);
        await _discardPartialDownload(partialFile);
        throw const DownloadTransferException(
          'invalid_media_response',
          'The download server returned a web page instead of media.',
          retryable: false,
        );
      }
      final body = response.data;
      if (body == null) {
        throw const DownloadTransferException(
          'empty_response',
          'The download server returned no response body.',
        );
      }

      if (offset == 0) {
        final newValidator = _resumeValidatorFromResponse(response);
        if (newValidator == null) {
          await _deleteResumeValidator(validatorFile);
        } else {
          await _writeResumeValidator(validatorFile, newValidator);
        }
      }

      final sink = partialFile.openWrite(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );
      var received = offset;
      var reportedAt = DateTime.now();
      var reportedBytes = received;
      final sniffedPrefix = <int>[];
      try {
        await for (final bytes in body.stream) {
          if (cancellation.isCancelled) {
            throw const DownloadTransferCancelled();
          }
          if (received + bytes.length > maximumBytes) {
            throw _downloadTooLarge();
          }
          if (offset == 0 && sniffedPrefix.length < _bodySniffBytes) {
            final remaining = _bodySniffBytes - sniffedPrefix.length;
            sniffedPrefix.addAll(
              bytes.length <= remaining ? bytes : bytes.take(remaining),
            );
            if (_looksLikeMarkupBody(sniffedPrefix)) {
              throw const DownloadTransferException(
                'invalid_media_response',
                'The download server returned a web page instead of media.',
                retryable: false,
              );
            }
          }
          sink.add(bytes);
          received += bytes.length;
          final now = DateTime.now();
          final elapsed = now.difference(reportedAt);
          if (elapsed >= const Duration(milliseconds: 250)) {
            final speed = elapsed.inMicroseconds <= 0
                ? 0
                : ((received - reportedBytes) *
                          Duration.microsecondsPerSecond /
                          elapsed.inMicroseconds)
                      .round();
            onProgress(
              DownloadTransferProgress(
                receivedBytes: received,
                totalBytes: totalBytes,
                speedBytesPerSecond: speed.clamp(0, 0x7fffffff),
              ),
            );
            reportedAt = now;
            reportedBytes = received;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      if (range != null && received - offset != range.length) {
        throw DownloadTransferException(
          'incomplete_body',
          'The connection ended after ${received - offset} of '
              '${range.length} response bytes.',
        );
      }
      if (totalBytes != null && received != totalBytes) {
        throw DownloadTransferException(
          'incomplete_body',
          'The connection ended after $received of $totalBytes bytes.',
        );
      }
      onProgress(
        DownloadTransferProgress(
          receivedBytes: received,
          totalBytes: totalBytes,
          speedBytesPerSecond: 0,
        ),
      );
      await _deleteResumeValidator(validatorFile);
      return DownloadTransferResult(
        receivedBytes: received,
        totalBytes: totalBytes,
        mimeType: mimeType,
      );
    } on DownloadTransferException catch (error) {
      if (error.code == 'download_too_large' ||
          error.code == 'invalid_media_response') {
        await _discardPartialDownload(partialFile);
      }
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || cancellation.isCancelled) {
        throw const DownloadTransferCancelled();
      }
      throw DownloadTransferException(
        'network_${error.type.name}',
        'The download connection failed.',
      );
    } on FileSystemException catch (error) {
      throw DownloadTransferException(
        'storage_io',
        error.osError?.message ?? 'The download could not be written.',
        retryable: false,
      );
    }
  }

  Future<Response<ResponseBody>> _open(
    Uri initial, {
    required int offset,
    required String? ifRange,
    required Map<String, String> headers,
    required CancelToken cancellation,
  }) async {
    var uri = initial;
    var scopedHeaders = headers;
    for (var redirect = 0; redirect <= 5; redirect++) {
      if (!_isSafeHttps(uri)) {
        throw const DownloadTransferException(
          'unsafe_redirect',
          'The download attempted to leave HTTPS.',
          retryable: false,
        );
      }
      final response = await _dio.getUri<ResponseBody>(
        uri,
        cancelToken: cancellation,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          headers: {
            ...scopedHeaders,
            if (offset > 0) HttpHeaders.rangeHeader: 'bytes=$offset-',
            if (offset > 0 && ifRange != null) 'If-Range': ifRange,
          },
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
        ),
      );
      final status = response.statusCode ?? 0;
      if (!_redirectStatuses.contains(status)) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await _discardBody(response);
      if (location == null || location.trim().isEmpty) {
        throw const DownloadTransferException(
          'invalid_redirect',
          'The download server returned an empty redirect.',
        );
      }
      final redirected = uri.resolve(location);
      if (!_sameOrigin(uri, redirected)) {
        scopedHeaders = _headersSafeAcrossOrigins(scopedHeaders);
      }
      uri = redirected;
    }
    throw const DownloadTransferException(
      'too_many_redirects',
      'The download server redirected too many times.',
    );
  }
}

Dio _publicDownloadDio() {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => createPinnedPublicHttpsClient(),
  );
  return dio;
}

const _redirectStatuses = {301, 302, 303, 307, 308};
const _defaultMaximumDownloadBytes = 32 * 1024 * 1024 * 1024;
const _bodySniffBytes = 512;

const _crossOriginSafeHeaders = {
  'accept',
  'accept-language',
  'content-type',
  'range',
  'user-agent',
};

Map<String, String> _headersSafeAcrossOrigins(Map<String, String> headers) =>
    Map.unmodifiable({
      for (final entry in headers.entries)
        if (_crossOriginSafeHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    });

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

bool _isSafeHttps(Uri uri) =>
    !uri.hasFragment && safePublicHttpsUri(uri.toString()) != null;

DownloadTransferException _downloadTooLarge() =>
    const DownloadTransferException(
      'download_too_large',
      'The media is larger than the configured offline download limit.',
      retryable: false,
    );

bool _isKnownNonMediaMimeType(String? value) {
  final mimeType = (value ?? '').split(';').first.trim().toLowerCase();
  if (mimeType.isEmpty || mimeType == 'application/octet-stream') return false;
  return mimeType.startsWith('text/') ||
      mimeType == 'application/json' ||
      mimeType.endsWith('+json') ||
      mimeType == 'application/xml' ||
      mimeType.endsWith('+xml') ||
      mimeType == 'application/javascript' ||
      mimeType == 'application/x-javascript';
}

bool _looksLikeMarkupBody(List<int> prefix) {
  if (prefix.isEmpty) return false;
  var text = utf8.decode(prefix, allowMalformed: true);
  if (text.startsWith('\ufeff')) text = text.substring(1);
  final normalized = text.trimLeft().toLowerCase();
  return normalized.startsWith('<!doctype html') ||
      normalized.startsWith('<html') ||
      normalized.startsWith('<head') ||
      normalized.startsWith('<body') ||
      normalized.startsWith('<?xml');
}

enum _ResumeValidatorKind { etag, lastModified }

class _ResumeValidator {
  const _ResumeValidator(this.kind, this.value);

  final _ResumeValidatorKind kind;
  final String value;

  String serialize() => jsonEncode({'kind': kind.name, 'value': value});

  static _ResumeValidator? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final kind = switch (decoded['kind']) {
        'etag' => _ResumeValidatorKind.etag,
        'lastModified' => _ResumeValidatorKind.lastModified,
        _ => null,
      };
      final value = decoded['value'];
      if (kind == null || value is! String || value.trim().isEmpty) return null;
      final validator = _ResumeValidator(kind, value);
      return validator.isValid ? validator : null;
    } on FormatException {
      return null;
    }
  }

  bool get isValid => switch (kind) {
    _ResumeValidatorKind.etag => _isStrongEtag(value),
    _ResumeValidatorKind.lastModified => _isValidHttpDate(value),
  };
}

File _resumeValidatorFile(File partialFile) =>
    File('${partialFile.path}.validator');

Future<_ResumeValidator?> _readResumeValidator(File file) async {
  if (!await file.exists()) return null;
  return _ResumeValidator.parse(await file.readAsString());
}

Future<void> _writeResumeValidator(
  File file,
  _ResumeValidator validator,
) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(validator.serialize(), flush: true);
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

Future<void> _deleteResumeValidator(File file) async {
  if (await file.exists()) await file.delete();
  final temporary = File('${file.path}.tmp');
  if (await temporary.exists()) await temporary.delete();
}

Future<void> _discardPartialDownload(File partialFile) async {
  if (await partialFile.exists()) await partialFile.delete();
  await _deleteResumeValidator(_resumeValidatorFile(partialFile));
}

_ResumeValidator? _resumeValidatorFromResponse(
  Response<ResponseBody> response,
) {
  final etag = response.headers.value(HttpHeaders.etagHeader)?.trim();
  if (etag != null && _isStrongEtag(etag)) {
    return _ResumeValidator(_ResumeValidatorKind.etag, etag);
  }
  final lastModified = response.headers
      .value(HttpHeaders.lastModifiedHeader)
      ?.trim();
  if (lastModified != null && _isValidHttpDate(lastModified)) {
    return _ResumeValidator(_ResumeValidatorKind.lastModified, lastModified);
  }
  return null;
}

bool _responseMatchesValidator(
  Response<ResponseBody> response,
  _ResumeValidator expected,
) {
  final actual = _resumeValidatorFromResponse(response);
  return actual != null &&
      actual.kind == expected.kind &&
      actual.value == expected.value;
}

bool _isStrongEtag(String value) {
  final trimmed = value.trim();
  return trimmed.length >= 2 &&
      !trimmed.toLowerCase().startsWith('w/') &&
      trimmed.startsWith('"') &&
      trimmed.endsWith('"');
}

bool _isValidHttpDate(String value) {
  try {
    HttpDate.parse(value);
    return true;
  } on HttpException {
    return false;
  }
}

Future<void> _discardBody(Response<ResponseBody> response) async {
  final body = response.data;
  if (body == null) return;
  final subscription = body.stream.listen((_) {});
  await subscription.cancel();
}

({int start, int end, int length, int? total})? _contentRange(
  Response<ResponseBody> response,
) {
  final value = response.headers.value(HttpHeaders.contentRangeHeader);
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    caseSensitive: false,
  ).firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = match.group(3) == '*' ? null : int.parse(match.group(3)!);
  if (end < start || (total != null && (total <= 0 || end >= total))) {
    return null;
  }
  return (start: start, end: end, length: end - start + 1, total: total);
}

int? _unsatisfiedRangeTotal(Response<ResponseBody> response) {
  final value = response.headers.value(HttpHeaders.contentRangeHeader);
  final match = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value?.trim() ?? '');
  return match == null ? null : int.parse(match.group(1)!);
}
