import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:path/path.dart' as path;

/// Hard resource ceilings for materializing an HLS VOD.
final class HlsOfflineDownloadLimits {
  const HlsOfflineDownloadLimits({
    this.maximumPlaylistBytes = 2 * 1024 * 1024,
    this.maximumPlaylistCount = 4,
    this.maximumVariantCount = 100,
    this.maximumSegmentCount = 20000,
    this.maximumSegmentBytes = 512 * 1024 * 1024,
    this.maximumTotalBytes = 32 * 1024 * 1024 * 1024,
    this.maximumConcurrency = 4,
    this.maximumRedirects = 5,
  }) : assert(maximumPlaylistBytes > 0),
       assert(maximumPlaylistCount > 0),
       assert(maximumVariantCount > 0),
       assert(maximumSegmentCount > 0),
       assert(maximumSegmentBytes > 0),
       assert(maximumTotalBytes > 0),
       assert(maximumConcurrency > 0),
       assert(maximumRedirects >= 0);

  final int maximumPlaylistBytes;
  final int maximumPlaylistCount;
  final int maximumVariantCount;
  final int maximumSegmentCount;
  final int maximumSegmentBytes;
  final int maximumTotalBytes;
  final int maximumConcurrency;
  final int maximumRedirects;
}

/// Directory holding the segments referenced by the eventual local playlist.
///
/// `episode.m3u8.part` becomes the adjacent `episode.m3u8.hls` directory, so
/// promoting the playlist to `episode.m3u8` does not invalidate its relative
/// references. Storage cleanup should remove this directory with either the
/// partial or completed playlist.
Directory hlsSegmentDirectoryForPartialFile(File partialFile) {
  final partialPath = partialFile.path;
  final outputPath = partialPath.endsWith('.part')
      ? partialPath.substring(0, partialPath.length - '.part'.length)
      : partialPath;
  return Directory('$outputPath.hls');
}

Dio _publicHlsDownloadDio() {
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

/// Downloads a bounded, unencrypted HLS VOD and writes a credential-free local
/// media playlist to [partialFile]. Completed segment files are immutable
/// checkpoints and are reused after cancellation or process restart.
final class HlsOfflineDownloadTransferClient implements DownloadTransferClient {
  HlsOfflineDownloadTransferClient({
    Dio? dio,
    this.limits = const HlsOfflineDownloadLimits(),
  }) : _dio = dio ?? _publicHlsDownloadDio();

  final Dio _dio;
  final HlsOfflineDownloadLimits limits;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) async {
    final rootUri = job.sourceUri;
    if (rootUri == null || !_isSafeHttps(rootUri)) {
      throw const DownloadTransferException(
        'invalid_hls_source',
        'The HLS download does not have a valid HTTPS source.',
        retryable: false,
      );
    }
    final headers = _validatedHeaders(requestHeaders);
    if (cancellation.isCancelled) throw const DownloadTransferCancelled();

    final dioCancellation = CancelToken();
    cancellation.whenCancelled(
      () => dioCancellation.cancel('offline HLS download cancelled'),
    );

    try {
      await _prepareParent(partialFile);
      final segmentDirectory = hlsSegmentDirectoryForPartialFile(partialFile);

      final playlistBudget = _PlaylistBudget(limits);
      var document = await _fetchPlaylist(
        rootUri,
        headers: headers,
        cancellation: dioCancellation,
        budget: playlistBudget,
      );
      final visited = <Uri>{};
      while (_isMasterPlaylist(document.text)) {
        if (!visited.add(document.uri)) {
          throw const DownloadTransferException(
            'recursive_hls_playlist',
            'The HLS playlist contains a recursive variant.',
            retryable: false,
          );
        }
        final variants = _parseMasterPlaylist(
          document.text,
          document.uri,
          limits.maximumVariantCount,
        );
        final selected = _selectVariant(variants, job.quality);
        if (selected.hasExternalAudio || selected.hasExternalSubtitles) {
          throw const DownloadTransferException(
            'unsupported_hls_rendition',
            'Offline HLS does not support external audio or subtitle renditions.',
            retryable: false,
          );
        }
        document = await _fetchPlaylist(
          selected.uri,
          headers: _childHeaders(document, selected.uri),
          cancellation: dioCancellation,
          budget: playlistBudget,
        );
      }

      final media = _parseMediaPlaylist(
        document.text,
        document.uri,
        path.basename(segmentDirectory.path),
        limits,
      );
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      await _prepareSegmentDirectory(segmentDirectory);
      await _ensureMatchingManifestFingerprint(
        segmentDirectory,
        _hlsManifestFingerprint(document, media),
      );

      final pending = <_HlsResource>[];
      var resumedBytes = 0;
      for (final resource in media.resources) {
        final file = File(path.join(segmentDirectory.path, resource.localName));
        final temporary = File('${file.path}.part');
        await _ensureRegularOrMissing(temporary);
        if (await temporary.exists()) await temporary.delete();
        final existing = await _completedResourceLength(file, limits);
        if (existing == null) {
          pending.add(resource);
        } else {
          resumedBytes += existing;
        }
      }
      final directoryBytes = await _directoryBytes(segmentDirectory, limits);
      final storage = _StorageBudget(
        maximumBytes: limits.maximumTotalBytes,
        initialBytes: directoryBytes,
      );

      final progress = _HlsProgressReporter(
        onProgress: onProgress,
        receivedBytes: resumedBytes,
        unresolvedResources: pending.length,
      );
      progress.report(force: resumedBytes > 0);
      await _downloadResources(
        pending,
        baseDocument: document,
        segmentDirectory: segmentDirectory,
        cancellation: cancellation,
        dioCancellation: dioCancellation,
        storage: storage,
        progress: progress,
      );
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      await _removeUnreferencedResources(segmentDirectory, {
        _hlsManifestFingerprintFileName,
        ...media.resources.map((resource) => resource.localName),
      });

      final playlistBytes = Uint8List.fromList(utf8.encode(media.localText));
      if (playlistBytes.length > limits.maximumPlaylistBytes ||
          storage.claimedBytes + playlistBytes.length >
              limits.maximumTotalBytes) {
        throw const DownloadTransferException(
          'hls_storage_limit',
          'The offline HLS download exceeds its storage safety limit.',
          retryable: false,
        );
      }
      await _writeLocalPlaylist(partialFile, playlistBytes);
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      progress.finish();

      // DownloadTransferResult describes the promoted partial file. Media-byte
      // progress is reported separately because segments live beside it.
      return DownloadTransferResult(
        receivedBytes: playlistBytes.length,
        totalBytes: playlistBytes.length,
        mimeType: 'application/vnd.apple.mpegurl',
      );
    } on DownloadTransferException {
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || cancellation.isCancelled) {
        throw const DownloadTransferCancelled();
      }
      throw const DownloadTransferException(
        'hls_network_failure',
        'The offline HLS connection failed.',
      );
    } on FileSystemException {
      throw const DownloadTransferException(
        'hls_storage_io',
        'Offline HLS data could not be written.',
        retryable: false,
      );
    } on FormatException {
      throw const DownloadTransferException(
        'invalid_hls_playlist',
        'The server returned an invalid HLS playlist.',
        retryable: false,
      );
    } catch (_) {
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      throw const DownloadTransferException(
        'hls_transfer_failure',
        'The offline HLS transfer failed safely.',
      );
    }
  }

  Future<void> _downloadResources(
    List<_HlsResource> resources, {
    required _PlaylistDocument baseDocument,
    required Directory segmentDirectory,
    required DownloadCancellationToken cancellation,
    required CancelToken dioCancellation,
    required _StorageBudget storage,
    required _HlsProgressReporter progress,
  }) async {
    var next = 0;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (firstError == null) {
        if (cancellation.isCancelled) {
          firstError = const DownloadTransferCancelled();
          firstStack = StackTrace.current;
          return;
        }
        if (next >= resources.length) return;
        final resource = resources[next++];
        try {
          await _downloadResource(
            resource,
            headers: _childHeaders(baseDocument, resource.uri),
            segmentDirectory: segmentDirectory,
            cancellation: cancellation,
            dioCancellation: dioCancellation,
            storage: storage,
            progress: progress,
          );
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
          return;
        }
      }
    }

    final workerCount = resources.length.clamp(0, limits.maximumConcurrency);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }

  Future<void> _downloadResource(
    _HlsResource resource, {
    required Map<String, String> headers,
    required Directory segmentDirectory,
    required DownloadCancellationToken cancellation,
    required CancelToken dioCancellation,
    required _StorageBudget storage,
    required _HlsProgressReporter progress,
  }) async {
    final destination = File(
      path.join(segmentDirectory.path, resource.localName),
    );
    final temporary = File('${destination.path}.part');
    await _ensureRegularOrMissing(temporary);
    if (await temporary.exists()) await temporary.delete();

    final opened = await _open(
      resource.uri,
      headers: headers,
      cancellation: dioCancellation,
    );
    final response = opened.response;
    final status = response.statusCode ?? 0;
    if (status != HttpStatus.ok) {
      await _discardBody(response);
      throw DownloadTransferException(
        'hls_http_$status',
        'The HLS server returned HTTP $status.',
        retryable: status >= 500 || status == 408 || status == 429,
      );
    }
    final body = response.data;
    if (body == null) {
      throw const DownloadTransferException(
        'empty_hls_segment',
        'The HLS server returned an empty segment response.',
      );
    }
    final declaredLength = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (declaredLength != null &&
        (declaredLength <= 0 || declaredLength > limits.maximumSegmentBytes)) {
      await _discardBody(response);
      throw const DownloadTransferException(
        'hls_segment_limit',
        'An HLS segment exceeds its size safety limit.',
        retryable: false,
      );
    }
    final mimeType = response.headers.value(Headers.contentTypeHeader);
    if (_isKnownNonMediaResourceMimeType(mimeType)) {
      await _discardBody(response);
      throw const DownloadTransferException(
        'invalid_hls_media_response',
        'The HLS server returned a web page instead of media.',
        retryable: false,
      );
    }
    progress.resourceOpened(declaredLength);

    final sink = temporary.openWrite(mode: FileMode.write);
    var received = 0;
    final sniffedPrefix = <int>[];
    try {
      await for (final bytes in body.stream) {
        if (cancellation.isCancelled) {
          throw const DownloadTransferCancelled();
        }
        if (received + bytes.length > limits.maximumSegmentBytes) {
          throw const DownloadTransferException(
            'hls_segment_limit',
            'An HLS segment exceeds its size safety limit.',
            retryable: false,
          );
        }
        if (sniffedPrefix.length < _hlsBodySniffBytes) {
          final remaining = _hlsBodySniffBytes - sniffedPrefix.length;
          sniffedPrefix.addAll(
            bytes.length <= remaining ? bytes : bytes.take(remaining),
          );
          if (_looksLikeHlsMarkupBody(sniffedPrefix)) {
            throw const DownloadTransferException(
              'invalid_hls_media_response',
              'The HLS server returned a web page instead of media.',
              retryable: false,
            );
          }
        }
        storage.claim(bytes.length);
        sink.add(bytes);
        received += bytes.length;
        progress.addBytes(bytes.length);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (cancellation.isCancelled) throw const DownloadTransferCancelled();
    if (received <= 0) {
      throw const DownloadTransferException(
        'empty_hls_segment',
        'The HLS server returned an empty segment.',
      );
    }
    if (declaredLength != null && received != declaredLength) {
      throw const DownloadTransferException(
        'incomplete_hls_segment',
        'An HLS segment ended before its declared size.',
      );
    }
    progress.resourceCompleted(declaredLength, received);
    await _ensureRegularOrMissing(destination);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  }

  Future<_PlaylistDocument> _fetchPlaylist(
    Uri uri, {
    required Map<String, String> headers,
    required CancelToken cancellation,
    required _PlaylistBudget budget,
  }) async {
    budget.claimPlaylist();
    final opened = await _open(
      uri,
      headers: headers,
      cancellation: cancellation,
    );
    final response = opened.response;
    final status = response.statusCode ?? 0;
    if (status != HttpStatus.ok) {
      await _discardBody(response);
      throw DownloadTransferException(
        'hls_http_$status',
        'The HLS server returned HTTP $status.',
        retryable: status >= 500 || status == 408 || status == 429,
      );
    }
    final body = response.data;
    if (body == null) {
      throw const DownloadTransferException(
        'empty_hls_playlist',
        'The HLS server returned no playlist body.',
      );
    }
    final declaredLength = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (declaredLength != null &&
        declaredLength > limits.maximumPlaylistBytes) {
      await _discardBody(response);
      throw const DownloadTransferException(
        'hls_playlist_limit',
        'The HLS playlist exceeds its size safety limit.',
        retryable: false,
      );
    }

    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final bytes in body.stream) {
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      received += bytes.length;
      if (received > limits.maximumPlaylistBytes) {
        throw const DownloadTransferException(
          'hls_playlist_limit',
          'The HLS playlist exceeds its size safety limit.',
          retryable: false,
        );
      }
      builder.add(bytes);
    }
    if (declaredLength != null && received != declaredLength) {
      throw const DownloadTransferException(
        'incomplete_hls_playlist',
        'The HLS playlist ended before its declared size.',
      );
    }
    final bytes = builder.takeBytes();
    final text = utf8.decode(bytes, allowMalformed: false);
    if (!_startsWithHeader(text)) {
      throw const DownloadTransferException(
        'invalid_hls_playlist',
        'The server returned an invalid HLS playlist.',
        retryable: false,
      );
    }
    return _PlaylistDocument(
      uri: opened.uri,
      requestHeaders: opened.requestHeaders,
      text: text,
    );
  }

  Future<_OpenedResponse> _open(
    Uri initial, {
    required Map<String, String> headers,
    required CancelToken cancellation,
  }) async {
    var uri = initial;
    var scopedHeaders = headers;
    for (var redirect = 0; redirect <= limits.maximumRedirects; redirect++) {
      if (!_isSafeHttps(uri)) {
        throw const DownloadTransferException(
          'unsafe_hls_uri',
          'The HLS download attempted to leave HTTPS.',
          retryable: false,
        );
      }
      final response = await _dio.getUri<ResponseBody>(
        uri,
        cancelToken: cancellation,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          headers: scopedHeaders,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
        ),
      );
      final status = response.statusCode ?? 0;
      if (!_redirectStatuses.contains(status)) {
        return _OpenedResponse(
          uri: uri,
          requestHeaders: scopedHeaders,
          response: response,
        );
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await _discardBody(response);
      if (location == null || location.trim().isEmpty) {
        throw const DownloadTransferException(
          'invalid_hls_redirect',
          'The HLS server returned an invalid redirect.',
        );
      }
      final next = _resolveHttps(uri, location);
      if (!_sameOrigin(uri, next)) scopedHeaders = const {};
      uri = next;
    }
    throw const DownloadTransferException(
      'too_many_hls_redirects',
      'The HLS server redirected too many times.',
    );
  }
}

const _redirectStatuses = {301, 302, 303, 307, 308};
const _hlsBodySniffBytes = 512;

bool _isKnownNonMediaResourceMimeType(String? value) {
  final mimeType = (value ?? '').split(';').first.trim().toLowerCase();
  if (mimeType.isEmpty ||
      mimeType == 'application/octet-stream' ||
      mimeType == 'binary/octet-stream') {
    return false;
  }
  return mimeType == 'text/html' ||
      mimeType == 'application/xhtml+xml' ||
      mimeType == 'application/json' ||
      mimeType.endsWith('+json') ||
      mimeType == 'application/xml' ||
      mimeType == 'text/xml' ||
      mimeType.endsWith('+xml') ||
      mimeType == 'application/javascript' ||
      mimeType == 'application/x-javascript' ||
      mimeType == 'text/javascript';
}

bool _looksLikeHlsMarkupBody(List<int> prefix) {
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

final class _PlaylistBudget {
  _PlaylistBudget(this.limits);

  final HlsOfflineDownloadLimits limits;
  int _count = 0;

  void claimPlaylist() {
    _count++;
    if (_count > limits.maximumPlaylistCount) {
      throw const DownloadTransferException(
        'hls_playlist_count_limit',
        'The HLS playlist nesting exceeds its safety limit.',
        retryable: false,
      );
    }
  }
}

final class _StorageBudget {
  _StorageBudget({required this.maximumBytes, required int initialBytes})
    : claimedBytes = initialBytes {
    if (initialBytes > maximumBytes) {
      throw const DownloadTransferException(
        'hls_storage_limit',
        'The offline HLS download exceeds its storage safety limit.',
        retryable: false,
      );
    }
  }

  final int maximumBytes;
  int claimedBytes;

  void claim(int bytes) {
    if (bytes < 0 || claimedBytes > maximumBytes - bytes) {
      throw const DownloadTransferException(
        'hls_storage_limit',
        'The offline HLS download exceeds its storage safety limit.',
        retryable: false,
      );
    }
    claimedBytes += bytes;
  }
}

final class _HlsProgressReporter {
  _HlsProgressReporter({
    required this.onProgress,
    required this.receivedBytes,
    required this.unresolvedResources,
  }) : _reportedAt = DateTime.now(),
       _reportedBytes = receivedBytes,
       _knownTotalBytes = receivedBytes;

  final void Function(DownloadTransferProgress progress) onProgress;
  int receivedBytes;
  int unresolvedResources;
  int _knownTotalBytes;
  DateTime _reportedAt;
  int _reportedBytes;

  void resourceOpened(int? declaredLength) {
    if (declaredLength == null) return;
    unresolvedResources--;
    _knownTotalBytes += declaredLength;
  }

  void resourceCompleted(int? declaredLength, int actualLength) {
    if (declaredLength != null) return;
    unresolvedResources--;
    _knownTotalBytes += actualLength;
  }

  void addBytes(int count) {
    receivedBytes += count;
    report();
  }

  void report({bool force = false}) {
    final now = DateTime.now();
    final elapsed = now.difference(_reportedAt);
    if (!force && elapsed < const Duration(milliseconds: 250)) return;
    final speed = elapsed.inMicroseconds <= 0
        ? 0
        : ((receivedBytes - _reportedBytes) *
                  Duration.microsecondsPerSecond /
                  elapsed.inMicroseconds)
              .round();
    onProgress(
      DownloadTransferProgress(
        receivedBytes: receivedBytes,
        totalBytes: unresolvedResources == 0 ? _knownTotalBytes : null,
        speedBytesPerSecond: speed.clamp(0, 0x7fffffff),
      ),
    );
    _reportedAt = now;
    _reportedBytes = receivedBytes;
  }

  void finish() {
    onProgress(
      DownloadTransferProgress(
        receivedBytes: receivedBytes,
        totalBytes: _knownTotalBytes,
        speedBytesPerSecond: 0,
      ),
    );
  }
}

final class _PlaylistDocument {
  const _PlaylistDocument({
    required this.uri,
    required this.requestHeaders,
    required this.text,
  });

  final Uri uri;
  final Map<String, String> requestHeaders;
  final String text;
}

final class _OpenedResponse {
  const _OpenedResponse({
    required this.uri,
    required this.requestHeaders,
    required this.response,
  });

  final Uri uri;
  final Map<String, String> requestHeaders;
  final Response<ResponseBody> response;
}

final class _HlsVariant {
  const _HlsVariant({
    required this.uri,
    required this.height,
    required this.bandwidth,
    required this.name,
    required this.hasExternalAudio,
    required this.hasExternalSubtitles,
    required this.position,
  });

  final Uri uri;
  final int? height;
  final int? bandwidth;
  final String? name;
  final bool hasExternalAudio;
  final bool hasExternalSubtitles;
  final int position;
}

final class _HlsResource {
  const _HlsResource({required this.uri, required this.localName});

  final Uri uri;
  final String localName;
}

final class _ParsedMediaPlaylist {
  const _ParsedMediaPlaylist({
    required this.resources,
    required this.localText,
  });

  final List<_HlsResource> resources;
  final String localText;
}

bool _startsWithHeader(String text) {
  final source = text.startsWith('\ufeff') ? text.substring(1) : text;
  final lines = const LineSplitter().convert(source);
  return lines.isNotEmpty && lines.first.trim() == '#EXTM3U';
}

bool _isMasterPlaylist(String text) => const LineSplitter()
    .convert(text)
    .any((line) => line.trim().toUpperCase().startsWith('#EXT-X-STREAM-INF:'));

List<_HlsVariant> _parseMasterPlaylist(
  String text,
  Uri baseUri,
  int maximumVariants,
) {
  final lines = const LineSplitter().convert(text);
  if (lines.any((line) {
    final upper = line.trim().toUpperCase();
    return upper.startsWith('#EXT-X-KEY:') ||
        upper.startsWith('#EXT-X-SESSION-KEY:');
  })) {
    throw const DownloadTransferException(
      'protected_hls_unsupported',
      'Encrypted or DRM-protected HLS cannot be saved offline.',
      retryable: false,
    );
  }
  final variants = <_HlsVariant>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (!line.toUpperCase().startsWith('#EXT-X-STREAM-INF:')) continue;
    final attributes = _parseAttributes(line.substring(line.indexOf(':') + 1));
    String? reference;
    while (++index < lines.length) {
      final candidate = lines[index].trim();
      if (candidate.isEmpty) continue;
      if (candidate.startsWith('#')) {
        throw const DownloadTransferException(
          'invalid_hls_playlist',
          'The HLS master playlist has an incomplete variant.',
          retryable: false,
        );
      }
      reference = candidate;
      break;
    }
    if (reference == null) {
      throw const DownloadTransferException(
        'invalid_hls_playlist',
        'The HLS master playlist has an incomplete variant.',
        retryable: false,
      );
    }
    final resolution = attributes['RESOLUTION']?.toLowerCase().split('x');
    final height = resolution != null && resolution.length == 2
        ? int.tryParse(resolution.last)
        : null;
    final bandwidth = int.tryParse(
      attributes['AVERAGE-BANDWIDTH'] ?? attributes['BANDWIDTH'] ?? '',
    );
    final audio = attributes['AUDIO']?.trim();
    final subtitles = attributes['SUBTITLES']?.trim();
    variants.add(
      _HlsVariant(
        uri: _resolveHttps(baseUri, reference),
        height: height,
        bandwidth: bandwidth,
        name: attributes['NAME'],
        hasExternalAudio:
            audio != null && audio.isNotEmpty && audio.toUpperCase() != 'NONE',
        hasExternalSubtitles:
            subtitles != null &&
            subtitles.isNotEmpty &&
            subtitles.toUpperCase() != 'NONE',
        position: variants.length,
      ),
    );
    if (variants.length > maximumVariants) {
      throw const DownloadTransferException(
        'hls_variant_count_limit',
        'The HLS master playlist contains too many variants.',
        retryable: false,
      );
    }
  }
  if (variants.isEmpty) {
    throw const DownloadTransferException(
      'invalid_hls_playlist',
      'The HLS master playlist contains no variants.',
      retryable: false,
    );
  }
  return variants;
}

_HlsVariant _selectVariant(List<_HlsVariant> source, String? requestedQuality) {
  final variants = source.toList();
  variants.sort(_compareVariants);
  final requested = requestedQuality?.trim().toLowerCase() ?? '';
  if (requested.isEmpty ||
      requested.contains('auto') ||
      requested.contains('best') ||
      requested.contains('high')) {
    return variants.first;
  }
  if (requested.contains('low')) return variants.last;

  final desiredHeight = int.tryParse(
    RegExp(r'\d{2,4}').firstMatch(requested)?.group(0) ?? '',
  );
  for (final variant in variants) {
    if ((desiredHeight != null && variant.height == desiredHeight) ||
        variant.name?.trim().toLowerCase() == requested) {
      return variant;
    }
  }
  return variants.first;
}

int _compareVariants(_HlsVariant left, _HlsVariant right) {
  final height = (right.height ?? -1).compareTo(left.height ?? -1);
  if (height != 0) return height;
  final bandwidth = (right.bandwidth ?? -1).compareTo(left.bandwidth ?? -1);
  if (bandwidth != 0) return bandwidth;
  return left.position.compareTo(right.position);
}

_ParsedMediaPlaylist _parseMediaPlaylist(
  String text,
  Uri baseUri,
  String localDirectoryName,
  HlsOfflineDownloadLimits limits,
) {
  final source = text.startsWith('\ufeff') ? text.substring(1) : text;
  final lines = const LineSplitter().convert(source);
  if (lines.isEmpty || lines.first.trim() != '#EXTM3U') {
    throw const DownloadTransferException(
      'invalid_hls_playlist',
      'The server returned an invalid HLS playlist.',
      retryable: false,
    );
  }

  final resources = <_HlsResource>[];
  final output = <String>['#EXTM3U'];
  final initializers = <Uri, String>{};
  String? pendingDuration;
  var hasEndList = false;
  var hasTargetDuration = false;
  var mediaSegments = 0;

  for (var index = 1; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    if (!line.startsWith('#')) {
      if (pendingDuration == null || hasEndList) {
        throw const DownloadTransferException(
          'invalid_hls_playlist',
          'The HLS media playlist contains an invalid segment.',
          retryable: false,
        );
      }
      final uri = _resolveHttps(baseUri, line);
      final localName =
          'segment-${mediaSegments.toString().padLeft(6, '0')}${_resourceExtension(uri, '.ts')}';
      resources.add(_HlsResource(uri: uri, localName: localName));
      mediaSegments++;
      if (resources.length > limits.maximumSegmentCount) {
        throw const DownloadTransferException(
          'hls_segment_count_limit',
          'The HLS playlist contains too many segments.',
          retryable: false,
        );
      }
      output
        ..add('#EXTINF:$pendingDuration,')
        ..add(_relativeUri(localDirectoryName, localName));
      pendingDuration = null;
      continue;
    }

    final colon = line.indexOf(':');
    final tag = (colon < 0 ? line : line.substring(0, colon)).toUpperCase();
    final value = colon < 0 ? '' : line.substring(colon + 1).trim();
    switch (tag) {
      case '#EXTM3U':
        throw const DownloadTransferException(
          'invalid_hls_playlist',
          'The HLS media playlist contains a second header.',
          retryable: false,
        );
      case '#EXT-X-KEY':
      case '#EXT-X-SESSION-KEY':
        throw const DownloadTransferException(
          'protected_hls_unsupported',
          'Encrypted or DRM-protected HLS cannot be saved offline.',
          retryable: false,
        );
      case '#EXT-X-BYTERANGE':
        throw const DownloadTransferException(
          'hls_byterange_unsupported',
          'Byte-range HLS playlists are not supported offline.',
          retryable: false,
        );
      case '#EXT-X-PART':
      case '#EXT-X-PRELOAD-HINT':
      case '#EXT-X-SERVER-CONTROL':
      case '#EXT-X-SKIP':
      case '#EXT-X-RENDITION-REPORT':
      case '#EXT-X-DEFINE':
        throw const DownloadTransferException(
          'dynamic_hls_unsupported',
          'Dynamic HLS playlist features are not supported offline.',
          retryable: false,
        );
      case '#EXT-X-STREAM-INF':
      case '#EXT-X-I-FRAME-STREAM-INF':
      case '#EXT-X-MEDIA':
        throw const DownloadTransferException(
          'invalid_hls_playlist',
          'The selected HLS variant is not a media playlist.',
          retryable: false,
        );
      case '#EXTINF':
        if (pendingDuration != null) {
          throw const DownloadTransferException(
            'invalid_hls_playlist',
            'The HLS media playlist contains an incomplete segment.',
            retryable: false,
          );
        }
        final durationText = value.split(',').first.trim();
        final duration = double.tryParse(durationText);
        if (duration == null || !duration.isFinite || duration < 0) {
          throw const DownloadTransferException(
            'invalid_hls_playlist',
            'The HLS media playlist contains an invalid duration.',
            retryable: false,
          );
        }
        pendingDuration = duration.toString();
      case '#EXT-X-MAP':
        final attributes = _parseAttributes(value);
        if (attributes.containsKey('BYTERANGE')) {
          throw const DownloadTransferException(
            'hls_byterange_unsupported',
            'Byte-range HLS playlists are not supported offline.',
            retryable: false,
          );
        }
        final reference = attributes['URI'];
        if (reference == null || reference.isEmpty) {
          throw const DownloadTransferException(
            'invalid_hls_playlist',
            'The HLS initialization map is invalid.',
            retryable: false,
          );
        }
        final uri = _resolveHttps(baseUri, reference);
        var localName = initializers[uri];
        if (localName == null) {
          localName =
              'init-${initializers.length.toString().padLeft(4, '0')}${_resourceExtension(uri, '.mp4')}';
          initializers[uri] = localName;
          resources.add(_HlsResource(uri: uri, localName: localName));
          if (resources.length > limits.maximumSegmentCount) {
            throw const DownloadTransferException(
              'hls_segment_count_limit',
              'The HLS playlist contains too many media resources.',
              retryable: false,
            );
          }
        }
        output.add(
          '#EXT-X-MAP:URI="${_relativeUri(localDirectoryName, localName)}"',
        );
      case '#EXT-X-ENDLIST':
        hasEndList = true;
      case '#EXT-X-TARGETDURATION':
        final duration = int.tryParse(value);
        if (duration == null || duration <= 0) {
          throw const DownloadTransferException(
            'invalid_hls_playlist',
            'The HLS target duration is invalid.',
            retryable: false,
          );
        }
        hasTargetDuration = true;
        output.add('#EXT-X-TARGETDURATION:$duration');
      case '#EXT-X-VERSION':
        final version = int.tryParse(value);
        if (version == null || version <= 0) {
          throw const DownloadTransferException(
            'invalid_hls_playlist',
            'The HLS version is invalid.',
            retryable: false,
          );
        }
        output.add('#EXT-X-VERSION:$version');
      case '#EXT-X-MEDIA-SEQUENCE':
      case '#EXT-X-DISCONTINUITY-SEQUENCE':
        final sequence = int.tryParse(value);
        if (sequence == null || sequence < 0) {
          throw const DownloadTransferException(
            'invalid_hls_playlist',
            'The HLS media sequence is invalid.',
            retryable: false,
          );
        }
        output.add('$tag:$sequence');
      case '#EXT-X-PLAYLIST-TYPE':
        if (value.toUpperCase() != 'VOD') {
          throw const DownloadTransferException(
            'hls_live_unsupported',
            'Live or mutable HLS playlists cannot be saved offline.',
            retryable: false,
          );
        }
        output.add('#EXT-X-PLAYLIST-TYPE:VOD');
      case '#EXT-X-INDEPENDENT-SEGMENTS':
      case '#EXT-X-DISCONTINUITY':
      case '#EXT-X-GAP':
        output.add(tag);
      default:
        // Unknown tags and comments are deliberately omitted so arbitrary
        // upstream text (including signed URLs) is never persisted locally.
        break;
    }
  }
  if (!hasEndList) {
    throw const DownloadTransferException(
      'hls_live_unsupported',
      'Live or mutable HLS playlists cannot be saved offline.',
      retryable: false,
    );
  }
  if (pendingDuration != null || mediaSegments == 0 || !hasTargetDuration) {
    throw const DownloadTransferException(
      'invalid_hls_playlist',
      'The HLS media playlist is incomplete.',
      retryable: false,
    );
  }
  output.add('#EXT-X-ENDLIST');
  return _ParsedMediaPlaylist(
    resources: List.unmodifiable(resources),
    localText: '${output.join('\n')}\n',
  );
}

Map<String, String> _parseAttributes(String source) {
  final result = <String, String>{};
  var start = 0;
  var quoted = false;
  final parts = <String>[];
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    if (character == '"') quoted = !quoted;
    if (character == ',' && !quoted) {
      parts.add(source.substring(start, index));
      start = index + 1;
    }
  }
  if (quoted) throw const FormatException('Unterminated HLS attribute.');
  parts.add(source.substring(start));
  for (final part in parts) {
    final equals = part.indexOf('=');
    if (equals <= 0) continue;
    final key = part.substring(0, equals).trim().toUpperCase();
    var value = part.substring(equals + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    result[key] = value;
  }
  return result;
}

String _resourceExtension(Uri uri, String fallback) {
  final extension = path.posix.extension(uri.path).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
      ? extension
      : fallback;
}

String _relativeUri(String directory, String filename) =>
    Uri(pathSegments: [directory, filename]).toString();

Uri _resolveHttps(Uri base, String reference) {
  final Uri resolved;
  try {
    resolved = base.resolve(reference.trim());
  } on FormatException {
    throw const DownloadTransferException(
      'unsafe_hls_uri',
      'The HLS playlist contains an unsafe media reference.',
      retryable: false,
    );
  }
  if (!_isSafeHttps(resolved)) {
    throw const DownloadTransferException(
      'unsafe_hls_uri',
      'The HLS playlist contains an unsafe media reference.',
      retryable: false,
    );
  }
  return resolved;
}

bool _isSafeHttps(Uri uri) =>
    !uri.hasFragment && safePublicHttpsUri(uri.toString()) != null;

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

Map<String, String> _childHeaders(_PlaylistDocument parent, Uri child) =>
    _sameOrigin(parent.uri, child) ? parent.requestHeaders : const {};

Map<String, String> _validatedHeaders(Map<String, String> source) {
  final result = <String, String>{};
  final name = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  const blocked = {
    'connection',
    'content-length',
    'host',
    'proxy-connection',
    'range',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  for (final entry in source.entries) {
    final lower = entry.key.toLowerCase();
    if (!name.hasMatch(entry.key) ||
        entry.value.contains(RegExp(r'[\r\n]')) ||
        blocked.contains(lower)) {
      throw const DownloadTransferException(
        'invalid_hls_headers',
        'The HLS request headers are invalid.',
        retryable: false,
      );
    }
    result[entry.key] = entry.value;
  }
  return Map.unmodifiable(result);
}

Future<void> _prepareParent(File partialFile) async {
  await _ensureRegularOrMissing(partialFile);
  final parentType = await FileSystemEntity.type(
    partialFile.parent.path,
    followLinks: false,
  );
  if (parentType == FileSystemEntityType.link) {
    throw const DownloadTransferException(
      'unsafe_hls_local_state',
      'The offline HLS storage path is unsafe.',
      retryable: false,
    );
  }
  if (parentType == FileSystemEntityType.notFound) {
    await partialFile.parent.create(recursive: true);
  } else if (parentType != FileSystemEntityType.directory) {
    throw const DownloadTransferException(
      'unsafe_hls_local_state',
      'The offline HLS storage path is unsafe.',
      retryable: false,
    );
  }
}

Future<void> _prepareSegmentDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await directory.create();
  } else if (type != FileSystemEntityType.directory) {
    throw const DownloadTransferException(
      'unsafe_hls_local_state',
      'The offline HLS segment path is unsafe.',
      retryable: false,
    );
  }
}

const _hlsManifestFingerprintFileName = '.tetotv-manifest.sha256';

String _hlsManifestFingerprint(
  _PlaylistDocument document,
  _ParsedMediaPlaylist media,
) {
  final identity = StringBuffer()
    ..writeln(document.uri.replace(query: '', fragment: '').toString());
  for (final resource in media.resources) {
    identity
      ..write(resource.localName)
      ..write('\u0000')
      ..writeln(resource.uri.toString());
  }
  return sha256.convert(utf8.encode(identity.toString())).toString();
}

Future<void> _ensureMatchingManifestFingerprint(
  Directory directory,
  String fingerprint,
) async {
  final marker = File(
    path.join(directory.path, _hlsManifestFingerprintFileName),
  );
  await _ensureRegularOrMissing(marker);
  var matches = false;
  if (await marker.exists() && await marker.length() <= 128) {
    try {
      matches = (await marker.readAsString()).trim() == fingerprint;
    } on FormatException {
      matches = false;
    }
  }
  if (!matches) {
    // Ordinal segment filenames are only reusable for the exact same media
    // playlist. Discard all prior checkpoints when the selected variant,
    // manifest, or signed resource set changes.
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw const DownloadTransferException(
          'unsafe_hls_local_state',
          'The offline HLS segment directory contains an unsafe entry.',
          retryable: false,
        );
      }
      await File(entity.path).delete();
    }
    await marker.writeAsString(fingerprint, flush: true);
  }
}

Future<void> _ensureRegularOrMissing(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw const DownloadTransferException(
      'unsafe_hls_local_state',
      'The offline HLS storage contains an unsafe entry.',
      retryable: false,
    );
  }
}

Future<int?> _completedResourceLength(
  File file,
  HlsOfflineDownloadLimits limits,
) async {
  await _ensureRegularOrMissing(file);
  if (!await file.exists()) return null;
  final length = await file.length();
  if (length <= 0) {
    await file.delete();
    return null;
  }
  if (length > limits.maximumSegmentBytes) {
    throw const DownloadTransferException(
      'hls_segment_limit',
      'A saved HLS segment exceeds its size safety limit.',
      retryable: false,
    );
  }
  return length;
}

Future<int> _directoryBytes(
  Directory directory,
  HlsOfflineDownloadLimits limits,
) async {
  var total = 0;
  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const DownloadTransferException(
        'unsafe_hls_local_state',
        'The offline HLS segment directory contains an unsafe entry.',
        retryable: false,
      );
    }
    total += await File(entity.path).length();
    if (total > limits.maximumTotalBytes) {
      throw const DownloadTransferException(
        'hls_storage_limit',
        'The offline HLS download exceeds its storage safety limit.',
        retryable: false,
      );
    }
  }
  return total;
}

Future<void> _removeUnreferencedResources(
  Directory directory,
  Set<String> retainedNames,
) async {
  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const DownloadTransferException(
        'unsafe_hls_local_state',
        'The offline HLS segment directory contains an unsafe entry.',
        retryable: false,
      );
    }
    if (!retainedNames.contains(path.basename(entity.path))) {
      await File(entity.path).delete();
    }
  }
}

Future<void> _writeLocalPlaylist(File file, Uint8List bytes) async {
  await _ensureRegularOrMissing(file);
  final sink = file.openWrite(mode: FileMode.write);
  try {
    sink.add(bytes);
    await sink.flush();
  } finally {
    await sink.close();
  }
}

Future<void> _discardBody(Response<ResponseBody> response) async {
  final body = response.data;
  if (body == null) return;
  final subscription = body.stream.listen((_) {});
  await subscription.cancel();
}
