import 'dart:async';

import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/episode_discovery_prefetch_controller.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancel stops every active details-discovery observer', () async {
    final releaseStarted = Completer<void>();
    final webStarted = Completer<void>();
    var releaseCancelled = false;
    var webCancelled = false;
    final releases = StreamController<ReleaseSearchProgress>(
      onListen: releaseStarted.complete,
      onCancel: () => releaseCancelled = true,
    );
    final web = StreamController<WebStreamSearchProgress>(
      onListen: webStarted.complete,
      onCancel: () => webCancelled = true,
    );
    final controller = EpisodeDiscoveryPrefetchController.withWatchers(
      releaseSearch: (_) => releases.stream,
      webSearch: (_) => web.stream,
    );

    final handle = controller.prefetch(
      const EpisodeReference(
        anilistMediaId: 7,
        title: 'Cancelable show',
        episode: 4,
      ),
      preferences: const SettingsPreferences(loaded: true),
    );
    await Future.wait([releaseStarted.future, webStarted.future]);
    await handle.cancel();

    expect(releaseCancelled, isTrue);
    expect(webCancelled, isTrue);
    await releases.close();
    await web.close();
    await controller.dispose();
  });

  test('identical prefetch requests share one cancellable operation', () async {
    var releaseListens = 0;
    final releases = StreamController<ReleaseSearchProgress>.broadcast(
      onListen: () => releaseListens++,
    );
    final controller = EpisodeDiscoveryPrefetchController.withWatchers(
      releaseSearch: (_) => releases.stream,
      webSearch: (_) => const Stream<WebStreamSearchProgress>.empty(),
    );
    const episode = EpisodeReference(
      anilistMediaId: 8,
      title: 'Shared show',
      episode: 2,
    );
    const preferences = SettingsPreferences(
      webStreamsEnabled: false,
      loaded: true,
    );

    final first = controller.prefetch(episode, preferences: preferences);
    final second = controller.prefetch(episode, preferences: preferences);

    expect(identical(first, second), isTrue);
    expect(releaseListens, 1);
    await first.cancel();
    await releases.close();
    await controller.dispose();
  });
}
