import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

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
  final client = MangaPageFetchClient();
  ref.onDispose(client.close);
  return client;
});

class MangaPageFetchException implements Exception {
  const MangaPageFetchException(this.message);

  final String message;

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
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration requestDeadline;
  final int maximumPageBytes;
  final int maximumRedirects;
  final int maximumCachedBytes;
  final int maximumConcurrentRequests;
  final int maximumCacheEntries;
  final LinkedHashMap<String, _MangaPageCacheEntry> _cache = LinkedHashMap();
  final Queue<_MangaPagePermitWaiter> _permitWaiters =
      Queue<_MangaPagePermitWaiter>();
  final Set<CancelToken> _activeTokens = <CancelToken>{};
  int _cachedBytes = 0;
  int _activeRequestCount = 0;
  bool _closed = false;

  Future<Uint8List> fetch(MangaRemotePageResource resource) {
    if (_closed) {
      return Future<Uint8List>.error(
        const MangaPageFetchException('The manga page loader is closed.'),
      );
    }
    final key = _cacheKey(resource);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached.future;
    }

    if (!_makeRoomForEntry()) {
      return Future<Uint8List>.error(
        const MangaPageFetchException(
          'Too many manga pages are already loading. Try again shortly.',
        ),
      );
    }

    final token = CancelToken();
    _activeTokens.add(token);
    final future = _fetchWithPermit(resource, token)
        .timeout(
          requestDeadline,
          onTimeout: () {
            token.cancel('Manga page exceeded its total request deadline.');
            throw const MangaPageFetchException(
              'The manga page took too long to load.',
            );
          },
        )
        .whenComplete(() => _activeTokens.remove(token));
    final entry = _MangaPageCacheEntry(future);
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

  Future<Uint8List> _fetchWithPermit(
    MangaRemotePageResource resource,
    CancelToken lifetimeToken,
  ) async {
    var acquired = false;
    try {
      await _acquirePermit(lifetimeToken);
      acquired = true;
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      return await _fetchValidated(resource, lifetimeToken);
    } finally {
      if (acquired) _releasePermit();
    }
  }

  Future<void> _acquirePermit(CancelToken token) {
    if (_closed) {
      return Future<void>.error(
        const MangaPageFetchException('The manga page loader is closed.'),
      );
    }
    if (token.isCancelled) return Future<void>.error(token.cancelError!);
    if (_activeRequestCount < maximumConcurrentRequests) {
      _activeRequestCount++;
      return Future<void>.value();
    }

    final waiter = _MangaPagePermitWaiter(token);
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

  void _releasePermit() {
    if (_activeRequestCount > 0) _activeRequestCount--;
    _startWaitingRequests();
  }

  void _startWaitingRequests() {
    while (!_closed &&
        _activeRequestCount < maximumConcurrentRequests &&
        _permitWaiters.isNotEmpty) {
      final waiter = _permitWaiters.removeFirst();
      if (waiter.completer.isCompleted) continue;
      if (waiter.token.isCancelled) {
        waiter.completer.completeError(waiter.token.cancelError!);
        continue;
      }
      _activeRequestCount++;
      waiter.completer.complete();
    }
  }

  bool _makeRoomForEntry() {
    while (_cache.length >= maximumCacheEntries) {
      String? completedKey;
      for (final candidate in _cache.entries) {
        if (candidate.value.isComplete) {
          completedKey = candidate.key;
          break;
        }
      }
      if (completedKey == null) return false;
      final removed = _cache.remove(completedKey)!;
      _cachedBytes -= removed.byteLength;
    }
    return true;
  }

  Future<Uint8List> _fetchValidated(
    MangaRemotePageResource resource,
    CancelToken lifetimeToken,
  ) async {
    final originalOrigin = _origin(resource.uri);
    var target = requireMangaPublicHttpsUri(
      resource.uri.toString(),
      field: 'Manga page URL',
    );
    for (var redirect = 0; redirect <= maximumRedirects; redirect++) {
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      await _validateTarget(target);
      if (lifetimeToken.isCancelled) throw lifetimeToken.cancelError!;
      final headers = _origin(target) == originalOrigin
          ? resource.headers
          : const <String, String>{};
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
      if (_redirectStatuses.contains(status)) {
        await _discardResponse(response.data, requestToken);
        if (redirect == maximumRedirects) {
          throw const MangaPageFetchException(
            'The manga page redirected too many times.',
          );
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.trim().isEmpty) {
          throw const MangaPageFetchException(
            'The manga page returned an invalid redirect.',
          );
        }
        target = resolveMangaPublicHttpsReference(
          target,
          location,
          field: 'Manga page redirect',
        );
        continue;
      }
      if (status != HttpStatus.ok) {
        await _discardResponse(response.data, requestToken);
        throw MangaPageFetchException(
          status == HttpStatus.unauthorized || status == HttpStatus.forbidden
              ? 'This manga page rejected the source credential.'
              : 'This manga page could not be loaded.',
        );
      }
      final declared = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (declared != null && (declared <= 0 || declared > maximumPageBytes)) {
        await _discardResponse(response.data, requestToken);
        throw const MangaPageFetchException(
          'This manga page is larger than the safe limit.',
        );
      }
      final body = response.data;
      if (body == null) {
        await _discardResponse(null, requestToken);
        throw const MangaPageFetchException('The manga page was empty.');
      }
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in body.stream) {
        received += chunk.length;
        if (received > maximumPageBytes) {
          requestToken.cancel('Manga page exceeded its byte limit.');
          throw const MangaPageFetchException(
            'This manga page is larger than the safe limit.',
          );
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) {
        throw const MangaPageFetchException('The manga page was empty.');
      }
      try {
        inspectMangaImage(bytes);
      } on MangaImageValidationException catch (error) {
        throw MangaPageFetchException(error.message);
      }
      return bytes;
    }
    throw const MangaPageFetchException('The manga page could not be loaded.');
  }

  void _trimCache({required String protectedKey}) {
    while (_cachedBytes > maximumCachedBytes && _cache.length > 1) {
      String? oldestCompletedKey;
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
    for (final token in _activeTokens.toList(growable: false)) {
      token.cancel('Manga page loader closed.');
    }
    _activeTokens.clear();
    while (_permitWaiters.isNotEmpty) {
      final waiter = _permitWaiters.removeFirst();
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(
          const MangaPageFetchException('The manga page loader is closed.'),
        );
      }
    }
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
  _MangaPageCacheEntry(this.future);

  final Future<Uint8List> future;
  bool isComplete = false;
  int byteLength = 0;
}

class _MangaPagePermitWaiter {
  _MangaPagePermitWaiter(this.token);

  final CancelToken token;
  final Completer<void> completer = Completer<void>();
}

String _cacheKey(MangaRemotePageResource resource) {
  final values = <int>[...resource.uri.toString().codeUnits];
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

const Set<int> _redirectStatuses = <int>{301, 302, 303, 307, 308};
