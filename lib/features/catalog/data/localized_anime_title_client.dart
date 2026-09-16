import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'anime_title_logo_client.dart';

/// Language-tagged display metadata only. Never changes AniList identity,
/// provider search aliases, tracking titles, or the user's stored library.
class LocalizedAnimeTitleClient {
  LocalizedAnimeTitleClient({
    Dio? dio,
    AnimeTitleLogoCacheStore? cacheStore,
    DateTime Function()? clock,
    Duration requestTimeout = const Duration(seconds: 10),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://api.ani.zip/',
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 8),
             ),
           ),
       _cache = cacheStore ?? const TetoTvAnimeTitleLogoCacheStore(),
       _clock = clock ?? DateTime.now,
       _requestTimeout = requestTimeout,
       _ownsDio = dio == null {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
  }

  static const maximumResponseBytes = 8 * 1024 * 1024;
  static const _cacheAge = Duration(days: 7);
  static const _supported = {'es', 'pt', 'fr', 'hi', 'de'};
  final Dio _dio;
  final AnimeTitleLogoCacheStore _cache;
  final DateTime Function() _clock;
  final Duration _requestTimeout;
  final bool _ownsDio;
  final _memory = <int, _CachedTitles>{};
  final _pending = <int, _TitleLookup>{};
  final _queue = Queue<_TitleLookup>();
  int _active = 0;
  bool _disposed = false;

  /// Each caller owns only its interest in a shared, identity-scoped request.
  /// Cancelling one locale must not cancel another live viewer of this title.
  Future<String?> lookup(
    int aniListId,
    String language, {
    CancelToken? cancelToken,
  }) async {
    if (_disposed ||
        cancelToken?.isCancelled == true ||
        aniListId <= 0 ||
        !_supported.contains(language)) {
      return null;
    }
    final cached = _memory.remove(aniListId);
    if (cached != null && _isFresh(cached.fetchedAt)) {
      _memory[aniListId] = cached;
      return cached.titles[language];
    }
    var work = _pending[aniListId];
    if (work == null) {
      // Browsing a large shelf must not flood the metadata service.
      if (_pending.length >= 64) return null;
      work = _TitleLookup(aniListId);
      _pending[aniListId] = work;
      _queue.add(work);
    }
    work.consumers++;
    _drain();
    try {
      final titles = cancelToken == null
          ? await work.result.future
          : await _untilCancelled(work.result.future, cancelToken);
      return cancelToken?.isCancelled == true ? null : titles[language];
    } catch (_) {
      return null;
    } finally {
      work.consumers--;
      if (work.consumers == 0 && !work.result.isCompleted) _discard(work);
    }
  }

  void _drain() {
    while (!_disposed && _active < 3 && _queue.isNotEmpty) {
      _active++;
      unawaited(_run(_queue.removeFirst()));
    }
  }

  Future<void> _run(_TitleLookup work) async {
    try {
      final titles = await _load(work);
      if (!work.result.isCompleted) work.result.complete(titles);
    } catch (_) {
      // Optional titles never block the catalog or cache transport failures.
      if (!work.result.isCompleted) work.result.complete(const {});
    } finally {
      if (identical(_pending[work.id], work)) _pending.remove(work.id);
      work.cancel.cancel();
      _active--;
      _drain();
    }
  }

  void _discard(_TitleLookup work) {
    if (identical(_pending[work.id], work)) _pending.remove(work.id);
    _queue.remove(work);
    work.cancel.cancel();
    if (!work.result.isCompleted) work.result.complete(const {});
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final work in _pending.values.toList()) {
      _discard(work);
    }
    _memory.clear();
    if (_ownsDio) _dio.close(force: true);
  }

  Future<Map<String, String>> _load(_TitleLookup work) async {
    final id = work.id;
    final cancel = work.cancel;
    // V2 carries the original fetch time through disk -> memory promotions.
    // Old records have no reliable remaining lifetime and are not reused.
    final key = 'localized-anime-title:v2:anilist:$id';
    try {
      final saved = await _untilCancelled(
        _cache.read(key).timeout(const Duration(seconds: 2)),
        cancel,
      );
      final fetchedAt = saved?['fetchedAt'];
      if (saved != null &&
          saved['anilistId'] == id &&
          saved['titles'] is Map &&
          fetchedAt is int &&
          _isFresh(fetchedAt)) {
        _checkLive(cancel);
        return _remember(id, _titles(saved['titles']), fetchedAt);
      }
    } catch (_) {
      // A locked/unavailable local cache is not a metadata-service failure.
    }
    _checkLive(cancel);
    final deadline = Timer(_requestTimeout, cancel.cancel);
    try {
      final response = await _untilCancelled(
        _dio.get<ResponseBody>(
          'mappings',
          queryParameters: {'anilist_id': id},
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
          ),
        ),
        cancel,
      );
      _checkLive(cancel);
      final body = response.data;
      if (response.statusCode != 200 || body == null) return const {};
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (length != null && length > maximumResponseBytes) {
        throw const FormatException('Metadata too large');
      }
      final bytes = await _readBody(body, cancel);
      _checkLive(cancel);
      final document = jsonDecode(utf8.decode(bytes));
      if (document is! Map ||
          document['mappings'] is! Map ||
          document['mappings']['anilist_id'].toString() != '$id' ||
          document['titles'] is! Map) {
        throw const FormatException('Mismatched title metadata');
      }
      final titles = _titles(document['titles']);
      final fetchedAt = _clock().millisecondsSinceEpoch;
      try {
        await _untilCancelled(
          _cache
              .write(key, {
                'anilistId': id,
                'titles': titles,
                'fetchedAt': fetchedAt,
              }, maxAge: _cacheAge)
              .timeout(const Duration(seconds: 2)),
          cancel,
        );
      } catch (_) {
        // Memory still benefits from valid metadata when persistence fails.
      }
      _checkLive(cancel);
      return _remember(id, titles, fetchedAt);
    } finally {
      deadline.cancel();
      cancel.cancel();
    }
  }

  Future<Uint8List> _readBody(ResponseBody body, CancelToken cancel) async {
    final bytes = BytesBuilder(copy: false);
    final result = Completer<Uint8List>();
    final subscription = body.stream.listen(
      (chunk) {
        if (cancel.isCancelled || result.isCompleted) return;
        if (bytes.length + chunk.length > maximumResponseBytes) {
          result.completeError(const FormatException('Metadata too large'));
        } else {
          bytes.add(chunk);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    try {
      // A streamed response can stall after headers, including custom adapters
      // that do not wire Dio's token into their stream. Bound that phase too.
      return await _untilCancelled(result.future, cancel);
    } finally {
      unawaited(subscription.cancel());
    }
  }

  static Future<T> _untilCancelled<T>(Future<T> future, CancelToken cancel) =>
      Future.any([future, cancel.whenCancel.then<T>((error) => throw error)]);

  void _checkLive(CancelToken cancel) {
    if (_disposed || cancel.isCancelled) {
      throw StateError('Title lookup cancelled');
    }
  }

  bool _isFresh(int fetchedAt) {
    final age = _clock().millisecondsSinceEpoch - fetchedAt;
    return fetchedAt > 0 && age >= 0 && age < _cacheAge.inMilliseconds;
  }

  Map<String, String> _remember(
    int id,
    Map<String, String> titles,
    int fetchedAt,
  ) {
    _memory[id] = _CachedTitles(titles, fetchedAt);
    while (_memory.length > 256) {
      _memory.remove(_memory.keys.first);
    }
    return titles;
  }

  static Map<String, String> _titles(Object? value) {
    if (value is! Map) return const {};
    final result = <String, String>{};
    for (final language in _supported) {
      // Prefer an exact language. Accept tagged regional metadata only when
      // the base language has no title; never guess from English or synonyms.
      final candidates = [
        language,
        ...value.keys
            .whereType<String>()
            .where(
              (key) => key
                  .toLowerCase()
                  .replaceAll('_', '-')
                  .startsWith('$language-'),
            )
            .toList()
          ..sort(),
      ];
      for (final key in candidates) {
        final raw = value[key];
        if (raw is! String) continue;
        final title = raw.trim();
        if (title.isEmpty ||
            title.length > 500 ||
            RegExp(
              r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
            ).hasMatch(title)) {
          continue;
        }
        result[language] = title;
        break;
      }
    }
    return result;
  }
}

class _CachedTitles {
  const _CachedTitles(this.titles, this.fetchedAt);

  final Map<String, String> titles;
  final int fetchedAt;
}

class _TitleLookup {
  _TitleLookup(this.id);

  final int id;
  final cancel = CancelToken();
  final result = Completer<Map<String, String>>();
  int consumers = 0;
}
