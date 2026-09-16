import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_web_provider.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

const _episode = EpisodeReference(
  anilistMediaId: 1,
  title: 'Example Show',
  episode: 2,
);

class _Store extends AddonStore {
  _Store({this.installed = const []}) : super(TetoTvDatabase.instance);
  final List<InstalledStreamingAddon> installed;
  final healthy = <String>[];
  final failures =
      <({String id, Object error, String? stage, String? reason})>[];

  @override
  Future<Map<String, ProviderHealth>> providerHealth() async => {};
  @override
  Future<List<InstalledStreamingAddon>> installedStreamingAddons() async =>
      installed;
  @override
  Future<void> recordProviderHealthyResponse(String id) async {
    healthy.add(id);
  }

  @override
  Future<ProviderHealth> recordProviderFailure(
    String id,
    Object error, {
    String? stage,
    String? reason,
  }) async {
    failures.add((id: id, error: error, stage: stage, reason: reason));
    return ProviderHealth(providerId: id);
  }
}

class _Provider implements WebStreamingProvider {
  _Provider(this.id, {this.fail = false});
  @override
  final String id;
  @override
  String get name => id;
  final bool fail;
  int calls = 0;
  @override
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  }) async {
    calls++;
    if (fail) throw StateError('Fixture unavailable.');
    return [
      WebStreamResult(
        providerId: id,
        providerName: name,
        title: '1080p',
        uri: Uri.parse('https://video.example/episode2.m3u8'),
        matchedEpisodeNumber: episode.episode,
        matchedSeriesTitle: episode.title,
        audioCapability: WebStreamAudioCapability.unknown,
      ),
    ];
  }
}

class _SlowProvider implements WebStreamingProvider {
  const _SlowProvider(this.id, this.delay);

  @override
  final String id;
  final Duration delay;

  @override
  String get name => id;

  @override
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  }) async {
    await Future<void>.delayed(delay);
    cancellation?.throwIfCancelled();
    return [
      WebStreamResult(
        providerId: id,
        providerName: name,
        title: '1080p',
        uri: Uri.parse('https://video.example/slow-episode2.m3u8'),
        matchedEpisodeNumber: episode.episode,
        matchedSeriesTitle: episode.title,
        audioCapability: WebStreamAudioCapability.unknown,
      ),
    ];
  }
}

AniyomiWebProvider _native() => AniyomiWebProvider(
  extensionId: 'example-extension',
  sourceId: '9',
  name: 'Native fixture',
  validateResultTarget: (_) async {},
  request: (request) async => switch (request['operation']) {
    'search' => {
      'items': [
        {'url': '/show', 'title': _episode.title},
      ],
    },
    'details' => {
      'item': {'url': '/show', 'title': _episode.title},
    },
    'episodes' => {
      'chapters': [
        {'url': '/ep2', 'name': 'Episode 2', 'number': 2.0},
      ],
    },
    'videos' => {
      'videos': [
        {'url': 'https://video.example/episode2.m3u8', 'quality': '1080p'},
      ],
    },
    _ => throw StateError('Unexpected operation'),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default constructor retains the empty Seanime-only path', () async {
    final progress = await WebStreamAggregator(
      _Store(),
    ).searchIncrementally(_episode).last;
    expect(progress.totalProviders, 0);
    expect(progress.aggregation.streams, isEmpty);
    expect(progress.aggregation.failures, isEmpty);
    expect(progress.isComplete, isTrue);
  });

  test(
    'ready native source invalidates a shared cold-start empty snapshot',
    () async {
      var generation = 0;
      var loaderCalls = 0;
      var providers = <WebStreamingProvider>[];
      final aggregator = WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () {
          loaderCalls++;
          return providers;
        },
        additionalProviderSnapshotGeneration: () => generation,
      );

      final cold = await aggregator.watchSearchIncrementally(_episode).last;
      expect(cold.aggregation.streams, isEmpty);
      expect(loaderCalls, 1);

      final replay = await aggregator.watchSearchIncrementally(_episode).last;
      expect(replay.aggregation.streams, isEmpty);
      expect(loaderCalls, 1, reason: 'An unchanged snapshot remains cached.');

      final ready = _Provider('aniyomi:anime:source:9');
      providers = [ready];
      generation++;
      final refreshed = await aggregator
          .watchSearchIncrementally(_episode)
          .last;

      expect(loaderCalls, 2);
      expect(ready.calls, 1);
      expect(refreshed.aggregation.streams.single.providerId, ready.id);
    },
  );

  test(
    'native source joins the existing pool and gets correct progress counts',
    () async {
      final store = _Store();
      final progress = await WebStreamAggregator(
        store,
        additionalProvidersLoader: () async => [_native()],
      ).searchIncrementally(_episode).last;
      expect(progress.totalProviders, 1);
      expect(progress.completedProviders, 1);
      expect(progress.isComplete, isTrue);
      expect(
        progress.aggregation.streams.single.providerId,
        'aniyomi:anime:source:9',
      );
      expect(progress.aggregation.failures, isEmpty);
      expect(store.healthy, contains('aniyomi:anime:source:9'));
    },
  );

  test(
    'additional provider outlives the normal deadline and foreground budget',
    () async {
      final provider = _SlowProvider(
        'aniyomi:anime:source:10',
        const Duration(milliseconds: 25),
      );
      final updates = await WebStreamAggregator(
        _Store(),
        providerDeadline: const Duration(milliseconds: 5),
        interactiveBudget: const Duration(milliseconds: 8),
        backgroundBudget: const Duration(milliseconds: 100),
        additionalProvidersLoader: () async => [provider],
      ).searchIncrementally(_episode).toList();

      expect(defaultWebProviderDeadline, const Duration(seconds: 12));
      expect(
        updates,
        contains(
          isA<WebStreamSearchProgress>()
              .having((item) => item.isForegroundComplete, 'foreground', true)
              .having((item) => item.isComplete, 'complete', false),
        ),
      );
      expect(updates.last.aggregation.failures, isEmpty);
      expect(updates.last.aggregation.streams.single.providerId, provider.id);
    },
  );

  test(
    'failed native peer never suppresses a successful source result',
    () async {
      final failed = _Provider('aniyomi:anime:source:8', fail: true);
      final progress = await WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () async => [failed, _native()],
      ).searchIncrementally(_episode).last;
      expect(progress.totalProviders, 2);
      expect(progress.completedProviders, 2);
      expect(
        progress.aggregation.streams.single.providerId,
        'aniyomi:anime:source:9',
      );
      expect(progress.aggregation.failures.single.providerId, failed.id);
    },
  );

  test(
    'native request rejection retains its safe operation stage in aggregation',
    () async {
      final store = _Store();
      final provider = AniyomiWebProvider(
        extensionId: 'aniyomi:anime:example-extension',
        sourceId: '9',
        name: 'Native fixture',
        request: (_) async => throw const AniyomiFailure('invalid_request'),
      );

      final progress = await WebStreamAggregator(
        store,
        additionalProvidersLoader: () async => [provider],
      ).searchIncrementally(_episode).last;

      final failure = progress.aggregation.failures.single;
      expect(failure.status, WebProviderFailureStatus.failed);
      expect(failure.stage, 'search');
      expect(failure.reason, 'invalid_payload');
      expect(store.failures.single.stage, 'search');
      expect(store.failures.single.reason, 'invalid_payload');
      expect(store.failures.single.error, isNot(contains('invalid_request')));
    },
  );

  test('native diagnostic identity is stable without becoming a URI', () {
    final message = webProviderSearchDiagnosticMessage(
      _Provider('aniyomi:anime:source:-8123456789012345678'),
      status: 'failed',
      count: 0,
      stage: 'search',
      reason: 'invalid_payload',
    );
    final malformed = webProviderSearchDiagnosticMessage(
      _Provider('aniyomi:anime:source:https://private.example/secret'),
      status: 'failed',
      count: 0,
      stage: 'runtime',
      reason: 'provider_error',
    );

    expect(
      message,
      contains('provider=aniyomi_anime_source_-8123456789012345678'),
    );
    expect(
      redactDiagnosticValue(message),
      contains('provider=aniyomi_anime_source_-8123456789012345678'),
    );
    expect(redactDiagnosticValue(message), isNot(contains('[URI]')));
    expect(message, isNot(contains('provider=aniyomi:')));
    expect(malformed, contains('provider=unknown'));
    expect(malformed, isNot(contains('private.example')));
    expect(malformed, isNot(contains('secret')));
  });

  test(
    'native loader failure is reported without aborting aggregation',
    () async {
      final progress = await WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () async => throw StateError('No worker'),
      ).searchIncrementally(_episode).last;
      expect(progress.isComplete, isTrue);
      expect(progress.totalProviders, 1);
      expect(progress.completedProviders, 1);
      expect(progress.aggregation.failures.single.providerId, 'aniyomi:loader');
      expect(
        progress.aggregation.failures.single.status,
        WebProviderFailureStatus.unavailable,
      );
    },
  );

  test(
    'additional providers participate in source-specific retries only',
    () async {
      final one = _Provider('aniyomi:anime:source:1');
      final two = _Provider('aniyomi:anime:source:2');
      final aggregator = WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () async => [one, two],
      );
      final progress = await aggregator.retryProvidersIncrementally(_episode, [
        two.id,
      ]).last;
      expect(one.calls, 0);
      expect(two.calls, 1);
      expect(progress.totalProviders, 1);
      expect(progress.aggregation.streams.single.providerId, two.id);
    },
  );

  test(
    'Seanime-only retry never invokes or reports the native loader',
    () async {
      var loaderCalls = 0;
      final aggregator = WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () {
          loaderCalls++;
          throw StateError('Native loader must stay out of this retry.');
        },
      );

      final progress = await aggregator.retryProvidersIncrementally(_episode, [
        'seanime-only-provider',
      ]).last;

      expect(loaderCalls, 0);
      expect(progress.aggregation.failures, isEmpty);
      expect(progress.isComplete, isTrue);
    },
  );

  testWidgets(
    'hung native discovery releases Seanime after its short optional budget',
    (tester) async {
      final pending = Completer<List<WebStreamingProvider>>();
      final addon = InstalledStreamingAddon(
        manifest: MarketplaceAddon.tryParse({
          'id': 'seanime-fixture',
          'name': 'Seanime fixture',
          'manifestURI': 'https://catalog.example/manifest.json',
          'type': 'onlinestream-provider',
          'language': 'javascript',
        }, repositoryUrl: 'https://catalog.example/index.json')!,
        payload: 'class Provider {}',
        enabled: true,
        installedAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final updates = <WebStreamSearchProgress>[];
      final subscription = WebStreamAggregator(
        _Store(installed: [addon]),
        additionalProvidersLoader: () => pending.future,
        // Exercise pool admission without loading a platform QuickJS bridge.
        backgroundBudget: Duration.zero,
      ).searchIncrementally(_episode).listen(updates.add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 249));
      expect(updates, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(updates, isNotEmpty);
      expect(updates.first.totalProviders, 2);
      expect(updates.first.pendingProviderNames, contains('Seanime fixture'));
      expect(updates.last.isComplete, isTrue);
      expect(
        updates.last.aggregation.failures.map((failure) => failure.providerId),
        containsAll(['aniyomi:loader', 'seanime-fixture']),
      );
      final lateProvider = _Provider('aniyomi:anime:source:99');
      pending.complete([lateProvider]);
      await tester.pump();
      expect(lateProvider.calls, 0);
      unawaited(subscription.cancel());
      await tester.pump();
    },
  );

  test(
    'duplicate injected IDs do not double-dispatch a native source',
    () async {
      final one = _Provider('aniyomi:anime:source:1');
      final duplicate = _Provider(one.id);
      final progress = await WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () async => [one, duplicate],
      ).searchIncrementally(_episode).last;
      expect(progress.totalProviders, 1);
      expect(one.calls, 1);
      expect(duplicate.calls, 0);
    },
  );

  test(
    'runtime additions cannot take over an existing Seanime identity',
    () async {
      final addon = InstalledStreamingAddon(
        manifest: MarketplaceAddon.tryParse({
          'id': 'seanime-fixture',
          'name': 'Seanime fixture',
          'manifestURI': 'https://catalog.example/manifest.json',
          'type': 'onlinestream-provider',
          'language': 'javascript',
        }, repositoryUrl: 'https://catalog.example/index.json')!,
        payload: 'class Provider {}',
        enabled: false,
        installedAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final takeover = _Provider('SEANIME-FIXTURE');
      final progress = await WebStreamAggregator(
        _Store(installed: [addon]),
        additionalProvidersLoader: () async => [takeover, _native()],
      ).searchIncrementally(_episode).last;
      expect(takeover.calls, 0);
      expect(progress.totalProviders, 1);
      expect(
        progress.aggregation.streams.single.providerId,
        'aniyomi:anime:source:9',
      );
    },
  );

  test(
    'oversized native loader list fails closed with a bounded diagnostic',
    () async {
      final provider = _Provider('aniyomi:anime:source:1');
      final progress = await WebStreamAggregator(
        _Store(),
        additionalProvidersLoader: () async => List.filled(129, provider),
      ).searchIncrementally(_episode).last;
      expect(provider.calls, 0);
      expect(progress.isComplete, isTrue);
      expect(
        progress.aggregation.failures.single.reason,
        'native_provider_loader_unavailable',
      );
    },
  );
}
