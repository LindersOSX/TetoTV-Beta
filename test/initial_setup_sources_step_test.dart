import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/discord/application/discord_account_link_resolver.dart';
import 'package:anime_tv/features/marketplace/application/source_pairing_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:anime_tv/features/marketplace/presentation/source_pairing_dialog.dart';
import 'package:anime_tv/features/settings/presentation/initial_setup_screen.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/device_setup_controller.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('setup saves audio and automatic skip preferences', (
    tester,
  ) async {
    await _pumpSetup(tester, const Size(1280, 720));

    expect(find.text('Preferred player'), findsNothing);
    expect(find.text('Audio & subtitle default'), findsOneWidget);
    expect(find.text('Anime title language'), findsOneWidget);
    expect(find.text('Automatic skipping'), findsOneWidget);

    await tester.tap(find.text('Subtitled'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Romaji'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip intros'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip outros'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(InitialSetupScreen)),
    );
    final preferences = container.read(settingsPreferencesProvider);
    expect(preferences.preferredPlayer, PreferredPlayer.mpv);
    expect(preferences.preferredAudio, PlaybackAudioPreference.sub);
    expect(
      container.read(titleLanguagePreferenceProvider),
      TitleLanguagePreference.romaji,
    );
    expect(preferences.autoSkipIntros, isTrue);
    expect(preferences.autoSkipOutros, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fresh setup defaults to TetoTV keyboard and saves D-pad choice',
    (tester) async {
      await _pumpSetup(tester, const Size(1280, 720));

      expect(find.text('Text input'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(InitialSetupScreen)),
      );
      expect(
        container.read(settingsPreferencesProvider).useBuiltInKeyboard,
        isTrue,
      );

      await tester.tap(find.text('Device keyboard'));
      await tester.pumpAndSettle();

      expect(
        container.read(settingsPreferencesProvider).useBuiltInKeyboard,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV setup fits playback and live layout preview at 960x540', (
    tester,
  ) async {
    await _pumpSetup(tester, const Size(960, 540), isTelevision: true);

    expect(
      find.byKey(const ValueKey('setup-tv-fit-without-scroll')),
      findsWidgets,
    );
    expect(find.byType(SingleChildScrollView), findsNothing);
    for (final label in [
      'Audio & subtitle default',
      'Subtitled',
      'Anime title language',
      'Romaji',
      'Device keyboard',
      'Skip outros',
    ]) {
      expect(
        find.text(label).hitTestable(),
        findsOneWidget,
        reason: '$label must be visible without scrolling',
      );
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.step.0.first-choice',
    );
    expect(tester.takeException(), isNull, reason: 'playback step');

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'default preview');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.step.1.first-choice',
    );
    for (final label in [
      'Navigation & logo size',
      'Small',
      'Medium',
      'Large',
      'Home layout',
      'Featured hero',
    ]) {
      expect(
        find.text(label).hitTestable(),
        findsOneWidget,
        reason: '$label must be visible beside the live preview',
      );
    }
    expect(find.text('Screen layout'), findsNothing);
    expect(find.text('Modern Layout'), findsNothing);
    expect(find.textContaining('Classic Layout'), findsNothing);
    final previewRail = find.byKey(const ValueKey('setup-preview-modern-rail'));
    expect(tester.getSize(previewRail).width, 34);

    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'large preview');
    expect(tester.getSize(previewRail).width, 42);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.step.2.first-choice',
    );
    for (final label in [
      'Set up streaming',
      'Debrid provider',
      'Your sources',
      'Add sources with phone',
      'Open Marketplace manually',
    ]) {
      expect(
        find.text(label).hitTestable(),
        findsOneWidget,
        reason: '$label must be visible on the Streaming step',
      );
    }

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.step.3.first-choice',
    );
    for (final label in [
      'Connect your accounts',
      'Anime list',
      'AniList',
      'MAL',
      'Discord presence',
    ]) {
      expect(
        find.text(label).hitTestable(),
        findsOneWidget,
        reason: '$label must be visible on the Accounts step',
      );
    }

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.step.4.first-choice',
    );
    for (final label in [
      'One last choice',
      'Anonymous crash and error reports',
      'Do not send',
      'Allow error reports',
      'Finish',
    ]) {
      expect(
        find.text(label).hitTestable(),
        findsOneWidget,
        reason: '$label must be visible on the Privacy step',
      );
    }
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Down from Watch Party focuses Continue on the TV layout step', (
    tester,
  ) async {
    await _pumpSetup(tester, const Size(960, 540), isTelevision: true);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Watch Party'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.tv-experience.watch-party',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.continue');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Down from Downloads focuses Continue on the TV layout step', (
    tester,
  ) async {
    await _pumpSetup(tester, const Size(960, 540), isTelevision: true);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup.tv-experience.downloads',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.continue');
    expect(tester.takeException(), isNull);
  });

  testWidgets('setup asks before enabling crash reports or Discord', (
    tester,
  ) async {
    final discord = await _pumpSetup(tester, const Size(1280, 720));

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Connect your accounts'), findsOneWidget);
    expect(find.text('Enable live count'), findsNothing);
    expect(find.textContaining('live viewer'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(InitialSetupScreen)),
    );
    expect(
      container
          .read(settingsPreferencesProvider)
          .anonymousCrashReportingEnabled,
      isFalse,
    );

    await tester.tap(find.text('Link Discord (optional)'));
    await tester.pumpAndSettle();
    expect(find.text('Discord age requirement'), findsOneWidget);
    expect(discord.authenticateCalls, 0);
    await tester.tap(find.byKey(const ValueKey('discord-age-confirm')));
    await tester.pumpAndSettle();
    expect(discord.authenticateCalls, 1);
    expect(find.text('Discord linked and enabled'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('One last choice'), findsOneWidget);
    expect(find.text('Do not send'), findsOneWidget);
    expect(find.text('Allow error reports'), findsOneWidget);
    await tester.tap(find.text('Allow error reports'));
    await tester.pumpAndSettle();
    expect(
      container
          .read(settingsPreferencesProvider)
          .anonymousCrashReportingEnabled,
      isTrue,
    );
  });

  testWidgets('Beta setup offers a default-on anonymous count opt-out', (
    tester,
  ) async {
    await _pumpSetup(tester, const Size(960, 540), isBetaBuild: true);
    for (var step = 0; step < 4; step++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    expect(
      find.text('Anonymous Beta live count').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Count me in').hitTestable(), findsOneWidget);
    expect(find.text('Opt out').hitTestable(), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(InitialSetupScreen)),
    );
    expect(
      container.read(settingsPreferencesProvider).anonymousUsageCountEnabled,
      isTrue,
    );
    await tester.tap(find.text('Opt out'));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsPreferencesProvider).anonymousUsageCountEnabled,
      isFalse,
    );
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV setup opens device pairing without launching a browser', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(
          path: '/setup',
          builder: (context, state) => const InitialSetupScreen(),
        ),
        GoRoute(
          path: '/pair/discord',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('TV DISCORD PAIRING'))),
        ),
      ],
    );
    addTearDown(router.dispose);
    final discord = await _pumpSetup(
      tester,
      const Size(1280, 720),
      isTelevision: true,
      router: router,
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link Discord (optional)'));
    await tester.pumpAndSettle();

    expect(find.text('TV DISCORD PAIRING'), findsOneWidget);
    expect(discord.authenticateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('setup repairs a stale Fire TV flag before Discord linking', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(
          path: '/setup',
          builder: (context, state) => const InitialSetupScreen(),
        ),
        GoRoute(
          path: '/pair/discord',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('TV DISCORD PAIRING'))),
        ),
      ],
    );
    addTearDown(router.dispose);
    final discord = await _pumpSetup(
      tester,
      const Size(1280, 720),
      isTelevision: false,
      nativeCategory: AndroidDeviceCategory.television,
      router: router,
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link Discord (optional)'));
    await tester.pumpAndSettle();

    expect(find.text('TV DISCORD PAIRING'), findsOneWidget);
    expect(discord.authenticateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV setup keeps Debrid and sources together before accounts', (
    tester,
  ) async {
    await _pumpSetup(tester, const Size(960, 540), isTelevision: true);

    for (var index = 0; index < 2; index++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    _expectSourcesStep(tester, isTelevision: true);
    expect(find.byIcon(Icons.qr_code_rounded), findsOneWidget);
    expect(find.byIcon(Icons.phone_android_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Add sources with phone'));
    await tester.pumpAndSettle();
    expect(find.byType(SourcePairingDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Connect your accounts'), findsOneWidget);
  });

  for (final size in const [Size(360, 800), Size(800, 360)]) {
    testWidgets(
      'Sources setup step fits phone ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await _pumpSetup(tester, size);
        for (var index = 0; index < 2; index++) {
          await tester.tap(find.text('Continue'));
          await tester.pumpAndSettle();
        }

        _expectSourcesStep(tester, isTelevision: false);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'setup scans quietly and only shows actionable compatibility advice',
    (tester) async {
      await _pumpSetup(tester, const Size(1280, 720));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(InitialSetupScreen)),
      );
      final deviceSetup =
          container.read(deviceSetupProvider.notifier)
              as _StaticDeviceSetupController;
      expect(deviceSetup.scanCalls, 1);
      expect(find.text('Playback compatibility'), findsNothing);
      expect(find.text('H.264 / AVC'), findsNothing);

      expect(find.text('Choose your playback defaults'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('setup-compatibility-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('1080p H.264'), findsOneWidget);
      expect(find.textContaining('AV1/HEVC'), findsNothing);
    },
  );

  testWidgets('modern TVs do not get a compatibility warning', (tester) async {
    await _pumpSetup(
      tester,
      const Size(1280, 720),
      deviceProfile: const TvDeviceProfile(
        manufacturer: 'Example',
        model: 'TV',
        sdk: 35,
        abis: ['arm64-v8a'],
        displayModes: [],
        hdrTypes: [],
        codecs: [
          TvCodecCapability(
            name: 'hardware.avc',
            mime: 'video/avc',
            hardware: true,
          ),
        ],
        audioOutputs: [],
      ),
    );

    expect(
      find.byKey(const ValueKey('setup-compatibility-warning')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first choice owns initial focus and remote Back returns a step',
    (tester) async {
      await _pumpSetup(tester, const Size(960, 540), isTelevision: true);

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'setup.step.0.first-choice',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Make it feel right on your TV'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Choose your playback defaults'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Leave setup?'), findsOneWidget);
      expect(find.text('Keep setting up'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV setup Back action and remote Back return to the method chooser',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/setup/start',
        routes: [
          GoRoute(
            path: '/setup/start',
            builder: (context, state) => const Scaffold(
              body: Center(
                child: Text(
                  'SETUP METHOD CHOOSER',
                  key: ValueKey('setup-method-destination'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/setup',
            builder: (context, state) =>
                const InitialSetupScreen(returnToMethodChoice: true),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pumpSetup(
        tester,
        const Size(960, 540),
        isTelevision: true,
        router: router,
      );

      router.push('/setup?from=method-choice');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setup-method-back')), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'setup.step.0.first-choice',
      );

      await tester.tap(find.byKey(const ValueKey('setup-method-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('setup-method-destination')),
        findsOneWidget,
      );

      router.push('/setup?from=method-choice');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('setup-method-destination')),
        findsOneWidget,
      );
      expect(find.text('Leave setup?'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Set up later never waits for the quiet device scan', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final delayedDeviceSetup = _DelayedDeviceSetupController();
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('HOME')),
        ),
        GoRoute(
          path: '/setup',
          builder: (context, state) => const InitialSetupScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceSetupProvider.overrideWith((_) => delayedDeviceSetup),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    expect(delayedDeviceSetup.state.loading, isTrue);

    await tester.tap(find.text('Set up later'));
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: initialSetupCompletedStorageKey), 'true');
    delayedDeviceSetup.completeScan(_legacyDeviceProfile);
    await tester.pump();
    await tester.pump();
    expect(delayedDeviceSetup.markCompletedCalls, 1);
    expect(delayedDeviceSetup.state.previouslyCompleted, isTrue);

    delayedDeviceSetup.persistWhenReady();
    await tester.pump();
    expect(delayedDeviceSetup.markCompletedCalls, 1);
  });

  testWidgets('Finish persists a known report that arrives after navigation', (
    tester,
  ) async {
    final delayedDeviceSetup = _DelayedDeviceSetupController();
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('HOME')),
        ),
        GoRoute(
          path: '/setup',
          builder: (context, state) => const InitialSetupScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await _pumpSetup(
      tester,
      const Size(960, 540),
      router: router,
      deviceSetupController: delayedDeviceSetup,
    );

    for (var index = 0; index < 4; index++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
    expect(delayedDeviceSetup.markCompletedCalls, 0);

    delayedDeviceSetup.completeScan(_legacyDeviceProfile);
    await tester.pump();
    await tester.pump();
    expect(delayedDeviceSetup.markCompletedCalls, 1);
  });

  testWidgets('a late unknown report persists no calibration', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final delayedDeviceSetup = _DelayedDeviceSetupController();
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('HOME')),
        ),
        GoRoute(
          path: '/setup',
          builder: (context, state) => const InitialSetupScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceSetupProvider.overrideWith((_) => delayedDeviceSetup),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Set up later'));
    await tester.pumpAndSettle();
    delayedDeviceSetup.completeScan(const TvDeviceProfile.unknown());
    await tester.pump();
    await tester.pump();

    expect(delayedDeviceSetup.markCompletedCalls, 0);
    expect(delayedDeviceSetup.state.previouslyCompleted, isFalse);
  });
}

const _legacyDeviceProfile = TvDeviceProfile(
  manufacturer: 'Example',
  model: 'Legacy TV',
  sdk: 33,
  abis: ['arm64-v8a'],
  displayModes: [],
  hdrTypes: [],
  codecs: [],
  audioOutputs: [],
);

Future<_SetupDiscordPlatform> _pumpSetup(
  WidgetTester tester,
  Size size, {
  bool isTelevision = false,
  bool isBetaBuild = false,
  AndroidDeviceCategory? nativeCategory,
  TvDeviceProfile deviceProfile = const TvDeviceProfile(
    manufacturer: 'Example',
    model: 'Legacy TV',
    sdk: 33,
    abis: ['arm64-v8a'],
    displayModes: [],
    hdrTypes: [],
    codecs: [],
    audioOutputs: [],
  ),
  DeviceSetupController? deviceSetupController,
  GoRouter? router,
}) async {
  FlutterSecureStorage.setMockInitialValues({
    userTorrentSourceManifestsStorageKey:
        '["https://one.example/manifest.json",'
        '"https://two.example/manifest.json",'
        '"https://three.example/manifest.json"]',
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final marketplace = _StaticMarketplaceController(
    MarketplaceState(
      repositories: [
        AddonRepository(
          url: 'https://one.example/marketplace.json',
          updatedAt: DateTime(2026),
        ),
        AddonRepository(
          url: 'https://two.example/marketplace.json',
          updatedAt: DateTime(2026),
        ),
      ],
      loading: false,
    ),
  );
  final pairing = _StaticSourcePairingController();
  final deviceSetup =
      deviceSetupController ?? _StaticDeviceSetupController(deviceProfile);
  final discord = _SetupDiscordPlatform();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        marketplaceControllerProvider.overrideWith((_) => marketplace),
        sourcePairingControllerProvider.overrideWith((_) => pairing),
        deviceSetupProvider.overrideWith((_) => deviceSetup),
        discordPresencePlatformProvider.overrideWithValue(discord),
        isTelevisionProvider.overrideWithValue(isTelevision),
        isInstalledBetaBuildProvider.overrideWithValue(isBetaBuild),
        discordAccountLinkResolverProvider.overrideWithValue(
          DiscordAccountLinkResolver(
            () async =>
                nativeCategory ??
                (isTelevision
                    ? AndroidDeviceCategory.television
                    : AndroidDeviceCategory.mobile),
          ),
        ),
      ],
      child: router == null
          ? const MaterialApp(home: InitialSetupScreen())
          : MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return discord;
}

void _expectSourcesStep(WidgetTester tester, {required bool isTelevision}) {
  expect(find.text('Set up streaming'), findsOneWidget);
  expect(find.text('Your sources'), findsOneWidget);
  expect(find.textContaining('does not bundle or recommend'), findsOneWidget);
  expect(find.text('2'), findsOneWidget);
  expect(find.text('Marketplace repositories'), findsOneWidget);
  expect(find.text('3'), findsOneWidget);
  expect(find.text('Torrent source manifests'), findsOneWidget);
  expect(find.text('Add sources with phone'), findsOneWidget);
  expect(find.text('Open Marketplace manually'), findsOneWidget);
  expect(find.text('Set up later'), findsOneWidget);
  expect(find.text('Back'), findsOneWidget);
  expect(find.text('Continue'), findsOneWidget);
}

class _StaticMarketplaceController extends MarketplaceController {
  _StaticMarketplaceController(MarketplaceState initial)
    : this._(AddonStore(TetoTvDatabase.instance), initial);

  _StaticMarketplaceController._(AddonStore store, MarketplaceState initial)
    : super(store, MarketplaceClient(store)) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}

class _StaticSourcePairingController extends SourcePairingController {
  _StaticSourcePairingController()
    : super(
        () async => null,
        (_) => throw UnimplementedError(),
        (_) async => const SourceImportSummary(),
      );

  @override
  Future<void> start() async {
    state = const SourcePairingState(
      stage: SourcePairingStage.failed,
      message: 'Pairing fixture',
    );
  }
}

class _StaticDeviceSetupController extends DeviceSetupController {
  _StaticDeviceSetupController(this.profile)
    : super(const FlutterSecureStorage());

  final TvDeviceProfile profile;
  int scanCalls = 0;

  @override
  Future<void> scan() async {
    scanCalls++;
    state = DeviceSetupState(report: buildDeviceCalibrationReport(profile));
  }

  @override
  Future<void> markCompleted() async {
    state = state.copyWith(previouslyCompleted: true);
  }
}

class _DelayedDeviceSetupController extends DeviceSetupController {
  _DelayedDeviceSetupController() : this._(Completer<TvDeviceProfile>());

  _DelayedDeviceSetupController._(this._scanCompleter)
    : super(
        const FlutterSecureStorage(),
        loadProfile: () => _scanCompleter.future,
      );

  final Completer<TvDeviceProfile> _scanCompleter;
  int markCompletedCalls = 0;

  @override
  Future<void> markCompleted() async {
    markCompletedCalls++;
    state = state.copyWith(previouslyCompleted: true);
  }

  void completeScan(TvDeviceProfile profile) =>
      _scanCompleter.complete(profile);
}

class _SetupDiscordPlatform implements DiscordPresencePlatform {
  int authenticateCalls = 0;

  @override
  Stream<DiscordBridgeEvent> get events => const Stream.empty();

  @override
  Future<DiscordTokenBundle> authenticate() async {
    authenticateCalls++;
    return DiscordTokenBundle(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      tokenType: 0,
      expiresAt: DateTime.now().add(const Duration(days: 7)),
      scopes: 'openid sdk.social_layer_presence',
    );
  }

  @override
  Future<void> cancelAuthentication() async {}

  @override
  Future<void> connect(DiscordTokenBundle token) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) =>
      throw UnimplementedError();

  @override
  Future<bool> revoke(String token) async => true;

  @override
  Future<Map<Object?, Object?>> sdkInfo() async => {
    'available': true,
    'status': 'disconnected',
    'version': '1.10.18369',
  };
}
