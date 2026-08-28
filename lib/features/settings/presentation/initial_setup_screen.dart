import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/discord/application/discord_account_link_resolver.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/presentation/source_pairing_dialog.dart';
import 'package:anime_tv/features/settings/application/all_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/device_setup_controller.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/premiumize_settings_controller.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/application/torbox_settings_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

class InitialSetupScreen extends ConsumerStatefulWidget {
  const InitialSetupScreen({this.returnToMethodChoice = false, super.key});

  final bool returnToMethodChoice;

  @override
  ConsumerState<InitialSetupScreen> createState() => _InitialSetupScreenState();
}

class _InitialSetupScreenState extends ConsumerState<InitialSetupScreen> {
  static const _stepCount = 5;
  static const _stepNames = [
    'Playback',
    'Home',
    'Streaming',
    'Accounts',
    'Privacy',
  ];
  final _pages = PageController();
  late final List<FocusNode> _firstChoiceFocusNodes = List.generate(
    _stepCount,
    (index) => FocusNode(debugLabel: 'setup.step.$index.first-choice'),
  );
  final _tvWatchPartyFocusNode = FocusNode(
    debugLabel: 'setup.tv-experience.watch-party',
  );
  final _tvDownloadsFocusNode = FocusNode(
    debugLabel: 'setup.tv-experience.downloads',
  );
  final _continueFocusNode = FocusNode(debugLabel: 'setup.continue');
  bool _finishing = false;
  bool _transitioning = false;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(setupProgressProvider.notifier).start();
      if (ref.read(deviceSetupProvider).report == null) {
        unawaited(ref.read(deviceSetupProvider.notifier).scan());
      }
      _firstChoiceFocusNodes.first.requestFocus();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final node in _firstChoiceFocusNodes) {
      node.dispose();
    }
    _tvWatchPartyFocusNode.dispose();
    _tvDownloadsFocusNode.dispose();
    _continueFocusNode.dispose();
    super.dispose();
  }

  Future<void> _setStep(int step) async {
    final next = step.clamp(0, _stepCount - 1);
    if (_transitioning || next == _step) return;
    _transitioning = true;
    try {
      setState(() => _step = next);
      await _pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _firstChoiceFocusNodes[next].context != null) {
            _firstChoiceFocusNodes[next].requestFocus();
          }
        });
      }
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final deviceSetup = ref.read(deviceSetupProvider.notifier);
    final setupProgress = ref.read(setupProgressProvider.notifier);
    try {
      deviceSetup.persistWhenReady();
      await setupProgress.complete();
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
    } finally {
      _finishing = false;
    }
  }

  Future<void> _handleBack() async {
    if (_transitioning || _finishing) return;
    if (_step > 0) {
      await _setStep(_step - 1);
      return;
    }
    if (widget.returnToMethodChoice) {
      context.go('/setup/start?focus=tv');
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.appPalette.surface,
        title: const Text('Leave setup?'),
        content: const Text(
          'You can finish these choices later from Settings.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep setting up'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Set up later'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _finish();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(settingsPreferencesProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: context.appPalette.background,
        body: SafeArea(
          minimum: context.responsiveScreenPadding,
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    clipBehavior: Clip.hardEdge,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Image.asset(
                      'assets/branding/tetotv_icon.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Set up TetoTV',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  _SetupButton(
                    label: 'Set up later',
                    icon: Icons.schedule_rounded,
                    onPressed: _finish,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SetupProgress(
                step: _step,
                count: _stepCount,
                label: _stepNames[_step],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: PageView(
                  controller: _pages,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _PlaybackStep(
                      preferences: preferences,
                      firstFocusNode: _firstChoiceFocusNodes[0],
                    ),
                    _TvExperienceStep(
                      preferences: preferences,
                      firstFocusNode: _firstChoiceFocusNodes[1],
                      watchPartyFocusNode: _tvWatchPartyFocusNode,
                      downloadsFocusNode: _tvDownloadsFocusNode,
                      continueFocusNode: _continueFocusNode,
                    ),
                    _StreamingStep(firstFocusNode: _firstChoiceFocusNodes[2]),
                    _AccountsStep(firstFocusNode: _firstChoiceFocusNodes[3]),
                    _PrivacyStep(
                      preferences: preferences,
                      firstFocusNode: _firstChoiceFocusNodes[4],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_step > 0 || widget.returnToMethodChoice)
                    _SetupButton(
                      key: const ValueKey('setup-method-back'),
                      label: 'Back',
                      icon: Icons.arrow_back_rounded,
                      onPressed: _handleBack,
                    ),
                  const Spacer(),
                  _SetupButton(
                    label: _step == _stepCount - 1 ? 'Finish' : 'Continue',
                    icon: _step == _stepCount - 1
                        ? Icons.check_rounded
                        : Icons.arrow_forward_rounded,
                    primary: true,
                    focusNode: _continueFocusNode,
                    onPressed: _step == _stepCount - 1
                        ? _finish
                        : () => _setStep(_step + 1),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvExperienceStep extends ConsumerWidget {
  const _TvExperienceStep({
    required this.preferences,
    required this.firstFocusNode,
    required this.watchPartyFocusNode,
    required this.downloadsFocusNode,
    required this.continueFocusNode,
  });

  final SettingsPreferences preferences;
  final FocusNode firstFocusNode;
  final FocusNode watchPartyFocusNode;
  final FocusNode downloadsFocusNode;
  final FocusNode continueFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(settingsPreferencesProvider.notifier);
    final isTelevision = ref.watch(isTelevisionProvider);
    return _SetupPage(
      icon: Icons.tune_rounded,
      title: isTelevision
          ? 'Make it feel right on your TV'
          : 'Make it feel right on your phone',
      subtitle: 'Choose how Home looks and keep your everyday shortcuts close.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 700;
          final blockWidth = twoColumns
              ? (constraints.maxWidth - 12) / 2
              : constraints.maxWidth;
          Widget block(Widget child) => SizedBox(
            width: blockWidth,
            child: Align(alignment: Alignment.topLeft, child: child),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TvExperiencePreview(preferences: preferences),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                alignment: WrapAlignment.start,
                children: [
                  block(
                    _SetupChoiceRow(
                      label: 'Navigation & logo size',
                      children: [
                        for (final size in NavigationChromeSize.values)
                          _SetupChoice(
                            label: size.displayName,
                            focusNode: size == NavigationChromeSize.values.first
                                ? firstFocusNode
                                : null,
                            selected: preferences.navigationChromeSize == size,
                            onPressed: () =>
                                controller.setNavigationChromeSize(size),
                          ),
                      ],
                    ),
                  ),
                  block(
                    _SetupChoiceRow(
                      label: 'Home layout',
                      children: [
                        for (final layout in HomeLayout.values)
                          _SetupChoice(
                            label: layout.displayName,
                            selected: preferences.homeLayout == layout,
                            onPressed: () => controller.setHomeLayout(layout),
                          ),
                      ],
                    ),
                  ),
                  block(
                    _SetupChoiceRow(
                      label: 'Navigation bar',
                      children: [
                        _SetupChoice(
                          label: 'My List',
                          selected: preferences.showMyList,
                          onPressed: () =>
                              controller.setShowMyList(!preferences.showMyList),
                        ),
                        _SetupChoice(
                          label: 'Discover',
                          selected: preferences.showDiscover,
                          onPressed: () => controller.setShowDiscover(
                            !preferences.showDiscover,
                          ),
                        ),
                        _SetupChoice(
                          label: 'Calendar',
                          selected: preferences.showCalendar,
                          onPressed: () => controller.setShowCalendar(
                            !preferences.showCalendar,
                          ),
                        ),
                        _SetupChoice(
                          label: 'Watch Party',
                          focusNode: watchPartyFocusNode,
                          downFocusNode: continueFocusNode,
                          selected: preferences.showWatchTogether,
                          onPressed: () => controller.setShowWatchTogether(
                            !preferences.showWatchTogether,
                          ),
                        ),
                        if (preferences.offlineDownloadsEnabled)
                          _SetupChoice(
                            label: 'Downloads',
                            focusNode: downloadsFocusNode,
                            downFocusNode: continueFocusNode,
                            selected: preferences.showDownloads,
                            onPressed: () => controller.setShowDownloads(
                              !preferences.showDownloads,
                            ),
                          ),
                      ],
                    ),
                  ),
                  block(
                    _SetupChoiceRow(
                      label: 'Home details',
                      children: [
                        _SetupChoice(
                          label: 'Featured hero',
                          selected: preferences.showHero,
                          onPressed: () =>
                              controller.setShowHero(!preferences.showHero),
                        ),
                        _SetupChoice(
                          label: 'Poster badges',
                          selected: preferences.showPosterMetadata,
                          onPressed: () => controller.setShowPosterMetadata(
                            !preferences.showPosterMetadata,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TvExperiencePreview extends StatelessWidget {
  const _TvExperiencePreview({required this.preferences});

  final SettingsPreferences preferences;

  IconData _iconFor(TopNavigationDestination destination) =>
      switch (destination) {
        TopNavigationDestination.search => Icons.search_rounded,
        TopNavigationDestination.home => Icons.home_rounded,
        TopNavigationDestination.myList => Icons.video_library_rounded,
        TopNavigationDestination.discover => Icons.explore_rounded,
        TopNavigationDestination.calendar => Icons.calendar_month_rounded,
        TopNavigationDestination.watchTogether => Icons.person_outline_rounded,
        TopNavigationDestination.downloads => Icons.download_rounded,
        TopNavigationDestination.settings => Icons.settings_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final visibleDestinations = preferences.topNavigationOrder
        .where(preferences.isTopNavigationDestinationVisible)
        .take(6)
        .toList(growable: false);
    final dense = preferences.homeLayout == HomeLayout.compact;
    final cardCount = dense ? 7 : 5;
    final modern = preferences.interfaceMode != InterfaceMode.phone;
    final (
      railWidth,
      logoSize,
      navigationIconSize,
    ) = switch (preferences.navigationChromeSize) {
      NavigationChromeSize.small => (27.0, 16.0, 8.0),
      NavigationChromeSize.medium => (34.0, 20.0, 10.0),
      NavigationChromeSize.large => (42.0, 24.0, 12.0),
    };
    final content = Stack(
      fit: StackFit.expand,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            gradient: preferences.showHero
                ? LinearGradient(
                    colors: [
                      context.appPalette.accent.withValues(alpha: .45),
                      const Color(0xFF11151C),
                      Colors.black,
                    ],
                  )
                : const LinearGradient(
                    colors: [Color(0xFF11151C), Colors.black],
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    preferences.homeLayout.displayName,
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: context.appPalette.accentBright,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
              if (preferences.showHero) ...[
                const Spacer(),
                Container(
                  width: 70,
                  height: 7,
                  decoration: BoxDecoration(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: 42,
                  height: 12,
                  decoration: BoxDecoration(
                    color: context.appPalette.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
              const Spacer(),
              SizedBox(
                height: dense ? 31 : 37,
                child: Row(
                  children: [
                    for (var index = 0; index < cardCount; index++) ...[
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Color.lerp(
                              context.appPalette.surfaceRaised,
                              context.appPalette.accent,
                              index / (cardCount * 2),
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: preferences.showPosterMetadata
                              ? const Align(
                                  alignment: Alignment.bottomLeft,
                                  child: Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(
                                      Icons.star_rounded,
                                      size: 7,
                                      color: Colors.white,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      if (index != cardCount - 1)
                        SizedBox(width: dense ? 3 : 5),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final rail = AnimatedContainer(
      key: const ValueKey('setup-preview-modern-rail'),
      duration: const Duration(milliseconds: 180),
      width: railWidth,
      color: const Color(0xFF080808),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: logoSize,
            height: logoSize,
            child: Image.asset(
              'assets/branding/tetotv_icon.png',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 3),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topCenter,
              child: Column(
                children: [
                  for (final destination in visibleDestinations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Icon(
                        _iconFor(destination),
                        size: navigationIconSize,
                        color: destination == TopNavigationDestination.home
                            ? context.appPalette.accentBright
                            : Colors.white70,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    final classicHeader = AnimatedContainer(
      key: const ValueKey('setup-preview-classic-header'),
      duration: const Duration(milliseconds: 180),
      height: railWidth * .62,
      color: const Color(0xFF080808),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(
        children: [
          Image.asset(
            'assets/branding/tetotv_icon.png',
            width: logoSize,
            height: logoSize,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 7),
          for (final destination in visibleDestinations) ...[
            Icon(
              _iconFor(destination),
              size: navigationIconSize,
              color: destination == TopNavigationDestination.home
                  ? context.appPalette.accentBright
                  : Colors.white70,
            ),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: context.appPalette.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      label:
          'Live preview: ${preferences.interfaceMode.displayName}, '
          '${preferences.navigationChromeSize.displayName} navigation and logo, '
          '${preferences.homeLayout.displayName} Home layout, '
          '${preferences.showHero ? 'featured hero shown' : 'featured hero hidden'}',
      child: AnimatedContainer(
        key: const ValueKey('setup-tv-experience-preview'),
        duration: const Duration(milliseconds: 180),
        height: 112,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: context.appPalette.accent.withValues(alpha: .6),
          ),
        ),
        child: modern
            ? Row(
                children: [
                  rail,
                  Expanded(child: content),
                ],
              )
            : Column(
                children: [
                  classicHeader,
                  Expanded(child: content),
                ],
              ),
      ),
    );
  }
}

class _PlaybackStep extends ConsumerWidget {
  const _PlaybackStep({
    required this.preferences,
    required this.firstFocusNode,
  });

  final SettingsPreferences preferences;
  final FocusNode firstFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(settingsPreferencesProvider.notifier);
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final report = ref.watch(deviceSetupProvider).report;
    final showCompatibilityAdvice =
        report != null &&
        report.profile.sdk > 0 &&
        !report.profile.codecs.any(
          (codec) => codec.hardware && codec.mime == 'video/avc',
        );
    return _SetupPage(
      icon: Icons.play_circle_outline_rounded,
      title: 'Choose your playback defaults',
      subtitle: 'Set your language, subtitles, input, and skipping.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 700;
          final blockWidth = twoColumns
              ? (constraints.maxWidth - 12) / 2
              : constraints.maxWidth;
          Widget block(Widget child) => SizedBox(
            width: blockWidth,
            child: Align(alignment: Alignment.topLeft, child: child),
          );

          return Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.start,
            children: [
              block(
                _SetupChoiceRow(
                  label: 'Audio & subtitle default',
                  children: [
                    for (final audio in PlaybackAudioPreference.values)
                      _SetupChoice(
                        label: audio.displayName,
                        focusNode: audio == PlaybackAudioPreference.values.first
                            ? firstFocusNode
                            : null,
                        selected: preferences.preferredAudio == audio,
                        onPressed: () => controller.setPreferredAudio(audio),
                      ),
                  ],
                ),
              ),
              block(
                _SetupChoiceRow(
                  label: 'Anime title language',
                  children: [
                    for (final language in TitleLanguagePreference.values)
                      _SetupChoice(
                        label: language.displayName,
                        selected: titlePreference == language,
                        onPressed: () => ref
                            .read(titleLanguagePreferenceProvider.notifier)
                            .setPreference(language),
                      ),
                  ],
                ),
              ),
              block(
                _SetupChoiceRow(
                  label: 'Text input',
                  children: [
                    _SetupChoice(
                      label: 'TetoTV keyboard',
                      selected: preferences.useBuiltInKeyboard,
                      onPressed: () => controller.setUseBuiltInKeyboard(true),
                    ),
                    _SetupChoice(
                      label: 'Device keyboard',
                      selected: !preferences.useBuiltInKeyboard,
                      onPressed: () => controller.setUseBuiltInKeyboard(false),
                    ),
                  ],
                ),
              ),
              block(
                _SetupChoiceRow(
                  label: 'Automatic skipping',
                  children: [
                    _SetupChoice(
                      label: 'Skip intros',
                      selected: preferences.autoSkipIntros,
                      onPressed: () => controller.setAutoSkipIntros(
                        !preferences.autoSkipIntros,
                      ),
                    ),
                    _SetupChoice(
                      label: 'Skip outros',
                      selected: preferences.autoSkipOutros,
                      onPressed: () => controller.setAutoSkipOutros(
                        !preferences.autoSkipOutros,
                      ),
                    ),
                  ],
                ),
              ),
              if (showCompatibilityAdvice)
                SizedBox(
                  width: constraints.maxWidth,
                  child: const _SetupNote(
                    key: ValueKey('setup-compatibility-warning'),
                    icon: Icons.info_outline_rounded,
                    text:
                        'For smoother playback on this TV, start with 1080p H.264 releases. TetoTV will use compatibility playback automatically.',
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AccountsStep extends ConsumerWidget {
  const _AccountsStep({required this.firstFocusNode});

  final FocusNode firstFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(settingsPreferencesProvider);
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final trackingConnected = accounts.isConnected(
      preferences.trackingProvider,
    );
    final isTelevision = ref.watch(isTelevisionProvider);
    final discord = ref.watch(discordPresenceControllerProvider);
    final discordController = ref.read(
      discordPresenceControllerProvider.notifier,
    );
    final discordLabel = discord.busy
        ? 'Connecting Discord'
        : !discord.loaded
        ? 'Checking Discord'
        : !discord.available
        ? 'Discord unavailable on this device'
        : discord.linked
        ? discord.enabled
              ? 'Discord linked and enabled'
              : 'Discord linked but disabled'
        : 'Link Discord (optional)';
    return _SetupPage(
      icon: Icons.people_alt_outlined,
      title: 'Connect your accounts',
      subtitle: 'Sync your watchlist and Discord presence, or skip either one.',
      child: Column(
        children: [
          _SetupChoiceRow(
            label: 'Anime list',
            children: [
              for (final provider in TrackingProvider.values)
                _SetupChoice(
                  label: provider.displayName,
                  focusNode: provider == TrackingProvider.values.first
                      ? firstFocusNode
                      : null,
                  selected: preferences.trackingProvider == provider,
                  onPressed: () => ref
                      .read(settingsPreferencesProvider.notifier)
                      .setTrackingProvider(provider),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _SetupButton(
            label: trackingConnected
                ? '${preferences.trackingProvider.displayName} connected'
                : 'Connect ${preferences.trackingProvider.displayName}',
            icon: trackingConnected
                ? Icons.check_rounded
                : Icons.qr_code_rounded,
            onPressed: () => context.push(
              preferences.trackingProvider == TrackingProvider.anilist
                  ? '/pair/anilist'
                  : '/pair/myanimelist',
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Discord presence',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          if (discord.busy || !discord.loaded || !discord.available)
            _FeaturePill(Icons.forum_rounded, discordLabel)
          else
            _SetupButton(
              label: discordLabel,
              icon: discord.linked ? Icons.check_rounded : Icons.forum_rounded,
              primary: !discord.linked,
              onPressed: discord.linked
                  ? () => discordController.setEnabled(!discord.enabled)
                  : () async {
                      final resolver = ref.read(
                        discordAccountLinkResolverProvider,
                      );
                      final flow = await resolver.resolve(
                        startupTelevision: isTelevision,
                      );
                      if (!context.mounted) return;
                      if (flow == DiscordAccountLinkFlow.deviceQr) {
                        await context.push('/pair/discord');
                      } else {
                        await discordController.linkAccount();
                      }
                    },
            ),
          const SizedBox(height: 9),
          Text(
            'Connections are optional. TetoTV never sees or stores your account passwords.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appPalette.mutedText, fontSize: 10),
          ),
          if (discord.error case final error?) ...[
            const SizedBox(height: 9),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appPalette.accentBright),
            ),
          ],
        ],
      ),
    );
  }
}

class _StreamingStep extends ConsumerWidget {
  const _StreamingStep({required this.firstFocusNode});

  final FocusNode firstFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(settingsPreferencesProvider);
    final realDebrid = ref.watch(realDebridSettingsControllerProvider);
    final torBox = ref.watch(torBoxSettingsControllerProvider);
    final allDebrid = ref.watch(allDebridSettingsControllerProvider);
    final premiumize = ref.watch(premiumizeSettingsControllerProvider);
    final marketplace = ref.watch(marketplaceControllerProvider);
    final torrentSources = ref.watch(userTorrentSourcesControllerProvider);
    final repositoryCount = marketplace.repositories.length;
    final manifestCount = torrentSources.manifestUrls.length;
    final selectedConnected = switch (preferences.debridProvider) {
      DebridService.realDebrid => realDebrid.hasSavedToken,
      DebridService.torBox => torBox.hasSavedToken,
      DebridService.allDebrid => allDebrid.hasSavedToken,
      DebridService.premiumize => premiumize.hasSavedToken,
    };
    return _SetupPage(
      icon: Icons.cloud_done_rounded,
      title: 'Set up streaming',
      subtitle:
          'Choose a debrid provider if you use one. Connecting it now is optional.',
      child: Column(
        children: [
          const Text(
            'Debrid provider',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final service in DebridService.values)
                _SetupChoice(
                  label: service.displayName,
                  focusNode: service == DebridService.values.first
                      ? firstFocusNode
                      : null,
                  selected: preferences.debridProvider == service,
                  onPressed: () => ref
                      .read(settingsPreferencesProvider.notifier)
                      .setDebridProvider(service),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _SetupButton(
            label: selectedConnected
                ? '${preferences.debridProvider.displayName} connected'
                : 'Connect ${preferences.debridProvider.displayName}',
            icon: selectedConnected
                ? Icons.check_rounded
                : Icons.qr_code_rounded,
            primary: !selectedConnected,
            onPressed: () => context.push(switch (preferences.debridProvider) {
              DebridService.realDebrid => '/pair/realdebrid',
              DebridService.torBox => '/pair/torbox',
              DebridService.allDebrid => '/pair/alldebrid',
              DebridService.premiumize => '/pair/premiumize',
            }),
          ),
          const SizedBox(height: 20),
          const Text(
            'Your sources',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(
            'Add only repositories and manifests you trust and are authorized to use. TetoTV does not bundle or recommend sources.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appPalette.mutedText, fontSize: 10),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              _SourceCount(
                icon: Icons.extension_rounded,
                count: repositoryCount,
                label: repositoryCount == 1
                    ? 'Marketplace repository'
                    : 'Marketplace repositories',
              ),
              _SourceCount(
                icon: Icons.cloud_download_outlined,
                count: manifestCount,
                label: manifestCount == 1
                    ? 'Torrent source manifest'
                    : 'Torrent source manifests',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              _SetupButton(
                label: 'Add sources with phone',
                icon: Icons.phone_android_rounded,
                primary: true,
                onPressed: () => showSourcePairingDialog(context),
              ),
              _SetupButton(
                label: 'Open Marketplace manually',
                icon: Icons.tune_rounded,
                onPressed: () => context.push('/settings/marketplace'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PrivacyStep extends ConsumerWidget {
  const _PrivacyStep({required this.preferences, required this.firstFocusNode});

  final SettingsPreferences preferences;
  final FocusNode firstFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.read(settingsPreferencesProvider.notifier);
    final isBeta = ref.watch(isInstalledBetaBuildProvider);
    return _SetupPage(
      icon: Icons.privacy_tip_outlined,
      title: 'One last choice',
      subtitle: 'Review the optional privacy controls used by this build.',
      child: Column(
        children: [
          _SetupChoiceRow(
            label: 'Anonymous crash and error reports',
            children: [
              _SetupChoice(
                label: 'Do not send',
                focusNode: firstFocusNode,
                selected: !preferences.anonymousCrashReportingEnabled,
                onPressed: () =>
                    settings.setAnonymousCrashReportingEnabled(false),
              ),
              _SetupChoice(
                label: 'Allow error reports',
                selected: preferences.anonymousCrashReportingEnabled,
                onPressed: () =>
                    settings.setAnonymousCrashReportingEnabled(true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Reports may include the app version, Android version, device class, error type, time, and a redacted trace. They never include what you watch, accounts, device IDs, sources, or URLs.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appPalette.mutedText, fontSize: 10),
          ),
          if (isBeta) ...[
            const SizedBox(height: 12),
            _SetupChoiceRow(
              label: 'Anonymous Beta live count',
              children: [
                _SetupChoice(
                  label: 'Count me in',
                  selected: preferences.anonymousUsageCountEnabled,
                  onPressed: () => settings.setAnonymousUsageCountEnabled(true),
                ),
                _SetupChoice(
                  label: 'Opt out',
                  selected: !preferences.anonymousUsageCountEnabled,
                  onPressed: () =>
                      settings.setAnonymousUsageCountEnabled(false),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Shares only whether this Beta app process is active or has an '
              'MPV player open. A paused or loading player can still count as '
              'watching. No profile, title, episode, source, device ID, URL, or media '
              'information is sent. HTTPS and abuse limits may process your IP, '
              'but it is not stored in the presence record.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontSize: 10,
              ),
            ),
          ],
          const SizedBox(height: 18),
          const _SetupNote(
            icon: Icons.check_circle_outline_rounded,
            text:
                'That’s it. Your choices are saved on this TV and remain available in Settings.',
          ),
        ],
      ),
    );
  }
}

class _SourceCount extends StatelessWidget {
  const _SourceCount({
    required this.icon,
    required this.count,
    required this.label,
  });

  final IconData icon;
  final int count;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(
      color: context.appPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.white12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: context.appPalette.secondaryAccent),
        const SizedBox(width: 7),
        Text(
          '$count',
          style: TextStyle(
            color: context.appPalette.accentBright,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

class _SetupPage extends StatelessWidget {
  const _SetupPage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final contentWidth = constraints.maxWidth.clamp(0.0, 900.0).toDouble();
      final card = SizedBox(
        width: contentWidth,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(context.isCompactWidth ? 18 : 22),
          decoration: BoxDecoration(
            color: context.appPalette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: .08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, color: context.appPalette.accentBright, size: 40),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 5),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.appPalette.mutedText),
              ),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      );
      if (context.isCompactWidth) {
        return SingleChildScrollView(child: Center(child: card));
      }
      // TV steps always stay inside the current viewport. Large-content steps
      // scale down as a unit instead of hiding their final choices below a
      // scroll edge that is easy to miss with a remote.
      return ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          child: FittedBox(
            key: const ValueKey('setup-tv-fit-without-scroll'),
            fit: BoxFit.scaleDown,
            alignment: Alignment.topCenter,
            child: card,
          ),
        ),
      );
    },
  );
}

class _SetupProgress extends StatelessWidget {
  const _SetupProgress({
    required this.step,
    required this.count,
    required this.label,
  });

  final int step;
  final int count;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
          ),
          const Spacer(),
          Text(
            '${step + 1} of $count',
            style: TextStyle(color: context.appPalette.mutedText, fontSize: 11),
          ),
        ],
      ),
      const SizedBox(height: 7),
      Row(
        children: [
          for (var index = 0; index < count; index++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 3,
                decoration: BoxDecoration(
                  color: index <= step
                      ? context.appPalette.accentBright
                      : Colors.white12,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            if (index != count - 1) const SizedBox(width: 5),
          ],
        ],
      ),
    ],
  );
}

class _SetupChoiceRow extends StatelessWidget {
  const _SetupChoiceRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.start,
        children: children,
      ),
    ],
  );
}

class _SetupChoice extends StatelessWidget {
  const _SetupChoice({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    this.downFocusNode,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final FocusNode? downFocusNode;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    onKeyEvent: downFocusNode == null
        ? null
        : (node, event) {
            if (event is! KeyDownEvent ||
                event.logicalKey != LogicalKeyboardKey.arrowDown) {
              return KeyEventResult.ignored;
            }
            downFocusNode!.requestFocus();
            return KeyEventResult.handled;
          },
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      height: 40,
      padding: EdgeInsets.symmetric(
        horizontal: context.isCompactWidth ? 10 : 14,
      ),
      decoration: BoxDecoration(
        color: selected
            ? context.appPalette.accent
            : context.appPalette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? context.appPalette.accentBright : Colors.white12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(selected ? Icons.check_rounded : Icons.add_rounded, size: 17),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    ),
  );
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(
      color: context.appPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: Colors.white12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: context.appPalette.secondaryAccent),
        const SizedBox(width: 7),
        Flexible(child: Text(label)),
      ],
    ),
  );
}

class _SetupNote extends StatelessWidget {
  const _SetupNote({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 660),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: context.appPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: context.appPalette.secondaryAccent),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _SetupButton extends StatelessWidget {
  const _SetupButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.focusNode,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: primary
            ? context.appPalette.accent
            : context.appPalette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19, color: primary ? Colors.white : null),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: primary ? Colors.white : null,
                fontSize: context.isCompactWidth ? 12 : null,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
