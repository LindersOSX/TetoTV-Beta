import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/features/catalog/application/localized_anime_title_provider.dart';
import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:anime_tv/features/catalog/data/localized_anime_title_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'memory and disk entries expire at the original seven-day boundary',
    () async {
      var now = DateTime.utc(2026, 9, 1);
      final store = _Store();
      var calls = 0;
      final dio = _instantDio((id) => {'es': 'Título ${++calls}'});
      final first = LocalizedAnimeTitleClient(
        dio: dio,
        cacheStore: store,
        clock: () => now,
      );
      final second = LocalizedAnimeTitleClient(
        dio: dio,
        cacheStore: store,
        clock: () => now,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      expect(await first.lookup(1, 'es'), 'Título 1');
      now = now.add(
        const Duration(days: 6, hours: 23, minutes: 59, seconds: 59),
      );
      expect(await first.lookup(1, 'es'), 'Título 1');
      expect(await second.lookup(1, 'es'), 'Título 1');
      expect(calls, 1);
      now = now.add(const Duration(seconds: 1));
      // The fake disk deliberately returns expired records. The payload's
      // original timestamp must independently reject them, without a new TTL.
      expect(await second.lookup(1, 'es'), 'Título 2');
      expect(await first.lookup(1, 'es'), 'Título 2');
      expect(calls, 2);
      expect(store.data.values.single['fetchedAt'], now.millisecondsSinceEpoch);
    },
  );

  for (final timestamp in <Object?>[null, '1788220800000', 1788912000000]) {
    test(
      'missing, malformed, or future cache timestamp is not promoted: $timestamp',
      () async {
        final store = _Store();
        store.data['localized-anime-title:v2:anilist:1'] = {
          'anilistId': 1,
          'titles': {'es': 'Stale'},
          'fetchedAt': ?timestamp,
        };
        final client = LocalizedAnimeTitleClient(
          dio: _instantDio((_) => {'es': 'Fresh'}),
          cacheStore: store,
          clock: () => DateTime.utc(2026, 9, 1),
        );
        addTearDown(client.dispose);
        expect(await client.lookup(1, 'es'), 'Fresh');
      },
    );
  }

  test('valid missing translations expire too', () async {
    var now = DateTime.utc(2026, 9, 1);
    var calls = 0;
    final client = LocalizedAnimeTitleClient(
      dio: _instantDio(
        (_) => ++calls == 1 ? {'en': 'Original'} : {'es': 'Nuevo'},
      ),
      cacheStore: _Store(),
      clock: () => now,
    );
    addTearDown(client.dispose);
    expect(await client.lookup(1, 'es'), isNull);
    now = now.add(const Duration(days: 7));
    expect(await client.lookup(1, 'es'), 'Nuevo');
    expect(calls, 2);
  });

  test('one cancelled language does not abort a shared live request', () async {
    final network = _Network();
    final client = LocalizedAnimeTitleClient(
      dio: network.dio,
      cacheStore: _Store(),
    );
    addTearDown(client.dispose);
    final spanish = CancelToken();
    final french = CancelToken();
    final first = client.lookup(1, 'es', cancelToken: spanish);
    final second = client.lookup(1, 'fr', cancelToken: french);
    await network.listening(1);
    spanish.cancel();
    expect(await first, isNull);
    expect(network.requests[1]!.cancelToken!.isCancelled, isFalse);
    network.complete(1, {'es': 'Uno', 'fr': 'Un'});
    expect(await second, 'Un');
    expect(network.requests.length, 1);
  });

  test(
    'last queued consumer removal frees the 64-title bound for a new card',
    () async {
      final network = _Network();
      final store = _Store();
      final client = LocalizedAnimeTitleClient(
        dio: network.dio,
        cacheStore: store,
      );
      addTearDown(client.dispose);
      final tokens = [for (var i = 0; i < 64; i++) CancelToken()];
      final results = [
        for (var i = 1; i <= 64; i++)
          client.lookup(i, 'es', cancelToken: tokens[i - 1]),
      ];
      await Future.wait([for (var i = 1; i <= 3; i++) network.listening(i)]);
      expect(await client.lookup(65, 'es'), isNull);
      expect(network.requests.keys, [1, 2, 3]);
      for (var i = 3; i < tokens.length; i++) {
        tokens[i].cancel();
      }
      expect(await Future.wait(results.skip(3)), everyElement(isNull));
      final visible = client.lookup(65, 'es');
      tokens[0].cancel();
      expect(await results.first, isNull);
      await network.listening(65);
      expect(network.requests.keys, [1, 2, 3, 65]);
      expect(store.reads, 4);
      expect(network.peak, 3);
      expect(network.cancelled, contains(1));
      network.complete(65, {'es': 'Visible'});
      expect(await visible, 'Visible');
      client.dispose();
      expect(await Future.wait(results), everyElement(isNull));
    },
  );

  test('queued duplicate remains until both consumers cancel', () async {
    final network = _Network();
    final client = LocalizedAnimeTitleClient(
      dio: network.dio,
      cacheStore: _Store(),
    );
    addTearDown(client.dispose);
    final blockers = [for (var i = 1; i <= 3; i++) client.lookup(i, 'es')];
    await Future.wait([for (var i = 1; i <= 3; i++) network.listening(i)]);
    final spanish = CancelToken();
    final french = CancelToken();
    final first = client.lookup(4, 'es', cancelToken: spanish);
    final second = client.lookup(4, 'fr', cancelToken: french);
    spanish.cancel();
    expect(await first, isNull);
    network.complete(1, {'es': 'Uno'});
    await network.listening(4);
    network.complete(4, {'fr': 'Quatre'});
    expect(await second, 'Quatre');
    client.dispose();
    await Future.wait(blockers);
  });

  test(
    'stream deadline cancels a stalled body and releases the next slot',
    () async {
      final network = _Network();
      final store = _Store();
      final client = LocalizedAnimeTitleClient(
        dio: network.dio,
        cacheStore: store,
        requestTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.dispose);
      final pending = [for (var i = 1; i <= 4; i++) client.lookup(i, 'es')];
      await Future.wait([for (var i = 1; i <= 3; i++) network.listening(i)]);
      // Headers are already delivered, but the stream deliberately never ends.
      expect(await pending.first, isNull);
      await network.listening(4);
      expect(network.cancelled, contains(1));
      expect(network.requests[1]!.cancelToken!.isCancelled, isTrue);
      network.complete(4, {'es': 'Fourth'});
      expect(await pending.last, 'Fourth');
      await Future.wait(pending);
      expect(store.data.keys, ['localized-anime-title:v2:anilist:4']);
      expect(network.peak, lessThanOrEqualTo(3));
    },
  );

  test(
    'last consumer cancels a stalled stream without caching partial data',
    () async {
      final network = _Network();
      final store = _Store();
      final client = LocalizedAnimeTitleClient(
        dio: network.dio,
        cacheStore: store,
      );
      addTearDown(client.dispose);
      final cancel = CancelToken();
      final pending = client.lookup(1, 'es', cancelToken: cancel);
      await network.listening(1);
      network.streams[1]!.add(Uint8List.fromList(utf8.encode('{"titles":')));
      cancel.cancel();
      expect(await pending, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(network.cancelled, contains(1));
      expect(network.requests[1]!.cancelToken!.isCancelled, isTrue);
      expect(store.data, isEmpty);
    },
  );

  test(
    'cancel during disk read cannot dispatch a late network request',
    () async {
      final store = _Store()..readGate = Completer<Map<String, dynamic>?>();
      var calls = 0;
      final client = LocalizedAnimeTitleClient(
        dio: _instantDio((_) {
          calls++;
          return {'es': 'Unexpected'};
        }),
        cacheStore: store,
      );
      addTearDown(client.dispose);
      final cancel = CancelToken();
      final pending = client.lookup(1, 'es', cancelToken: cancel);
      cancel.cancel();
      expect(await pending, isNull);
      store.readGate!.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      expect(store.data, isEmpty);
    },
  );

  test(
    'client disposal drops queued work and rejects future lookups',
    () async {
      final network = _Network();
      final client = LocalizedAnimeTitleClient(
        dio: network.dio,
        cacheStore: _Store(),
      );
      final pending = [for (var i = 1; i <= 5; i++) client.lookup(i, 'es')];
      await Future.wait([for (var i = 1; i <= 3; i++) network.listening(i)]);
      client.dispose();
      client.dispose();
      expect(await Future.wait(pending), everyElement(isNull));
      expect(await client.lookup(6, 'es'), isNull);
      expect(network.requests.keys, [1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      expect(network.cancelled, containsAll([1, 2, 3]));
    },
  );

  test(
    'provider disposal after debounce releases queued work for new viewers',
    () async {
      final network = _Network();
      final client = LocalizedAnimeTitleClient(
        dio: network.dio,
        cacheStore: _Store(),
      );
      final container = ProviderContainer(
        overrides: [
          localizedAnimeTitleClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.dispose);
      final subscriptions = [
        for (var i = 1; i <= 4; i++)
          container.listen(
            localizedAnimeTitleProvider((aniListId: i, language: 'es')),
            (_, _) {},
          ),
      ];
      await Future.wait([for (var i = 1; i <= 3; i++) network.listening(i)]);
      subscriptions.last.close();
      await container.pump();
      final visible = localizedAnimeTitleProvider((
        aniListId: 5,
        language: 'es',
      ));
      final visibleSubscription = container.listen(visible, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      subscriptions.first.close();
      await container.pump();
      await network.listening(5);
      expect(network.requests.keys, [1, 2, 3, 5]);
      network.complete(5, {'es': 'Visible'});
      expect(await container.read(visible.future), 'Visible');
      visibleSubscription.close();
      for (final subscription in subscriptions.skip(1)) {
        subscription.close();
      }
      await container.pump();
    },
  );

  test('non-positive request deadlines are rejected', () {
    expect(
      () => LocalizedAnimeTitleClient(requestTimeout: Duration.zero),
      throwsArgumentError,
    );
  });
}

Dio _instantDio(Map<String, String> Function(int) titles) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.ani.zip/'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (r, handler) {
        final id = r.queryParameters['anilist_id'] as int;
        handler.resolve(
          Response(
            requestOptions: r,
            statusCode: 200,
            data: ResponseBody.fromString(
              jsonEncode({
                'mappings': {'anilist_id': id},
                'titles': titles(id),
              }),
              200,
            ),
          ),
        );
      },
    ),
  );
  return dio;
}

class _Network {
  _Network() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, handler) {
          final id = r.queryParameters['anilist_id'] as int;
          requests[id] = r;
          final stream = StreamController<Uint8List>(
            onListen: () {
              active++;
              if (active > peak) peak = active;
              _listening.putIfAbsent(id, Completer<void>.new).complete();
            },
            onCancel: () {
              active--;
              cancelled.add(id);
            },
          );
          streams[id] = stream;
          handler.resolve(
            Response(
              requestOptions: r,
              statusCode: 200,
              data: ResponseBody(stream.stream, 200),
            ),
          );
        },
      ),
    );
  }

  final dio = Dio(BaseOptions(baseUrl: 'https://api.ani.zip/'));
  final requests = <int, RequestOptions>{};
  final streams = <int, StreamController<Uint8List>>{};
  final _listening = <int, Completer<void>>{};
  final cancelled = <int>{};
  int active = 0;
  int peak = 0;

  Future<void> listening(int id) => _listening
      .putIfAbsent(id, Completer<void>.new)
      .future
      .timeout(const Duration(seconds: 2));

  void complete(int id, Map<String, String> titles) {
    streams[id]!.add(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'mappings': {'anilist_id': id},
            'titles': titles,
          }),
        ),
      ),
    );
    unawaited(streams[id]!.close());
  }
}

class _Store implements AnimeTitleLogoCacheStore {
  final data = <String, Map<String, dynamic>>{};
  Completer<Map<String, dynamic>?>? readGate;
  int reads = 0;

  @override
  Future<Map<String, dynamic>?> read(
    String key, {
    bool allowExpired = false,
  }) async {
    reads++;
    return readGate == null ? data[key] : await readGate!.future;
  }

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    required Duration maxAge,
  }) async {
    data[key] = value;
  }
}
