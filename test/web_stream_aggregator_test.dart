import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a failed provider does not hide another provider result', () async {
    const episode = EpisodeReference(
      anilistMediaId: 1,
      title: 'Test',
      episode: 2,
    );
    final result = await aggregateWebStreamingProviders([
      _FakeProvider('broken', 'Broken', () => throw StateError('offline')),
      _FakeProvider(
        'working',
        'Working',
        () async => [
          WebStreamResult(
            providerId: 'working',
            providerName: 'Working',
            title: '1080p',
            uri: Uri.parse('https://cdn.example.com/video.m3u8'),
          ),
        ],
      ),
    ], episode);

    expect(result.streams, hasLength(1));
    expect(result.streams.single.providerName, 'Working');
    expect(result.failures, hasLength(1));
    expect(result.failures.single.providerName, 'Broken');
    expect(result.failures.single.message, 'offline');
    expect(result.failures.single.message, isNot(contains('Bad state')));
  });

  test('same stream URL stays visible once per provider', () async {
    final sharedUri = Uri.parse('https://cdn.example.com/video.m3u8');
    final result = await aggregateWebStreamingProviders([
      _FakeProvider(
        'one',
        'One',
        () async => [
          WebStreamResult(
            providerId: 'one',
            providerName: 'One',
            title: 'Auto',
            uri: sharedUri,
          ),
        ],
      ),
      _FakeProvider(
        'two',
        'Two',
        () async => [
          WebStreamResult(
            providerId: 'two',
            providerName: 'Two',
            title: 'Auto',
            uri: sharedUri,
          ),
        ],
      ),
    ], const EpisodeReference(anilistMediaId: 1, title: 'Test', episode: 1));

    expect(result.streams, hasLength(2));
    expect(result.streams.map((item) => item.providerId), ['one', 'two']);
  });

  test('provider name isolates shared URLs when provider ids are empty', () {
    final sharedUri = Uri.parse('https://cdn.example.com/shared.m3u8');
    final result = mergeWebProviderOutcomes([
      (
        streams: [
          WebStreamResult(
            providerId: '',
            providerName: 'Provider One',
            title: '1080p',
            uri: sharedUri,
          ),
        ],
        failure: null,
      ),
      (
        streams: [
          WebStreamResult(
            providerId: '',
            providerName: 'Provider Two',
            title: '1080p',
            uri: sharedUri,
          ),
        ],
        failure: null,
      ),
    ]);

    expect(result.streams, hasLength(2));
    expect(result.streams.map((item) => item.providerName), [
      'Provider One',
      'Provider Two',
    ]);
  });

  test('provider-fair ordering interleaves deterministic quality buckets', () {
    WebStreamResult stream(String id, String provider, String quality) =>
        WebStreamResult(
          providerId: id,
          providerName: provider,
          title: '$provider $quality',
          quality: quality,
          uri: Uri.parse('https://$id.example/$quality.m3u8'),
        );
    final providerA = [
      stream('provider-a', 'Example Provider A', '720p'),
      stream('provider-a', 'Example Provider A', '2160p'),
      stream('provider-a', 'Example Provider A', '1080p'),
    ];
    final providerB = [
      stream('provider-b', 'Example Provider B', '720p'),
      stream('provider-b', 'Example Provider B', '1080p'),
    ];
    final other = [stream('other', 'Other', '480p')];

    final result = mergeWebProviderOutcomes([
      (streams: providerA, failure: null),
      (streams: providerB, failure: null),
      (streams: other, failure: null),
    ]);

    expect(result.streams.map((item) => item.providerId), [
      'provider-a',
      'provider-b',
      'other',
      'provider-a',
      'provider-b',
      'provider-a',
    ]);
    expect(
      result.streams
          .where((item) => item.providerId == 'provider-a')
          .map((item) => item.quality),
      ['2160p', '1080p', '720p'],
    );
    final reversed = mergeWebProviderOutcomes([
      (streams: other, failure: null),
      (streams: providerB.reversed.toList(), failure: null),
      (streams: providerA.reversed.toList(), failure: null),
    ]);
    expect(
      reversed.streams.map((item) => item.uri),
      result.streams.map((item) => item.uri),
    );
  });

  test(
    'empty results and runtime failures have distinct typed states',
    () async {
      const episode = EpisodeReference(
        anilistMediaId: 2,
        title: 'Classification fixture',
        episode: 1,
      );
      final result = await aggregateWebStreamingProviders([
        _FakeProvider('empty', 'Empty', () async => const []),
        _FakeProvider(
          'failed',
          'Failed',
          () => throw StateError(
            'NO_MATCH: upstream failed [stage=search; reason=network]',
          ),
        ),
      ], episode);

      expect(result.failures, hasLength(2));
      expect(
        result.failures
            .singleWhere((item) => item.providerId == 'empty')
            .status,
        WebProviderFailureStatus.noMatch,
      );
      expect(
        result.failures
            .singleWhere((item) => item.providerId == 'failed')
            .status,
        WebProviderFailureStatus.failed,
      );
    },
  );

  test(
    'episode mismatches are a no-match and never record provider success',
    () async {
      var successCalls = 0;
      var noMatchCalls = 0;
      final progress = await aggregateWebStreamingProvidersIncrementally(
        [
          _FakeProvider(
            'wrong-episode',
            'Wrong Episode',
            () async => [
              WebStreamResult(
                providerId: 'wrong-episode',
                providerName: 'Wrong Episode',
                title: '1080p',
                uri: Uri.parse('https://cdn.example.com/wrong.m3u8'),
                matchedEpisodeNumber: 3,
              ),
            ],
          ),
        ],
        const EpisodeReference(
          anilistMediaId: 2,
          title: 'Classification fixture',
          episode: 2,
        ),
        onSuccess: (_, _) => successCalls++,
        onFailure: (_, _, noMatch) {
          if (noMatch) noMatchCalls++;
        },
      ).last;

      expect(successCalls, 0);
      expect(noMatchCalls, 1);
      expect(progress.aggregation.streams, isEmpty);
      expect(progress.aggregation.failures, hasLength(1));
      expect(
        progress.aggregation.failures.single,
        isA<WebProviderFailure>()
            .having(
              (failure) => failure.status,
              'status',
              WebProviderFailureStatus.noMatch,
            )
            .having((failure) => failure.stage, 'stage', 'episode_lookup')
            .having(
              (failure) => failure.reason,
              'reason',
              'episode_identity_mismatch',
            ),
      );
    },
  );

  test(
    'success bookkeeping receives only episode-compatible streams',
    () async {
      List<WebStreamResult>? recorded;
      final progress = await aggregateWebStreamingProvidersIncrementally(
        [
          _FakeProvider(
            'mixed',
            'Mixed',
            () async => [
              WebStreamResult(
                providerId: 'mixed',
                providerName: 'Mixed',
                title: 'Wrong 1080p',
                uri: Uri.parse('https://cdn.example.com/wrong.m3u8'),
                matchedEpisodeNumber: 3,
              ),
              WebStreamResult(
                providerId: 'mixed',
                providerName: 'Mixed',
                title: 'Right 1080p',
                uri: Uri.parse('https://cdn.example.com/right.m3u8'),
                matchedEpisodeNumber: 2,
              ),
            ],
          ),
        ],
        const EpisodeReference(
          anilistMediaId: 2,
          title: 'Classification fixture',
          episode: 2,
        ),
        onSuccess: (_, streams) => recorded = streams,
      ).last;

      expect(recorded, hasLength(1));
      expect(recorded!.single.matchedEpisodeNumber, 2);
      expect(progress.aggregation.streams, hasLength(1));
      expect(progress.aggregation.streams.single.matchedEpisodeNumber, 2);
      expect(progress.aggregation.failures, isEmpty);
    },
  );

  test('explicit episode match wins over a misleading server label', () async {
    final progress = await aggregateWebStreamingProvidersIncrementally(
      [
        _FakeProvider(
          'server-number',
          'Server Number',
          () async => [
            WebStreamResult(
              providerId: 'server-number',
              providerName: 'Server Number',
              title: 'Server - 1',
              uri: Uri.parse('https://cdn.example.com/episode-18.m3u8'),
              matchedEpisodeNumber: 18,
            ),
          ],
        ),
      ],
      const EpisodeReference(
        anilistMediaId: 18,
        title: 'Classification fixture',
        episode: 18,
      ),
    ).last;

    expect(progress.aggregation.streams, hasLength(1));
    expect(progress.aggregation.failures, isEmpty);
  });

  test('title and season metadata do not hide a wrong episode label', () async {
    final progress = await aggregateWebStreamingProvidersIncrementally(
      [
        _FakeProvider(
          'title-only',
          'Title Only',
          () async => [
            WebStreamResult(
              providerId: 'title-only',
              providerName: 'Title Only',
              title: 'Server - 1',
              uri: Uri.parse('https://cdn.example.com/unknown.m3u8'),
              matchedSeriesTitle: 'Classification fixture',
              matchedSeasonNumber: 1,
            ),
          ],
        ),
      ],
      const EpisodeReference(
        anilistMediaId: 18,
        title: 'Classification fixture Season 1',
        alternativeTitles: ['Classification fixture'],
        episode: 18,
      ),
    ).last;

    expect(progress.aggregation.streams, isEmpty);
    expect(progress.aggregation.failures, hasLength(1));
  });

  test('duplicate metadata and ordering are independent of arrival order', () {
    final duplicateUri = Uri.parse('https://cdn.example.com/video.m3u8');
    final sparse = WebStreamResult(
      providerId: 'a-provider',
      providerName: 'A Provider',
      title: 'Auto',
      uri: duplicateUri,
    );
    final richer = WebStreamResult(
      providerId: 'a-provider',
      providerName: 'A Provider',
      title: '1080p',
      uri: duplicateUri,
      quality: '1080p',
      headers: const {'Referer': 'https://provider.example/'},
    );
    final other = WebStreamResult(
      providerId: 'b-provider',
      providerName: 'B Provider',
      title: '720p',
      uri: Uri.parse('https://cdn.example.com/other.m3u8'),
    );

    final forward = mergeWebProviderOutcomes([
      (streams: [sparse, other], failure: null),
      (streams: [richer], failure: null),
    ]);
    final reversed = mergeWebProviderOutcomes([
      (streams: [richer], failure: null),
      (streams: [other, sparse], failure: null),
    ]);

    expect(forward.streams.map((stream) => stream.providerId), [
      'a-provider',
      'b-provider',
    ]);
    expect(
      reversed.streams.map((stream) => stream.providerId),
      forward.streams.map((stream) => stream.providerId),
    );
    expect(forward.streams.first.headers, isNotEmpty);
  });

  test(
    'same provider URI merges Sub and Dub into one English-capable source',
    () {
      final uri = Uri.parse('https://cdn.example.com/multi-audio.m3u8');
      final sub = WebStreamResult(
        providerId: 'provider',
        providerName: 'Provider',
        title: '1080p',
        uri: uri,
        audioCapability: WebStreamAudioCapability.sub,
      );
      final dub = WebStreamResult(
        providerId: 'provider',
        providerName: 'Provider',
        title: '1080p',
        uri: uri,
        headers: const {'Referer': 'https://provider.example/'},
        audioCapability: WebStreamAudioCapability.dub,
      );

      final forward = mergeWebProviderOutcomes([
        (streams: [sub], failure: null),
        (streams: [dub], failure: null),
      ]);
      final reversed = mergeWebProviderOutcomes([
        (streams: [dub], failure: null),
        (streams: [sub], failure: null),
      ]);

      for (final result in [forward, reversed]) {
        expect(result.streams, hasLength(1));
        expect(result.streams.single.supportsSubAudio, isTrue);
        expect(result.streams.single.supportsDubAudio, isTrue);
        expect(
          result.streams.single.effectiveAudioCapability.pickerLabel,
          'SUB / DUB',
        );
        expect(result.streams.single.headers, isNotEmpty);
      }
    },
  );

  test('emits a working provider before a slower provider completes', () async {
    final slow = Completer<List<WebStreamResult>>();
    final progress = aggregateWebStreamingProvidersIncrementally([
      _FakeProvider('slow', 'Slow', () => slow.future),
      _FakeProvider(
        'fast',
        'Fast',
        () async => [
          WebStreamResult(
            providerId: 'fast',
            providerName: 'Fast',
            title: '1080p',
            uri: Uri.parse('https://cdn.example.com/fast.m3u8'),
          ),
        ],
      ),
    ], const EpisodeReference(anilistMediaId: 1, title: 'Test', episode: 1));
    final iterator = StreamIterator(progress);

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.completedProviders, 0);
    expect(
      iterator.current.pendingProviderNames,
      containsAll(['Slow', 'Fast']),
    );
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.aggregation.streams.single.providerName, 'Fast');
    expect(iterator.current.pendingProviderNames, ['Slow']);

    slow.complete(const []);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.isComplete, isTrue);
    await iterator.cancel();
  });

  test('times out a stalled provider without losing a valid result', () async {
    final result = await aggregateWebStreamingProviders(
      [
        _FakeProvider(
          'stalled',
          'Stalled',
          () => Completer<List<WebStreamResult>>().future,
        ),
        _FakeProvider(
          'working',
          'Working',
          () async => [
            WebStreamResult(
              providerId: 'working',
              providerName: 'Working',
              title: '720p',
              uri: Uri.parse('https://cdn.example.com/working.m3u8'),
            ),
          ],
        ),
      ],
      const EpisodeReference(anilistMediaId: 1, title: 'Test', episode: 1),
      deadline: const Duration(milliseconds: 10),
    );

    expect(result.streams.single.providerName, 'Working');
    expect(result.failures.single.providerName, 'Stalled');
    expect(result.failures.single.message, contains('Timed out'));
  });

  test('never runs more providers than the configured worker limit', () async {
    var active = 0;
    var maximumActive = 0;
    final providers = [
      for (var index = 0; index < 7; index++)
        _FakeProvider('provider-$index', 'Provider $index', () async {
          active++;
          if (active > maximumActive) maximumActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
          return const [];
        }),
    ];

    await aggregateWebStreamingProviders(
      providers,
      const EpisodeReference(anilistMediaId: 1, title: 'Test', episode: 1),
      maxConcurrentProviders: 2,
    );

    expect(maximumActive, 2);
  });

  test(
    'cancelling discovery stops active work and never starts queued jobs',
    () async {
      final activeStarted = Completer<void>();
      final activeCancelled = Completer<void>();
      var queuedStarts = 0;
      var recordedFailures = 0;
      final progress = aggregateWebStreamingProvidersIncrementally(
        [
          _CancellableProvider(
            'active',
            'Active',
            onStarted: activeStarted.complete,
            onCancelled: activeCancelled.complete,
          ),
          _FakeProvider('queued-1', 'Queued 1', () async {
            queuedStarts++;
            return const [];
          }),
          _FakeProvider('queued-2', 'Queued 2', () async {
            queuedStarts++;
            return const [];
          }),
        ],
        const EpisodeReference(anilistMediaId: 1, title: 'Test', episode: 1),
        deadline: const Duration(minutes: 1),
        maxConcurrentProviders: 1,
        onFailure: (_, _, _) => recordedFailures++,
      );
      final subscription = progress.listen((_) {});

      await activeStarted.future.timeout(const Duration(seconds: 1));
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await activeCancelled.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(queuedStarts, 0);
      expect(
        recordedFailures,
        0,
        reason: 'cancellation is not a provider failure',
      );
    },
  );

  test('healthy providers are queued ahead of repeatedly failing ones', () {
    final addons = [
      _installedAddon('never-used'),
      _installedAddon('failing'),
      _installedAddon('successful'),
    ];
    final ordered = orderInstalledProvidersByHealth(addons, {
      'failing': const ProviderHealth(
        providerId: 'failing',
        consecutiveFailures: 3,
      ),
      'successful': ProviderHealth(
        providerId: 'successful',
        lastSuccessAt: DateTime.utc(2026, 8, 1),
      ),
    });

    expect(ordered.map((addon) => addon.manifest.id), [
      'successful',
      'never-used',
      'failing',
    ]);
  });

  test('installed provider availability distinguishes advisory and paused', () {
    final broken = installedWebProviderAvailabilityFailure(
      _installedAddon('reported-broken', reportedBroken: true),
      null,
    );
    final paused = installedWebProviderAvailabilityFailure(
      _installedAddon('paused'),
      ProviderHealth(
        providerId: 'paused',
        consecutiveFailures: 3,
        quarantinedUntil: DateTime.now().add(const Duration(minutes: 5)),
      ),
    );

    expect(broken?.status, WebProviderFailureStatus.advisory);
    expect(broken?.reason, 'reported_broken');
    expect(paused?.status, WebProviderFailureStatus.paused);
    expect(paused?.reason, 'health_quarantine');
    expect(paused?.message, contains('Reset to retry now'));
    final brokenAndPaused = installedWebProviderAvailabilityFailure(
      _installedAddon('broken-paused', reportedBroken: true),
      ProviderHealth(
        providerId: 'broken-paused',
        quarantinedUntil: DateTime.now().add(const Duration(minutes: 5)),
      ),
    );
    expect(brokenAndPaused?.status, WebProviderFailureStatus.paused);
    expect(
      installedWebProviderAvailabilityFailure(_installedAddon('ready'), null),
      isNull,
    );
  });

  test('runtime API incompatibility is not mislabeled as a timed pause', () {
    for (final (reason, message) in [
      ('runtime_api', 'Incompatible'),
      ('unsafe_target', 'safety checks'),
    ]) {
      final failure = installedWebProviderAvailabilityFailure(
        _installedAddon('$reason-provider'),
        ProviderHealth(
          providerId: '$reason-provider',
          consecutiveFailures: 10,
          lastFailureStage: 'search',
          lastFailureReason: reason,
        ),
      );

      expect(failure?.status, WebProviderFailureStatus.unavailable);
      expect(failure?.reason, reason);
      expect(failure?.message, contains(message));
    }
  });

  test('real provider failures sort ahead of neutral no-match notices', () {
    const noMatch = WebProviderFailure(
      providerName: 'A no match',
      status: WebProviderFailureStatus.noMatch,
      message: 'No match.',
    );
    const failed = WebProviderFailure(
      providerName: 'Z failed',
      status: WebProviderFailureStatus.failed,
      message: 'Failed.',
    );
    final result = mergeWebProviderOutcomes([
      (streams: const <WebStreamResult>[], failure: noMatch),
      (streams: const <WebStreamResult>[], failure: failed),
    ]);

    expect(result.failures.map((failure) => failure.status), [
      WebProviderFailureStatus.failed,
      WebProviderFailureStatus.noMatch,
    ]);
  });

  test(
    'provider outcome diagnostics are bounded and contain no media data',
    () {
      final provider = SeanimeJavascriptProvider(
        _installedAddon(
          'diagnostic-provider',
          version: '1.2.3',
          repositoryUrl:
              'https://catalog.example/marketplace.json?token=private',
          payloadUrl: 'https://runtime.example/provider.js?token=private',
        ),
      );
      final message = webProviderSearchDiagnosticMessage(
        provider,
        status: 'success',
        count: 7,
        stage: 'complete',
        reason: 'streams_returned',
      );

      expect(message, contains('provider=diagnostic-provider'));
      expect(message, contains('version=1.2.3'));
      expect(message, contains('repositoryHost=catalog.example'));
      expect(message, contains('executableHost=runtime.example'));
      expect(message, contains('stage=complete'));
      expect(message, contains('status=success'));
      expect(message, contains('count=7'));
      expect(message, isNot(contains('token')));
      expect(message, isNot(contains('private')));
      expect(message, isNot(contains('Classification fixture')));
    },
  );

  test('resolver and player share one episode discovery session', () async {
    final release = Completer<void>();
    final aggregator = _CountingSharedAggregator(release.future);
    const episode = EpisodeReference(
      anilistMediaId: 77,
      title: 'Shared Search',
      episode: 4,
    );
    final resolver = StreamIterator(
      aggregator.watchSearchIncrementally(episode),
    );
    expect(await resolver.moveNext(), isTrue);
    expect(aggregator.searchCalls, 1);

    final player = StreamIterator(aggregator.watchSearchIncrementally(episode));
    expect(await player.moveNext(), isTrue);
    expect(aggregator.searchCalls, 1);
    expect(player.current.pendingProviderNames, ['Shared provider']);

    release.complete();
    expect(await resolver.moveNext(), isTrue);
    expect(await player.moveNext(), isTrue);
    expect(resolver.current.isComplete, isTrue);
    expect(player.current.isComplete, isTrue);
    await resolver.cancel();
    await player.cancel();
  });

  test(
    'shared discovery survives route handoff then cancels when abandoned',
    () async {
      final cancelled = Completer<void>();
      final source = StreamController<WebStreamSearchProgress>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      addTearDown(source.close);
      final aggregator = _CancellableSharedAggregator(source.stream);
      const episode = EpisodeReference(
        anilistMediaId: 78,
        title: 'Graceful Handoff',
        episode: 2,
      );
      final resolver = StreamIterator(
        aggregator.watchSearchIncrementally(episode),
      );
      final firstProgress = resolver.moveNext();
      source.add(
        const WebStreamSearchProgress(
          totalProviders: 1,
          pendingProviderNames: ['Slow provider'],
        ),
      );
      expect(await firstProgress, isTrue);
      await resolver.cancel();

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final player = StreamIterator(
        aggregator.watchSearchIncrementally(episode),
      );
      expect(await player.moveNext(), isTrue);
      expect(aggregator.searchCalls, 1);
      expect(cancelled.isCompleted, isFalse);

      await player.cancel();
      await cancelled.future.timeout(const Duration(seconds: 1));
    },
  );
}

class _CountingSharedAggregator extends WebStreamAggregator {
  _CountingSharedAggregator(this.release)
    : super(AddonStore(TetoTvDatabase.instance));

  final Future<void> release;
  int searchCalls = 0;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    searchCalls++;
    yield const WebStreamSearchProgress(
      totalProviders: 1,
      pendingProviderNames: ['Shared provider'],
    );
    await release;
    yield const WebStreamSearchProgress(
      completedProviders: 1,
      totalProviders: 1,
    );
  }
}

class _CancellableSharedAggregator extends WebStreamAggregator {
  _CancellableSharedAggregator(this.source)
    : super(
        AddonStore(TetoTvDatabase.instance),
        sharedSessionGrace: const Duration(milliseconds: 50),
      );

  final Stream<WebStreamSearchProgress> source;
  int searchCalls = 0;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) {
    searchCalls++;
    return source;
  }
}

InstalledStreamingAddon _installedAddon(
  String id, {
  bool reportedBroken = false,
  String? version,
  String repositoryUrl = 'https://example.com/marketplace.json',
  String? payloadUrl,
}) {
  final manifest = MarketplaceAddon.tryParse({
    'id': id,
    'name': id,
    'manifestURI': 'https://example.com/$id/manifest.json',
    'payloadURI': payloadUrl ?? 'https://example.com/$id/provider.js',
    'type': 'onlinestream-provider',
    'language': 'javascript',
    if (reportedBroken) 'brokenTag': true,
    'version': version ?? '',
  }, repositoryUrl: repositoryUrl)!;
  return InstalledStreamingAddon(
    manifest: manifest,
    payload: 'class Provider {}',
    enabled: true,
    installedAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
}

class _FakeProvider implements WebStreamingProvider {
  const _FakeProvider(this.id, this.name, this.callback);

  @override
  final String id;
  @override
  final String name;
  final Future<List<WebStreamResult>> Function() callback;

  @override
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  }) => callback();
}

class _CancellableProvider implements WebStreamingProvider {
  const _CancellableProvider(
    this.id,
    this.name, {
    required this.onStarted,
    required this.onCancelled,
  });

  @override
  final String id;
  @override
  final String name;
  final void Function() onStarted;
  final void Function() onCancelled;

  @override
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  }) {
    onStarted();
    cancellation!.addListener(onCancelled);
    return Completer<List<WebStreamResult>>().future;
  }
}
