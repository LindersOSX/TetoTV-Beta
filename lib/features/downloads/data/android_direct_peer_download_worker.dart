import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A short-lived authorization to materialize one torrent-backed episode.
///
/// The magnet is deliberately private, has no serialization API, and is
/// redacted from [toString]. Callers must create a fresh capability after an
/// app restart instead of persisting it with a [DownloadJob].
final class DirectPeerDownloadCapability {
  DirectPeerDownloadCapability._({
    required this._magnet,
    required this.episode,
    required this.preferredFileIndex,
  });

  factory DirectPeerDownloadCapability({
    required String magnet,
    required int episode,
    int? preferredFileIndex,
  }) {
    if (!_isValidMagnet(magnet)) {
      throw ArgumentError.value(
        '<redacted>',
        'magnet',
        'must be a bounded BitTorrent magnet URI',
      );
    }
    if (episode <= 0 || episode > 100000) {
      throw ArgumentError.value(episode, 'episode');
    }
    if (preferredFileIndex != null && preferredFileIndex < 0) {
      throw ArgumentError.value(preferredFileIndex, 'preferredFileIndex');
    }
    return DirectPeerDownloadCapability._(
      magnet: magnet,
      episode: episode,
      preferredFileIndex: preferredFileIndex,
    );
  }

  final String _magnet;
  final int episode;
  final int? preferredFileIndex;

  @override
  String toString() =>
      'DirectPeerDownloadCapability(<redacted>, episode: $episode)';
}

/// Injectable boundary around the Android direct-torrent bridge.
abstract interface class DirectPeerNativePlatform {
  bool get isAvailable;

  Future<DirectTorrentCapability> capability();

  Future<DirectTorrentNativeSession> start({
    required String requestId,
    required String magnet,
    required int episode,
    int? preferredFileIndex,
  });

  Future<bool> cancelStart(String requestId);

  Future<bool> stop(String sessionId);
}

final class AndroidDirectPeerNativePlatform
    implements DirectPeerNativePlatform {
  const AndroidDirectPeerNativePlatform({this.bridge});

  final AndroidTvBridge? bridge;

  AndroidTvBridge get _resolvedBridge => bridge ?? AndroidTvBridge.instance;

  @override
  bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<DirectTorrentCapability> capability() =>
      _resolvedBridge.getDirectTorrentCapability();

  @override
  Future<DirectTorrentNativeSession> start({
    required String requestId,
    required String magnet,
    required int episode,
    int? preferredFileIndex,
  }) => _resolvedBridge.startDirectTorrent(
    requestId: requestId,
    magnet: magnet,
    episode: episode,
    preferredFileIndex: preferredFileIndex,
  );

  @override
  Future<bool> cancelStart(String requestId) =>
      _resolvedBridge.cancelDirectTorrentStart(requestId);

  @override
  Future<bool> stop(String sessionId) =>
      _resolvedBridge.stopDirectTorrent(sessionId);
}

typedef DirectPeerHttpClientFactory = HttpClient Function();

/// Downloads the native direct-torrent loopback stream into app-private
/// offline storage.
///
/// The authenticated loopback URL is accepted only from the current native
/// session and is never copied into the persistent [DownloadJob].
final class AndroidDirectPeerDownloadWorker
    implements DirectPeerDownloadWorker {
  AndroidDirectPeerDownloadWorker({
    this.platform = const AndroidDirectPeerNativePlatform(),
    DirectPeerHttpClientFactory? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? _newLoopbackClient;

  final DirectPeerNativePlatform platform;
  final DirectPeerHttpClientFactory _httpClientFactory;

  static int _requestSequence = 0;

  @override
  bool get isAvailable => platform.isAvailable;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required Object capability,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
  }) async {
    if (capability is! DirectPeerDownloadCapability) {
      throw const DownloadTransferException(
        'invalid_direct_peer_capability',
        'Re-select this torrent source to authorize the direct download.',
        retryable: false,
      );
    }
    if (job.transport != DownloadTransport.directPeer) {
      throw const DownloadTransferException(
        'invalid_direct_peer_job',
        'This download is not configured for a direct torrent transfer.',
        retryable: false,
      );
    }
    if (!platform.isAvailable) {
      throw const DownloadTransferException(
        'direct_peer_worker_unavailable',
        'Direct torrent downloads are unavailable on this device.',
        retryable: false,
      );
    }
    if (cancellation.isCancelled) throw const DownloadTransferCancelled();

    final requestId = _newRequestId();
    DirectTorrentNativeSession? session;
    HttpClient? client;
    var startPending = false;
    Future<void>? stopFuture;
    Future<void>? cancelStartFuture;

    Future<void> stopSession() {
      final current = session;
      if (current == null) return Future.value();
      return stopFuture ??= _ignoreCleanupFailure(
        () => platform.stop(current.sessionId),
      );
    }

    Future<void> cancelPendingStart() => cancelStartFuture ??=
        _ignoreCleanupFailure(() => platform.cancelStart(requestId));

    void handleCancellation() {
      client?.close(force: true);
      if (session != null) {
        unawaited(stopSession());
      } else if (startPending) {
        unawaited(cancelPendingStart());
      }
    }

    cancellation.whenCancelled(handleCancellation);

    try {
      final nativeCapability = await platform.capability();
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      if (!nativeCapability.supported ||
          !nativeCapability.supportsSeeking ||
          nativeCapability.maximumFileBytes <= 0) {
        throw const DownloadTransferException(
          'direct_peer_worker_unavailable',
          'This device cannot create resumable direct torrent downloads.',
          retryable: false,
        );
      }

      startPending = true;
      try {
        session = await platform.start(
          requestId: requestId,
          magnet: capability._magnet,
          episode: capability.episode,
          preferredFileIndex: capability.preferredFileIndex,
        );
      } finally {
        startPending = false;
      }
      if (cancellation.isCancelled) {
        await stopSession();
        throw const DownloadTransferCancelled();
      }

      final activeSession = session;
      _validateSession(activeSession, nativeCapability);
      if (!await partialFile.parent.exists()) {
        await partialFile.parent.create(recursive: true);
      }

      var offset = await partialFile.exists() ? await partialFile.length() : 0;
      if (offset > activeSession.size) {
        await partialFile.delete();
        offset = 0;
      }
      if (offset == activeSession.size) {
        onProgress(
          DownloadTransferProgress(
            receivedBytes: offset,
            totalBytes: activeSession.size,
            speedBytesPerSecond: 0,
          ),
        );
        return DownloadTransferResult(
          receivedBytes: offset,
          totalBytes: activeSession.size,
          mimeType: _safeMimeType(activeSession.mimeType),
        );
      }

      client = _httpClientFactory();
      _hardenLoopbackClient(client);
      final result = await _downloadLoopback(
        client: client,
        session: activeSession,
        partialFile: partialFile,
        initialOffset: offset,
        cancellation: cancellation,
        onProgress: onProgress,
      );
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      return result;
    } on DownloadTransferCancelled {
      rethrow;
    } on DownloadTransferException {
      rethrow;
    } on PlatformException catch (error) {
      if (cancellation.isCancelled ||
          error.code.toUpperCase().contains('CANCEL')) {
        throw const DownloadTransferCancelled();
      }
      throw DownloadTransferException(
        'direct_peer_start_failed',
        'The direct torrent download could not be prepared.',
        retryable: !error.code.toUpperCase().contains('UNSUPPORTED'),
      );
    } on FileSystemException {
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      throw const DownloadTransferException(
        'storage_io',
        'The direct torrent download could not be written to storage.',
        retryable: false,
      );
    } on SocketException {
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      throw const DownloadTransferException(
        'direct_peer_connection',
        'The local direct torrent connection ended unexpectedly.',
      );
    } on HttpException {
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      throw const DownloadTransferException(
        'direct_peer_connection',
        'The local direct torrent connection returned an invalid response.',
      );
    } catch (_) {
      if (cancellation.isCancelled) throw const DownloadTransferCancelled();
      throw const DownloadTransferException(
        'direct_peer_transfer_failed',
        'The direct torrent download could not be completed.',
      );
    } finally {
      client?.close(force: true);
      await stopSession();
    }
  }

  Future<DownloadTransferResult> _downloadLoopback({
    required HttpClient client,
    required DirectTorrentNativeSession session,
    required File partialFile,
    required int initialOffset,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
  }) async {
    var offset = initialOffset;
    var response = await _openLoopback(client, session.uri, offset: offset);

    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      final remoteTotal = _unsatisfiedRangeTotal(response);
      await _cancelResponse(response);
      if (remoteTotal == session.size && offset == session.size) {
        return DownloadTransferResult(
          receivedBytes: offset,
          totalBytes: session.size,
          mimeType: _safeMimeType(session.mimeType),
        );
      }
      if (await partialFile.exists()) await partialFile.delete();
      offset = 0;
      response = await _openLoopback(client, session.uri, offset: 0);
    }

    // A malformed server must not cause a complete response to be appended to
    // an existing partial file. Restart safely from byte zero instead.
    if (offset > 0 && response.statusCode == HttpStatus.ok) {
      await _cancelResponse(response);
      if (await partialFile.exists()) await partialFile.delete();
      offset = 0;
      response = await _openLoopback(client, session.uri, offset: 0);
    }

    final status = response.statusCode;
    if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
      await _cancelResponse(response);
      throw DownloadTransferException(
        'direct_peer_http_$status',
        'The local direct torrent connection returned HTTP $status.',
      );
    }

    final range = _contentRange(response);
    if (status == HttpStatus.partialContent &&
        (range == null ||
            range.start != offset ||
            range.end != session.size - 1 ||
            range.total != session.size)) {
      await _cancelResponse(response);
      throw const DownloadTransferException(
        'invalid_direct_peer_range',
        'The local direct torrent connection returned an invalid byte range.',
        retryable: false,
      );
    }
    final responseLength = response.contentLength;
    if (responseLength < 0 || offset + responseLength != session.size) {
      await _cancelResponse(response);
      throw const DownloadTransferException(
        'invalid_direct_peer_length',
        'The local direct torrent connection returned an invalid length.',
        retryable: false,
      );
    }

    final sink = partialFile.openWrite(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    var received = offset;
    var reportedAt = DateTime.now();
    var reportedBytes = received;
    try {
      await for (final bytes in response) {
        if (cancellation.isCancelled) throw const DownloadTransferCancelled();
        sink.add(bytes);
        received += bytes.length;
        if (received > session.size) {
          throw const DownloadTransferException(
            'direct_peer_body_too_large',
            'The local direct torrent connection exceeded its declared size.',
            retryable: false,
          );
        }
        final now = DateTime.now();
        final elapsed = now.difference(reportedAt);
        if (elapsed >= const Duration(milliseconds: 250)) {
          final speed = elapsed.inMicroseconds <= 0
              ? 0
              : ((received - reportedBytes) *
                        Duration.microsecondsPerSecond /
                        elapsed.inMicroseconds)
                    .round()
                    .clamp(0, 0x7fffffff);
          onProgress(
            DownloadTransferProgress(
              receivedBytes: received,
              totalBytes: session.size,
              speedBytesPerSecond: speed,
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
    if (received != session.size) {
      throw DownloadTransferException(
        'incomplete_direct_peer_body',
        'The local direct torrent connection ended after $received of '
            '${session.size} bytes.',
      );
    }
    onProgress(
      DownloadTransferProgress(
        receivedBytes: received,
        totalBytes: session.size,
        speedBytesPerSecond: 0,
      ),
    );
    return DownloadTransferResult(
      receivedBytes: received,
      totalBytes: session.size,
      mimeType: _safeMimeType(session.mimeType),
    );
  }

  static Future<HttpClientResponse> _openLoopback(
    HttpClient client,
    Uri uri, {
    required int offset,
  }) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.maxRedirects = 0;
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    return request.close();
  }

  static void _validateSession(
    DirectTorrentNativeSession session,
    DirectTorrentCapability capability,
  ) {
    final uri = session.uri;
    final validPath = RegExp(r'^/[0-9a-f]{64}$').hasMatch(uri.path);
    final validSessionId = RegExp(
      r'^[A-Za-z0-9._:-]{1,128}$',
    ).hasMatch(session.sessionId);
    if (!validSessionId ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.port <= 0 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !validPath ||
        session.size <= 0 ||
        (capability.maximumFileBytes > 0 &&
            session.size > capability.maximumFileBytes)) {
      throw const DownloadTransferException(
        'invalid_direct_peer_session',
        'Android returned an invalid direct torrent download session.',
        retryable: false,
      );
    }
  }

  static String _safeMimeType(String value) {
    final normalized = value.trim().toLowerCase();
    return RegExp(
          r'^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}$',
        ).hasMatch(normalized)
        ? normalized
        : 'application/octet-stream';
  }

  static String _newRequestId() {
    _requestSequence = (_requestSequence + 1) & 0x7fffffff;
    return 'offline-${DateTime.now().microsecondsSinceEpoch}-$_requestSequence';
  }
}

HttpClient _newLoopbackClient() => HttpClient();

void _hardenLoopbackClient(HttpClient client) {
  client
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 90)
    ..findProxy = (_) => 'DIRECT';
}

Future<void> _ignoreCleanupFailure(Future<bool> Function() cleanup) async {
  try {
    await cleanup();
  } catch (_) {
    // Cleanup errors are intentionally not logged because native failures can
    // contain private peer endpoints or temporary paths.
  }
}

Future<void> _cancelResponse(HttpClientResponse response) async {
  final subscription = response.listen((_) {});
  await subscription.cancel();
}

({int start, int end, int total})? _contentRange(HttpClientResponse response) {
  final value = response.headers.value(HttpHeaders.contentRangeHeader);
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  return (
    start: int.parse(match.group(1)!),
    end: int.parse(match.group(2)!),
    total: int.parse(match.group(3)!),
  );
}

int? _unsatisfiedRangeTotal(HttpClientResponse response) {
  final value = response.headers.value(HttpHeaders.contentRangeHeader);
  final match = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value?.trim() ?? '');
  return match == null ? null : int.parse(match.group(1)!);
}

bool _isValidMagnet(String value) {
  if (value.length < 20 || value.length > 8192 || value.trim() != value) {
    return false;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'magnet' ||
      uri.hasAuthority ||
      uri.path.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  final topics = uri.queryParametersAll.entries
      .where((entry) => entry.key.toLowerCase() == 'xt')
      .expand((entry) => entry.value)
      .map((value) => value.toLowerCase());
  for (final topic in topics) {
    if (RegExp(r'^urn:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})$').hasMatch(topic) ||
        RegExp(r'^urn:btmh:[0-9a-f]{20,160}$').hasMatch(topic)) {
      return true;
    }
  }
  return false;
}
