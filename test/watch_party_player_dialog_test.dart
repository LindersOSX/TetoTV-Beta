import 'package:anime_tv/features/player/presentation/watch_party_player_dialog.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player HUD labels total participant count as people watching', () {
    expect(watchPartyViewerCountLabel(-1), '0 people watching');
    expect(watchPartyViewerCountLabel(0), '0 people watching');
    expect(watchPartyViewerCountLabel(1), '1 person watching');
    expect(watchPartyViewerCountLabel(2), '2 people watching');
  });

  testWidgets(
    'player HUD creates a room, shows code guidance, and Close keeps it active',
    (tester) async {
      final client = _HudWatchPartyClient();
      final controller = WatchPartyController(client);
      final identity = WatchPartyPublicIdentity.tryCreate(
        displayName: 'Teto Fan',
        avatarUrl:
            'https://s4.anilist.co/file/anilistcdn/user/avatar/large/x.jpg',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            watchPartyControllerProvider.overrideWith((_) => controller),
            watchPartyClientProvider.overrideWithValue(client),
            watchPartyPublicIdentityProvider.overrideWithValue(identity),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showWatchPartyPlayerDialog(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump();

      expect(client.createCalls, 1);
      expect(client.publicIdentity?.displayName, 'Teto Fan');
      expect(
        find.byKey(const ValueKey('player-watch-party-dialog')),
        findsOneWidget,
      );
      expect(find.text('Watch Party room'), findsOneWidget);
      expect(find.textContaining('Watch Together'), findsNothing);
      expect(find.text('23456789'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-watch-party-qr')), findsNothing);
      expect(
        find.textContaining('Closing this panel does not end'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Stream URLs, tokens, headers'),
        findsOneWidget,
      );
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.watch-party.copy',
      );

      expect(find.text('Host profile'), findsOneWidget);
      expect(find.text('Guest profile'), findsOneWidget);
      expect(find.text('2 people watching • 1 guest ready'), findsOneWidget);
      await tester.tap(find.text('Guest profile'));
      await tester.pumpAndSettle();
      expect(find.text('Manage Guest profile'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-watch-party-transfer-host')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-watch-party-kick')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('player-watch-party-manage-cancel')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Manage Guest profile'), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('player-watch-party-close')),
      );
      await tester.tap(find.byKey(const ValueKey('player-watch-party-close')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('player-watch-party-dialog')),
        findsNothing,
      );
      expect(controller.state.isActive, isTrue);
      expect(client.leaveCalls, 0);

      // Dispose the overridden provider before its recurring room poll is due.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final action in const <String, String>{
    'player-watch-party-kick': 'kick',
    'player-watch-party-transfer-host': 'transfer',
  }.entries) {
    testWidgets('${action.value} restores participant focus to Copy code', (
      tester,
    ) async {
      final client = _HudWatchPartyClient();
      final controller = WatchPartyController(client);
      await _openPlayerWatchPartyDialog(tester, client, controller);

      final participant = find.byKey(
        const ValueKey('player-watch-party-participant-abcdefghijklmnop'),
      );
      expect(participant, findsOneWidget);
      await tester.tap(participant);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(action.key)));
      await tester.pumpAndSettle();

      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'player.watch-party.copy',
      );
      if (action.value == 'kick') {
        expect(participant, findsNothing);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('focused participant leaving restores focus to Copy code', (
    tester,
  ) async {
    final client = _HudWatchPartyClient();
    final controller = WatchPartyController(client);
    await _openPlayerWatchPartyDialog(tester, client, controller);

    final participant = find.byKey(
      const ValueKey('player-watch-party-participant-abcdefghijklmnop'),
    );
    final focusable = find.descendant(
      of: participant,
      matching: find.byType(FocusableActionDetector),
    );
    final focusNode = tester
        .widget<FocusableActionDetector>(focusable)
        .focusNode!;
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasPrimaryFocus, isTrue);

    client
      ..includeGuest = false
      ..revision += 1;
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    await tester.pump();

    expect(participant, findsNothing);
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'player.watch-party.copy',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> _openPlayerWatchPartyDialog(
  WidgetTester tester,
  _HudWatchPartyClient client,
  WatchPartyController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        watchPartyControllerProvider.overrideWith((_) => controller),
        watchPartyClientProvider.overrideWithValue(client),
        watchPartyPublicIdentityProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showWatchPartyPlayerDialog(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump();
  expect(
    tester.binding.focusManager.primaryFocus?.debugLabel,
    'player.watch-party.copy',
  );
}

class _HudWatchPartyClient extends WatchPartyClient {
  _HudWatchPartyClient() : super(baseUrl: 'https://tetotv-bot.wisp.uno');

  var createCalls = 0;
  var leaveCalls = 0;
  var includeGuest = true;
  var snapshotRole = WatchPartyRole.host;
  var revision = 0;
  WatchPartyPublicIdentity? publicIdentity;

  @override
  void setPublicIdentity(WatchPartyPublicIdentity? identity) {
    super.setPublicIdentity(identity);
    publicIdentity = identity;
  }

  final session = WatchPartySession(
    roomCode: '23456789',
    token: List.filled(48, 'a').join(),
    role: WatchPartyRole.host,
    expiresAt: DateTime.utc(2030),
    watchUrl: Uri.parse('https://tetotv-bot.wisp.uno/watch?room=23456789'),
  );

  @override
  Future<WatchPartyCreated> create() async {
    createCalls += 1;
    return WatchPartyCreated(session: session);
  }

  @override
  Future<WatchPartySnapshot> snapshot(WatchPartySession session) async =>
      _snapshot();

  WatchPartySnapshot _snapshot() => WatchPartySnapshot(
    roomCode: session.roomCode,
    role: snapshotRole,
    revision: revision,
    playing: false,
    position: Duration.zero,
    effectiveAt: DateTime.utc(2026),
    serverTime: DateTime.utc(2026),
    participantCount: 1,
    readyCount: 1,
    rosterRevision: revision,
    participants: [
      WatchPartyParticipant(
        displayName: 'Host profile',
        role: snapshotRole == WatchPartyRole.host
            ? WatchPartyRole.host
            : WatchPartyRole.guest,
        ready: true,
      ),
      if (includeGuest)
        WatchPartyParticipant(
          displayName: 'Guest profile',
          participantId: 'abcdefghijklmnop',
          role: snapshotRole == WatchPartyRole.host
              ? WatchPartyRole.guest
              : WatchPartyRole.host,
          ready: false,
        ),
    ],
    expiresAt: DateTime.utc(2030),
  );

  @override
  Future<WatchPartySnapshot> kick({
    required WatchPartySession session,
    required String participantId,
    required int baseRosterRevision,
  }) async {
    includeGuest = false;
    revision += 1;
    return _snapshot();
  }

  @override
  Future<WatchPartySnapshot> transferHost({
    required WatchPartySession session,
    required String participantId,
    required int baseRosterRevision,
  }) async {
    snapshotRole = WatchPartyRole.guest;
    revision += 1;
    return _snapshot();
  }

  @override
  Future<void> leave(WatchPartySession session) async {
    leaveCalls += 1;
  }
}
