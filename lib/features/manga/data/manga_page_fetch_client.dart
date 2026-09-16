import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const int maximumMangaRemotePageBytes = 20 * 1024 * 1024;

typedef MangaPageTargetValidator = Future<void> Function(Uri uri);

final mangaPageFetchClientProvider = Provider<MangaPageFetchClient>((ref) {
  final client = MangaPageFetchClient(
    transcodeUnsupportedArtwork: AndroidTvBridge.instance.transcodeMangaArtwork,
    reportFailure: (failure) => TetoTvDatabase.instance.recordDiagnosticEvent(
      category: 'manga-reader',
      severity: 'warning',
      message: 'Manga page fetch failed',
      details: failure.diagnosticDetails,
    ),
  );
  ref.onDispose(client.close);
  return client;
});

typedef MangaPageFailureReporter =
    FutureOr<void> Function(MangaPageFetchException failure);

typedef MangaUnsupportedArtworkTranscoder =
    Future<Uint8List?> Function(Uint8List encoded);

/// A bounded header-magic hint, not a claim that an image can be decoded.
/// Labels are fixed signatures, never copied from provider headers or body text.
enum MangaPageResponseFormat {
  unknown,
  empty,
  jpeg,
  png,
  webp,
  gif,
  avif,
  heif,
  html,
}

class MangaPageFetchException implements Exception {
  const MangaPageFetchException(
    this.message, {
    this.reasonCode = 'unknown',
    this.statusCode,
    this.redirectCount = 0,
    this.crossOriginRedirect = false,
    this.responseFormat = MangaPageResponseFormat.unknown,
    this.encodedByteCount = 0,
  });

  final String message;
  final String reasonCode;
  final int? statusCode;
  final int redirectCount;
  final bool crossOriginRedirect;
  final MangaPageResponseFormat responseFormat;

  /// Bytes actually received for the current response, never Content-Length.
  final int encodedByteCount;

  /// Only fixed enum names, numbers and booleans enter this technical summary.
  /// `message` survives both persisted-context and explicit-export redaction;
  /// arbitrary redirect/context keys intentionally remain disallowed there.
  Map<String, Object?> get diagnosticDetails => <String, Object?>{
    'reason_code': reasonCode,
    'status': ?statusCode,
    'message':
        'format=${responseFormat.name} '
        'encoded_byte_count=$encodedByteCount '
        'redirect_hops=$redirectCount changed_site=$crossOriginRedirect',
  };

  MangaPageFetchException withRedirectContext({
    required int redirectCount,
    required bool crossOriginRedirect,
    int? statusCode,
    MangaPageResponseFormat? responseFormat,
    int? encodedByteCount,
  }) {
    if (this.redirectCount == redirectCount &&
        this.crossOriginRedirect == crossOriginRedirect &&
        (statusCode == null || this.statusCode == statusCode) &&
        (responseFormat == null || this.responseFormat == responseFormat) &&
        (encodedByteCount == null ||
            this.encodedByteCount == encodedByteCount)) {
      return this;
    }
    return MangaPageFetchException(
      message,
      reasonCode: reasonCode,
      statusCode: statusCode ?? this.statusCode,
      redirectCount: redirectCount,
      crossOriginRedirect: crossOriginRedirect,
      responseFormat: responseFormat ?? this.responseFormat,
      encodedByteCount: encodedByteCount ?? this.encodedByteCount,
    );
  }

  @override
  String toString() => message;
}

/// Fetches reader images through TetoTV's pinned-public-HTTPS boundary.
///
/// Flutter's stock [NetworkImage] follows redirects internally. That is useful
/// for ordinary public artwork, but it cannot enforce the manga reader's
/// source capability boundary at every redirect. This client does: every hop
/// is DNS-validated and IP-pinned, credentials are stripped on an origin
/// change, responses are streamed under a hard byte limit, and image magic is
/// checked before bytes reach a decoder.
class MangaPageFetchClient {
  MangaPageFetchClient({
    Dio? dio,
    MangaPageTargetValidator? validateTarget,
    this.connectTimeout = const Duration(seconds: 8),
    this.receiveTimeout = const Duration(seconds: 15),
    this.requestDeadline = const Duration(seconds: 45),
    this.maximumPageBytes = maximumMangaRemotePageBytes,
    this.maximumRedirects = 5,
    this.maximumCachedBytes = 48 * 1024 * 1024,
    this.maximumConcurrentRequests = 8,
    this.maximumCacheEntries = 64,
    this.transcodeUnsupportedArtwork,
    this.reportFailure,
  }) : _validateTarget = validateTarget ?? validatePublicNetworkTarget,
       _dio =
           dio ??
           createPinnedPublicHttpsDio(
             BaseOptions(
               connectTimeout: connectTimeout,
               receiveTimeout: receiveTimeout,
               sendTimeout: connectTimeout,
               followRedirects: false,
               maxRedirects: 0,
               validateStatus: (_) => true,
               responseType: ResponseType.stream,
             ),
           ) {
    if (maximumPageBytes <= 0 ||
        maximumPageBytes > maximumMangaRemotePageBytes ||
        maximumRedirects < 0 ||
        maximumRedirects > 8 ||
        maximumCachedBytes < maximumPageBytes ||
        maximumConcurrentRequests <= 0 ||
        maximumConcurrentRequests > 16 ||
        maximumCacheEntries < maximumConcurrentRequests ||
        maximumCacheEntries > 512 ||
        requestDeadline <= Duration.zero) {
      throw ArgumentError('Invalid manga page fetch limits.');
    }
  }

  final Dio _dio;
  final MangaPageTargetValidator _validateTarget;
  final MangaPageFailureReporter? reportFailure;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration requestDeadline;
  final int maximumPageBytes;
  final int maximumRedirects;
  final int maximumCachedBytes;
  final int maximumConcurrentRequests;
  final int maximumCacheEntries;
  final MangaUnsupportedArtworkTranscoder? transcodeUnsupportedArtwork;
  final LinkedHashMap<Object, _MangaPageCacheEntry> _cache = LinkedHashMap();
  final Queue<_MangaPagePermitWaiter> _permitWaiters =
      Queue<_MangaPagePermitWaiter>();
  final Set<CancelToken> _activeTokens = <CancelToken>{};
  final Set<CancelToken> _runningPrefetchTokens = <CancelToken>{};
  int _cachedBytes = 0;
  int _activeRequestCount = 0;
  bool _closed = false;

  /// Visible consumers claim the shared request and promote queued lookahead.
  Future<Uint8List> fetch(MangaFetchablePageResource resource) =>
      _fetch(resource);

  /// Speculation is owned by an opaque process-local reader, never a URL or ID.
  Future<Uint8List> prefetch(
    MangaFetchablePageResource resource, {
    required Object owner,
  }) => _fetch(resource, prefetchOwner: owner);

  void cancelPrefetches(
    Object owner, {
    Iterable<MangaFetchablePageResource> keep = const [],
  }) {
    final retained = keep.map(_cacheKey).toSet();
    for (final cached in _cache.entries.toList(growable: false)) {
      final entry = cached.value;
      if (entry.visible || retained.contains(cached.key)) continue;
      entry.prefetchOwners.remove(owner);
      if (!entry.isComplete && entry.prefetchOwners.isEmpty) {
        _cache.remove(cached.key);
        entry.token.cancel('Reader lookahead is no longer needed.');
      }
    }
  }

  Future<Uint8List> _fetch(
    MangaFetchablePageResource resource, {
    Object? prefetchOwner,
  }) {
    final visible = prefetchOwner == null;
    if (_closed) {
      return Future<Uint8List>.error(
        const MangaPageFetchException(
          'The manga page loader is closed.',
          reasonCode: 'loader_closed',
        ),
      );
    }
    final key = _cacheKey(resource);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      if (visible && !cached.visible) {
        _promoteVisible(cached);
      } else if (!visible && !cached.visible) {
        // A pathological number of independent consumers must not grow an
        // unbounded owner set. Treat heavily shared work as non-cancellable.
        if (cached.prefetchOwners.length >= 16) {
          _promoteVisible(cached);
        } else {
          cached.prefetchOwners.add(prefetchOwner);
        }
      }
      return cached.future;
    }

    if (!_makeRoomForEntry(visible: visible)) {
      return Future<Uint8List>.error(
        const MangaPageFetchException(
          'Too many manga pages are already loading. Try again shortly.',
          reasonCode: 'queue_saturated',
        ),
      );
    }

    final token = CancelToken();
    _activeTokens.add(token);
    final future = _fetchWithDiagnostics(
      resource,
      token,
      isPrefetch: !visible,
    ).whenComplete(() => _activeTokens.remove(token));
    final entry = _MangaPageCacheEntry(future, token, visible: visible);
    if (prefetchOwner != null) entry.prefetchOwners.add(prefetchOwner);
    _cache[key] = entry;
    unawaited(
      future.then(
        (bytes) {
          if (_closed || !identical(_cache[key], entry)) return;
          entry.isComplete = true;
          entry.byteLength = bytes.length;
          _cachedBytes += bytes.length;
          _trimCache(protectedKey: key);
        },
        onError: (Object _, StackTrace _) {
          if (identical(_cache[key], entry)) _cache.remove(key);
        },
      ),
    );
    return future;
  }

  void _promoteVisible(_MangaPageCacheEntry cached) {
    cached.visible = true;
    cached.prefetchOwners.clear();
    _runningPrefetchTokens.remove(cached.token);
    for (final waiter in _permitWaiters) {
      if (identical(waiter.token, cached.token)) waiter.isPrefetch = false;
    }
    _startWaitingRequests();
  }

  Future<Uint8List> _fetchWithDiagnostics(
    MangaFetchablePageResource resource,
    CancelToken token, {
    required bool isPrefetch,
  }) async {
    final context = _MangaPageFetchContext();
    try {
      return await _fetchWithPermit(
        resource,
        token,
        context,
        isPrefetch: isPrefetch,
      ).timeout(
        requestDeadline,
        onTimeout: () {
          token.cancel('Manga page exceeded its total request deadline.');
          throw const MangaPageFetchException(
            'The manga page took too long to load.',
            reasonCode: 'request_timeout',
          );
        },
      );
    } catch (error, stackTrace) {
      final failure = _normalizeFailure(error).withRedirectContext(
        redirectCount: context.redirectCount,
        crossOriginRedirect: context.crossOriginRedirect,
        statusCode: context.statusCode,
        responseFormat: context.responseFormat,
        encodedByteCount: context.encodedByteCount,
      );
      _recordFailure(failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  MangaPageFetchException _normalizeFailure(Object error) {
    if (error is MangaPageFetchException) return error;
    if (error is DioException) {
      if (_closed) {
        return const MangaPageFetchException(
          'The manga page loader is closed.',
          reasonCode: 'loader_closed',
        );
      }
      if (error.type == DioExceptionType.cancel) {
        return const MangaPageFetchException(
          'The manga page loader was interrupted.',
          reasonCode: 'request_cancelled',
        );
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return const MangaPageFetchException(
          'The manga page took too long to load.',
          reasonCode: 'transport_timeout',
        );
      }
      return const MangaPageFetchException(
        'The manga page host could not be reached. Check the connection and try again.',
        reasonCode: 'transport_failure',
      );
    }
    return const MangaPageFetchException(
      'The manga page could not be loaded.',
      reasonCode: 'unexpected_failure',
    );
  }

  void _recordFailure(MangaPageFetchException failure) {
    final reporter = reportFailure;
    if (reporter == null ||
        failure.reasonCode == 'loader_closed' ||
        failure.reasonCode == 'request_cancelled') {
      return;
    }
    unawaited(
      Future<void>.sync(() async => reporter(failure)).catchError((_) {}),
    );
  }

  Future<Uint8List> _fetchWithPermit(
    MangaFetchablePageResource resource,
    CancelToken lifetimeToken,
    _MangaPageFetchContext context, {
    required bool isPrefetch,
  }) async {
    var acquired = false;
    try {
      await _acquirePermit(lifetimeToken, isPrefetch: isPrefetch);
      acquired = true;
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      return await _fetchValidated(resource, lifetimeToken, context);
    } finally {
      if (acquired) _releasePermit(lifetimeToken);
    }
  }

  int get _maximumConcurrentPrefetches =>
      maximumConcurrentRequests > 1 ? maximumConcurrentRequests - 1 : 1;

  Future<void> _acquirePermit(CancelToken token, {required bool isPrefetch}) {
    if (_closed) {
      return Future<void>.error(
        const MangaPageFetchException(
          'The manga page loader is closed.',
          reasonCode: 'loader_closed',
        ),
      );
    }
    if (token.isCancelled) return Future<void>.error(token.cancelError!);
    if (_activeRequestCount < maximumConcurrentRequests &&
        (!isPrefetch ||
            _runningPrefetchTokens.length < _maximumConcurrentPrefetches)) {
      _activeRequestCount++;
      if (isPrefetch) _runningPrefetchTokens.add(token);
      return Future<void>.value();
    }

    final waiter = _MangaPagePermitWaiter(token, isPrefetch: isPrefetch);
    _permitWaiters.addLast(waiter);
    unawaited(
      token.whenCancel.then((error) {
        if (_permitWaiters.remove(waiter) && !waiter.completer.isCompleted) {
          waiter.completer.completeError(error);
        }
      }),
    );
    return waiter.completer.future;
  }

  void _releasePermit(CancelToken token) {
    _runningPrefetchTokens.remove(token);
    if (_activeRequestCount > 0) _activeRequestCount--;
    _startWaitingRequests();
  }

  void _startWaitingRequests() {
    while (!_closed &&
        _activeRequestCount < maximumConcurrentRequests &&
        _permitWaiters.isNotEmpty) {
      _MangaPagePermitWaiter? selected;
      for (final candidate in _permitWaiters) {
        if (!candidate.isPrefetch) {
          selected = candidate;
          break;
        }
      }
      final waiter = selected ?? _permitWaiters.first;
      if (waiter.isPrefetch &&
          !waiter.token.isCancelled &&
          _runningPrefetchTokens.length >= _maximumConcurrentPrefetches) {
        break;
      }
      _permitWaiters.remove(waiter);
      if (waiter.completer.isCompleted) continue;
      if (waiter.token.isCancelled) {
        waiter.completer.completeError(waiter.token.cancelError!);
        continue;
      }
      _activeRequestCount++;
      if (waiter.isPrefetch) _runningPrefetchTokens.add(waiter.token);
      waiter.completer.complete();
    }
  }

  bool _makeRoomForEntry({required bool visible}) {
    while (_cache.length >= maximumCacheEntries) {
      Object? completedKey;
      for (final candidate in _cache.entries) {
        if (candidate.value.isComplete) {
          completedKey = candidate.key;
          break;
        }
      }
      if (completedKey == null && visible) {
        for (final candidate in _cache.entries) {
          if (!candidate.value.visible) {
            completedKey = candidate.key;
            candidate.value.token.cancel(
              'Visible page needs this lookahead slot.',
            );
            break;
          }
        }
      }
      if (completedKey == null) return false;
      final removed = _cache.remove(completedKey)!;
      _cachedBytes -= removed.byteLength;
    }
    return true;
  }

  Future<Uint8List> _fetchValidated(
    MangaFetchablePageResource resource,
    CancelToken lifetimeToken,
    _MangaPageFetchContext context,
  ) async {
    if (resource is MangaOpaquePageResource) {
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      final bytes = await resource.loadImage();
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      context.encodedByteCount = bytes.length;
      context.responseFormat = _classifyPageResponse(bytes);
      if (bytes.isEmpty) {
        throw const MangaPageFetchException(
          'The manga page was empty.',
          reasonCode: 'empty_response',
        );
      }
      if (bytes.length > maximumPageBytes) {
        throw const MangaPageFetchException(
          'This manga page is larger than the safe limit.',
          reasonCode: 'size_limit',
        );
      }
      try {
        inspectMangaImage(bytes);
      } on MangaImageValidationException catch (error) {
        final format = context.responseFormat;
        if (error.failure == MangaImageValidationFailure.unsupported &&
            resource.allowPlatformArtworkTranscode &&
            (format == MangaPageResponseFormat.avif ||
                format == MangaPageResponseFormat.heif)) {
          final recovered = await _transcodeArtwork(bytes);
          if (recovered != null) return recovered;
        }
        throw MangaPageFetchException(
          error.message,
          reasonCode: switch (error.failure) {
            MangaImageValidationFailure.unsupported => 'unsupported_image',
            MangaImageValidationFailure.malformed => 'malformed_image',
            MangaImageValidationFailure.dimensionsExceeded =>
              'image_dimensions_exceeded',
          },
        );
      }
      return bytes;
    }
    if (resource is! MangaRemotePageResource) {
      throw const MangaPageFetchException(
        'The manga page could not be loaded.',
        reasonCode: 'unsupported_resource',
      );
    }
    final originalOrigin = _origin(resource.uri);
    var target = requireMangaPublicHttpsUri(
      resource.uri.toString(),
      field: 'Manga page URL',
    );
    for (var redirect = 0; redirect <= maximumRedirects; redirect++) {
      context.beginResponse();
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      await _validateTarget(target);
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      final headers = _pageRequestHeaders(
        resource.headers,
        sameOrigin: _origin(target) == originalOrigin,
      );
      final requestToken = CancelToken();
      unawaited(
        lifetimeToken.whenCancel.then((error) {
          if (!requestToken.isCancelled) requestToken.cancel(error);
        }),
      );
      final response = await _dio.get<ResponseBody>(
        target.toString(),
        options: Options(
          headers: headers,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
          responseType: ResponseType.stream,
        ),
        cancelToken: requestToken,
      );
      final status = response.statusCode ?? 0;
      context.statusCode = response.statusCode;
      if (_redirectStatuses.contains(status)) {
        await _discardResponse(response.data, requestToken);
        if (redirect == maximumRedirects) {
          throw const MangaPageFetchException(
            'The manga page redirected too many times.',
            reasonCode: 'redirect_limit',
          );
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.trim().isEmpty) {
          throw const MangaPageFetchException(
            'The manga page returned an invalid redirect.',
            reasonCode: 'invalid_redirect',
          );
        }
        final redirected = resolveMangaPublicHttpsReference(
          target,
          location,
          field: 'Manga page redirect',
        );
        context.recordRedirect(from: target, to: redirected);
        target = redirected;
        continue;
      }
      if (status != HttpStatus.ok) {
        await _discardResponse(response.data, requestToken);
        throw _httpPageFailure(status);
      }
      final declared = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (declared != null && (declared <= 0 || declared > maximumPageBytes)) {
        await _discardResponse(response.data, requestToken);
        throw const MangaPageFetchException(
          'This manga page is larger than the safe limit.',
          reasonCode: 'size_limit',
        );
      }
      final body = response.data;
      if (body == null) {
        await _discardResponse(null, requestToken);
        throw const MangaPageFetchException(
          'The manga page was empty.',
          reasonCode: 'empty_response',
        );
      }
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in body.stream) {
        received += chunk.length;
        context.encodedByteCount = received;
        if (received > maximumPageBytes) {
          requestToken.cancel('Manga page exceeded its byte limit.');
          throw const MangaPageFetchException(
            'This manga page is larger than the safe limit.',
            reasonCode: 'size_limit',
          );
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      context.responseFormat = _classifyPageResponse(bytes);
      if (bytes.isEmpty) {
        throw const MangaPageFetchException(
          'The manga page was empty.',
          reasonCode: 'empty_response',
        );
      }
      try {
        inspectMangaImage(bytes);
      } on MangaImageValidationException catch (error) {
        final format = context.responseFormat;
        if (error.failure == MangaImageValidationFailure.unsupported &&
            resource.allowPlatformArtworkTranscode &&
            (format == MangaPageResponseFormat.avif ||
                format == MangaPageResponseFormat.heif)) {
          final recovered = await _transcodeArtwork(bytes);
          if (recovered != null) return recovered;
        }
        throw MangaPageFetchException(
          error.message,
          reasonCode: switch (error.failure) {
            MangaImageValidationFailure.unsupported => 'unsupported_image',
            MangaImageValidationFailure.malformed => 'malformed_image',
            MangaImageValidationFailure.dimensionsExceeded =>
              'image_dimensions_exceeded',
          },
        );
      }
      return bytes;
    }
    throw const MangaPageFetchException(
      'The manga page could not be loaded.',
      reasonCode: 'redirect_failure',
    );
  }

  Future<Uint8List?> _transcodeArtwork(Uint8List encoded) async {
    final transcoder = transcodeUnsupportedArtwork;
    if (transcoder == null) return null;
    try {
      final recovered = await transcoder(encoded);
      if (recovered == null ||
          recovered.isEmpty ||
          recovered.length > maximumPageBytes) {
        return null;
      }
      inspectMangaImage(recovered);
      return recovered;
    } catch (_) {
      // A device without this codec follows the ordinary unsupported-image
      // path. Native decoder details are never surfaced or persisted.
      return null;
    }
  }

  void _trimCache({required Object protectedKey}) {
    while (_cachedBytes > maximumCachedBytes && _cache.length > 1) {
      Object? oldestCompletedKey;
      for (final candidate in _cache.entries) {
        if (candidate.key != protectedKey && candidate.value.isComplete) {
          oldestCompletedKey = candidate.key;
          break;
        }
      }
      if (oldestCompletedKey == null) break;
      final removed = _cache.remove(oldestCompletedKey)!;
      _cachedBytes -= removed.byteLength;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Complete permit waiters explicitly before cancelling their lifetime
    // tokens. Otherwise the cancellation callback can race this loop and turn
    // a deliberate loader shutdown into a misleading request_cancelled error.
    while (_permitWaiters.isNotEmpty) {
      final waiter = _permitWaiters.removeFirst();
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(
          const MangaPageFetchException(
            'The manga page loader is closed.',
            reasonCode: 'loader_closed',
          ),
        );
      }
    }
    for (final token in _activeTokens.toList(growable: false)) {
      token.cancel('Manga page loader closed.');
    }
    _activeTokens.clear();
    _runningPrefetchTokens.clear();
    _cache.clear();
    _cachedBytes = 0;
    _dio.close(force: true);
  }
}

/// Cancels an unread streamed response without draining attacker-controlled
/// bytes. Dio's response wrapper does not forward output-stream cancellation
/// to its adapter subscription, so the per-request token is cancelled first;
/// the wrapper subscription is then cancelled without consuming any chunks.
Future<void> _discardResponse(
  ResponseBody? body,
  CancelToken requestToken,
) async {
  if (!requestToken.isCancelled) {
    requestToken.cancel('Manga response is no longer needed.');
  }
  if (body != null) {
    final subscription = body.stream.listen(
      (_) {},
      onError: (_) {},
      cancelOnError: true,
    );
    await subscription.cancel();
  }
  // Dio's stream wrapper cancels the adapter subscription from the token's
  // completion callback. Yield once so that cleanup runs before another hop.
  await Future<void>.delayed(Duration.zero);
}

class _MangaPageCacheEntry {
  _MangaPageCacheEntry(this.future, this.token, {required this.visible});

  final Future<Uint8List> future;
  final CancelToken token;
  bool visible;
  final Set<Object> prefetchOwners = {};
  bool isComplete = false;
  int byteLength = 0;
}

class _MangaPagePermitWaiter {
  _MangaPagePermitWaiter(this.token, {required this.isPrefetch});

  final CancelToken token;
  bool isPrefetch;
  final Completer<void> completer = Completer<void>();
}

class _MangaPageFetchContext {
  int redirectCount = 0;
  bool crossOriginRedirect = false;
  int? statusCode;
  int encodedByteCount = 0;
  MangaPageResponseFormat responseFormat = MangaPageResponseFormat.unknown;

  void beginResponse() {
    // A failed next hop must not inherit the previous redirect's HTTP status.
    statusCode = null;
    encodedByteCount = 0;
    responseFormat = MangaPageResponseFormat.unknown;
  }

  void recordRedirect({required Uri from, required Uri to}) {
    redirectCount++;
    if (_origin(from) != _origin(to)) crossOriginRedirect = true;
  }
}

Object _cacheKey(MangaFetchablePageResource resource) {
  if (resource is MangaOpaquePageResource) return resource.cacheIdentity;
  if (resource is! MangaRemotePageResource) return resource;
  final values = <int>[
    ...resource.uri.toString().codeUnits,
    resource.allowPlatformArtworkTranscode ? 1 : 0,
  ];
  final keys = resource.headers.keys.toList()..sort();
  for (final key in keys) {
    values
      ..add(0)
      ..addAll(key.toLowerCase().codeUnits)
      ..add(0)
      ..addAll(resource.headers[key]!.codeUnits);
  }
  return sha256.convert(values).toString();
}

String _origin(Uri uri) =>
    '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}';

MangaPageResponseFormat _classifyPageResponse(List<int> bytes) {
  if (bytes.isEmpty) return MangaPageResponseFormat.empty;
  final supported = detectMangaImageType(bytes);
  if (supported != null) {
    return switch (supported) {
      MangaArchiveImageType.jpeg => MangaPageResponseFormat.jpeg,
      MangaArchiveImageType.png => MangaPageResponseFormat.png,
      MangaArchiveImageType.webp => MangaPageResponseFormat.webp,
      MangaArchiveImageType.gif => MangaPageResponseFormat.gif,
    };
  }
  // Inspect only a complete, bounded leading ISO-BMFF ftyp box. Its major or
  // compatible brand is evidence of an unsupported format, not permission to
  // decode it. No untrusted FourCC/string is copied into diagnostics.
  if (bytes.length >= 16 && _matchesPageAscii(bytes, 4, 'ftyp')) {
    final boxSize =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    if (boxSize >= 16 &&
        boxSize <= 256 &&
        boxSize <= bytes.length &&
        boxSize % 4 == 0) {
      var heif = false;
      for (var offset = 8; offset < boxSize; offset += 4) {
        if (offset == 12) continue; // minor_version is not a brand.
        if (_matchesPageAscii(bytes, offset, 'avif') ||
            _matchesPageAscii(bytes, offset, 'avis')) {
          return MangaPageResponseFormat.avif;
        }
        for (final brand in const [
          'heic',
          'heix',
          'hevc',
          'hevx',
          'mif1',
          'msf1',
        ]) {
          if (_matchesPageAscii(bytes, offset, brand)) heif = true;
        }
      }
      if (heif) return MangaPageResponseFormat.heif;
    }
  }
  var start =
      bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf
      ? 3
      : 0;
  while (start < bytes.length &&
      start < 64 &&
      const [9, 10, 12, 13, 32].contains(bytes[start])) {
    start++;
  }
  for (final prefix in const ['<!doctype html', '<html', '<head', '<body']) {
    if (!_matchesPageAscii(bytes, start, prefix, ignoreCase: true)) continue;
    final end = start + prefix.length;
    if (end < bytes.length &&
        const [9, 10, 12, 13, 32, 62].contains(bytes[end])) {
      return MangaPageResponseFormat.html;
    }
  }
  return MangaPageResponseFormat.unknown;
}

bool _matchesPageAscii(
  List<int> bytes,
  int start,
  String expected, {
  bool ignoreCase = false,
}) {
  if (start + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    var byte = bytes[start + i];
    if (ignoreCase && byte >= 65 && byte <= 90) byte += 32;
    if (byte != expected.codeUnitAt(i)) return false;
  }
  return true;
}

const _supportedPageImageAccept =
    'image/jpeg,image/png,image/webp,image/gif;q=0.9';

String _supportedPageAccept(String value) {
  final advertisesUnsupported = value.split(',').any((entry) {
    final mime = entry.split(';').first.trim().toLowerCase();
    return const {
      'image/avif',
      'image/heif',
      'image/heic',
      'image/avif-sequence',
      'image/heif-sequence',
      'image/heic-sequence',
    }.contains(mime);
  });
  return advertisesUnsupported ? _supportedPageImageAccept : value;
}

/// Cross-origin image redirects are common for manga CDNs. Preserve only the
/// ordinary media-request metadata needed by hotlink-protected hosts while
/// continuing to strip credentials and arbitrary provider headers.
Map<String, String> _pageRequestHeaders(
  Map<String, String> headers, {
  required bool sameOrigin,
}) {
  final safe = <String, String>{};
  for (final header in headers.entries) {
    final name = header.key.toLowerCase();
    if (sameOrigin) {
      final value = switch (name) {
        'accept' => _supportedPageAccept(header.value),
        'origin' => canonicalMangaPageOriginHeader(header.value),
        'referer' => canonicalMangaPageRefererHeader(header.value),
        _ => header.value,
      };
      if (value != null) safe[header.key] = value;
      continue;
    }
    if (_crossOriginSafePageHeaders.contains(name)) {
      final value = _safeCrossOriginHeaderValue(name, header.value);
      if (value != null) safe[header.key] = value;
    }
  }
  final present = safe.keys.map((key) => key.toLowerCase()).toSet();
  if (!present.contains('accept')) {
    safe['Accept'] = _supportedPageImageAccept;
  }
  if (!present.contains('user-agent')) {
    safe['User-Agent'] = 'TetoTV/2 Android manga';
  }
  return Map<String, String>.unmodifiable(safe);
}

String? _safeCrossOriginHeaderValue(String name, String value) {
  return switch (name) {
    'accept' => _supportedPageAccept(value),
    'origin' => canonicalMangaPageOriginHeader(value),
    'referer' => canonicalMangaPageRefererHeader(value, originOnly: true),
    _ => value,
  };
}

MangaPageFetchException _httpPageFailure(int status) => switch (status) {
  HttpStatus.unauthorized => MangaPageFetchException(
    'The manga source rejected its access credential.',
    reasonCode: 'http_unauthorized',
    statusCode: status,
  ),
  HttpStatus.forbidden => MangaPageFetchException(
    'The manga source refused this page request.',
    reasonCode: 'http_forbidden',
    statusCode: status,
  ),
  HttpStatus.notFound => MangaPageFetchException(
    'This manga page is no longer available from the source.',
    reasonCode: 'http_not_found',
    statusCode: status,
  ),
  HttpStatus.tooManyRequests => MangaPageFetchException(
    'The manga source is temporarily limiting requests. Try again shortly.',
    reasonCode: 'http_rate_limited',
    statusCode: status,
  ),
  >= 500 && <= 599 => MangaPageFetchException(
    'The manga source is temporarily unavailable. Try again shortly.',
    reasonCode: 'http_server_failure',
    statusCode: status,
  ),
  _ => MangaPageFetchException(
    'This manga page could not be loaded.',
    reasonCode: 'http_failure',
    statusCode: status,
  ),
};

const Set<String> _crossOriginSafePageHeaders = <String>{
  'accept',
  'accept-language',
  'content-type',
  'origin',
  'range',
  'referer',
  'user-agent',
};

const Set<int> _redirectStatuses = <int>{301, 302, 303, 307, 308};
