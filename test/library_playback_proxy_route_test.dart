import 'dart:async';

import 'package:anime_tv/features/player/application/library_playback_proxy.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/library_tv_player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the player route protects requests before mounting MPV', (
    tester,
  ) async {
    final request = LibraryPlaybackRequest(
      source: Uri.parse('https://media.example/Videos/1/stream'),
      title: 'Private episode',
      releaseName: 'Private episode.mkv',
      streamLabel: 'Jellyfin',
      checkpointKey: 'local:0123456789abcdef',
      timelineIdentity: 'private-server-item-7',
      headers: const {'Authorization': 'MediaBrowser Token="secret-token"'},
    );
    final proxy = _RejectingLibraryPlaybackProxy();
    final observed = <LibraryPlaybackResult>[];

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryTvPlayerScreen(
          request: request,
          playbackProxy: proxy,
          onPlaybackFinished: observed.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(proxy.request, same(request));
    expect(
      find.text('Private media could not be prepared safely.'),
      findsOneWidget,
    );
    expect(find.textContaining('secret-token'), findsNothing);
    expect(find.text('Go back'), findsOneWidget);
    expect(observed, hasLength(1));
    expect(observed.single.reason, LibraryPlaybackEndReason.failed);
    expect(
      observed.single.failureStage,
      LibraryPlaybackFailureStage.preparation,
    );
    expect(observed.single.started, isFalse);
    expect(observed.single.error, isNot(contains('secret-token')));
    await tester.pump(const Duration(seconds: 1));
    expect(
      observed,
      hasLength(1),
      reason: 'preparation result is emitted once',
    );
  });

  testWidgets('automatic preparation failure reports once and closes route', (
    tester,
  ) async {
    final request = LibraryPlaybackRequest(
      source: Uri.parse('https://media.example/Videos/1/stream'),
      title: 'Private episode',
      releaseName: 'Private episode.mkv',
      streamLabel: 'Jellyfin',
      checkpointKey: 'local:0123456789abcdef',
      timelineIdentity: 'private-server-item-7',
      headers: const {'Authorization': 'MediaBrowser Token="secret-token"'},
    );
    final observed = <LibraryPlaybackResult>[];
    var routeReturns = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () {
              Navigator.of(context)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => LibraryTvPlayerScreen(
                        request: request,
                        playbackProxy: _RejectingLibraryPlaybackProxy(),
                        onPlaybackFinished: observed.add,
                        autoCloseOnPreparationFailure: true,
                      ),
                    ),
                  )
                  .then((_) => routeReturns++);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(routeReturns, 1);
    expect(observed, hasLength(1));
    expect(observed.single.reason, LibraryPlaybackEndReason.failed);
    expect(
      observed.single.failureStage,
      LibraryPlaybackFailureStage.preparation,
    );
    expect(
      observed.single.error,
      'Private media could not be prepared safely.',
    );
    expect(observed.single.error, isNot(contains('secret-token')));
  });

  testWidgets(
    'route pop propagates the typed playback result before returning',
    (tester) async {
      final request = LibraryPlaybackRequest(
        source: Uri.parse('content://media/external/video/7'),
        title: 'Private episode',
        releaseName: 'Private episode.mkv',
        streamLabel: 'Local media',
        checkpointKey: 'local:0123456789abcdef',
        timelineIdentity: 'private-server-item-7',
      );
      final proxy = _CompletingLibraryPlaybackProxy();
      final navigatorKey = GlobalKey<NavigatorState>();
      LibraryPlaybackResult? observed;
      LibraryPlaybackResult? observedWhenRouteReturned;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                Navigator.of(context)
                    .push<void>(
                      MaterialPageRoute(
                        builder: (_) => LibraryTvPlayerScreen(
                          request: request,
                          playbackProxy: proxy,
                          onPlaybackFinished: (value) => observed = value,
                        ),
                      ),
                    )
                    .then((_) => observedWhenRouteReturned = observed);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      proxy.complete(request);
      await tester.idle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(observed?.reason, LibraryPlaybackEndReason.exited);
      expect(observedWhenRouteReturned, same(observed));
    },
  );
}

class _RejectingLibraryPlaybackProxy extends LibraryPlaybackProxy {
  LibraryPlaybackRequest? request;

  @override
  Future<LibraryPlaybackRequest> protect(LibraryPlaybackRequest request) async {
    this.request = request;
    throw const FormatException('secret-token must not reach the UI');
  }
}

class _CompletingLibraryPlaybackProxy extends LibraryPlaybackProxy {
  final _preparation = Completer<LibraryPlaybackRequest>();

  void complete(LibraryPlaybackRequest request) =>
      _preparation.complete(request);

  @override
  Future<LibraryPlaybackRequest> protect(LibraryPlaybackRequest request) =>
      _preparation.future;
}
