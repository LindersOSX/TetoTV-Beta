import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stream source and keyboard preferences persist', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SettingsPreferencesController(storage);

    await controller.setDebridStreamsEnabled(false);
    await controller.setWebStreamsEnabled(false);
    await controller.setUseBuiltInKeyboard(false);
    await controller.setAutoSkipIntros(true);
    await controller.setAutoSkipOutros(true);
    await controller.setShowFillerIndicators(false);
    await controller.setHomeLayout(HomeLayout.compact);
    await controller.setShowTitleStyle(ShowTitleStyle.text);
    await controller.setShowHome(false);
    await controller.setShowMyList(false);
    await controller.setShowDiscover(false);
    await controller.setShowCalendar(false);
    await controller.setShowWatchTogether(false);
    await controller.setOfflineDownloadsEnabled(false);
    await controller.setShowHero(false);
    await controller.setShowPosterMetadata(false);
    await controller.setShowCardSubtitles(false);
    await controller.setTrackerUpdateThreshold(TrackerUpdateThreshold.halfway);
    await controller.setInterfaceMode(InterfaceMode.television);
    await controller.setInterfaceScale(.8);
    await controller.setNavigationSounds(false);
    await controller.setClickSounds(false);
    await controller.setPreferredPlayer(PreferredPlayer.mpv);
    await controller.setPreferredAudio(PlaybackAudioPreference.sub);
    await controller.setDebridStreamSort(DebridStreamSort.largestSize);
    await controller.setStreamSourcePriority(StreamSourcePriority.webFirst);
    await controller.setWebStreamQuality(WebStreamQualityPreference.p720);
    await controller.setAutoPickSourceEnabled(true);
    await controller.setAutoPickSourcePriority(const [
      AutoPickSourcePriority.web,
      AutoPickSourcePriority.debrid,
    ]);
    await controller.setAutoPickQualityPriority(const [
      AutoPickQuality.p480,
      AutoPickQuality.p720,
      AutoPickQuality.p1080,
      AutoPickQuality.p2160,
    ]);
    await controller.setAutoPickAudio(AutoPickAudio.subOnly);
    await controller.setDefaultLandingPage(LandingPage.myList);
    await controller.setAnonymousCrashReportingEnabled(true);
    await controller.setAnonymousUsageCountEnabled(false);
    await controller.setSubEpisodeNotificationsEnabled(true);
    await controller.setDubEpisodeNotificationsEnabled(true);
    await controller.setNavigationChromeSize(NavigationChromeSize.large);
    await controller.setTopNavigationOrder(const [
      TopNavigationDestination.watchTogether,
      TopNavigationDestination.settings,
      TopNavigationDestination.calendar,
      TopNavigationDestination.discover,
      TopNavigationDestination.myList,
      TopNavigationDestination.home,
      TopNavigationDestination.search,
    ]);

    final restored = SettingsPreferencesController(storage);
    await restored.load();
    expect(restored.state.debridStreamsEnabled, isFalse);
    expect(restored.state.webStreamsEnabled, isFalse);
    expect(restored.state.useBuiltInKeyboard, isFalse);
    expect(restored.state.autoSkipIntros, isTrue);
    expect(restored.state.autoSkipOutros, isTrue);
    expect(restored.state.showFillerIndicators, isFalse);
    expect(restored.state.homeLayout, HomeLayout.compact);
    expect(restored.state.showTitleStyle, ShowTitleStyle.text);
    expect(restored.state.showHome, isFalse);
    expect(restored.state.showSettings, isTrue);
    expect(restored.state.showMyList, isFalse);
    expect(restored.state.showDiscover, isFalse);
    expect(restored.state.showCalendar, isFalse);
    expect(restored.state.showWatchTogether, isFalse);
    expect(restored.state.offlineDownloadsEnabled, isFalse);
    expect(
      restored.state.isTopNavigationDestinationVisible(
        TopNavigationDestination.downloads,
      ),
      isFalse,
    );
    expect(restored.state.showHero, isFalse);
    expect(restored.state.showPosterMetadata, isFalse);
    expect(restored.state.showCardSubtitles, isFalse);
    expect(
      restored.state.trackerUpdateThreshold,
      TrackerUpdateThreshold.halfway,
    );
    expect(restored.state.interfaceMode, InterfaceMode.television);
    expect(restored.state.interfaceScale, .8);
    expect(restored.state.navigationSounds, isFalse);
    expect(restored.state.clickSounds, isFalse);
    expect(restored.state.preferredPlayer, PreferredPlayer.mpv);
    expect(restored.state.preferredAudio, PlaybackAudioPreference.sub);
    expect(restored.state.debridStreamSort, DebridStreamSort.largestSize);
    expect(restored.state.streamSourcePriority, StreamSourcePriority.webFirst);
    expect(restored.state.webStreamQuality, WebStreamQualityPreference.p720);
    expect(restored.state.autoPickSourceEnabled, isTrue);
    expect(restored.state.autoPickSourcePriority, const [
      AutoPickSourcePriority.web,
      AutoPickSourcePriority.debrid,
      AutoPickSourcePriority.yourMedia,
    ]);
    expect(restored.state.autoPickQualityPriority, const [
      AutoPickQuality.p480,
      AutoPickQuality.p720,
      AutoPickQuality.p1080,
      AutoPickQuality.p2160,
    ]);
    expect(restored.state.autoPickSourceType, AutoPickSourceType.webOnly);
    expect(restored.state.autoPickQuality, AutoPickQuality.p480);
    expect(restored.state.autoPickAudio, AutoPickAudio.subOnly);
    expect(restored.state.defaultLandingPage, LandingPage.myList);
    expect(restored.state.anonymousCrashReportingEnabled, isTrue);
    expect(restored.state.anonymousUsageCountEnabled, isFalse);
    expect(restored.state.subEpisodeNotificationsEnabled, isTrue);
    expect(restored.state.dubEpisodeNotificationsEnabled, isTrue);
    expect(restored.state.navigationChromeSize, NavigationChromeSize.large);
    expect(restored.state.topNavigationOrder, [
      TopNavigationDestination.watchTogether,
      TopNavigationDestination.downloads,
      TopNavigationDestination.settings,
      TopNavigationDestination.calendar,
      TopNavigationDestination.discover,
      TopNavigationDestination.myList,
      TopNavigationDestination.home,
      TopNavigationDestination.search,
    ]);
    expect(restored.state.loaded, isTrue);
  });

  test('retired Classic Layout preference migrates to Automatic', () async {
    final values = <String, String>{
      'appearance_interface_mode': InterfaceMode.phone.name,
    };
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => values[key],
      writeValue: (key, value) async => values[key] = value,
    );

    await controller.load();

    expect(controller.state.interfaceMode, InterfaceMode.automatic);
    expect(values['appearance_interface_mode'], InterfaceMode.automatic.name);
  });

  test(
    'Watch Party defaults on for a fresh install and preserves an explicit opt-out',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final fresh = SettingsPreferencesController(storage);

      await fresh.load();
      expect(fresh.state.showWatchTogether, isTrue);

      await fresh.setShowWatchTogether(false);
      final restored = SettingsPreferencesController(storage);
      await restored.load();
      expect(restored.state.showWatchTogether, isFalse);
    },
  );

  test(
    'fresh installs keep anonymous crash reporting off by default',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
      );
      await controller.load();

      expect(controller.state.debridStreamsEnabled, isTrue);
      expect(controller.state.directTorrentStreamingEnabled, isFalse);
      expect(controller.state.webStreamsEnabled, isTrue);
      expect(controller.state.useBuiltInKeyboard, isTrue);
      expect(controller.state.autoSkipIntros, isFalse);
      expect(controller.state.autoSkipOutros, isFalse);
      expect(controller.state.showFillerIndicators, isTrue);
      expect(controller.state.homeLayout, HomeLayout.cinematic);
      expect(controller.state.showTitleStyle, ShowTitleStyle.englishLogo);
      expect(controller.state.interfaceMode, InterfaceMode.automatic);
      expect(controller.state.navigationSounds, isTrue);
      expect(controller.state.clickSounds, isTrue);
      expect(controller.state.defaultLandingPage, LandingPage.home);
      expect(controller.state.showHome, isTrue);
      expect(controller.state.showSettings, isTrue);
      expect(
        controller.state.navigationChromeSize,
        NavigationChromeSize.medium,
      );
      expect(
        controller.state.settingsEntryPlacement,
        SettingsEntryPlacement.topNavigation,
      );
      expect(controller.state.topNavigationOrder, const [
        TopNavigationDestination.home,
        TopNavigationDestination.search,
        TopNavigationDestination.myList,
        TopNavigationDestination.discover,
        TopNavigationDestination.calendar,
        TopNavigationDestination.watchTogether,
        TopNavigationDestination.downloads,
        TopNavigationDestination.settings,
      ]);
      expect(controller.state.showMyList, isTrue);
      expect(controller.state.showDiscover, isTrue);
      expect(controller.state.showCalendar, isTrue);
      expect(controller.state.showWatchTogether, isTrue);
      expect(controller.state.showDownloads, isTrue);
      expect(controller.state.offlineDownloadsEnabled, isTrue);
      expect(controller.state.anonymousCrashReportingEnabled, isFalse);
      expect(controller.state.anonymousUsageCountEnabled, isTrue);
      expect(controller.state.subEpisodeNotificationsEnabled, isFalse);
      expect(controller.state.dubEpisodeNotificationsEnabled, isFalse);
      expect(controller.state.externalPlayerEnabled, isFalse);
      expect(controller.state.preferredAudio, PlaybackAudioPreference.dub);
      expect(controller.state.preferredPlayer, PreferredPlayer.mpv);
      expect(controller.state.debridStreamSort, DebridStreamSort.bestQuality);
      expect(
        controller.state.streamSourcePriority,
        StreamSourcePriority.debridFirst,
      );
      expect(
        controller.state.webStreamQuality,
        WebStreamQualityPreference.bestAvailable,
      );
      expect(controller.state.autoPickSourceEnabled, isFalse);
      expect(
        controller.state.autoPickSourcePriority,
        defaultAutoPickSourcePriority,
      );
      expect(
        controller.state.autoPickQualityPriority,
        defaultAutoPickQualityPriority,
      );
      expect(controller.state.autoPickSourceType, AutoPickSourceType.any);
      expect(controller.state.autoPickQuality, AutoPickQuality.any);
      expect(controller.state.autoPickAudio, AutoPickAudio.any);
      expect(controller.state.loaded, isTrue);
      expect(
        controller.state.trackerUpdateThreshold,
        TrackerUpdateThreshold.nearlyFinished,
      );
    },
  );

  test('Direct torrent is opt-in and persists explicit changes', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final fresh = SettingsPreferencesController(storage);

    await fresh.load();
    expect(fresh.state.directTorrentStreamingEnabled, isFalse);

    await fresh.setDirectTorrentStreamingEnabled(true);
    final enabled = SettingsPreferencesController(storage);
    await enabled.load();
    expect(enabled.state.directTorrentStreamingEnabled, isTrue);

    await enabled.setDirectTorrentStreamingEnabled(false);
    final disabledAgain = SettingsPreferencesController(storage);
    await disabledAgain.load();
    expect(disabledAgain.state.directTorrentStreamingEnabled, isFalse);
  });

  test(
    'offline downloads default on and master disable preserves navigation choice',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final controller = SettingsPreferencesController(storage);

      await controller.load();
      expect(controller.state.offlineDownloadsEnabled, isTrue);
      expect(controller.state.showDownloads, isTrue);
      expect(
        controller.state.isTopNavigationDestinationVisible(
          TopNavigationDestination.downloads,
        ),
        isTrue,
      );

      await controller.setOfflineDownloadsEnabled(false);
      expect(controller.state.showDownloads, isTrue);
      expect(
        controller.state.isTopNavigationDestinationVisible(
          TopNavigationDestination.downloads,
        ),
        isFalse,
      );

      final disabled = SettingsPreferencesController(storage);
      await disabled.load();
      expect(disabled.state.offlineDownloadsEnabled, isFalse);
      expect(disabled.state.showDownloads, isTrue);

      await disabled.setOfflineDownloadsEnabled(true);
      final restored = SettingsPreferencesController(storage);
      await restored.load();
      expect(restored.state.offlineDownloadsEnabled, isTrue);
      expect(restored.state.showDownloads, isTrue);
      expect(
        restored.state.isTopNavigationDestinationVisible(
          TopNavigationDestination.downloads,
        ),
        isTrue,
      );
    },
  );

  test('External player handoff is opt-in and persists', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final fresh = SettingsPreferencesController(storage);

    await fresh.load();
    expect(fresh.state.externalPlayerEnabled, isFalse);

    await fresh.setExternalPlayerEnabled(true);
    final restored = SettingsPreferencesController(storage);
    await restored.load();
    expect(restored.state.externalPlayerEnabled, isTrue);
  });

  test(
    'specific default external player persists and can fall back to MPV',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final controller = SettingsPreferencesController(storage);

      await controller.setDefaultExternalPlayer(
        packageName: 'org.example.player',
        label: ' Example   Player ',
      );
      final restored = SettingsPreferencesController(storage);
      await restored.load();

      expect(restored.state.preferredPlayer, PreferredPlayer.external);
      expect(restored.state.externalPlayerEnabled, isTrue);
      expect(
        restored.state.selectedExternalPlayerPackage,
        'org.example.player',
      );
      expect(restored.state.selectedExternalPlayerLabel, 'Example Player');

      await restored.setExternalPlayerEnabled(false);
      final fallback = SettingsPreferencesController(storage);
      await fallback.load();
      expect(fallback.state.preferredPlayer, PreferredPlayer.mpv);
      expect(fallback.state.externalPlayerEnabled, isFalse);
      expect(fallback.state.selectedExternalPlayerPackage, isNull);
      expect(fallback.state.selectedExternalPlayerLabel, isNull);
    },
  );

  test('invalid persisted external package safely migrates to MPV', () async {
    FlutterSecureStorage.setMockInitialValues({
      'player_preferred_engine': 'external',
      'player_external_default_package': '../not-a-package',
      'player_external_default_label': 'Unsafe',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.preferredPlayer, PreferredPlayer.mpv);
    expect(controller.state.selectedExternalPlayerPackage, isNull);
  });

  test('disabled external playback cannot remain the default', () async {
    FlutterSecureStorage.setMockInitialValues({
      'player_preferred_engine': 'external',
      'player_external_handoff_enabled': 'false',
      'player_external_default_package': 'org.example.player',
      'player_external_default_label': 'Example Player',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.externalPlayerEnabled, isFalse);
    expect(controller.state.preferredPlayer, PreferredPlayer.mpv);
  });

  test('legacy player choices migrate to MPV', () async {
    FlutterSecureStorage.setMockInitialValues({
      'player_preferred_engine': 'automatic',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.preferredPlayer, PreferredPlayer.mpv);
  });

  test(
    'legacy custom navigation keeps its order and inserts Watch Together',
    () async {
      const customOrder = <TopNavigationDestination>[
        TopNavigationDestination.calendar,
        TopNavigationDestination.settings,
        TopNavigationDestination.discover,
        TopNavigationDestination.myList,
        TopNavigationDestination.search,
        TopNavigationDestination.home,
      ];
      FlutterSecureStorage.setMockInitialValues({
        'navigation_top_bar_order': customOrder
            .map((destination) => destination.name)
            .join(','),
      });
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
      );

      await controller.load();

      expect(controller.state.topNavigationOrder, const [
        TopNavigationDestination.calendar,
        TopNavigationDestination.watchTogether,
        TopNavigationDestination.downloads,
        TopNavigationDestination.settings,
        TopNavigationDestination.discover,
        TopNavigationDestination.myList,
        TopNavigationDestination.search,
        TopNavigationDestination.home,
      ]);
    },
  );

  test('invalid Auto Pick values migrate safely without enabling it', () async {
    FlutterSecureStorage.setMockInitialValues({
      'streaming_auto_pick_source_type': 'legacySource',
      'streaming_auto_pick_quality': '8kMaybe',
      'streaming_auto_pick_audio': 'bothSometimes',
      'streaming_auto_pick_source_priority_v2': 'web,unknown,web',
      'streaming_auto_pick_quality_priority_v2': 'p720,any,p720,8k',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.autoPickSourceEnabled, isFalse);
    expect(controller.state.autoPickSourceType, AutoPickSourceType.any);
    expect(controller.state.autoPickQuality, AutoPickQuality.any);
    expect(controller.state.autoPickAudio, AutoPickAudio.any);
    expect(controller.state.autoPickSourcePriority, const [
      AutoPickSourcePriority.web,
      AutoPickSourcePriority.debrid,
      AutoPickSourcePriority.yourMedia,
    ]);
    expect(controller.state.autoPickQualityPriority, const [
      AutoPickQuality.p720,
      AutoPickQuality.p2160,
      AutoPickQuality.p1080,
      AutoPickQuality.p480,
    ]);
  });

  test('legacy Auto Pick values seed the first V2 priority', () async {
    FlutterSecureStorage.setMockInitialValues({
      'streaming_auto_pick_source_type': 'webOnly',
      'streaming_auto_pick_quality': 'p1080',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(
      controller.state.autoPickSourcePriority.first,
      AutoPickSourcePriority.web,
    );
    expect(
      controller.state.autoPickQualityPriority.first,
      AutoPickQuality.p1080,
    );
    expect(
      controller.state.autoPickSourcePriority.last,
      AutoPickSourcePriority.yourMedia,
    );
  });

  test(
    'existing V2 source order appends Your Media without reordering',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'streaming_auto_pick_source_priority_v2': 'web,debrid',
      });
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
      );

      await controller.load();

      expect(controller.state.autoPickSourcePriority, const [
        AutoPickSourcePriority.web,
        AutoPickSourcePriority.debrid,
        AutoPickSourcePriority.yourMedia,
      ]);
    },
  );

  test('priority move methods normalize, reorder, and persist', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SettingsPreferencesController(storage);

    await controller.moveAutoPickSourcePriority(AutoPickSourcePriority.web, -1);
    await controller.moveAutoPickQualityPriority(AutoPickQuality.p480, -3);

    expect(
      controller.state.autoPickSourcePriority.first,
      AutoPickSourcePriority.web,
    );
    expect(
      controller.state.autoPickQualityPriority.first,
      AutoPickQuality.p480,
    );

    final restored = SettingsPreferencesController(storage);
    await restored.load();
    expect(
      restored.state.autoPickSourcePriority,
      controller.state.autoPickSourcePriority,
    );
    expect(
      restored.state.autoPickQualityPriority,
      controller.state.autoPickQualityPriority,
    );
  });

  test(
    'Your Media can be promoted and persists without a legacy override',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final controller = SettingsPreferencesController(storage);

      await controller.moveAutoPickSourcePriority(
        AutoPickSourcePriority.yourMedia,
        -2,
      );

      expect(
        controller.state.autoPickSourcePriority.first,
        AutoPickSourcePriority.yourMedia,
      );
      expect(controller.state.autoPickSourceType, AutoPickSourceType.any);

      final restored = SettingsPreferencesController(storage);
      await restored.load();
      expect(
        restored.state.autoPickSourcePriority.first,
        AutoPickSourcePriority.yourMedia,
      );
      expect(
        restored.state.effectiveAutoPickSourcePriority.first,
        AutoPickSourcePriority.yourMedia,
      );
    },
  );

  test('effective priorities honor direct legacy constructor values', () {
    const preferences = SettingsPreferences(
      autoPickSourceType: AutoPickSourceType.webOnly,
      autoPickQuality: AutoPickQuality.p1080,
    );

    expect(
      preferences.effectiveAutoPickSourcePriority.first,
      AutoPickSourcePriority.web,
    );
    expect(
      preferences.effectiveAutoPickQualityPriority.first,
      AutoPickQuality.p1080,
    );
  });

  test(
    'completed legacy installs without a keyboard choice keep device input',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        initialSetupCompletedStorageKey: 'true',
      });
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
      );

      await controller.load();

      expect(controller.state.useBuiltInKeyboard, isFalse);
    },
  );

  test('legacy installs migrate to visible filler indicators', () async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
      'player_auto_skip_intros': 'true',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.showFillerIndicators, isTrue);
  });

  test('reset appearance restores visible filler indicators', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SettingsPreferencesController(storage);

    await controller.setShowFillerIndicators(false);
    await controller.setShowTitleStyle(ShowTitleStyle.text);
    expect(controller.state.showFillerIndicators, isFalse);
    expect(controller.state.showTitleStyle, ShowTitleStyle.text);
    await controller.resetAppearance();
    expect(controller.state.showFillerIndicators, isTrue);
    expect(controller.state.showTitleStyle, ShowTitleStyle.englishLogo);

    final restored = SettingsPreferencesController(storage);
    await restored.load();
    expect(restored.state.showFillerIndicators, isTrue);
    expect(restored.state.showTitleStyle, ShowTitleStyle.englishLogo);
  });

  test('explicit built-in keyboard choice is preserved', () async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.useBuiltInKeyboard, isTrue);
  });

  test('explicit device keyboard choice is preserved', () async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'false',
      initialSetupCompletedStorageKey: 'true',
    });
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.useBuiltInKeyboard, isFalse);
  });

  test(
    'anonymous crash reporting persists only after explicit opt in',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final controller = SettingsPreferencesController(storage);

      expect(controller.state.anonymousCrashReportingEnabled, isFalse);
      await controller.setAnonymousCrashReportingEnabled(true);
      final restored = SettingsPreferencesController(storage);
      await restored.load();

      expect(restored.state.anonymousCrashReportingEnabled, isTrue);
    },
  );

  test('hidden navigation route cannot remain the landing page', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.setDefaultLandingPage(LandingPage.search);
    expect(controller.state.defaultLandingPage, LandingPage.search);
    await controller.setShowSearch(false);

    expect(controller.state.showSearch, isFalse);
    expect(controller.state.defaultLandingPage, LandingPage.home);
    expect(controller.takeInitialLandingRoute(), isNull);
  });

  test('Settings stays visible while Home remains optional', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SettingsPreferencesController(storage);

    await controller.setShowHome(false);
    expect(controller.state.showHome, isFalse);
    expect(controller.state.showSettings, isTrue);
    expect(
      controller.state.settingsEntryPlacement,
      SettingsEntryPlacement.topNavigation,
    );

    await controller.setShowSettings(false);
    expect(controller.state.showSettings, isTrue);

    await controller.setShowHome(true);
    await controller.setShowSettings(false);
    expect(controller.state.showHome, isTrue);
    expect(controller.state.showSettings, isTrue);

    final restored = SettingsPreferencesController(storage);
    await restored.load();
    expect(restored.state.showHome, isTrue);
    expect(restored.state.showSettings, isTrue);
  });

  test('a saved hidden Settings destination is repaired on load', () async {
    FlutterSecureStorage.setMockInitialValues({
      'navigation_show_home': 'false',
      'navigation_show_settings': 'false',
    });
    const storage = FlutterSecureStorage();
    final controller = SettingsPreferencesController(storage);

    await controller.load();

    expect(controller.state.showHome, isFalse);
    expect(controller.state.showSettings, isTrue);
    expect(
      controller.state.isTopNavigationDestinationVisible(
        TopNavigationDestination.settings,
      ),
      isTrue,
    );
    expect(await storage.read(key: 'navigation_show_settings'), 'true');
  });

  test(
    'Settings placement persists and customization reset restores top row',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final controller = SettingsPreferencesController(storage);

      expect(
        controller.state.settingsEntryPlacement,
        SettingsEntryPlacement.topNavigation,
      );
      await controller.setSettingsEntryPlacement(
        SettingsEntryPlacement.profileMenu,
      );
      await controller.setShowWatchTogether(false);
      expect(
        controller.state.settingsEntryPlacement,
        SettingsEntryPlacement.profileMenu,
      );
      expect(controller.state.showSettings, isTrue);
      expect(controller.state.showWatchTogether, isFalse);

      final restored = SettingsPreferencesController(storage);
      await restored.load();
      expect(
        restored.state.settingsEntryPlacement,
        SettingsEntryPlacement.profileMenu,
      );
      expect(restored.state.showWatchTogether, isFalse);

      await restored.resetCustomization();
      expect(
        restored.state.settingsEntryPlacement,
        SettingsEntryPlacement.topNavigation,
      );
      expect(restored.state.showWatchTogether, isTrue);
      final resetRestored = SettingsPreferencesController(storage);
      await resetRestored.load();
      expect(
        resetRestored.state.settingsEntryPlacement,
        SettingsEntryPlacement.topNavigation,
      );
      expect(resetRestored.state.showWatchTogether, isTrue);
    },
  );

  test('navigation bar order is normalized, movable, and persisted', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SettingsPreferencesController(storage);

    await controller.setTopNavigationOrder(const [
      TopNavigationDestination.settings,
      TopNavigationDestination.search,
    ]);
    expect(controller.state.topNavigationOrder, [
      TopNavigationDestination.watchTogether,
      TopNavigationDestination.downloads,
      TopNavigationDestination.settings,
      TopNavigationDestination.search,
      TopNavigationDestination.home,
      TopNavigationDestination.myList,
      TopNavigationDestination.discover,
      TopNavigationDestination.calendar,
    ]);

    await controller.moveTopNavigationDestination(
      TopNavigationDestination.calendar,
      -2,
    );
    expect(
      controller.state.topNavigationOrder.indexOf(
        TopNavigationDestination.calendar,
      ),
      controller.state.topNavigationOrder.length - 3,
    );

    final restored = SettingsPreferencesController(storage);
    await restored.load();
    expect(
      restored.state.topNavigationOrder,
      controller.state.topNavigationOrder,
    );
  });

  test('configured landing page is consumed only once per launch', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
    );
    await controller.setDefaultLandingPage(LandingPage.calendar);

    expect(controller.takeInitialLandingRoute(), '/calendar');
    expect(controller.takeInitialLandingRoute(), isNull);
  });

  test('one failed storage read does not discard other preferences', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async {
        if (key == 'appearance_caption_text_size') {
          throw StateError('one encrypted value is unavailable');
        }
        return const {
          'streaming_web_enabled': 'false',
          'audio_navigation_sounds': 'false',
          'navigation_default_landing_page': 'search',
        }[key];
      },
    );

    await controller.load();

    expect(controller.state.captionTextSize, 34);
    expect(controller.state.webStreamsEnabled, isFalse);
    expect(controller.state.navigationSounds, isFalse);
    expect(controller.state.defaultLandingPage, LandingPage.search);
  });

  test(
    'anonymous live count fails closed when its storage read fails',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
        readValue: (key) async {
          if (key == 'privacy_anonymous_usage_count') {
            throw StateError('encrypted opt-out is temporarily unavailable');
          }
          return null;
        },
      );

      await controller.load();

      expect(controller.state.loaded, isTrue);
      expect(controller.state.anonymousUsageCountEnabled, isFalse);
    },
  );

  test(
    'startup load is single-flight and preserves an early mutation',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final gate = Completer<void>();
      var reads = 0;
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
        readValue: (key) async {
          reads++;
          await gate.future;
          return const {
            'streaming_web_enabled': 'false',
            'audio_navigation_sounds': 'false',
          }[key];
        },
      );

      final firstLoad = controller.load();
      final duplicateLoad = controller.load();
      await controller.setWebStreamsEnabled(true);
      gate.complete();
      await Future.wait([firstLoad, duplicateLoad]);

      expect(reads, 58, reason: 'duplicate startup loads must be coalesced');
      expect(controller.state.webStreamsEnabled, isTrue);
      expect(controller.state.navigationSounds, isFalse);
    },
  );

  test(
    'serializes rapid writes so the newest preference persists last',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final firstWriteGate = Completer<void>();
      final writes = <String>[];
      final controller = SettingsPreferencesController(
        const FlutterSecureStorage(),
        writeValue: (key, value) async {
          writes.add(value);
          if (value == '0.8') await firstWriteGate.future;
        },
      );

      final first = controller.setInterfaceScale(.8);
      await Future<void>.delayed(Duration.zero);
      final second = controller.setInterfaceScale(1.2);
      await Future<void>.delayed(Duration.zero);

      expect(writes, ['0.8']);
      expect(controller.state.interfaceScale, 1.2);
      firstWriteGate.complete();
      await Future.wait([first, second]);
      expect(writes, ['0.8', '1.2']);
    },
  );

  test('tracker threshold only completes a whole episode when crossed', () {
    const duration = Duration(minutes: 24);

    expect(
      trackerUpdateThresholdReached(
        position: const Duration(minutes: 11),
        duration: duration,
        threshold: TrackerUpdateThreshold.halfway,
      ),
      isFalse,
    );
    expect(
      trackerUpdateThresholdReached(
        position: const Duration(minutes: 12),
        duration: duration,
        threshold: TrackerUpdateThreshold.halfway,
      ),
      isTrue,
    );
    expect(
      trackerUpdateThresholdReached(
        position: duration,
        duration: duration,
        threshold: TrackerUpdateThreshold.episodeEnd,
      ),
      isFalse,
    );
    expect(
      trackerUpdateThresholdReached(
        position: duration,
        duration: duration,
        threshold: TrackerUpdateThreshold.episodeEnd,
        playbackEnded: true,
      ),
      isTrue,
    );
  });
}
