import 'dart:convert';

import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/local_profiles_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  group('local profile storage', () {
    test(
      'normalizes a name, selects it, and leaves tracker data untouched',
      () async {
        const storage = FlutterSecureStorage();
        FlutterSecureStorage.setMockInitialValues({
          TrackingProvider.anilist.tokenStorageKey: 'tracker-secret',
          'tracking_profile_index_v1': '[{"tracker":"index"}]',
        });
        final service = LocalProfileService(
          storage,
          idFactory: () => 'localprofile000001',
        );

        final created = await service.create('  Living   Room  ');
        final snapshot = await service.snapshot();

        expect(created.displayName, 'Living Room');
        expect(snapshot.activeProfileId, 'localprofile000001');
        expect(snapshot.activeProfile?.displayName, 'Living Room');
        expect(
          await storage.read(key: TrackingProvider.anilist.tokenStorageKey),
          'tracker-secret',
        );
        expect(
          await storage.read(key: 'tracking_profile_index_v1'),
          '[{"tracker":"index"}]',
        );
        final encoded = await storage.read(key: 'local_profile_index_v1');
        expect(encoded, contains('Living Room'));
        expect(encoded, isNot(contains('tracker-secret')));
      },
    );

    test(
      'rejects empty, email-shaped, overlong, and duplicate names',
      () async {
        var nextId = 0;
        final service = LocalProfileService(
          const FlutterSecureStorage(),
          idFactory: () =>
              'localprofile${(++nextId).toString().padLeft(6, '0')}',
        );

        await expectLater(service.create('   '), throwsFormatException);
        await expectLater(
          service.create('viewer@example.com'),
          throwsFormatException,
        );
        await expectLater(
          service.create(List<String>.filled(49, 'x').join()),
          throwsFormatException,
        );
        await service.create('Guest');
        await expectLater(
          service.create('  guest  '),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'switches and safely reselects when the active profile is deleted',
      () async {
        var nextId = 0;
        final service = LocalProfileService(
          const FlutterSecureStorage(),
          idFactory: () =>
              'localprofile${(++nextId).toString().padLeft(6, '0')}',
        );
        final livingRoom = await service.create('Living Room');
        final guest = await service.create('Guest');

        await service.activate(livingRoom);
        expect((await service.snapshot()).activeProfileId, livingRoom.id);
        await service.delete(livingRoom);

        final remaining = await service.snapshot();
        expect(remaining.profiles, hasLength(1));
        expect(remaining.activeProfileId, guest.id);
        await service.delete(guest);
        expect((await service.snapshot()).activeProfile, isNull);
      },
    );

    test(
      'ignores malformed, duplicate, and privacy-unsafe stored entries',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'local_profile_index_v1': jsonEncode([
            {'id': 'localprofile000001', 'display_name': 'Safe Guest'},
            {'id': 'localprofile000002', 'display_name': 'safe guest'},
            {'id': 'short', 'display_name': 'Bad identifier'},
            {'id': 'localprofile000003', 'display_name': 'user@example.com'},
            {'id': 'localprofile000004', 'display_name': 'Another Guest'},
          ]),
          'local_profile_active_v1': 'localprofile000001',
        });

        final snapshot = await LocalProfileService(
          const FlutterSecureStorage(),
        ).snapshot();

        expect(snapshot.profiles.map((profile) => profile.displayName), [
          'Another Guest',
          'Safe Guest',
        ]);
        expect(snapshot.activeProfile?.displayName, 'Safe Guest');
      },
    );
  });

  test('Watch Party uses active local name without a tracker or avatar', () {
    final localIdentity = watchPartyPublicIdentityForProfiles(
      activeLocalProfile: const LocalProfile(
        id: 'localprofile000001',
        displayName: 'Living Room',
      ),
      trackerProfiles: const {
        TrackingProvider.anilist: TrackingAccountProfile(
          provider: TrackingProvider.anilist,
          username: 'Tracker User',
          avatarUrl:
              'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
        ),
      },
      preferredTracker: TrackingProvider.anilist,
    );
    expect(localIdentity?.toJson(), {'display_name': 'Living Room'});

    final trackerIdentity = watchPartyPublicIdentityForProfiles(
      activeLocalProfile: null,
      trackerProfiles: const {
        TrackingProvider.anilist: TrackingAccountProfile(
          provider: TrackingProvider.anilist,
          username: 'Tracker User',
          avatarUrl:
              'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
        ),
      },
      preferredTracker: TrackingProvider.anilist,
    );
    expect(trackerIdentity?.displayName, 'Tracker User');
    expect(trackerIdentity?.avatarUrl, startsWith('https://s4.anilist.co/'));
  });

  testWidgets('top-right switcher shows and switches local-only profiles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const livingRoom = LocalProfile(
      id: 'localprofile000001',
      displayName: 'Living Room',
    );
    const guest = LocalProfile(id: 'localprofile000002', displayName: 'Guest');
    final localController = _StaticLocalProfilesController(
      const LocalProfilesState(
        profiles: [livingRoom, guest],
        activeProfileId: 'localprofile000001',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localProfilesControllerProvider.overrideWith((_) => localController),
          trackingAccountsControllerProvider.overrideWith(
            (_) => _StaticTrackingAccountsController(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: MainNavigationBar(
              active: MainNavigationDestination.home,
              preferences: SettingsPreferences(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('main-nav-profile-local')),
      findsOneWidget,
    );
    expect(find.text('Living Room'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('main-nav-profile-summary')));
    await tester.pumpAndSettle();
    final guestMenu = find.byKey(
      const ValueKey('main-nav-switch-local-profile-localprofile000002'),
    );
    expect(guestMenu, findsOneWidget);
    expect(find.text('LOCAL'), findsNWidgets(3));

    await tester.tap(guestMenu);
    await tester.pumpAndSettle();

    expect(localController.state.activeProfileId, guest.id);
    expect(find.text('Guest'), findsNothing);
    expect(
      find.byKey(const ValueKey('main-nav-profile-local')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Modern Home profile switcher supports a local-only identity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final localController = _StaticLocalProfilesController(
      const LocalProfilesState(
        profiles: [
          LocalProfile(id: 'localprofile000001', displayName: 'Family TV'),
        ],
        activeProfileId: 'localprofile000001',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localProfilesControllerProvider.overrideWith((_) => localController),
          trackingAccountsControllerProvider.overrideWith(
            (_) => _StaticTrackingAccountsController(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: HomeProfileSwitcher(preferences: SettingsPreferences()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-profile-switcher')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('main-nav-profile-local')),
      findsOneWidget,
    );
    expect(find.text('Family TV'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('home-profile-switcher'))),
      const Size(52, 52),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local-only identity relocates Settings consistently on TV and phone',
    (tester) async {
      final localController = _StaticLocalProfilesController(
        const LocalProfilesState(
          profiles: [
            LocalProfile(id: 'localprofile000001', displayName: 'Family TV'),
          ],
          activeProfileId: 'localprofile000001',
        ),
      );
      const preferences = SettingsPreferences(
        settingsEntryPlacement: SettingsEntryPlacement.profileMenu,
      );

      Future<void> pumpNavigation(Widget navigation) => tester.pumpWidget(
        ProviderScope(
          overrides: [
            localProfilesControllerProvider.overrideWith(
              (_) => localController,
            ),
            trackingAccountsControllerProvider.overrideWith(
              (_) => _StaticTrackingAccountsController(),
            ),
          ],
          child: MaterialApp(home: Scaffold(body: navigation)),
        ),
      );

      await pumpNavigation(
        HomeSideNavigation(
          preferences: preferences,
          onExitRight: () {},
          metrics: homeNavigationRailMetrics(NavigationChromeSize.medium),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('main-nav-settings')), findsNothing);

      await pumpNavigation(
        const PhoneBottomNavigation(
          preferences: preferences,
          activeDestination: TopNavigationDestination.home,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('main-nav-settings')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Tracking Settings exposes a privacy-clear local profile action',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localProfilesControllerProvider.overrideWith(
              (_) => _StaticLocalProfilesController(const LocalProfilesState()),
            ),
            trackingAccountsControllerProvider.overrideWith(
              (_) => _StaticTrackingAccountsController(),
            ),
          ],
          child: const MaterialApp(home: AccountsScreen(openTracking: true)),
        ),
      );
      await tester.pumpAndSettle();

      final manage = find.byKey(const ValueKey('manage-local-profiles'));
      expect(manage, findsOneWidget);
      expect(find.textContaining('stored only on this device'), findsOneWidget);
      await tester.ensureVisible(manage);
      await tester.tap(manage);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('local-profiles-dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local-profile-name-input')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('create-local-profile')),
        findsOneWidget,
      );
      expect(
        find.textContaining('never include tracker credentials'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local profile entry moves right to Create then resets focus to Back',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final localController = LocalProfilesController(
        LocalProfileService(
          const FlutterSecureStorage(),
          idFactory: () => 'localprofile000001',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localProfilesControllerProvider.overrideWith(
              (_) => localController,
            ),
            trackingAccountsControllerProvider.overrideWith(
              (_) => _StaticTrackingAccountsController(),
            ),
          ],
          child: const MaterialApp(home: AccountsScreen(openTracking: true)),
        ),
      );
      await tester.pumpAndSettle();

      final manage = find.byKey(const ValueKey('manage-local-profiles'));
      await tester.ensureVisible(manage);
      await tester.tap(manage);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      final inputFinder = find.byKey(
        const ValueKey('local-profile-name-input'),
      );
      final input = tester.widget<TvTextInput>(inputFinder);
      input.controller.text = 'Living Room';
      input.focusNode!.requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.name',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.create',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Living Room'), findsOneWidget);
      expect(input.controller.text, isEmpty);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.back',
      );

      input.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.delete.localprofile000001',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.back',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local-profiles-dialog')), findsNothing);
      expect(
        find.byKey(const ValueKey('manage-local-profiles')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'activating and deleting profiles rehomes focus to Delete or Back',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const livingRoom = LocalProfile(
        id: 'localprofile000001',
        displayName: 'Living Room',
      );
      const guest = LocalProfile(
        id: 'localprofile000002',
        displayName: 'Guest',
      );
      final localController = _StaticLocalProfilesController(
        const LocalProfilesState(
          profiles: [livingRoom, guest],
          activeProfileId: 'localprofile000001',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localProfilesControllerProvider.overrideWith(
              (_) => localController,
            ),
            trackingAccountsControllerProvider.overrideWith(
              (_) => _StaticTrackingAccountsController(),
            ),
          ],
          child: const MaterialApp(home: AccountsScreen(openTracking: true)),
        ),
      );
      await tester.pumpAndSettle();
      final manage = find.byKey(const ValueKey('manage-local-profiles'));
      await tester.ensureVisible(manage);
      await tester.tap(manage);
      await tester.pumpAndSettle();

      final activateGuest = find.byKey(
        const ValueKey('activate-local-profile-localprofile000002'),
      );
      final activateDetector = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: activateGuest,
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      activateDetector.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(localController.state.activeProfileId, guest.id);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.delete.localprofile000002',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(localController.state.profiles, [livingRoom]);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.delete.localprofile000001',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(localController.state.profiles, isEmpty);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-profiles.back',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _StaticLocalProfilesController extends LocalProfilesController {
  _StaticLocalProfilesController(LocalProfilesState initial)
    : super(LocalProfileService(const FlutterSecureStorage())) {
    state = initial;
  }

  @override
  Future<void> load() async {}

  @override
  Future<bool> activate(LocalProfile profile) async {
    state = LocalProfilesState(
      profiles: state.profiles,
      activeProfileId: profile.id,
    );
    return true;
  }

  @override
  Future<bool> delete(LocalProfile profile) async {
    final remaining = state.profiles
        .where((candidate) => candidate.id != profile.id)
        .toList(growable: false);
    state = LocalProfilesState(
      profiles: remaining,
      activeProfileId: state.activeProfileId == profile.id
          ? remaining.firstOrNull?.id
          : state.activeProfileId,
    );
    return true;
  }
}

class _StaticTrackingAccountsController extends TrackingAccountsController {
  _StaticTrackingAccountsController()
    : super(
        _TrackingAccountsRef(),
        TrackingTokenService(const FlutterSecureStorage()),
      );

  @override
  Future<void> load() async {}
}

class _TrackingAccountsRef extends Fake implements Ref {}
