import 'dart:convert';

import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/presentation/watch_together_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('TV lobby initially focuses Create room and keeps code visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = WatchPartyController(_ScreenWatchPartyClient());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _WatchSettingsController(),
          ),
          watchPartyControllerProvider.overrideWith((_) => controller),
        ],
        child: const MaterialApp(home: WatchTogetherScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Watch Party'), findsOneWidget);
    final watchNavigation = find.byKey(
      const ValueKey('main-nav-watch-together'),
    );
    expect(watchNavigation, findsOneWidget);
    expect(
      find.descendant(
        of: watchNavigation,
        matching: find.byIcon(Icons.person_outline_rounded),
      ),
      findsOneWidget,
    );
    final selectedSemantics = tester
        .widgetList<Semantics>(
          find.descendant(
            of: watchNavigation,
            matching: find.byType(Semantics),
          ),
        )
        .where((widget) => widget.properties.selected != null)
        .single;
    expect(selectedSemantics.properties.selected, isTrue);
    expect(find.byKey(const ValueKey('watch-together-create')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('watch-together-code-input')),
      findsOneWidget,
    );
    final codeField = tester.widget<TvTextInput>(
      find.byKey(const ValueKey('watch-together-code-input')),
    );
    expect(codeField.keyboardType, TextInputType.number);
    expect(codeField.numericOnly, isTrue);
    expect(codeField.maxLength, 8);
    expect(codeField.autofocus, isFalse);
    expect(find.byKey(const ValueKey('tv-keyboard-panel')), findsNothing);
    expect(find.text('8 digits using numbers 2-9 only'), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'watch-together.create',
    );
    codeField.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'watch-together.create',
    );
    codeField.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'watch-together.join',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('active room exposes share code, counts, and end action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = WatchPartyController(_ScreenWatchPartyClient());
    expect(await controller.create(), isTrue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _WatchSettingsController(),
          ),
          watchPartyControllerProvider.overrideWith((_) => controller),
        ],
        child: const MaterialApp(home: WatchTogetherScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('watch-together-qr')), findsNothing);
    expect(find.text('23456789'), findsOneWidget);
    expect(find.text('2 people watching • 0 guests ready'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(find.text('End party'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'watch-together.copy',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('active room leaves membership notices to the app-wide overlay', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _ScreenWatchPartyClient();
    final controller = WatchPartyController(client);
    expect(await controller.create(), isTrue);
    client.events = const [
      WatchPartyEvent(
        sequence: 1,
        type: WatchPartyEventType.kicked,
        displayName: 'Removed Viewer',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _WatchSettingsController(),
          ),
          watchPartyControllerProvider.overrideWith((_) => controller),
        ],
        child: const MaterialApp(home: WatchTogetherScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();

    expect(controller.state.notices, hasLength(1));
    expect(
      find.byKey(const ValueKey('watch-party-membership-notice-1')),
      findsNothing,
      reason:
          'route screens must not mount a second copy of the global overlay',
    );
  });

  testWidgets('room shows safe public participants and selected profile avatar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _ScreenWatchPartyClient()
      ..participants = const [
        WatchPartyParticipant(
          displayName: 'Teto Host',
          role: WatchPartyRole.host,
          ready: true,
        ),
        WatchPartyParticipant(
          displayName: 'Anime Guest',
          avatarUrl: 'https://cdn.myanimelist.net/images/userimages/456.jpg',
          role: WatchPartyRole.guest,
          ready: false,
        ),
      ];
    final controller = WatchPartyController(client);
    expect(await controller.create(), isTrue);
    final accounts = _StaticTrackingAccountsController(
      const TrackingAccountsState(
        profiles: {
          TrackingProvider.anilist: TrackingAccountProfile(
            provider: TrackingProvider.anilist,
            username: 'Public Profile',
            avatarUrl:
                'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b9.jpg',
            slotId: 'private-account-slot',
          ),
        },
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _WatchSettingsController(),
          ),
          trackingAccountsControllerProvider.overrideWith((_) => accounts),
          watchPartyClientProvider.overrideWithValue(client),
          watchPartyControllerProvider.overrideWith((_) => controller),
        ],
        child: const MaterialApp(home: WatchTogetherScreen()),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('watch-together-participant-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('watch-together-participant-1')),
      findsOneWidget,
    );
    expect(find.text('Teto Host'), findsOneWidget);
    expect(find.text('Anime Guest'), findsOneWidget);
    expect(find.text('Host • Ready'), findsOneWidget);
    expect(find.text('Guest • Not ready'), findsOneWidget);
    expect(find.text('TH'), findsOneWidget);
    final artwork = tester.widget<NetworkArtwork>(
      find.descendant(
        of: find.byKey(const ValueKey('watch-together-participant-1')),
        matching: find.byType(NetworkArtwork),
      ),
    );
    expect(
      artwork.url,
      'https://cdn.myanimelist.net/images/userimages/456.jpg',
    );
    expect(client.lastIdentity?.toJson(), {
      'display_name': 'Public Profile',
      'avatar_url':
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b9.jpg',
    });
    final identityJson = jsonEncode(client.lastIdentity?.toJson());
    expect(identityJson, isNot(contains('private-account-slot')));
    expect(identityJson, isNot(contains('provider')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Classic navigation exposes Watch Together and restores lobby focus',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = WatchPartyController(_ScreenWatchPartyClient());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) =>
                  _WatchSettingsController(interfaceMode: InterfaceMode.phone),
            ),
            watchPartyControllerProvider.overrideWith((_) => controller),
          ],
          child: const MaterialApp(home: WatchTogetherScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('main-nav-watch-together')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'watch-together.create',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'watch-together.navigation',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'watch-together.create',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _WatchSettingsController extends SettingsPreferencesController {
  _WatchSettingsController({
    InterfaceMode interfaceMode = InterfaceMode.automatic,
  }) : super(const FlutterSecureStorage()) {
    state = SettingsPreferences(loaded: true, interfaceMode: interfaceMode);
  }

  @override
  Future<void> load() async {}
}

class _ScreenWatchPartyClient extends WatchPartyClient {
  _ScreenWatchPartyClient()
    : super(baseUrl: 'https://tetotv.example', dio: Dio());

  final session = WatchPartySession(
    roomCode: '23456789',
    token: List.filled(43, 'a').join(),
    role: WatchPartyRole.host,
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 6)),
    watchUrl: Uri.parse('https://tetotv.example/watch?room=23456789'),
  );
  List<WatchPartyParticipant> participants = const [];
  List<WatchPartyEvent> events = const [];
  WatchPartyPublicIdentity? lastIdentity;

  @override
  void setPublicIdentity(WatchPartyPublicIdentity? identity) {
    super.setPublicIdentity(identity);
    lastIdentity = identity;
  }

  @override
  Future<WatchPartyCreated> create() async =>
      WatchPartyCreated(session: session);

  @override
  Future<WatchPartySnapshot> snapshot(WatchPartySession session) async =>
      WatchPartySnapshot(
        roomCode: session.roomCode,
        role: session.role,
        revision: 0,
        playing: false,
        position: Duration.zero,
        effectiveAt: DateTime.now().toUtc(),
        serverTime: DateTime.now().toUtc(),
        participantCount: 1,
        readyCount: 0,
        participants: participants,
        events: events,
        expiresAt: session.expiresAt,
      );

  @override
  Future<void> leave(WatchPartySession session) async {}
}

class _StaticTrackingAccountsController extends TrackingAccountsController {
  _StaticTrackingAccountsController(TrackingAccountsState initial)
    : super(
        _TrackingAccountsRef(),
        TrackingTokenService(const FlutterSecureStorage()),
      ) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}

class _TrackingAccountsRef extends Fake implements Ref {}
