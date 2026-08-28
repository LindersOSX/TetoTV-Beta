import 'dart:async';

import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/anime_details_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'episode actions create a room then replace the button with code and avatars',
    (tester) async {
      final client = _DetailsWatchPartyClient();
      final controller = WatchPartyController(client);
      final identity = WatchPartyPublicIdentity.tryCreate(
        displayName: 'Details host',
        avatarUrl:
            'https://s4.anilist.co/file/anilistcdn/user/avatar/large/host.jpg',
      );

      await _pumpDetails(
        tester,
        client: client,
        controller: controller,
        identity: identity,
      );

      final skipFiller = find.byKey(
        const ValueKey('episode-action-skip-filler'),
      );
      final watchTogether = find.byKey(
        const ValueKey('episode-action-watch-together'),
      );
      expect(find.text('Start Watch Party'), findsOneWidget);
      expect(
        tester.getTopLeft(watchTogether).dy,
        greaterThan(tester.getTopLeft(skipFiller).dy),
      );

      await tester.tap(watchTogether);
      await tester.pump();
      await tester.pump();

      expect(client.createCalls, 1);
      expect(client.publicIdentity?.displayName, 'Details host');
      expect(find.text('23456789'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('episode-watch-party-avatars')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('episode-watch-party-avatar-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('episode-watch-party-avatar-1')),
        findsOneWidget,
      );
      final unsafeAvatar = find.byKey(
        const ValueKey('episode-watch-party-avatar-2'),
      );
      expect(unsafeAvatar, findsOneWidget);
      expect(
        find.descendant(
          of: unsafeAvatar,
          matching: find.byType(NetworkArtwork),
        ),
        findsNothing,
        reason: 'untrusted profile hosts must never receive an image request',
      );
      expect(find.text('Host profile'), findsNothing);
      expect(find.text('Guest profile'), findsNothing);
      expect(find.text('private@example.com'), findsNothing);
      final semantics = _watchPartySemantics(tester);
      expect(
        semantics.properties.label,
        'Watch Party room 23456789, 3 people. Host room active',
      );
      expect(semantics.excludeSemantics, isTrue);
      expect(semantics.properties.onTap, isNull);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('Watch Party is the next D-pad stop after Skip filler', (
    tester,
  ) async {
    final client = _DetailsWatchPartyClient();
    final controller = WatchPartyController(client);
    await _pumpDetails(tester, client: client, controller: controller);

    final skipFillerDetector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-action-skip-filler')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    skipFillerDetector.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final detector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-action-watch-together')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    expect(detector.focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'room creation stays focused while busy then moves to an episode control',
    (tester) async {
      final gate = Completer<void>();
      final client = _DetailsWatchPartyClient()..createGate = gate;
      final controller = WatchPartyController(client);
      await _pumpDetails(tester, client: client, controller: controller);

      _watchPartyDetector(tester).focusNode!.requestFocus();
      await tester.pump();
      final watchTogether = find.byKey(
        const ValueKey('episode-action-watch-together'),
      );
      await tester.tap(watchTogether);
      await tester.tap(watchTogether);
      await tester.pump();

      expect(client.createCalls, 1);
      expect(find.text('Starting…'), findsOneWidget);
      expect(_watchPartyDetector(tester).focusNode?.hasFocus, isTrue);
      expect(_watchPartySemantics(tester).properties.enabled, isFalse);

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('23456789'), findsOneWidget);
      expect(
        find.descendant(
          of: watchTogether,
          matching: find.byType(FocusableActionDetector),
        ),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'episode.next',
        reason:
            'the focused Start action is replaced by a non-action room card',
      );
      expect(client.createCalls, 1);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('disposing details during room creation is lifecycle-safe', (
    tester,
  ) async {
    final gate = Completer<void>();
    final client = _DetailsWatchPartyClient()..createGate = gate;
    final controller = WatchPartyController(client);
    await _pumpDetails(tester, client: client, controller: controller);

    await tester.tap(
      find.byKey(const ValueKey('episode-action-watch-together')),
    );
    await tester.pump();
    expect(client.createCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an active host room stays inline and does not open room controls',
    (tester) async {
      final client = _DetailsWatchPartyClient();
      final controller = WatchPartyController(client);
      expect(await controller.create(), isTrue);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const AnimeDetailsScreen(animeId: 317),
          ),
          GoRoute(
            path: '/watch-together',
            builder: (_, _) => const Scaffold(
              body: SizedBox(key: ValueKey('watch-together-route-destination')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pumpDetails(
        tester,
        client: client,
        controller: controller,
        app: MaterialApp.router(routerConfig: router),
      );

      expect(find.text('23456789'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('episode-action-watch-together')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('watch-together-route-destination')),
        findsNothing,
      );
      expect(client.createCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an active host room is skipped for the next episode control', (
    tester,
  ) async {
    final client = _DetailsWatchPartyClient();
    final controller = WatchPartyController(client);
    expect(await controller.create(), isTrue);
    await _pumpDetails(tester, client: client, controller: controller);

    final skipFillerDetector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-action-skip-filler')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    skipFillerDetector.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final nextEpisodeDetector = tester.widget<FocusableActionDetector>(
      find.descendant(
        of: find.byKey(const ValueKey('episode-step-next')),
        matching: find.byType(FocusableActionDetector),
      ),
    );
    expect(nextEpisodeDetector.focusNode?.hasFocus, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-actions-panel')),
        matching: find.byKey(const ValueKey('anime-details-download-season')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('anime-details-information-actions')),
        matching: find.byKey(const ValueKey('anime-details-download-season')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-action-watch-together')),
        matching: find.byType(FocusableActionDetector),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active guest sees the episode and can leave inline', (
    tester,
  ) async {
    final client = _DetailsWatchPartyClient(role: WatchPartyRole.guest);
    final controller = WatchPartyController(client);
    expect(await controller.create(), isTrue);
    await _pumpDetails(tester, client: client, controller: controller);

    expect(find.text('23456789'), findsOneWidget);
    expect(find.text('Watch Party Details Test • Episode 4'), findsOneWidget);
    expect(find.text('Episode 4 of 12'), findsOneWidget);
    expect(find.byKey(const ValueKey('episode-action-resume')), findsNothing);
    expect(find.byKey(const ValueKey('episode-action-restart')), findsNothing);
    expect(find.byKey(const ValueKey('episode-action-selected')), findsNothing);
    expect(
      find.byKey(const ValueKey('episode-watch-party-leave')),
      findsOneWidget,
    );

    final skipFillerDetector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-action-skip-filler')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    skipFillerDetector.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_watchPartyDetector(tester).focusNode?.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('episode-watch-party-leave')));
    await tester.pump();

    expect(client.leaveCalls, 1);
    expect(find.text('Start Watch Party'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Watch Party action is absent when the feature is disabled', (
    tester,
  ) async {
    final client = _DetailsWatchPartyClient();
    final controller = WatchPartyController(client);
    expect(await controller.create(), isTrue);
    await _pumpDetails(
      tester,
      client: client,
      controller: controller,
      showWatchParty: false,
    );

    expect(
      find.byKey(const ValueKey('episode-action-watch-together')),
      findsNothing,
    );
    expect(find.text('23456789'), findsNothing);
    expect(find.text('Start Watch Party'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(960, 540), Size(1920, 1080)]) {
    testWidgets('Watch Party card fits the ${size.width.toInt()}px TV layout', (
      tester,
    ) async {
      final client = _DetailsWatchPartyClient()
        ..participants = List<WatchPartyParticipant>.generate(
          maximumWatchPartyRosterSize,
          (index) => WatchPartyParticipant(
            displayName: 'Viewer ${index + 1}',
            role: index == 0 ? WatchPartyRole.host : WatchPartyRole.guest,
            ready: index == 0,
          ),
        );
      final controller = WatchPartyController(client);
      expect(await controller.create(), isTrue);
      await _pumpDetails(
        tester,
        client: client,
        controller: controller,
        size: size,
      );

      final rect = tester.getRect(
        find.byKey(const ValueKey('episode-action-watch-together')),
      );
      expect(rect.height, size.width >= 1500 ? 76 : 42);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(
        find.byKey(const ValueKey('episode-watch-party-avatars')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

FocusableActionDetector _watchPartyDetector(WidgetTester tester) =>
    tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-action-watch-together')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );

Semantics _watchPartySemantics(WidgetTester tester) => tester.widget<Semantics>(
  find
      .descendant(
        of: find.byKey(const ValueKey('episode-action-watch-together')),
        matching: find.byType(Semantics),
      )
      .first,
);

Future<void> _pumpDetails(
  WidgetTester tester, {
  required _DetailsWatchPartyClient client,
  required WatchPartyController controller,
  WatchPartyPublicIdentity? identity,
  bool showWatchParty = true,
  Size size = const Size(1280, 720),
  Widget? app,
}) async {
  const anime = AnimeSummary(
    id: 317,
    idMal: 731,
    title: 'Watch Party Details Test',
    description: 'A test series.',
    episodes: 12,
    score: 8,
    seasonYear: 2026,
    status: 'RELEASING',
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeDetailsProvider.overrideWith((_, _) async => anime),
        trackingHomeProvider.overrideWith(
          (_) async => const TrackingHomeData(
            watching: [],
            planToWatch: [],
            completed: [],
          ),
        ),
        seriesPlaybackPreferencesProvider(
          anime.id,
        ).overrideWith((_) async => const SeriesPlaybackPreferences()),
        settingsPreferencesProvider.overrideWith(
          (_) => _DetailsSettingsController(showWatchParty: showWatchParty),
        ),
        watchPartyClientProvider.overrideWithValue(client),
        watchPartyControllerProvider.overrideWith((_) => controller),
        watchPartyPublicIdentityProvider.overrideWithValue(identity),
      ],
      child: app ?? const MaterialApp(home: AnimeDetailsScreen(animeId: 317)),
    ),
  );
  await tester.pumpAndSettle();
}

class _DetailsWatchPartyClient extends WatchPartyClient {
  _DetailsWatchPartyClient({this.role = WatchPartyRole.host})
    : super(baseUrl: 'https://tetotv-bot.wisp.uno');

  final WatchPartyRole role;
  var createCalls = 0;
  var leaveCalls = 0;
  Completer<void>? createGate;
  WatchPartyPublicIdentity? publicIdentity;
  List<WatchPartyParticipant> participants = const [
    WatchPartyParticipant(
      displayName: 'Host profile',
      avatarUrl:
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/host.jpg',
      role: WatchPartyRole.host,
      ready: true,
    ),
    WatchPartyParticipant(
      displayName: 'Guest profile',
      participantId: 'abcdefghijklmnop',
      avatarUrl: 'https://cdn.myanimelist.net/images/userimages/123456.jpg',
      role: WatchPartyRole.guest,
      ready: false,
    ),
    WatchPartyParticipant(
      displayName: 'private@example.com',
      avatarUrl: 'https://tracker.example/avatar?token=private',
      role: WatchPartyRole.guest,
      ready: false,
    ),
  ];

  WatchPartySession get session => WatchPartySession(
    roomCode: '23456789',
    token: List.filled(48, 'a').join(),
    role: role,
    expiresAt: DateTime.utc(2030),
    watchUrl: Uri.parse('https://tetotv-bot.wisp.uno/watch?room=23456789'),
  );

  @override
  void setPublicIdentity(WatchPartyPublicIdentity? identity) {
    super.setPublicIdentity(identity);
    publicIdentity = identity;
  }

  @override
  Future<WatchPartyCreated> create() async {
    createCalls += 1;
    await createGate?.future;
    return WatchPartyCreated(session: session);
  }

  @override
  Future<WatchPartySnapshot> snapshot(WatchPartySession session) async =>
      WatchPartySnapshot(
        roomCode: session.roomCode,
        role: role,
        revision: 0,
        playing: false,
        position: Duration.zero,
        effectiveAt: DateTime.utc(2026),
        serverTime: DateTime.utc(2026),
        participantCount: participants
            .where((participant) => participant.role == WatchPartyRole.guest)
            .length,
        readyCount: 1,
        participants: participants,
        media: const WatchPartyMedia(
          kind: 'anilist',
          title: 'Watch Party Details Test',
          anilistId: 317,
          episode: 4,
        ),
        expiresAt: DateTime.utc(2030),
      );

  @override
  Future<void> leave(WatchPartySession session) async {
    leaveCalls += 1;
  }
}

class _DetailsSettingsController extends SettingsPreferencesController {
  _DetailsSettingsController({required bool showWatchParty})
    : super(const FlutterSecureStorage()) {
    state = SettingsPreferences(
      loaded: true,
      showFillerIndicators: false,
      showWatchTogether: showWatchParty,
    );
  }

  @override
  Future<void> load() async {}
}
