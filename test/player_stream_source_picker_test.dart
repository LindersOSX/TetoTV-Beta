import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/player/presentation/player_stream_source_picker.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web playback launch preserves explicit and multi audio intent', () {
    final sub = playbackOptionForWebStream(
      WebStreamResult(
        providerId: 'provider',
        providerName: 'Provider',
        title: 'SUB / 1080p',
        uri: Uri.parse('https://video.example/sub.m3u8'),
        audioCapability: WebStreamAudioCapability.sub,
      ),
    );
    final multi = playbackOptionForWebStream(
      WebStreamResult(
        providerId: 'provider',
        providerName: 'Provider',
        title: '1080p',
        uri: Uri.parse('https://video.example/multi.m3u8'),
        audioCapability: WebStreamAudioCapability.subAndDub,
      ),
    );
    final unlabeled = playbackOptionForWebStream(
      WebStreamResult(
        providerId: 'legacy',
        providerName: 'Legacy',
        title: '1080p',
        uri: Uri.parse('https://video.example/unknown.m3u8'),
      ),
    );

    expect(sub.release.audioIntent, ReleaseAudioIntent.sub);
    expect(multi.release.audioIntent, ReleaseAudioIntent.multi);
    expect(unlabeled.release.audioIntent, ReleaseAudioIntent.unknown);
  });

  test(
    'web playback option preserves structured provider episode identity',
    () {
      final option = playbackOptionForWebStream(
        WebStreamResult(
          providerId: 'provider',
          providerName: 'Provider',
          title: 'Server - 1',
          uri: Uri.parse('https://video.example/episode-18.m3u8'),
          matchedEpisodeNumber: 18,
          matchedSeasonNumber: 1,
          matchedSeriesTitle: 'Show',
        ),
      );
      const episode = EpisodeReference(
        anilistMediaId: 18,
        title: 'Show Season 1',
        episode: 18,
      );

      expect(option.stream.providerEpisodeIdentity?.episodeNumber, 18);
      expect(option.stream.providerEpisodeIdentity?.seasonNumber, 1);
      expect(option.stream.providerEpisodeIdentity?.seriesTitle, 'Show');
      expect(
        playbackEpisodeIdentityIsCompatible(
          episode: episode,
          stream: option.stream,
          release: option.release,
        ),
        isTrue,
      );
    },
  );

  test('source merge deduplicates by URI and sorts highest quality first', () {
    final low = _option(
      'https://video.example/720.m3u8',
      '720p',
      providerId: 'same-provider',
    );
    final high = _option('https://video.example/1080.m3u8', '1080p');
    final duplicate = _option(
      'https://video.example/720.m3u8',
      '4K',
      providerId: 'same-provider',
    );

    final merged = mergePlaybackStreamOptions([low], [high, duplicate]);

    expect(merged, hasLength(2));
    expect(merged.first.stream.uri, high.stream.uri);
    expect(merged.last.release.quality, '720p');
  });

  test('source merge exposes every provider before one provider repeats', () {
    final providerA2160 = _option(
      'https://video.example/a-2160.m3u8',
      '2160p',
      providerId: 'provider-a',
    );
    final providerA1080 = _option(
      'https://video.example/a-1080.m3u8',
      '1080p',
      providerId: 'provider-a',
    );
    final providerB720 = _option(
      'https://video.example/b-720.m3u8',
      '720p',
      providerId: 'provider-b',
    );

    final merged = mergePlaybackStreamOptions(
      [providerA1080],
      [providerB720, providerA2160],
    );

    expect(merged, [providerA2160, providerB720, providerA1080]);
  });

  test(
    'same CDN URI from different providers preserves both playback choices',
    () {
      const sharedUri = 'https://cdn.example/shared/master.m3u8';
      final providerA = _option(
        sharedUri,
        '1080p',
        providerId: 'provider-a',
        providerName: 'Provider A',
        headers: const {'Referer': 'https://provider-a.example/'},
        externalSubtitle: Uri.parse(
          'https://provider-a.example/subtitles/en.vtt',
        ),
      );
      final providerB = _option(
        sharedUri,
        '1080p',
        providerId: 'provider-b',
        providerName: 'Provider B',
        headers: const {'Referer': 'https://provider-b.example/'},
        externalSubtitle: Uri.parse(
          'https://provider-b.example/subtitles/en.vtt',
        ),
      );

      final merged = mergePlaybackStreamOptions([providerA], [providerB]);

      expect(merged, hasLength(2));
      expect(merged.map(playbackStreamOptionProviderIdentity).toSet(), {
        'provider-a',
        'provider-b',
      });
      expect(merged.map(playbackStreamOptionAttemptKey).toSet(), hasLength(2));
      expect(merged.map(playbackStreamOptionKey).toSet(), hasLength(2));
      expect(merged.map((option) => option.stream.headers['Referer']).toSet(), {
        'https://provider-a.example/',
        'https://provider-b.example/',
      });
      expect(merged.map((option) => option.stream.externalSubtitle).toSet(), {
        Uri.parse('https://provider-a.example/subtitles/en.vtt'),
        Uri.parse('https://provider-b.example/subtitles/en.vtt'),
      });
    },
  );

  test('web recovery sees late direct sources before engine fallback', () {
    final current = _option('https://video.example/current.m3u8', '720p');
    final alternate = _option('https://video.example/alternate.m3u8', '1080p');

    expect(
      hasUntriedDirectWebStream(
        current: current.stream,
        options: [current, alternate],
      ),
      isTrue,
    );
    expect(
      hasUntriedDirectWebStream(
        current: current.stream,
        options: [current, alternate],
        failedStreamKeys: {playbackStreamOptionAttemptKey(alternate)},
      ),
      isFalse,
    );
  });

  test('same URI from a second provider remains an untried failover', () {
    const sharedUri = 'https://cdn.example/shared/master.m3u8';
    final current = _option(
      sharedUri,
      '1080p',
      providerId: 'provider-a',
      headers: const {'Referer': 'https://provider-a.example/'},
    );
    final alternate = _option(
      sharedUri,
      '1080p',
      providerId: 'provider-b',
      headers: const {'Referer': 'https://provider-b.example/'},
    );

    expect(
      hasUntriedDirectWebStream(
        current: current.stream,
        currentFallbackProviderId: current.release.sourceId,
        options: [current, alternate],
        failedStreamKeys: {playbackStreamOptionAttemptKey(current)},
      ),
      isTrue,
    );
    expect(
      hasUntriedDirectWebStream(
        current: current.stream,
        currentFallbackProviderId: current.release.sourceId,
        options: [current, alternate],
        failedStreamKeys: {
          playbackStreamOptionAttemptKey(current),
          playbackStreamOptionAttemptKey(alternate),
        },
      ),
      isFalse,
    );
  });

  test('engine handoff preserves newly discovered source choices', () {
    final initial = _option('https://video.example/initial.m3u8', '720p');
    final discovered = _option('https://video.example/discovered.m3u8', '4K');

    final handoff = playbackStreamOptionsForHandoff(
      currentStream: initial.stream,
      currentRelease: initial.release,
      existing: [discovered],
    );

    expect(
      handoff.map((option) => option.stream.uri),
      containsAll([initial.stream.uri, discovered.stream.uri]),
    );
    expect(handoff.first.stream.uri, discovered.stream.uri);
  });

  test('validated redirect replaces raw URL and cannot loop recovery', () {
    final raw = _option('https://video.example/raw', '1080p');
    final redirected = _option('https://cdn.example/final.m3u8', '1080p');
    final fallback = _option('https://video.example/fallback.m3u8', '720p');

    final options = replaceValidatedPlaybackStreamOption(
      options: [raw, fallback, redirected],
      requestedUri: raw.stream.uri,
      validated: redirected,
    );

    expect(
      options.map((option) => option.stream.uri),
      containsAll([redirected.stream.uri, fallback.stream.uri]),
    );
    expect(
      options.map((option) => option.stream.uri),
      isNot(contains(raw.stream.uri)),
    );
    expect(
      validatedRedirectWasAlreadyAttempted(
        requested: raw,
        validated: redirected,
        attemptedStreamKeys: {playbackStreamOptionAttemptKey(redirected)},
      ),
      isTrue,
    );
    expect(
      validatedRedirectWasAlreadyAttempted(
        requested: fallback,
        validated: fallback,
        attemptedStreamKeys: {playbackStreamOptionAttemptKey(fallback)},
      ),
      isFalse,
    );
  });

  test(
    'validated redirect keeps another provider using the same destination',
    () {
      const sharedUri = 'https://cdn.example/shared/master.m3u8';
      final rawA = _option(
        'https://provider-a.example/redirect',
        '1080p',
        providerId: 'provider-a',
        providerName: 'Provider A',
      );
      final validatedA = _option(
        sharedUri,
        '1080p',
        providerId: 'provider-a',
        providerName: 'Provider A',
        headers: const {'Referer': 'https://provider-a.example/'},
        externalSubtitle: Uri.parse(
          'https://provider-a.example/subtitles/en.vtt',
        ),
      );
      final providerB = _option(
        sharedUri,
        '1080p',
        providerId: 'provider-b',
        providerName: 'Provider B',
        headers: const {'Referer': 'https://provider-b.example/'},
        externalSubtitle: Uri.parse(
          'https://provider-b.example/subtitles/en.vtt',
        ),
      );

      final options = replaceValidatedPlaybackStreamOption(
        options: [rawA, providerB],
        requestedUri: rawA.stream.uri,
        validated: validatedA,
      );

      expect(options, hasLength(2));
      expect(options.map(playbackStreamOptionProviderIdentity).toSet(), {
        'provider-a',
        'provider-b',
      });
      expect(
        options,
        containsAll(<PlaybackStreamOption>[validatedA, providerB]),
      );
      expect(
        validatedRedirectWasAlreadyAttempted(
          requested: rawA,
          validated: validatedA,
          attemptedStreamKeys: {playbackStreamOptionAttemptKey(providerB)},
        ),
        isFalse,
      );
    },
  );

  testWidgets('same-URI provider cards remain independently selectable', (
    tester,
  ) async {
    const sharedUri = 'https://cdn.example/shared/master.m3u8';
    final providerA = _option(
      sharedUri,
      '1080p',
      providerId: 'provider-a',
      providerName: 'Provider A',
      headers: const {'Referer': 'https://provider-a.example/'},
    );
    final providerB = _option(
      sharedUri,
      '1080p',
      providerId: 'provider-b',
      providerName: 'Provider B',
      headers: const {'Referer': 'https://provider-b.example/'},
    );
    PlaybackStreamOption? chosen;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showPlayerStreamSourcePicker(
                context: context,
                initialOptions: [providerA, providerB],
                selectedUri: providerA.stream.uri,
                selectedStreamKey: playbackStreamOptionAttemptKey(providerA),
                onOptionsChanged: (_) {},
              );
            },
            child: const Text('Open sources'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open sources'));
    await tester.pumpAndSettle();
    final providerAFinder = find.byKey(
      ValueKey('player-source-option-${playbackStreamOptionKey(providerA)}'),
    );
    final providerBFinder = find.byKey(
      ValueKey('player-source-option-${playbackStreamOptionKey(providerB)}'),
    );
    expect(providerAFinder, findsOneWidget);
    expect(providerBFinder, findsOneWidget);
    expect(
      find.descendant(
        of: providerAFinder,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: providerBFinder,
        matching: find.byIcon(Icons.play_circle_outline_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(providerBFinder);
    await tester.pumpAndSettle();
    expect(chosen, same(providerB));
  });

  testWidgets('late higher-quality insertion preserves focused source', (
    tester,
  ) async {
    final progress = StreamController<WebStreamSearchProgress>();
    addTearDown(progress.close);
    final low = _option('https://video.example/720.m3u8', '720p');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerStreamSourcePicker(
            initialOptions: [low],
            selectedUri: low.stream.uri,
            onOptionsChanged: (_) {},
            discover: ({bool refresh = false}) => progress.stream,
          ),
        ),
      ),
    );
    await tester.pump();

    FocusableActionDetector detectorFor(PlaybackStreamOption option) =>
        tester.widget(
          find.descendant(
            of: find.byKey(
              ValueKey(
                'player-source-option-${playbackStreamOptionKey(option)}',
              ),
            ),
            matching: find.byType(FocusableActionDetector),
          ),
        );

    expect(detectorFor(low).focusNode?.hasFocus, isTrue);

    progress.add(
      WebStreamSearchProgress(
        aggregation: WebStreamAggregation(
          streams: [
            WebStreamResult(
              providerId: 'late',
              providerName: 'Late Provider',
              title: 'Episode 1 1080p',
              uri: Uri.https('video.example', '/1080.m3u8'),
              quality: '1080p',
            ),
          ],
        ),
        completedProviders: 1,
        totalProviders: 2,
        pendingProviderNames: const ['Another Provider'],
      ),
    );
    await tester.pump();

    expect(find.textContaining('1080p'), findsWidgets);
    expect(detectorFor(low).focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty discovery keeps Refresh and Close focusable while searching',
    (tester) async {
      final progress = StreamController<WebStreamSearchProgress>();
      addTearDown(progress.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerStreamSourcePicker(
              initialOptions: const [],
              selectedUri: Uri.parse('https://video.example/missing.m3u8'),
              onOptionsChanged: (_) {},
              discover: ({bool refresh = false}) => progress.stream,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('player-source-refresh')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-source-close')), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player-source.refresh',
        reason: 'an empty picker must never open without a D-pad target',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player-source.close',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player-source.refresh',
      );

      progress.add(
        const WebStreamSearchProgress(
          aggregation: WebStreamAggregation(),
          completedProviders: 1,
          totalProviders: 1,
        ),
      );
      await tester.pump();
      expect(find.text('No playable sources yet'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player-source.refresh',
        reason: 'finishing with no sources must preserve the action path',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('provider discovery status keeps no-match and paused distinct', (
    tester,
  ) async {
    final progress = StreamController<WebStreamSearchProgress>();
    addTearDown(progress.close);
    final selected = _option('https://video.example/720.m3u8', '720p');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerStreamSourcePicker(
            initialOptions: [selected],
            selectedUri: selected.stream.uri,
            onOptionsChanged: (_) {},
            discover: ({bool refresh = false}) => progress.stream,
          ),
        ),
      ),
    );
    await tester.pump();
    progress.add(
      const WebStreamSearchProgress(
        aggregation: WebStreamAggregation(
          failures: [
            WebProviderFailure(
              providerName: 'No match',
              status: WebProviderFailureStatus.noMatch,
              message: 'No match.',
            ),
            WebProviderFailure(
              providerName: 'Paused',
              status: WebProviderFailureStatus.paused,
              message: 'Paused.',
            ),
            WebProviderFailure(
              providerName: 'Failed',
              status: WebProviderFailureStatus.failed,
              message: 'Failed.',
            ),
          ],
        ),
        completedProviders: 3,
        totalProviders: 3,
      ),
    );
    await tester.pump();

    expect(
      find.text('1 source | 1 unavailable | 1 paused | 1 no match'),
      findsOneWidget,
    );
    expect(find.textContaining('3 unavailable'), findsNothing);
  });

  for (final size in const [Size(360, 800), Size(800, 360)]) {
    testWidgets(
      'source picker fits phone viewport ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final selected = _option(
          'https://video.example/selected.m3u8',
          '1080p',
          providerName: 'A deliberately long provider name',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: PlayerStreamSourcePicker(
                initialOptions: [
                  selected,
                  _option('https://video.example/720.m3u8', '720p'),
                ],
                selectedUri: selected.stream.uri,
                onOptionsChanged: (_) {},
                discover: ({bool refresh = false}) => Stream.value(
                  const WebStreamSearchProgress(
                    aggregation: WebStreamAggregation(),
                    completedProviders: 1,
                    totalProviders: 1,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final panelRect = tester.getRect(
          find.byKey(const ValueKey('player-source-picker-panel')),
        );
        expect(panelRect.left, greaterThanOrEqualTo(0));
        expect(panelRect.top, greaterThanOrEqualTo(0));
        expect(panelRect.right, lessThanOrEqualTo(size.width));
        expect(panelRect.bottom, lessThanOrEqualTo(size.height));
        expect(
          find.byKey(const ValueKey('player-source-refresh')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('player-source-close')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('source picker follows a custom Theme Studio palette', (
    tester,
  ) async {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF061522),
      surface: const Color(0xFF1A3548),
      accent: const Color(0xFF32A86B),
      primaryText: const Color(0xFFF2E5D2),
      mutedText: const Color(0xFF90A8BA),
    );
    final selected = _option('https://video.example/1080.m3u8', '1080p');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: Scaffold(
          body: PlayerStreamSourcePicker(
            initialOptions: [selected],
            selectedUri: selected.stream.uri,
            onOptionsChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-source-picker-panel')),
    );
    final decoration = panel.decoration as BoxDecoration;
    expect(
      decoration.color,
      palette.surface.withValues(alpha: const Color(0xF5080808).a),
    );
    expect(decoration.border!.top.color, palette.accent.withValues(alpha: .75));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.video_library_rounded)).color,
      palette.accentBright,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-source-status')))
          .style
          ?.color,
      palette.mutedText,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_circle_rounded)).color,
      palette.accentBright,
    );
    expect(tester.takeException(), isNull);
  });
}

PlaybackStreamOption _option(
  String uri,
  String quality, {
  String? providerId,
  String? providerName,
  Map<String, String> headers = const {},
  Uri? externalSubtitle,
}) {
  final identity = providerId ?? quality;
  final displayProvider = providerName ?? 'Provider $quality';
  final stream = StreamReady(
    uri: Uri.parse(uri),
    displayName: quality,
    headers: headers,
    externalSubtitle: externalSubtitle,
    providerId: identity,
    providerName: displayProvider,
  );
  return PlaybackStreamOption(
    stream: stream,
    release: ReleaseCandidate(
      infoHash: uri,
      magnetUri: '',
      releaseName: 'Episode 1 $quality',
      seeders: 0,
      sourceId: 'web:$identity',
      quality: quality,
      provider: displayProvider,
    ),
  );
}
