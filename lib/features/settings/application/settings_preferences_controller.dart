import 'dart:async';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _debridProviderKey = 'settings_selected_debrid_provider';
const _trackingProviderKey = 'settings_selected_tracking_provider';
const _captionTextColorKey = 'appearance_caption_text_color';
const _captionBackgroundColorKey = 'appearance_caption_background_color';
const _captionTextSizeKey = 'appearance_caption_text_size';
const _thumbnailScaleKey = 'appearance_thumbnail_scale';
const _interfaceScaleKey = 'appearance_interface_scale';
const _contentDensityKey = 'appearance_content_density';
const _seekBackSecondsKey = 'player_seek_back_seconds';
const _seekForwardSecondsKey = 'player_seek_forward_seconds';
const _builtInKeyboardKey = 'input_use_built_in_keyboard';
const _debridStreamsEnabledKey = 'streaming_debrid_enabled';
const _webStreamsEnabledKey = 'streaming_web_enabled';
const _autoSkipIntrosKey = 'player_auto_skip_intros';
const _autoSkipOutrosKey = 'player_auto_skip_outros';
const _showFillerIndicatorsKey = 'player_show_filler_indicators';
const _homeLayoutKey = 'appearance_home_layout';
const _showSearchKey = 'navigation_show_search';
const _showHomeKey = 'navigation_show_home';
const _showMyListKey = 'navigation_show_my_list';
const _showDiscoverKey = 'navigation_show_discover';
const _showCalendarKey = 'navigation_show_calendar';
const _showSettingsKey = 'navigation_show_settings';
const _topNavigationOrderKey = 'navigation_top_bar_order';
const _settingsEntryPlacementKey = 'navigation_settings_entry_placement';
const _navigationChromeSizeKey = 'navigation_chrome_size';
const _showHeroKey = 'home_show_featured_hero';
const _showPosterMetadataKey = 'home_show_poster_metadata';
const _showCardSubtitlesKey = 'home_show_card_subtitles';
const _trackerUpdateThresholdKey = 'tracking_episode_update_threshold';
const _interfaceModeKey = 'appearance_interface_mode';
const _navigationSoundsKey = 'audio_navigation_sounds';
const _clickSoundsKey = 'audio_click_sounds';
const _defaultLandingPageKey = 'navigation_default_landing_page';
const _preferredPlayerKey = 'player_preferred_engine';
const _preferredAudioKey = 'player_preferred_audio';
const _anonymousCrashReportingKey = 'privacy_anonymous_crash_reporting';
const _anonymousUsageCountKey = 'privacy_anonymous_usage_count';
const _debridStreamSortKey = 'streaming_debrid_sort';
const _streamSourcePriorityKey = 'streaming_source_priority';
const _webStreamQualityKey = 'streaming_web_quality_preference';
const _autoPickSourceEnabledKey = 'streaming_auto_pick_source_enabled';
const _autoPickSourceTypeKey = 'streaming_auto_pick_source_type';
const _autoPickQualityKey = 'streaming_auto_pick_quality';
const _autoPickAudioKey = 'streaming_auto_pick_audio';
const _showWatchTogetherKey = 'navigation_show_watch_together';
const _autoPickSourcePriorityKey = 'streaming_auto_pick_source_priority_v2';
const _autoPickQualityPriorityKey = 'streaming_auto_pick_quality_priority_v2';
const _directTorrentStreamingEnabledKey = 'streaming_direct_torrent_enabled';
const _externalPlayerEnabledKey = 'player_external_handoff_enabled';
const _externalPlayerPackageKey = 'player_external_default_package';
const _externalPlayerLabelKey = 'player_external_default_label';
const _showDownloadsKey = 'navigation_show_downloads';
const _showTitleStyleKey = 'appearance_show_title_style';
const _subEpisodeNotificationsKey = 'notifications_calendar_sub_releases';
const _dubEpisodeNotificationsKey = 'notifications_calendar_dub_releases';
const _offlineDownloadsEnabledKey = 'streaming_offline_downloads_enabled';

/// AniList and MyAnimeList only accept a whole number of completed episodes.
/// This setting controls how much of the current episode must be watched before
/// TetoTV records that episode number on the connected trackers.
enum TrackerUpdateThreshold {
  halfway,
  threeQuarters,
  nearlyFinished,
  episodeEnd,
}

extension TrackerUpdateThresholdLabel on TrackerUpdateThreshold {
  String get displayName => switch (this) {
    TrackerUpdateThreshold.halfway => 'After 50%',
    TrackerUpdateThreshold.threeQuarters => 'After 75%',
    TrackerUpdateThreshold.nearlyFinished => 'After 90%',
    TrackerUpdateThreshold.episodeEnd => 'At episode end',
  };

  String get description => switch (this) {
    TrackerUpdateThreshold.halfway =>
      'Mark the episode watched once half of it has played.',
    TrackerUpdateThreshold.threeQuarters =>
      'Mark the episode watched after three quarters has played.',
    TrackerUpdateThreshold.nearlyFinished =>
      'Mark the episode watched near the end (recommended).',
    TrackerUpdateThreshold.episodeEnd =>
      'Only mark the episode watched after playback finishes.',
  };

  double get watchedFraction => switch (this) {
    TrackerUpdateThreshold.halfway => .5,
    TrackerUpdateThreshold.threeQuarters => .75,
    TrackerUpdateThreshold.nearlyFinished => .9,
    TrackerUpdateThreshold.episodeEnd => 1,
  };
}

bool trackerUpdateThresholdReached({
  required Duration position,
  required Duration duration,
  required TrackerUpdateThreshold threshold,
  bool playbackEnded = false,
}) {
  if (playbackEnded) return true;
  if (duration <= Duration.zero || position < Duration.zero) return false;
  if (threshold == TrackerUpdateThreshold.episodeEnd) return false;
  return position.inMilliseconds / duration.inMilliseconds >=
      threshold.watchedFraction;
}

enum HomeLayout { cinematic, compact }

extension HomeLayoutLabel on HomeLayout {
  String get displayName => switch (this) {
    HomeLayout.cinematic => 'Cinematic',
    HomeLayout.compact => 'Compact',
  };
}

/// Controls whether TetoTV uses its device-aware canvas or always uses the
/// 10-foot TV canvas.
///
/// [InterfaceMode.phone] is retained only so older persisted values can be
/// decoded and migrated. Classic Layout is no longer user-selectable; phones
/// continue to receive the handheld layout through [InterfaceMode.automatic].
enum InterfaceMode { automatic, television, phone }

const supportedInterfaceModes = <InterfaceMode>[
  InterfaceMode.automatic,
  InterfaceMode.television,
];

InterfaceMode migrateRetiredInterfaceMode(InterfaceMode mode) =>
    mode == InterfaceMode.phone ? InterfaceMode.automatic : mode;

extension InterfaceModeLabel on InterfaceMode {
  String get displayName => switch (this) {
    InterfaceMode.automatic => 'Automatic',
    InterfaceMode.television => 'Modern Layout',
    InterfaceMode.phone => 'Classic Layout (retired)',
  };
}

/// Scales only the permanent TV navigation rail and its brand mark.
///
/// This stays separate from [interfaceScale] so people can make the chrome
/// quieter without shrinking text, cards, dialogs, or playback controls.
enum NavigationChromeSize { small, medium, large }

extension NavigationChromeSizeLabel on NavigationChromeSize {
  String get displayName => switch (this) {
    NavigationChromeSize.small => 'Small',
    NavigationChromeSize.medium => 'Medium',
    NavigationChromeSize.large => 'Large',
  };
}

enum LandingPage { home, search, myList, discover, calendar }

extension LandingPageLabel on LandingPage {
  String get displayName => switch (this) {
    LandingPage.home => 'Home',
    LandingPage.search => 'Search',
    LandingPage.myList => 'My List',
    LandingPage.discover => 'Discover',
    LandingPage.calendar => 'Calendar',
  };

  String get route => switch (this) {
    LandingPage.home => '/',
    LandingPage.search => '/search',
    LandingPage.myList => '/my-list',
    LandingPage.discover => '/discover',
    LandingPage.calendar => '/calendar',
  };
}

/// Destinations that can be shown and ordered in the shared top navigation.
enum TopNavigationDestination {
  search,
  home,
  myList,
  discover,
  calendar,
  settings,
  // Keep new destinations append-only so persisted enum assumptions remain
  // stable. The separately persisted order still places this before Settings.
  watchTogether,
  downloads,
}

/// Controls the title shown on featured, show-detail, and episode experiences.
/// Catalog cards keep their existing text treatment in either mode.
enum ShowTitleStyle { englishLogo, text }

extension ShowTitleStyleLabel on ShowTitleStyle {
  String get displayName => switch (this) {
    ShowTitleStyle.englishLogo => 'Title logo',
    ShowTitleStyle.text => 'Text title',
  };
}

/// Chooses which always-reachable navigation surface owns Settings.
enum SettingsEntryPlacement { topNavigation, profileMenu }

extension SettingsEntryPlacementLabel on SettingsEntryPlacement {
  String get displayName => switch (this) {
    SettingsEntryPlacement.topNavigation => 'Top row',
    SettingsEntryPlacement.profileMenu => 'Profile menu',
  };
}

const defaultTopNavigationOrder = <TopNavigationDestination>[
  TopNavigationDestination.home,
  TopNavigationDestination.search,
  TopNavigationDestination.myList,
  TopNavigationDestination.discover,
  TopNavigationDestination.calendar,
  TopNavigationDestination.watchTogether,
  TopNavigationDestination.downloads,
  TopNavigationDestination.settings,
];

extension TopNavigationDestinationLabel on TopNavigationDestination {
  String get displayName => switch (this) {
    TopNavigationDestination.search => 'Search',
    TopNavigationDestination.home => 'Home',
    TopNavigationDestination.myList => 'My List',
    TopNavigationDestination.discover => 'Discover',
    TopNavigationDestination.calendar => 'Calendar',
    TopNavigationDestination.settings => 'Settings',
    TopNavigationDestination.watchTogether => 'Watch Party',
    TopNavigationDestination.downloads => 'Downloads',
  };
}

enum ContentDensity { compact, standard, comfortable }

extension ContentDensityLabel on ContentDensity {
  String get displayName => switch (this) {
    ContentDensity.compact => 'Compact',
    ContentDensity.standard => 'Standard',
    ContentDensity.comfortable => 'Comfortable',
  };

  double get spacingScale => switch (this) {
    ContentDensity.compact => .88,
    ContentDensity.standard => 1,
    ContentDensity.comfortable => 1.12,
  };
}

enum PreferredPlayer { mpv, external }

extension PreferredPlayerLabel on PreferredPlayer {
  String get displayName => switch (this) {
    PreferredPlayer.mpv => 'MPV',
    PreferredPlayer.external => 'External player',
  };

  String get description => switch (this) {
    PreferredPlayer.mpv => 'TetoTV built-in player',
    PreferredPlayer.external => 'A selected app installed on this device',
  };
}

/// Legacy single-value Auto Pick source constraint.
///
/// New code should use [AutoPickSourcePriority] and
/// [SettingsPreferences.autoPickSourcePriority]. This enum remains readable so
/// an existing install can be migrated without losing its first choice.
enum AutoPickSourceType { any, debridOnly, webOnly }

extension AutoPickSourceTypeLabel on AutoPickSourceType {
  String get displayName => switch (this) {
    AutoPickSourceType.any => 'Any',
    AutoPickSourceType.debridOnly => 'Debrid only',
    AutoPickSourceType.webOnly => 'Web only',
  };

  String get description => switch (this) {
    AutoPickSourceType.any => 'Use the preferred source order',
    AutoPickSourceType.debridOnly => 'Automatically select cached releases',
    AutoPickSourceType.webOnly => 'Automatically select Web streams',
  };
}

/// A source class in the ordered Auto Pick preference list.
enum AutoPickSourcePriority {
  debrid,
  web,

  /// Append-only: persisted V2 priorities are stored by enum name and older
  /// installs must keep their existing Debrid/Web order during migration.
  yourMedia,
}

extension AutoPickSourcePriorityLabel on AutoPickSourcePriority {
  String get displayName => switch (this) {
    AutoPickSourcePriority.debrid => 'Debrid',
    AutoPickSourcePriority.web => 'Web',
    AutoPickSourcePriority.yourMedia => 'Local library',
  };

  String get description => switch (this) {
    AutoPickSourcePriority.debrid => 'Cached torrent and debrid releases',
    AutoPickSourcePriority.web => 'Marketplace Web streams',
    AutoPickSourcePriority.yourMedia =>
      'Exact episode matches from local, Jellyfin, or Plex libraries',
  };
}

/// Exact resolution required for automatic source selection.
/// [any] keeps quality as a ranking preference instead of a hard filter.
enum AutoPickQuality { any, p2160, p1080, p720, p480 }

extension AutoPickQualityLabel on AutoPickQuality {
  String get displayName => switch (this) {
    AutoPickQuality.any => 'Any',
    AutoPickQuality.p2160 => '2160p (4K)',
    AutoPickQuality.p1080 => '1080p',
    AutoPickQuality.p720 => '720p',
    AutoPickQuality.p480 => '480p',
  };

  String get description => switch (this) {
    AutoPickQuality.any => 'Allow every available resolution',
    AutoPickQuality.p2160 => 'Require an exact 2160p stream',
    AutoPickQuality.p1080 => 'Require an exact 1080p stream',
    AutoPickQuality.p720 => 'Require an exact 720p stream',
    AutoPickQuality.p480 => 'Require an exact 480p stream',
  };

  int? get targetHeight => switch (this) {
    AutoPickQuality.any => null,
    AutoPickQuality.p2160 => 2160,
    AutoPickQuality.p1080 => 1080,
    AutoPickQuality.p720 => 720,
    AutoPickQuality.p480 => 480,
  };
}

const defaultAutoPickSourcePriority = <AutoPickSourcePriority>[
  AutoPickSourcePriority.debrid,
  AutoPickSourcePriority.web,
  AutoPickSourcePriority.yourMedia,
];

const defaultAutoPickQualityPriority = <AutoPickQuality>[
  AutoPickQuality.p2160,
  AutoPickQuality.p1080,
  AutoPickQuality.p720,
  AutoPickQuality.p480,
];

/// Exact audio class required for automatic source selection.
enum AutoPickAudio { any, dubOnly, subOnly }

extension AutoPickAudioLabel on AutoPickAudio {
  String get displayName => switch (this) {
    AutoPickAudio.any => 'Any',
    AutoPickAudio.dubOnly => 'Dub only',
    AutoPickAudio.subOnly => 'Sub only',
  };

  String get description => switch (this) {
    AutoPickAudio.any => 'Allow dubbed or subtitled streams',
    AutoPickAudio.dubOnly => 'Require English audio support',
    AutoPickAudio.subOnly => 'Require original audio support',
  };
}

class SettingsPreferences {
  const SettingsPreferences({
    this.debridProvider = DebridService.realDebrid,
    this.trackingProvider = TrackingProvider.anilist,
    this.captionTextColor = 0xFFFFFFFF,
    this.captionBackgroundColor = 0x00000000,
    this.captionTextSize = 34,
    this.thumbnailScale = 1,
    this.interfaceScale = 1,
    this.contentDensity = ContentDensity.standard,
    this.seekBackSeconds = 10,
    this.seekForwardSeconds = 10,
    // Fresh installs start with TetoTV's D-pad keyboard. First-time setup asks
    // explicitly, and existing installations keep their saved/migrated choice.
    this.useBuiltInKeyboard = true,
    this.debridStreamsEnabled = true,
    this.webStreamsEnabled = true,
    this.directTorrentStreamingEnabled = false,
    this.autoSkipIntros = false,
    this.autoSkipOutros = false,
    this.showFillerIndicators = true,
    this.homeLayout = HomeLayout.cinematic,
    this.showTitleStyle = ShowTitleStyle.englishLogo,
    this.showSearch = true,
    this.showHome = true,
    this.showMyList = true,
    this.showDiscover = true,
    this.showCalendar = true,
    this.showWatchTogether = true,
    this.showDownloads = true,
    this.offlineDownloadsEnabled = true,
    this.showSettings = true,
    this.topNavigationOrder = defaultTopNavigationOrder,
    this.settingsEntryPlacement = SettingsEntryPlacement.topNavigation,
    this.navigationChromeSize = NavigationChromeSize.medium,
    this.showHero = true,
    this.showPosterMetadata = true,
    this.showCardSubtitles = true,
    this.trackerUpdateThreshold = TrackerUpdateThreshold.nearlyFinished,
    this.interfaceMode = InterfaceMode.automatic,
    this.navigationSounds = true,
    this.clickSounds = true,
    this.defaultLandingPage = LandingPage.home,
    this.preferredPlayer = PreferredPlayer.mpv,
    this.preferredAudio = PlaybackAudioPreference.dub,
    this.debridStreamSort = DebridStreamSort.bestQuality,
    this.streamSourcePriority = StreamSourcePriority.debridFirst,
    this.webStreamQuality = WebStreamQualityPreference.bestAvailable,
    this.autoPickSourceEnabled = false,
    this.autoPickSourcePriority = defaultAutoPickSourcePriority,
    this.autoPickQualityPriority = defaultAutoPickQualityPriority,
    // Retained as migration/compatibility mirrors. Priority lists above are
    // the canonical Auto Pick settings.
    this.autoPickSourceType = AutoPickSourceType.any,
    this.autoPickQuality = AutoPickQuality.any,
    this.autoPickAudio = AutoPickAudio.any,
    this.anonymousCrashReportingEnabled = false,
    // Beta builds contribute to the aggregate live app count unless the user
    // opts out. Public builds never start the reporter, regardless of this
    // stored preference.
    this.anonymousUsageCountEnabled = true,
    // External handoff gives another installed app the selected media URI.
    // Keep this explicit and off on every fresh installation.
    this.externalPlayerEnabled = false,
    this.selectedExternalPlayerPackage,
    this.selectedExternalPlayerLabel,
    // New-episode alerts are opt-in so upgrading cannot unexpectedly request
    // Android notification permission. Manual Calendar reminders are
    // unaffected. Dub stays separately configurable but is only acted on when
    // an upstream feed explicitly verifies a dub release timestamp.
    this.subEpisodeNotificationsEnabled = false,
    this.dubEpisodeNotificationsEnabled = false,
    this.loaded = false,
  });

  final DebridService debridProvider;
  final TrackingProvider trackingProvider;
  final int captionTextColor;
  final int captionBackgroundColor;
  final double captionTextSize;
  final double thumbnailScale;
  final double interfaceScale;
  final ContentDensity contentDensity;
  final int seekBackSeconds;
  final int seekForwardSeconds;
  final bool useBuiltInKeyboard;
  final bool debridStreamsEnabled;
  final bool webStreamsEnabled;
  final bool directTorrentStreamingEnabled;
  final bool autoSkipIntros;
  final bool autoSkipOutros;
  final bool showFillerIndicators;
  final HomeLayout homeLayout;
  final ShowTitleStyle showTitleStyle;
  final bool showSearch;
  final bool showHome;
  final bool showMyList;
  final bool showDiscover;
  final bool showCalendar;
  final bool showWatchTogether;
  final bool showDownloads;
  final bool offlineDownloadsEnabled;
  final bool showSettings;
  final List<TopNavigationDestination> topNavigationOrder;
  final SettingsEntryPlacement settingsEntryPlacement;
  final NavigationChromeSize navigationChromeSize;
  final bool showHero;
  final bool showPosterMetadata;
  final bool showCardSubtitles;
  final TrackerUpdateThreshold trackerUpdateThreshold;
  final InterfaceMode interfaceMode;
  final bool navigationSounds;
  final bool clickSounds;
  final LandingPage defaultLandingPage;
  final PreferredPlayer preferredPlayer;
  final PlaybackAudioPreference preferredAudio;
  final DebridStreamSort debridStreamSort;
  final StreamSourcePriority streamSourcePriority;
  final WebStreamQualityPreference webStreamQuality;
  final bool autoPickSourceEnabled;
  final List<AutoPickSourcePriority> autoPickSourcePriority;
  final List<AutoPickQuality> autoPickQualityPriority;
  final AutoPickSourceType autoPickSourceType;
  final AutoPickQuality autoPickQuality;
  final AutoPickAudio autoPickAudio;
  final bool anonymousCrashReportingEnabled;
  final bool anonymousUsageCountEnabled;
  final bool externalPlayerEnabled;
  final String? selectedExternalPlayerPackage;
  final String? selectedExternalPlayerLabel;
  final bool subEpisodeNotificationsEnabled;
  final bool dubEpisodeNotificationsEnabled;
  final bool loaded;

  /// Canonical source order with a legacy constructor value promoted to the
  /// first slot. This keeps direct test/setup objects from older callers
  /// working while persisted V2 settings use [autoPickSourcePriority].
  List<AutoPickSourcePriority> get effectiveAutoPickSourcePriority {
    final legacyFirst = switch (autoPickSourceType) {
      AutoPickSourceType.debridOnly => AutoPickSourcePriority.debrid,
      AutoPickSourceType.webOnly => AutoPickSourcePriority.web,
      AutoPickSourceType.any => null,
    };
    final priority = [...autoPickSourcePriority];
    if (legacyFirst != null) priority.insert(0, legacyFirst);
    return _normalizeAutoPickSourcePriority(priority);
  }

  /// Canonical quality order with a non-`any` legacy constructor value first.
  List<AutoPickQuality> get effectiveAutoPickQualityPriority =>
      _normalizeAutoPickQualityPriority([
        if (autoPickQuality != AutoPickQuality.any) autoPickQuality,
        ...autoPickQualityPriority,
      ]);

  SettingsPreferences copyWith({
    DebridService? debridProvider,
    TrackingProvider? trackingProvider,
    int? captionTextColor,
    int? captionBackgroundColor,
    double? captionTextSize,
    double? thumbnailScale,
    double? interfaceScale,
    ContentDensity? contentDensity,
    int? seekBackSeconds,
    int? seekForwardSeconds,
    bool? useBuiltInKeyboard,
    bool? debridStreamsEnabled,
    bool? webStreamsEnabled,
    bool? directTorrentStreamingEnabled,
    bool? autoSkipIntros,
    bool? autoSkipOutros,
    bool? showFillerIndicators,
    HomeLayout? homeLayout,
    ShowTitleStyle? showTitleStyle,
    bool? showSearch,
    bool? showHome,
    bool? showMyList,
    bool? showDiscover,
    bool? showCalendar,
    bool? showWatchTogether,
    bool? showDownloads,
    bool? offlineDownloadsEnabled,
    bool? showSettings,
    List<TopNavigationDestination>? topNavigationOrder,
    SettingsEntryPlacement? settingsEntryPlacement,
    NavigationChromeSize? navigationChromeSize,
    bool? showHero,
    bool? showPosterMetadata,
    bool? showCardSubtitles,
    TrackerUpdateThreshold? trackerUpdateThreshold,
    InterfaceMode? interfaceMode,
    bool? navigationSounds,
    bool? clickSounds,
    LandingPage? defaultLandingPage,
    PreferredPlayer? preferredPlayer,
    PlaybackAudioPreference? preferredAudio,
    DebridStreamSort? debridStreamSort,
    StreamSourcePriority? streamSourcePriority,
    WebStreamQualityPreference? webStreamQuality,
    bool? autoPickSourceEnabled,
    List<AutoPickSourcePriority>? autoPickSourcePriority,
    List<AutoPickQuality>? autoPickQualityPriority,
    AutoPickSourceType? autoPickSourceType,
    AutoPickQuality? autoPickQuality,
    AutoPickAudio? autoPickAudio,
    bool? anonymousCrashReportingEnabled,
    bool? anonymousUsageCountEnabled,
    bool? externalPlayerEnabled,
    String? selectedExternalPlayerPackage,
    String? selectedExternalPlayerLabel,
    bool clearSelectedExternalPlayer = false,
    bool? subEpisodeNotificationsEnabled,
    bool? dubEpisodeNotificationsEnabled,
    bool? loaded,
  }) => SettingsPreferences(
    debridProvider: debridProvider ?? this.debridProvider,
    trackingProvider: trackingProvider ?? this.trackingProvider,
    captionTextColor: captionTextColor ?? this.captionTextColor,
    captionBackgroundColor:
        captionBackgroundColor ?? this.captionBackgroundColor,
    captionTextSize: captionTextSize ?? this.captionTextSize,
    thumbnailScale: thumbnailScale ?? this.thumbnailScale,
    interfaceScale: interfaceScale ?? this.interfaceScale,
    contentDensity: contentDensity ?? this.contentDensity,
    seekBackSeconds: seekBackSeconds ?? this.seekBackSeconds,
    seekForwardSeconds: seekForwardSeconds ?? this.seekForwardSeconds,
    useBuiltInKeyboard: useBuiltInKeyboard ?? this.useBuiltInKeyboard,
    debridStreamsEnabled: debridStreamsEnabled ?? this.debridStreamsEnabled,
    webStreamsEnabled: webStreamsEnabled ?? this.webStreamsEnabled,
    directTorrentStreamingEnabled:
        directTorrentStreamingEnabled ?? this.directTorrentStreamingEnabled,
    autoSkipIntros: autoSkipIntros ?? this.autoSkipIntros,
    autoSkipOutros: autoSkipOutros ?? this.autoSkipOutros,
    showFillerIndicators: showFillerIndicators ?? this.showFillerIndicators,
    homeLayout: homeLayout ?? this.homeLayout,
    showTitleStyle: showTitleStyle ?? this.showTitleStyle,
    showSearch: showSearch ?? this.showSearch,
    showHome: showHome ?? this.showHome,
    showMyList: showMyList ?? this.showMyList,
    showDiscover: showDiscover ?? this.showDiscover,
    showCalendar: showCalendar ?? this.showCalendar,
    showWatchTogether: showWatchTogether ?? this.showWatchTogether,
    showDownloads: showDownloads ?? this.showDownloads,
    offlineDownloadsEnabled:
        offlineDownloadsEnabled ?? this.offlineDownloadsEnabled,
    showSettings: showSettings ?? this.showSettings,
    topNavigationOrder: topNavigationOrder ?? this.topNavigationOrder,
    settingsEntryPlacement:
        settingsEntryPlacement ?? this.settingsEntryPlacement,
    navigationChromeSize: navigationChromeSize ?? this.navigationChromeSize,
    showHero: showHero ?? this.showHero,
    showPosterMetadata: showPosterMetadata ?? this.showPosterMetadata,
    showCardSubtitles: showCardSubtitles ?? this.showCardSubtitles,
    trackerUpdateThreshold:
        trackerUpdateThreshold ?? this.trackerUpdateThreshold,
    interfaceMode: interfaceMode ?? this.interfaceMode,
    navigationSounds: navigationSounds ?? this.navigationSounds,
    clickSounds: clickSounds ?? this.clickSounds,
    defaultLandingPage: defaultLandingPage ?? this.defaultLandingPage,
    preferredPlayer: preferredPlayer ?? this.preferredPlayer,
    preferredAudio: preferredAudio ?? this.preferredAudio,
    debridStreamSort: debridStreamSort ?? this.debridStreamSort,
    streamSourcePriority: streamSourcePriority ?? this.streamSourcePriority,
    webStreamQuality: webStreamQuality ?? this.webStreamQuality,
    autoPickSourceEnabled: autoPickSourceEnabled ?? this.autoPickSourceEnabled,
    autoPickSourcePriority:
        autoPickSourcePriority ?? this.autoPickSourcePriority,
    autoPickQualityPriority:
        autoPickQualityPriority ?? this.autoPickQualityPriority,
    autoPickSourceType: autoPickSourceType ?? this.autoPickSourceType,
    autoPickQuality: autoPickQuality ?? this.autoPickQuality,
    autoPickAudio: autoPickAudio ?? this.autoPickAudio,
    anonymousCrashReportingEnabled:
        anonymousCrashReportingEnabled ?? this.anonymousCrashReportingEnabled,
    anonymousUsageCountEnabled:
        anonymousUsageCountEnabled ?? this.anonymousUsageCountEnabled,
    externalPlayerEnabled: externalPlayerEnabled ?? this.externalPlayerEnabled,
    selectedExternalPlayerPackage: clearSelectedExternalPlayer
        ? null
        : selectedExternalPlayerPackage ?? this.selectedExternalPlayerPackage,
    selectedExternalPlayerLabel: clearSelectedExternalPlayer
        ? null
        : selectedExternalPlayerLabel ?? this.selectedExternalPlayerLabel,
    subEpisodeNotificationsEnabled:
        subEpisodeNotificationsEnabled ?? this.subEpisodeNotificationsEnabled,
    dubEpisodeNotificationsEnabled:
        dubEpisodeNotificationsEnabled ?? this.dubEpisodeNotificationsEnabled,
    loaded: loaded ?? this.loaded,
  );

  bool isTopNavigationDestinationVisible(
    TopNavigationDestination destination,
  ) => switch (destination) {
    TopNavigationDestination.search => showSearch,
    TopNavigationDestination.home => showHome,
    TopNavigationDestination.myList => showMyList,
    TopNavigationDestination.discover => showDiscover,
    TopNavigationDestination.calendar => showCalendar,
    TopNavigationDestination.watchTogether => showWatchTogether,
    TopNavigationDestination.downloads =>
      offlineDownloadsEnabled && showDownloads,
    // Settings is the permanent recovery path for navigation customization.
    TopNavigationDestination.settings => true,
  };

  /// Settings is always available so every other destination can be hidden.
  bool canHideTopNavigationDestination(TopNavigationDestination destination) {
    return switch (destination) {
      TopNavigationDestination.settings => false,
      _ => true,
    };
  }
}

final settingsPreferencesProvider =
    StateNotifierProvider<SettingsPreferencesController, SettingsPreferences>((
      ref,
    ) {
      final controller = SettingsPreferencesController(
        ref.watch(secureStorageProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

final class SettingsPreferencesImportSnapshot {
  const SettingsPreferencesImportSnapshot._(this.state, this._values);

  final SettingsPreferences state;
  final Map<String, String?> _values;
}

final class SettingsPreferencesRollbackException implements Exception {
  const SettingsPreferencesRollbackException();

  @override
  String toString() => 'Setup preference rollback failed.';
}

final _strictPreferencePersistenceZoneKey = Object();

const _phoneSetupPreferenceKeys = [
  _preferredAudioKey,
  _builtInKeyboardKey,
  _autoSkipIntrosKey,
  _autoSkipOutrosKey,
  _homeLayoutKey,
  _showHeroKey,
  _showPosterMetadataKey,
  _showMyListKey,
  _showDiscoverKey,
  _showCalendarKey,
  _showWatchTogetherKey,
  _showDownloadsKey,
  _anonymousCrashReportingKey,
  _anonymousUsageCountKey,
  _trackingProviderKey,
  _debridProviderKey,
  _interfaceModeKey,
];

class SettingsPreferencesController extends StateNotifier<SettingsPreferences> {
  SettingsPreferencesController(
    this._storage, {
    this.readValue,
    this.writeValue,
    this.deleteValue,
  }) : super(const SettingsPreferences());

  final FlutterSecureStorage _storage;
  final Future<String?> Function(String key)? readValue;
  final Future<void> Function(String key, String value)? writeValue;
  final Future<void> Function(String key)? deleteValue;
  bool _initialLandingPageConsumed = false;
  Future<void>? _loadFuture;
  bool _initialLoadComplete = false;
  int _revision = 0;
  final Map<String, int> _keyRevisions = {};
  final Set<String> _preloadMutations = {};
  Future<void> _storageTail = Future<void>.value();

  /// Returns the configured non-Home route once per app process. This avoids
  /// redirecting again when the user intentionally navigates back to Home.
  String? takeInitialLandingRoute() {
    if (_initialLandingPageConsumed) return null;
    _initialLandingPageConsumed = true;
    final route = state.defaultLandingPage.route;
    return route == '/' ? null : route;
  }

  /// Coalesces simultaneous startup loads, restores each preference
  /// independently, and preserves any user choice made before encrypted
  /// storage finishes responding.
  Future<void> load() => _loadFuture ??= _load().whenComplete(() {
    _loadFuture = null;
  });

  /// Makes storage errors observable to transactional import callers while
  /// preserving the app's normal best-effort preference behavior elsewhere.
  Future<T> runWithStrictPersistence<T>(Future<T> Function() operation) {
    return runZoned(
      operation,
      zoneValues: {_strictPreferencePersistenceZoneKey: true},
    );
  }

  Future<SettingsPreferencesImportSnapshot> snapshotForImport() async {
    await _storageTail;
    final values = <String, String?>{};
    for (final key in _phoneSetupPreferenceKeys) {
      values[key] = await (readValue?.call(key) ?? _storage.read(key: key));
    }
    return SettingsPreferencesImportSnapshot._(
      state,
      Map<String, String?>.unmodifiable(values),
    );
  }

  Future<void> restoreImportSnapshot(
    SettingsPreferencesImportSnapshot snapshot,
  ) async {
    try {
      await runWithStrictPersistence(
        () => _enqueueStorage(() async {
          Object? firstError;
          StackTrace? firstStackTrace;
          for (final key in _phoneSetupPreferenceKeys.reversed) {
            try {
              final value = snapshot._values[key];
              if (value == null) {
                await _delete(key);
              } else {
                await _write(key, value);
              }
            } catch (error, stackTrace) {
              firstError ??= error;
              firstStackTrace ??= stackTrace;
            }
          }
          if (firstError != null) {
            Error.throwWithStackTrace(
              const SettingsPreferencesRollbackException(),
              firstStackTrace ?? StackTrace.current,
            );
          }
        }),
      );
    } finally {
      _markMutated(_phoneSetupPreferenceKeys);
      if (mounted) state = snapshot.state;
    }
  }

  Future<void> _load() async {
    final revisionAtStart = _revision;
    final wasInitialLoad = !_initialLoadComplete;
    final values = await Future.wait<Object?>([
      _safeRead(_debridProviderKey),
      _safeRead(_trackingProviderKey),
      _safeRead(_captionTextColorKey),
      _safeRead(_captionBackgroundColorKey),
      _safeRead(_captionTextSizeKey),
      _safeRead(_thumbnailScaleKey),
      _safeRead(_interfaceScaleKey),
      _safeRead(_contentDensityKey),
      _safeRead(_seekBackSecondsKey),
      _safeRead(_seekForwardSecondsKey),
      _safeRead(_builtInKeyboardKey),
      _safeRead(_debridStreamsEnabledKey),
      _safeRead(_webStreamsEnabledKey),
      _safeRead(_autoSkipIntrosKey),
      _safeRead(_autoSkipOutrosKey),
      _safeRead(_homeLayoutKey),
      _safeRead(_showSearchKey),
      _safeRead(_showMyListKey),
      _safeRead(_showDiscoverKey),
      _safeRead(_showCalendarKey),
      _safeRead(_showHeroKey),
      _safeRead(_showPosterMetadataKey),
      _safeRead(_showCardSubtitlesKey),
      _safeRead(_trackerUpdateThresholdKey),
      _safeRead(_interfaceModeKey),
      _safeRead(_navigationSoundsKey),
      _safeRead(_clickSoundsKey),
      _safeRead(_defaultLandingPageKey),
      _safeRead(_preferredPlayerKey),
      _safeRead(_anonymousCrashReportingKey),
      _safeRead(_preferredAudioKey),
      _safeRead(initialSetupCompletedStorageKey),
      _safeRead(_showFillerIndicatorsKey),
      _safeRead(_debridStreamSortKey),
      _safeRead(_streamSourcePriorityKey),
      _safeRead(_webStreamQualityKey),
      _safeRead(_showHomeKey),
      _safeRead(_showSettingsKey),
      _safeRead(_topNavigationOrderKey),
      _safeRead(_settingsEntryPlacementKey),
      _safeRead(_navigationChromeSizeKey),
      // Append-only: existing positions above are migration-sensitive.
      _safeRead(_autoPickSourceEnabledKey),
      _safeRead(_autoPickSourceTypeKey),
      _safeRead(_autoPickQualityKey),
      _safeRead(_autoPickAudioKey),
      // Append-only: do not shift any migration-sensitive index above.
      _safeRead(_showWatchTogetherKey),
      // V2 Auto Pick priorities. The legacy singular keys above remain in the
      // read list so their first choice can seed these ordered lists.
      _safeRead(_autoPickSourcePriorityKey),
      _safeRead(_autoPickQualityPriorityKey),
      // Direct peer networking is append-only and opt-in on every install.
      _safeRead(_directTorrentStreamingEnabledKey),
      // Anonymous aggregate presence is append-only so every earlier storage
      // index remains migration-safe.
      _safeRead(_anonymousUsageCountKey),
      // External player handoff is append-only so every earlier storage index
      // remains migration-safe.
      _safeRead(_externalPlayerEnabledKey),
      _safeRead(_externalPlayerPackageKey),
      _safeRead(_externalPlayerLabelKey),
      // Downloads is append-only so persisted preference indexes stay stable.
      _safeRead(_showDownloadsKey),
      // Show-title style is append-only so every earlier index remains stable.
      _safeRead(_showTitleStyleKey),
      // Calendar notification choices are append-only and independently
      // persisted. Normal airtimes and verified dubs must never share a key.
      _safeRead(_subEpisodeNotificationsKey),
      _safeRead(_dubEpisodeNotificationsKey),
      // The feature-wide offline-download switch is append-only. Missing
      // values intentionally migrate existing installs to enabled.
      _safeRead(_offlineDownloadsEnabledKey),
    ]);

    bool canRestore(String key, int index) {
      if (identical(values[index], _preferenceReadFailed)) return false;
      if (wasInitialLoad && _preloadMutations.contains(key)) return false;
      return (_keyRevisions[key] ?? 0) <= revisionAtStart;
    }

    String? valueAt(int index) => values[index] as String?;
    var restored = state;
    if (canRestore(_debridProviderKey, 0)) {
      restored = restored.copyWith(
        debridProvider:
            DebridService.fromSlug(valueAt(0)) ?? DebridService.realDebrid,
      );
    }
    if (canRestore(_trackingProviderKey, 1)) {
      restored = restored.copyWith(
        trackingProvider: TrackingProvider.values.firstWhere(
          (provider) => provider.slug == valueAt(1),
          orElse: () => TrackingProvider.anilist,
        ),
      );
    }
    if (canRestore(_captionTextColorKey, 2)) {
      restored = restored.copyWith(
        captionTextColor: _parseInt(valueAt(2), 0xFFFFFFFF),
      );
    }
    if (canRestore(_captionBackgroundColorKey, 3)) {
      restored = restored.copyWith(
        captionBackgroundColor: _parseInt(valueAt(3), 0x00000000),
      );
    }
    if (canRestore(_captionTextSizeKey, 4)) {
      restored = restored.copyWith(
        captionTextSize: _parseDouble(valueAt(4), 34).clamp(18, 60),
      );
    }
    if (canRestore(_thumbnailScaleKey, 5)) {
      restored = restored.copyWith(
        thumbnailScale: _parseDouble(valueAt(5), 1).clamp(.8, 1.25),
      );
    }
    if (canRestore(_interfaceScaleKey, 6)) {
      restored = restored.copyWith(
        interfaceScale: _parseDouble(valueAt(6), 1).clamp(.8, 1.2),
      );
    }
    if (canRestore(_contentDensityKey, 7)) {
      restored = restored.copyWith(
        contentDensity: ContentDensity.values.firstWhere(
          (density) => density.name == valueAt(7),
          orElse: () => ContentDensity.standard,
        ),
      );
    }
    if (canRestore(_seekBackSecondsKey, 8)) {
      restored = restored.copyWith(seekBackSeconds: _seekValue(valueAt(8)));
    }
    if (canRestore(_seekForwardSecondsKey, 9)) {
      restored = restored.copyWith(seekForwardSeconds: _seekValue(valueAt(9)));
    }
    if (canRestore(_builtInKeyboardKey, 10)) {
      final savedKeyboard = valueAt(10);
      final completedLegacySetup =
          canRestore(initialSetupCompletedStorageKey, 31) &&
          valueAt(31) == 'true';
      // The previous release migrated an existing installation with no saved
      // keyboard key to device input. Keep that behavior once onboarding was
      // already completed, while a genuinely empty install gets the new
      // TetoTV-keyboard default and can choose on the Customize step.
      restored = restored.copyWith(
        useBuiltInKeyboard: savedKeyboard == null
            ? !completedLegacySetup
            : savedKeyboard == 'true',
      );
    }
    if (canRestore(_debridStreamsEnabledKey, 11)) {
      restored = restored.copyWith(
        debridStreamsEnabled: valueAt(11) != 'false',
      );
    }
    if (canRestore(_webStreamsEnabledKey, 12)) {
      restored = restored.copyWith(webStreamsEnabled: valueAt(12) != 'false');
    }
    if (canRestore(_autoSkipIntrosKey, 13)) {
      restored = restored.copyWith(autoSkipIntros: valueAt(13) == 'true');
    }
    if (canRestore(_autoSkipOutrosKey, 14)) {
      restored = restored.copyWith(autoSkipOutros: valueAt(14) == 'true');
    }
    if (canRestore(_homeLayoutKey, 15)) {
      restored = restored.copyWith(
        homeLayout: HomeLayout.values.firstWhere(
          (layout) => layout.name == valueAt(15),
          orElse: () => HomeLayout.cinematic,
        ),
      );
    }
    if (canRestore(_showSearchKey, 16)) {
      restored = restored.copyWith(showSearch: valueAt(16) != 'false');
    }
    if (canRestore(_showMyListKey, 17)) {
      restored = restored.copyWith(showMyList: valueAt(17) != 'false');
    }
    if (canRestore(_showDiscoverKey, 18)) {
      restored = restored.copyWith(showDiscover: valueAt(18) != 'false');
    }
    if (canRestore(_showCalendarKey, 19)) {
      restored = restored.copyWith(showCalendar: valueAt(19) != 'false');
    }
    if (canRestore(_showHeroKey, 20)) {
      restored = restored.copyWith(showHero: valueAt(20) != 'false');
    }
    if (canRestore(_showPosterMetadataKey, 21)) {
      restored = restored.copyWith(showPosterMetadata: valueAt(21) != 'false');
    }
    if (canRestore(_showCardSubtitlesKey, 22)) {
      restored = restored.copyWith(showCardSubtitles: valueAt(22) != 'false');
    }
    if (canRestore(_trackerUpdateThresholdKey, 23)) {
      restored = restored.copyWith(
        trackerUpdateThreshold: TrackerUpdateThreshold.values.firstWhere(
          (threshold) => threshold.name == valueAt(23),
          orElse: () => TrackerUpdateThreshold.nearlyFinished,
        ),
      );
    }
    var repairRetiredInterfaceMode = false;
    if (canRestore(_interfaceModeKey, 24)) {
      final storedMode = InterfaceMode.values.firstWhere(
        (mode) => mode.name == valueAt(24),
        orElse: () => InterfaceMode.automatic,
      );
      final supportedMode = migrateRetiredInterfaceMode(storedMode);
      repairRetiredInterfaceMode = supportedMode != storedMode;
      restored = restored.copyWith(interfaceMode: supportedMode);
    }
    if (canRestore(_navigationSoundsKey, 25)) {
      restored = restored.copyWith(navigationSounds: valueAt(25) != 'false');
    }
    if (canRestore(_clickSoundsKey, 26)) {
      restored = restored.copyWith(clickSounds: valueAt(26) != 'false');
    }
    if (canRestore(_defaultLandingPageKey, 27)) {
      restored = restored.copyWith(
        defaultLandingPage: LandingPage.values.firstWhere(
          (page) => page.name == valueAt(27),
          orElse: () => LandingPage.home,
        ),
      );
    }
    if (canRestore(_preferredPlayerKey, 28)) {
      restored = restored.copyWith(
        preferredPlayer: PreferredPlayer.values.firstWhere(
          (player) => player.name == valueAt(28),
          orElse: () => PreferredPlayer.mpv,
        ),
      );
    }
    if (canRestore(_anonymousCrashReportingKey, 29)) {
      restored = restored.copyWith(
        anonymousCrashReportingEnabled: valueAt(29) == 'true',
      );
    }
    if (canRestore(_preferredAudioKey, 30)) {
      restored = restored.copyWith(
        preferredAudio: PlaybackAudioPreferenceLabel.fromStorage(valueAt(30)),
      );
    }
    if (canRestore(_showFillerIndicatorsKey, 32)) {
      // Existing installations have no saved value, so absence migrates to
      // the enabled default while an explicit opt-out remains permanent.
      restored = restored.copyWith(
        showFillerIndicators: valueAt(32) != 'false',
      );
    }
    if (canRestore(_debridStreamSortKey, 33)) {
      restored = restored.copyWith(
        debridStreamSort: _enumByName(
          DebridStreamSort.values,
          valueAt(33),
          DebridStreamSort.bestQuality,
        ),
      );
    }
    if (canRestore(_streamSourcePriorityKey, 34)) {
      restored = restored.copyWith(
        streamSourcePriority: _enumByName(
          StreamSourcePriority.values,
          valueAt(34),
          StreamSourcePriority.debridFirst,
        ),
      );
    }
    if (canRestore(_webStreamQualityKey, 35)) {
      restored = restored.copyWith(
        webStreamQuality: _enumByName(
          WebStreamQualityPreference.values,
          valueAt(35),
          WebStreamQualityPreference.bestAvailable,
        ),
      );
    }
    if (canRestore(_showHomeKey, 36)) {
      restored = restored.copyWith(showHome: valueAt(36) != 'false');
    }
    final repairHiddenSettings =
        canRestore(_showSettingsKey, 37) && valueAt(37) == 'false';
    // Settings is now the permanent recovery path. Ignore and repair a hidden
    // value left by an older build instead of briefly hiding it at startup.
    restored = restored.copyWith(showSettings: true);
    if (canRestore(_topNavigationOrderKey, 38)) {
      restored = restored.copyWith(
        topNavigationOrder: _parseTopNavigationOrder(valueAt(38)),
      );
    }
    if (canRestore(_settingsEntryPlacementKey, 39)) {
      restored = restored.copyWith(
        settingsEntryPlacement: _enumByName(
          SettingsEntryPlacement.values,
          valueAt(39),
          SettingsEntryPlacement.topNavigation,
        ),
      );
    }
    if (canRestore(_navigationChromeSizeKey, 40)) {
      restored = restored.copyWith(
        navigationChromeSize: _enumByName(
          NavigationChromeSize.values,
          valueAt(40),
          NavigationChromeSize.medium,
        ),
      );
    }
    if (canRestore(_autoPickSourceEnabledKey, 41)) {
      restored = restored.copyWith(
        autoPickSourceEnabled: valueAt(41) == 'true',
      );
    }
    if (canRestore(_autoPickSourceTypeKey, 42)) {
      restored = restored.copyWith(
        autoPickSourceType: _enumByName(
          AutoPickSourceType.values,
          valueAt(42),
          AutoPickSourceType.any,
        ),
      );
    }
    if (canRestore(_autoPickQualityKey, 43)) {
      restored = restored.copyWith(
        autoPickQuality: _enumByName(
          AutoPickQuality.values,
          valueAt(43),
          AutoPickQuality.any,
        ),
      );
    }
    if (canRestore(_autoPickAudioKey, 44)) {
      restored = restored.copyWith(
        autoPickAudio: _enumByName(
          AutoPickAudio.values,
          valueAt(44),
          AutoPickAudio.any,
        ),
      );
    }
    if (canRestore(_showWatchTogetherKey, 45)) {
      // Existing installations have no saved value and migrate to visible.
      restored = restored.copyWith(showWatchTogether: valueAt(45) != 'false');
    }
    if (canRestore(_autoPickSourcePriorityKey, 46)) {
      restored = restored.copyWith(
        autoPickSourcePriority: _parseAutoPickSourcePriority(
          valueAt(46),
          fallback: _sourcePriorityFromLegacy(
            restored.autoPickSourceType,
            restored.streamSourcePriority,
          ),
        ),
      );
    }
    if (canRestore(_autoPickQualityPriorityKey, 47)) {
      restored = restored.copyWith(
        autoPickQualityPriority: _parseAutoPickQualityPriority(
          valueAt(47),
          fallback: _qualityPriorityFromLegacy(restored.autoPickQuality),
        ),
      );
    }
    if (canRestore(_directTorrentStreamingEnabledKey, 48)) {
      restored = restored.copyWith(
        directTorrentStreamingEnabled: valueAt(48) == 'true',
      );
    }
    final anonymousUsageReadFailed = identical(
      values[49],
      _preferenceReadFailed,
    );
    final anonymousUsageChangedDuringInitialLoad =
        wasInitialLoad && _preloadMutations.contains(_anonymousUsageCountKey);
    if (anonymousUsageReadFailed && !anonymousUsageChangedDuringInitialLoad) {
      // A storage failure must never turn a previously saved opt-out back on.
      // An explicit choice made while the initial read was pending remains
      // authoritative through the normal revision/preload guard.
      restored = restored.copyWith(anonymousUsageCountEnabled: false);
    } else if (canRestore(_anonymousUsageCountKey, 49)) {
      restored = restored.copyWith(
        anonymousUsageCountEnabled: valueAt(49) != 'false',
      );
    }
    if (canRestore(_externalPlayerEnabledKey, 50)) {
      restored = restored.copyWith(
        externalPlayerEnabled: valueAt(50) == 'true',
      );
    }
    if (canRestore(_externalPlayerPackageKey, 51)) {
      final packageName = normalizeExternalPlayerPackageName(valueAt(51));
      restored = packageName == null
          ? restored.copyWith(clearSelectedExternalPlayer: true)
          : restored.copyWith(selectedExternalPlayerPackage: packageName);
    }
    if (canRestore(_externalPlayerLabelKey, 52)) {
      final label = normalizeExternalPlayerLabel(valueAt(52));
      if (label != null) {
        restored = restored.copyWith(selectedExternalPlayerLabel: label);
      }
    }
    if (canRestore(_showDownloadsKey, 53)) {
      // Existing installations have no saved value and migrate to visible.
      restored = restored.copyWith(showDownloads: valueAt(53) != 'false');
    }
    if (canRestore(_showTitleStyleKey, 54)) {
      restored = restored.copyWith(
        showTitleStyle: ShowTitleStyle.values.firstWhere(
          (style) => style.name == valueAt(54),
          orElse: () => ShowTitleStyle.englishLogo,
        ),
      );
    }
    if (canRestore(_subEpisodeNotificationsKey, 55)) {
      restored = restored.copyWith(
        subEpisodeNotificationsEnabled: valueAt(55) == 'true',
      );
    }
    if (canRestore(_dubEpisodeNotificationsKey, 56)) {
      restored = restored.copyWith(
        dubEpisodeNotificationsEnabled: valueAt(56) == 'true',
      );
    }
    if (canRestore(_offlineDownloadsEnabledKey, 57)) {
      restored = restored.copyWith(
        offlineDownloadsEnabled: valueAt(57) != 'false',
      );
    }
    if (restored.preferredPlayer == PreferredPlayer.external &&
        (!restored.externalPlayerEnabled ||
            restored.selectedExternalPlayerPackage == null)) {
      restored = restored.copyWith(preferredPlayer: PreferredPlayer.mpv);
    }
    state = restored.copyWith(loaded: true);
    _initialLoadComplete = true;
    _preloadMutations.clear();
    if (repairHiddenSettings || repairRetiredInterfaceMode) {
      await _enqueueStorage(() async {
        if (repairHiddenSettings) {
          await _write(_showSettingsKey, 'true');
        }
        if (repairRetiredInterfaceMode) {
          await _write(_interfaceModeKey, InterfaceMode.automatic.name);
        }
      });
    }
  }

  Future<Object?> _safeRead(String key) async {
    try {
      return await (readValue?.call(key) ?? _storage.read(key: key));
    } catch (_) {
      return _preferenceReadFailed;
    }
  }

  void _markMutated(Iterable<String> keys) {
    final revision = ++_revision;
    for (final key in keys) {
      _keyRevisions[key] = revision;
      if (!_initialLoadComplete) _preloadMutations.add(key);
    }
  }

  Future<void> setDebridProvider(DebridService value) => _update(
    state.copyWith(debridProvider: value),
    {_debridProviderKey: value.slug},
  );

  Future<void> setTrackingProvider(TrackingProvider value) => _update(
    state.copyWith(trackingProvider: value),
    {_trackingProviderKey: value.slug},
  );

  Future<void> setCaptionTextColor(int value) => _update(
    state.copyWith(captionTextColor: value),
    {_captionTextColorKey: value.toString()},
  );

  Future<void> setCaptionBackgroundColor(int value) => _update(
    state.copyWith(captionBackgroundColor: value),
    {_captionBackgroundColorKey: value.toString()},
  );

  Future<void> setCaptionTextSize(double value) => _update(
    state.copyWith(captionTextSize: value),
    {_captionTextSizeKey: value.toString()},
  );

  Future<void> setThumbnailScale(double value) => _update(
    state.copyWith(thumbnailScale: value),
    {_thumbnailScaleKey: value.toString()},
  );

  Future<void> setInterfaceScale(double value) => _update(
    state.copyWith(interfaceScale: value),
    {_interfaceScaleKey: value.toString()},
  );

  Future<void> setContentDensity(ContentDensity value) => _update(
    state.copyWith(contentDensity: value),
    {_contentDensityKey: value.name},
  );

  Future<void> setShowTitleStyle(ShowTitleStyle value) => _update(
    state.copyWith(showTitleStyle: value),
    {_showTitleStyleKey: value.name},
  );

  Future<void> setSeekBackSeconds(int value) => _update(
    state.copyWith(seekBackSeconds: value),
    {_seekBackSecondsKey: value.toString()},
  );

  Future<void> setSeekForwardSeconds(int value) => _update(
    state.copyWith(seekForwardSeconds: value),
    {_seekForwardSecondsKey: value.toString()},
  );

  Future<void> setUseBuiltInKeyboard(bool value) => _update(
    state.copyWith(useBuiltInKeyboard: value),
    {_builtInKeyboardKey: value.toString()},
  );

  Future<void> setDebridStreamsEnabled(bool value) => _update(
    state.copyWith(debridStreamsEnabled: value),
    {_debridStreamsEnabledKey: value.toString()},
  );

  Future<void> setWebStreamsEnabled(bool value) => _update(
    state.copyWith(webStreamsEnabled: value),
    {_webStreamsEnabledKey: value.toString()},
  );

  Future<void> setDirectTorrentStreamingEnabled(bool value) => _update(
    state.copyWith(directTorrentStreamingEnabled: value),
    {_directTorrentStreamingEnabledKey: value.toString()},
  );

  Future<void> setAutoSkipIntros(bool value) => _update(
    state.copyWith(autoSkipIntros: value),
    {_autoSkipIntrosKey: value.toString()},
  );

  Future<void> setAutoSkipOutros(bool value) => _update(
    state.copyWith(autoSkipOutros: value),
    {_autoSkipOutrosKey: value.toString()},
  );

  Future<void> setShowFillerIndicators(bool value) => _update(
    state.copyWith(showFillerIndicators: value),
    {_showFillerIndicatorsKey: value.toString()},
  );

  Future<void> setHomeLayout(HomeLayout value) =>
      _update(state.copyWith(homeLayout: value), {_homeLayoutKey: value.name});

  Future<void> setShowSearch(bool value) => setTopNavigationDestinationVisible(
    TopNavigationDestination.search,
    value,
  );

  Future<void> setShowHome(bool value) =>
      setTopNavigationDestinationVisible(TopNavigationDestination.home, value);

  Future<void> setShowMyList(bool value) => setTopNavigationDestinationVisible(
    TopNavigationDestination.myList,
    value,
  );

  Future<void> setShowDiscover(bool value) =>
      setTopNavigationDestinationVisible(
        TopNavigationDestination.discover,
        value,
      );

  Future<void> setShowCalendar(bool value) =>
      setTopNavigationDestinationVisible(
        TopNavigationDestination.calendar,
        value,
      );

  Future<void> setShowWatchTogether(bool value) =>
      setTopNavigationDestinationVisible(
        TopNavigationDestination.watchTogether,
        value,
      );

  Future<void> setShowDownloads(bool value) =>
      setTopNavigationDestinationVisible(
        TopNavigationDestination.downloads,
        value,
      );

  Future<void> setOfflineDownloadsEnabled(bool value) => _update(
    state.copyWith(offlineDownloadsEnabled: value),
    {_offlineDownloadsEnabledKey: value.toString()},
  );

  Future<void> setShowSettings(bool value) =>
      setTopNavigationDestinationVisible(
        TopNavigationDestination.settings,
        value,
      );

  Future<void> setTopNavigationDestinationVisible(
    TopNavigationDestination destination,
    bool visible,
  ) {
    if (!visible && !state.canHideTopNavigationDestination(destination)) {
      return Future<void>.value();
    }
    final next = switch (destination) {
      TopNavigationDestination.search => state.copyWith(showSearch: visible),
      TopNavigationDestination.home => state.copyWith(showHome: visible),
      TopNavigationDestination.myList => state.copyWith(showMyList: visible),
      TopNavigationDestination.discover => state.copyWith(
        showDiscover: visible,
      ),
      TopNavigationDestination.calendar => state.copyWith(
        showCalendar: visible,
      ),
      TopNavigationDestination.watchTogether => state.copyWith(
        showWatchTogether: visible,
      ),
      TopNavigationDestination.downloads => state.copyWith(
        showDownloads: visible,
      ),
      TopNavigationDestination.settings => state.copyWith(
        showSettings: visible,
      ),
    };
    final visibilityKey = switch (destination) {
      TopNavigationDestination.search => _showSearchKey,
      TopNavigationDestination.home => _showHomeKey,
      TopNavigationDestination.myList => _showMyListKey,
      TopNavigationDestination.discover => _showDiscoverKey,
      TopNavigationDestination.calendar => _showCalendarKey,
      TopNavigationDestination.watchTogether => _showWatchTogetherKey,
      TopNavigationDestination.downloads => _showDownloadsKey,
      TopNavigationDestination.settings => _showSettingsKey,
    };
    final landingPage = _landingPageForTopDestination(destination);
    final nextLandingPage = !visible && state.defaultLandingPage == landingPage
        ? LandingPage.home
        : state.defaultLandingPage;
    return _update(next.copyWith(defaultLandingPage: nextLandingPage), {
      visibilityKey: visible.toString(),
      if (nextLandingPage != state.defaultLandingPage)
        _defaultLandingPageKey: nextLandingPage.name,
    });
  }

  Future<void> moveTopNavigationDestination(
    TopNavigationDestination destination,
    int offset,
  ) {
    final current = [...state.topNavigationOrder];
    final from = current.indexOf(destination);
    if (from < 0) return Future<void>.value();
    final to = (from + offset).clamp(0, current.length - 1);
    if (from == to) return Future<void>.value();
    current
      ..removeAt(from)
      ..insert(to, destination);
    return setTopNavigationOrder(current);
  }

  Future<void> setTopNavigationOrder(Iterable<TopNavigationDestination> order) {
    final normalized = _normalizeTopNavigationOrder(order);
    return _update(state.copyWith(topNavigationOrder: normalized), {
      _topNavigationOrderKey: normalized.map((item) => item.name).join(','),
    });
  }

  Future<void> setSettingsEntryPlacement(SettingsEntryPlacement value) =>
      _update(state.copyWith(settingsEntryPlacement: value), {
        _settingsEntryPlacementKey: value.name,
      });

  Future<void> setNavigationChromeSize(NavigationChromeSize value) => _update(
    state.copyWith(navigationChromeSize: value),
    {_navigationChromeSizeKey: value.name},
  );

  Future<void> setShowHero(bool value) => _update(
    state.copyWith(showHero: value),
    {_showHeroKey: value.toString()},
  );

  Future<void> setShowPosterMetadata(bool value) => _update(
    state.copyWith(showPosterMetadata: value),
    {_showPosterMetadataKey: value.toString()},
  );

  Future<void> setShowCardSubtitles(bool value) => _update(
    state.copyWith(showCardSubtitles: value),
    {_showCardSubtitlesKey: value.toString()},
  );

  Future<void> setTrackerUpdateThreshold(TrackerUpdateThreshold value) =>
      _update(state.copyWith(trackerUpdateThreshold: value), {
        _trackerUpdateThresholdKey: value.name,
      });

  Future<void> setSubEpisodeNotificationsEnabled(bool value) => _update(
    state.copyWith(subEpisodeNotificationsEnabled: value),
    {_subEpisodeNotificationsKey: value.toString()},
  );

  Future<void> setDubEpisodeNotificationsEnabled(bool value) => _update(
    state.copyWith(dubEpisodeNotificationsEnabled: value),
    {_dubEpisodeNotificationsKey: value.toString()},
  );

  Future<void> setInterfaceMode(InterfaceMode value) => _update(
    state.copyWith(interfaceMode: value),
    {_interfaceModeKey: value.name},
  );

  Future<void> setNavigationSounds(bool value) => _update(
    state.copyWith(navigationSounds: value),
    {_navigationSoundsKey: value.toString()},
  );

  Future<void> setClickSounds(bool value) => _update(
    state.copyWith(clickSounds: value),
    {_clickSoundsKey: value.toString()},
  );

  Future<void> setDefaultLandingPage(LandingPage value) => _update(
    state.copyWith(defaultLandingPage: value),
    {_defaultLandingPageKey: value.name},
  );

  Future<void> setPreferredPlayer(PreferredPlayer value) => _update(
    state.copyWith(preferredPlayer: value),
    {_preferredPlayerKey: value.name},
  );

  Future<void> setDefaultExternalPlayer({
    required String packageName,
    required String label,
  }) {
    final normalizedPackage = normalizeExternalPlayerPackageName(packageName);
    final normalizedLabel = normalizeExternalPlayerLabel(label);
    if (normalizedPackage == null || normalizedLabel == null) {
      throw ArgumentError('A valid installed video player is required.');
    }
    return _update(
      state.copyWith(
        preferredPlayer: PreferredPlayer.external,
        externalPlayerEnabled: true,
        selectedExternalPlayerPackage: normalizedPackage,
        selectedExternalPlayerLabel: normalizedLabel,
      ),
      {
        _preferredPlayerKey: PreferredPlayer.external.name,
        _externalPlayerEnabledKey: 'true',
        _externalPlayerPackageKey: normalizedPackage,
        _externalPlayerLabelKey: normalizedLabel,
      },
    );
  }

  Future<void> fallBackToMpvAndClearExternalPlayer() {
    const keys = [
      _preferredPlayerKey,
      _externalPlayerPackageKey,
      _externalPlayerLabelKey,
    ];
    _markMutated(keys);
    state = state.copyWith(
      preferredPlayer: PreferredPlayer.mpv,
      clearSelectedExternalPlayer: true,
    );
    return _enqueueStorage(() async {
      await _write(_preferredPlayerKey, PreferredPlayer.mpv.name);
      await _delete(_externalPlayerPackageKey);
      await _delete(_externalPlayerLabelKey);
    });
  }

  Future<void> setPreferredAudio(PlaybackAudioPreference value) => _update(
    state.copyWith(preferredAudio: value),
    {_preferredAudioKey: value.name},
  );

  Future<void> setDebridStreamSort(DebridStreamSort value) => _update(
    state.copyWith(debridStreamSort: value),
    {_debridStreamSortKey: value.name},
  );

  Future<void> setStreamSourcePriority(StreamSourcePriority value) => _update(
    state.copyWith(streamSourcePriority: value),
    {_streamSourcePriorityKey: value.name},
  );

  Future<void> setWebStreamQuality(WebStreamQualityPreference value) => _update(
    state.copyWith(webStreamQuality: value),
    {_webStreamQualityKey: value.name},
  );

  Future<void> setAutoPickSourceEnabled(bool value) => _update(
    state.copyWith(autoPickSourceEnabled: value),
    {_autoPickSourceEnabledKey: value.toString()},
  );

  Future<void> setAutoPickSourcePriority(
    Iterable<AutoPickSourcePriority> priority,
  ) {
    final normalized = _normalizeAutoPickSourcePriority(priority);
    final legacyMirror = switch (normalized.first) {
      AutoPickSourcePriority.debrid => AutoPickSourceType.debridOnly,
      AutoPickSourcePriority.web => AutoPickSourceType.webOnly,
      AutoPickSourcePriority.yourMedia => AutoPickSourceType.any,
    };
    return _update(
      state.copyWith(
        autoPickSourcePriority: normalized,
        autoPickSourceType: legacyMirror,
      ),
      {
        _autoPickSourcePriorityKey: _encodeEnumPriority(normalized),
        _autoPickSourceTypeKey: legacyMirror.name,
      },
    );
  }

  Future<void> moveAutoPickSourcePriority(
    AutoPickSourcePriority source,
    int offset,
  ) {
    final current = [...state.autoPickSourcePriority];
    final from = current.indexOf(source);
    if (from < 0) return Future<void>.value();
    final to = (from + offset).clamp(0, current.length - 1);
    if (from == to) return Future<void>.value();
    current
      ..removeAt(from)
      ..insert(to, source);
    return setAutoPickSourcePriority(current);
  }

  Future<void> setAutoPickQualityPriority(Iterable<AutoPickQuality> priority) {
    final normalized = _normalizeAutoPickQualityPriority(priority);
    final legacyMirror = normalized.first;
    return _update(
      state.copyWith(
        autoPickQualityPriority: normalized,
        autoPickQuality: legacyMirror,
      ),
      {
        _autoPickQualityPriorityKey: _encodeEnumPriority(normalized),
        _autoPickQualityKey: legacyMirror.name,
      },
    );
  }

  Future<void> moveAutoPickQualityPriority(
    AutoPickQuality quality,
    int offset,
  ) {
    final current = [...state.autoPickQualityPriority];
    final from = current.indexOf(quality);
    if (from < 0) return Future<void>.value();
    final to = (from + offset).clamp(0, current.length - 1);
    if (from == to) return Future<void>.value();
    current
      ..removeAt(from)
      ..insert(to, quality);
    return setAutoPickQualityPriority(current);
  }

  /// Compatibility entry point for callers from builds that stored a single
  /// source constraint. The selected value becomes the first priority.
  Future<void> setAutoPickSourceType(AutoPickSourceType value) {
    final normalized = _sourcePriorityFromLegacy(
      value,
      state.streamSourcePriority,
    );
    return _update(
      state.copyWith(
        autoPickSourceType: value,
        autoPickSourcePriority: normalized,
      ),
      {
        _autoPickSourceTypeKey: value.name,
        _autoPickSourcePriorityKey: _encodeEnumPriority(normalized),
      },
    );
  }

  /// Compatibility entry point for callers from builds that stored one exact
  /// quality. The selected quality becomes the first priority.
  Future<void> setAutoPickQuality(AutoPickQuality value) {
    final normalized = _qualityPriorityFromLegacy(value);
    return _update(
      state.copyWith(
        autoPickQuality: value,
        autoPickQualityPriority: normalized,
      ),
      {
        _autoPickQualityKey: value.name,
        _autoPickQualityPriorityKey: _encodeEnumPriority(normalized),
      },
    );
  }

  Future<void> setAutoPickAudio(AutoPickAudio value) => _update(
    state.copyWith(autoPickAudio: value),
    {_autoPickAudioKey: value.name},
  );

  Future<void> setAnonymousCrashReportingEnabled(bool value) => _update(
    state.copyWith(anonymousCrashReportingEnabled: value, loaded: true),
    {_anonymousCrashReportingKey: value.toString()},
  );

  Future<void> setAnonymousUsageCountEnabled(bool value) => _update(
    state.copyWith(anonymousUsageCountEnabled: value, loaded: true),
    {_anonymousUsageCountKey: value.toString()},
  );

  Future<void> setExternalPlayerEnabled(bool value) {
    if (value) {
      return _update(
        state.copyWith(externalPlayerEnabled: true, loaded: true),
        {_externalPlayerEnabledKey: 'true'},
      );
    }

    // Do not leave Settings claiming that an external app is the default
    // while the feature gate silently routes playback through MPV. Disabling
    // external playback is an explicit return to the built-in player.
    const keys = [
      _externalPlayerEnabledKey,
      _preferredPlayerKey,
      _externalPlayerPackageKey,
      _externalPlayerLabelKey,
    ];
    _markMutated(keys);
    state = state.copyWith(
      externalPlayerEnabled: false,
      preferredPlayer: PreferredPlayer.mpv,
      clearSelectedExternalPlayer: true,
      loaded: true,
    );
    return _enqueueStorage(() async {
      await _write(_externalPlayerEnabledKey, 'false');
      await _write(_preferredPlayerKey, PreferredPlayer.mpv.name);
      await _delete(_externalPlayerPackageKey);
      await _delete(_externalPlayerLabelKey);
    });
  }

  Future<void> resetCustomization() {
    const defaults = SettingsPreferences();
    const keys = [
      _homeLayoutKey,
      _showSearchKey,
      _showHomeKey,
      _showMyListKey,
      _showDiscoverKey,
      _showCalendarKey,
      _showWatchTogetherKey,
      _showDownloadsKey,
      _showSettingsKey,
      _topNavigationOrderKey,
      _settingsEntryPlacementKey,
      _navigationChromeSizeKey,
      _showHeroKey,
      _showPosterMetadataKey,
      _showCardSubtitlesKey,
      _navigationSoundsKey,
      _clickSoundsKey,
      _defaultLandingPageKey,
    ];
    _markMutated(keys);
    state = state.copyWith(
      homeLayout: defaults.homeLayout,
      showSearch: defaults.showSearch,
      showHome: defaults.showHome,
      showMyList: defaults.showMyList,
      showDiscover: defaults.showDiscover,
      showCalendar: defaults.showCalendar,
      showWatchTogether: defaults.showWatchTogether,
      showDownloads: defaults.showDownloads,
      showSettings: defaults.showSettings,
      topNavigationOrder: defaults.topNavigationOrder,
      settingsEntryPlacement: defaults.settingsEntryPlacement,
      navigationChromeSize: defaults.navigationChromeSize,
      showHero: defaults.showHero,
      showPosterMetadata: defaults.showPosterMetadata,
      showCardSubtitles: defaults.showCardSubtitles,
      navigationSounds: defaults.navigationSounds,
      clickSounds: defaults.clickSounds,
      defaultLandingPage: defaults.defaultLandingPage,
    );
    return _enqueueStorage(() async {
      for (final key in keys) {
        await _delete(key);
      }
    });
  }

  Future<void> resetAppearance() {
    const defaults = SettingsPreferences();
    const keys = [
      _captionTextColorKey,
      _captionBackgroundColorKey,
      _captionTextSizeKey,
      _thumbnailScaleKey,
      _interfaceScaleKey,
      _contentDensityKey,
      _interfaceModeKey,
      _seekBackSecondsKey,
      _seekForwardSecondsKey,
      _preferredPlayerKey,
      _preferredAudioKey,
      _showFillerIndicatorsKey,
      _externalPlayerEnabledKey,
      _externalPlayerPackageKey,
      _externalPlayerLabelKey,
      _showTitleStyleKey,
    ];
    _markMutated(keys);
    state = state.copyWith(
      captionTextColor: defaults.captionTextColor,
      captionBackgroundColor: defaults.captionBackgroundColor,
      captionTextSize: defaults.captionTextSize,
      thumbnailScale: defaults.thumbnailScale,
      interfaceScale: defaults.interfaceScale,
      contentDensity: defaults.contentDensity,
      interfaceMode: defaults.interfaceMode,
      seekBackSeconds: defaults.seekBackSeconds,
      seekForwardSeconds: defaults.seekForwardSeconds,
      preferredPlayer: defaults.preferredPlayer,
      preferredAudio: defaults.preferredAudio,
      showFillerIndicators: defaults.showFillerIndicators,
      showTitleStyle: defaults.showTitleStyle,
      externalPlayerEnabled: defaults.externalPlayerEnabled,
      clearSelectedExternalPlayer: true,
    );
    return _enqueueStorage(() async {
      for (final key in keys) {
        await _delete(key);
      }
    });
  }

  Future<void> _update(SettingsPreferences next, Map<String, String> values) {
    _markMutated(values.keys);
    state = next;
    return _enqueueStorage(() async {
      for (final entry in values.entries) {
        await _write(entry.key, entry.value);
      }
    });
  }

  Future<void> _enqueueStorage(Future<void> Function() operation) {
    final previous = _storageTail;
    final strict = Zone.current[_strictPreferencePersistenceZoneKey] == true;
    final request = () async {
      await previous;
      try {
        await operation();
      } catch (_) {
        if (strict) rethrow;
        // Keep the in-memory preference if platform storage is unavailable.
      }
    }();
    // A strict caller observes its own failure, but the shared queue remains
    // usable for rollback and later ordinary preference changes.
    _storageTail = request.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return request;
  }

  Future<void> _write(String key, String value) =>
      writeValue?.call(key, value) ?? _storage.write(key: key, value: value);

  Future<void> _delete(String key) =>
      deleteValue?.call(key) ?? _storage.delete(key: key);
}

const _preferenceReadFailed = Object();

int _parseInt(String? value, int fallback) =>
    int.tryParse(value ?? '') ?? fallback;

double _parseDouble(String? value, double fallback) =>
    double.tryParse(value ?? '') ?? fallback;

int _seekValue(String? value) {
  const allowed = {5, 10, 15, 30, 60};
  final parsed = int.tryParse(value ?? '');
  return allowed.contains(parsed) ? parsed! : 10;
}

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) =>
    values.where((value) => value.name == name).firstOrNull ?? fallback;

String _encodeEnumPriority<T extends Enum>(Iterable<T> values) =>
    values.map((value) => value.name).join(',');

List<AutoPickSourcePriority> _parseAutoPickSourcePriority(
  String? raw, {
  required Iterable<AutoPickSourcePriority> fallback,
}) {
  final parsed = (raw ?? '')
      .split(',')
      .map(
        (name) => AutoPickSourcePriority.values
            .where((value) => value.name == name.trim())
            .firstOrNull,
      )
      .whereType<AutoPickSourcePriority>();
  return _normalizeAutoPickSourcePriority([...parsed, ...fallback]);
}

List<AutoPickQuality> _parseAutoPickQualityPriority(
  String? raw, {
  required Iterable<AutoPickQuality> fallback,
}) {
  final parsed = (raw ?? '')
      .split(',')
      .map(
        (name) => AutoPickQuality.values
            .where((value) => value.name == name.trim())
            .firstOrNull,
      )
      .whereType<AutoPickQuality>();
  return _normalizeAutoPickQualityPriority([...parsed, ...fallback]);
}

List<AutoPickSourcePriority> _normalizeAutoPickSourcePriority(
  Iterable<AutoPickSourcePriority> priority,
) {
  final normalized = <AutoPickSourcePriority>[];
  for (final value in [...priority, ...defaultAutoPickSourcePriority]) {
    if (!normalized.contains(value)) normalized.add(value);
  }
  return List<AutoPickSourcePriority>.unmodifiable(normalized);
}

List<AutoPickQuality> _normalizeAutoPickQualityPriority(
  Iterable<AutoPickQuality> priority,
) {
  final normalized = <AutoPickQuality>[];
  for (final value in [...priority, ...defaultAutoPickQualityPriority]) {
    if (value == AutoPickQuality.any || normalized.contains(value)) continue;
    normalized.add(value);
  }
  return List<AutoPickQuality>.unmodifiable(normalized);
}

String? normalizeExternalPlayerPackageName(String? value) {
  final normalized = value?.trim() ?? '';
  if (normalized.length < 3 || normalized.length > 255) return null;
  return RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$').hasMatch(normalized)
      ? normalized
      : null;
}

String? normalizeExternalPlayerLabel(String? value) {
  final normalized = value?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
  if (normalized.isEmpty) return null;
  return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
}

List<AutoPickSourcePriority> _sourcePriorityFromLegacy(
  AutoPickSourceType legacy,
  StreamSourcePriority generalPriority,
) {
  final first = switch (legacy) {
    AutoPickSourceType.debridOnly => AutoPickSourcePriority.debrid,
    AutoPickSourceType.webOnly => AutoPickSourcePriority.web,
    AutoPickSourceType.any => switch (generalPriority) {
      StreamSourcePriority.debridFirst => AutoPickSourcePriority.debrid,
      StreamSourcePriority.webFirst => AutoPickSourcePriority.web,
    },
  };
  return _normalizeAutoPickSourcePriority([first]);
}

List<AutoPickQuality> _qualityPriorityFromLegacy(AutoPickQuality legacy) =>
    _normalizeAutoPickQualityPriority([
      if (legacy != AutoPickQuality.any) legacy,
    ]);

LandingPage? _landingPageForTopDestination(
  TopNavigationDestination destination,
) => switch (destination) {
  TopNavigationDestination.search => LandingPage.search,
  TopNavigationDestination.home => LandingPage.home,
  TopNavigationDestination.myList => LandingPage.myList,
  TopNavigationDestination.discover => LandingPage.discover,
  TopNavigationDestination.calendar => LandingPage.calendar,
  TopNavigationDestination.watchTogether => null,
  TopNavigationDestination.downloads => null,
  TopNavigationDestination.settings => null,
};

List<TopNavigationDestination> _parseTopNavigationOrder(String? value) {
  final parsed = (value ?? '')
      .split(',')
      .map(
        (name) => TopNavigationDestination.values
            .where((destination) => destination.name == name)
            .firstOrNull,
      )
      .whereType<TopNavigationDestination>();
  return _normalizeTopNavigationOrder(parsed);
}

List<TopNavigationDestination> _normalizeTopNavigationOrder(
  Iterable<TopNavigationDestination> order,
) {
  final normalized = <TopNavigationDestination>[];
  for (final destination in order) {
    if (!normalized.contains(destination)) normalized.add(destination);
  }
  for (final destination in defaultTopNavigationOrder) {
    if (normalized.contains(destination)) continue;
    // An older saved order already contains Settings. Insert the newly added
    // new destinations immediately before it without disturbing the relative
    // order of any destination the viewer customized.
    if (destination == TopNavigationDestination.watchTogether ||
        destination == TopNavigationDestination.downloads) {
      final settingsIndex = normalized.indexOf(
        TopNavigationDestination.settings,
      );
      if (settingsIndex >= 0) {
        normalized.insert(settingsIndex, destination);
        continue;
      }
    }
    normalized.add(destination);
  }
  return List<TopNavigationDestination>.unmodifiable(normalized);
}
