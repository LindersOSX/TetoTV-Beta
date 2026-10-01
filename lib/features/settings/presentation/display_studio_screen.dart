import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_studio_components.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/home_shelf_preferences_controller.dart';
import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Display choices stay in a draft until Apply. A stable editor lets people
/// compare layouts without moving the controls beneath their finger or D-pad.
class DisplayStudioScreen extends ConsumerStatefulWidget {
  const DisplayStudioScreen({super.key});

  static const routePath = '/settings/display-studio';

  @override
  ConsumerState<DisplayStudioScreen> createState() =>
      _DisplayStudioScreenState();
}

class _DisplayStudioScreenState extends ConsumerState<DisplayStudioScreen> {
  late SettingsPreferences _draft;
  bool _edited = false;
  bool _saving = false;
  bool _previewPhone = false;
  bool _menuExpanded = false;
  bool _shelvesExpanded = false;
  late Set<HomeShelf> _draftShelves;
  late List<HomeShelf> _draftShelfOrder;
  final _interfaceFocus = FocusNode(debugLabel: 'display-studio.interface');
  final _thumbnailFocus = FocusNode(debugLabel: 'display-studio.thumbnail');
  final _densityFocus = FocusNode(debugLabel: 'display-studio.density');
  final _layoutFocus = FocusNode(debugLabel: 'display-studio.layout');
  final _navigationFocus = FocusNode(debugLabel: 'display-studio.navigation');
  final _landingFocus = FocusNode(debugLabel: 'display-studio.landing-page');
  final _menuFocus = FocusNode(debugLabel: 'display-studio.menu-order');
  final _shelvesFocus = FocusNode(debugLabel: 'display-studio.home-shelves');
  final _applyFocus = FocusNode(debugLabel: 'display-studio.apply');
  final _resetFocus = FocusNode(debugLabel: 'display-studio.reset');

  @override
  void initState() {
    super.initState();
    _draft = ref.read(settingsPreferencesProvider);
    _draftShelves = {...ref.read(homeShelfPreferencesProvider)};
    _draftShelfOrder = [...ref.read(homeShelfOrderProvider)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _interfaceFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _interfaceFocus.dispose();
    _thumbnailFocus.dispose();
    _densityFocus.dispose();
    _layoutFocus.dispose();
    _navigationFocus.dispose();
    _landingFocus.dispose();
    _menuFocus.dispose();
    _shelvesFocus.dispose();
    _applyFocus.dispose();
    _resetFocus.dispose();
    super.dispose();
  }

  bool _isArrow(KeyEvent event, LogicalKeyboardKey key) =>
      (event is KeyDownEvent || event is KeyRepeatEvent) &&
      event.logicalKey == key;

  void _focusAndReveal(FocusNode node) {
    node.requestFocus();
    if (node.context case final context?) {
      Scrollable.ensureVisible(
        context,
        alignment: .8,
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
      );
    }
  }

  void _focusAvailableAction() => _focusAndReveal(
    _applyFocus.canRequestFocus && _applyFocus.context != null
        ? _applyFocus
        : _resetFocus,
  );

  KeyEventResult _menuKey(FocusNode _, KeyEvent event) {
    if (_isArrow(event, LogicalKeyboardKey.arrowDown) && !_menuExpanded) {
      _focusAndReveal(_shelvesFocus);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _shelvesKey(FocusNode _, KeyEvent event) {
    if (_isArrow(event, LogicalKeyboardKey.arrowUp)) {
      _focusAndReveal(_menuFocus);
      return KeyEventResult.handled;
    }
    if (_isArrow(event, LogicalKeyboardKey.arrowDown) && !_shelvesExpanded) {
      _focusAvailableAction();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _applyKey(FocusNode _, KeyEvent event) {
    if (_isArrow(event, LogicalKeyboardKey.arrowUp)) {
      _focusAndReveal(_shelvesFocus);
      return KeyEventResult.handled;
    }
    if (_isArrow(event, LogicalKeyboardKey.arrowRight)) {
      _focusAndReveal(_resetFocus);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _resetKey(FocusNode _, KeyEvent event) {
    if (_isArrow(event, LogicalKeyboardKey.arrowUp)) {
      _focusAndReveal(_shelvesFocus);
      return KeyEventResult.handled;
    }
    if (_isArrow(event, LogicalKeyboardKey.arrowLeft) &&
        _applyFocus.canRequestFocus) {
      _focusAndReveal(_applyFocus);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _change(SettingsPreferences value) => setState(() {
    _draft = value;
    _edited = true;
  });

  Future<void> _selectLandingPage() async {
    final options = LandingPage.values
        .where(
          (page) => switch (page) {
            LandingPage.home => true,
            LandingPage.search => _draft.showSearch,
            LandingPage.myList => _draft.showMyList,
            LandingPage.discover => _draft.showDiscover,
            LandingPage.calendar => _draft.showCalendar,
          },
        )
        .toList(growable: false);
    final selected = await showTetoDialog<LandingPage>(
      context: context,
      builder: (context) => _LandingPagePickerDialog(
        selected: _draft.defaultLandingPage,
        options: options,
      ),
    );
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _landingFocus.requestFocus();
    });
    if (selected != null && selected != _draft.defaultLandingPage) {
      _change(_draft.copyWith(defaultLandingPage: selected));
    }
  }

  void _changeShelves(Set<HomeShelf> enabled, List<HomeShelf> order) =>
      setState(() {
        _draftShelves = enabled;
        _draftShelfOrder = order;
        _edited = true;
      });

  void _moveShelf(HomeShelf shelf, int offset) {
    final order = [..._draftShelfOrder];
    final index = order.indexOf(shelf);
    if (index < 0 || index + offset < 0 || index + offset >= order.length) {
      return;
    }
    order.removeAt(index);
    order.insert(index + offset, shelf);
    _changeShelves({..._draftShelves}, order);
  }

  void _move(TopNavigationDestination destination, int offset) {
    final order = [..._draft.topNavigationOrder];
    final displayed = order
        .where(
          (item) =>
              item != TopNavigationDestination.downloads ||
              _draft.offlineDownloadsEnabled,
        )
        .toList();
    final index = displayed.indexOf(destination);
    if (index < 0 || index + offset < 0 || index + offset >= displayed.length) {
      return;
    }
    final first = order.indexOf(destination);
    final second = order.indexOf(displayed[index + offset]);
    order[first] = order[second];
    order[second] = destination;
    _change(_draft.copyWith(topNavigationOrder: order));
  }

  void _toggleDestination(TopNavigationDestination destination, bool visible) {
    final next = switch (destination) {
      TopNavigationDestination.home => _draft.copyWith(showHome: visible),
      TopNavigationDestination.search => _draft.copyWith(showSearch: visible),
      TopNavigationDestination.myList => _draft.copyWith(showMyList: visible),
      TopNavigationDestination.discover => _draft.copyWith(
        showDiscover: visible,
      ),
      TopNavigationDestination.calendar => _draft.copyWith(
        showCalendar: visible,
      ),
      TopNavigationDestination.watchTogether => _draft.copyWith(
        showWatchTogether: visible,
      ),
      TopNavigationDestination.manga => _draft.copyWith(
        mangaReaderEnabled: visible,
      ),
      TopNavigationDestination.downloads => _draft.copyWith(
        showDownloads: visible,
      ),
      TopNavigationDestination.settings => _draft.copyWith(
        showSettings: visible,
      ),
    };
    final page = switch (destination) {
      TopNavigationDestination.home => LandingPage.home,
      TopNavigationDestination.search => LandingPage.search,
      TopNavigationDestination.myList => LandingPage.myList,
      TopNavigationDestination.discover => LandingPage.discover,
      TopNavigationDestination.calendar => LandingPage.calendar,
      _ => null,
    };
    _change(
      !visible && next.defaultLandingPage == page
          ? next.copyWith(defaultLandingPage: LandingPage.home)
          : next,
    );
  }

  double _percentStep(double value, double minimum, double maximum) =>
      ((value * 100).round() / 100).clamp(minimum, maximum);

  bool _hasChanges(
    SettingsPreferences saved,
    Set<HomeShelf> savedShelves,
    List<HomeShelf> savedShelfOrder,
  ) =>
      (_draft.interfaceScale - saved.interfaceScale).abs() > .001 ||
      (_draft.thumbnailScale - saved.thumbnailScale).abs() > .001 ||
      (_draft.effectiveContentDensityScale - saved.effectiveContentDensityScale)
              .abs() >
          .001 ||
      (_draft.effectiveHomeLayoutCompactness -
                  saved.effectiveHomeLayoutCompactness)
              .abs() >
          .001 ||
      _draft.showCardSubtitles != saved.showCardSubtitles ||
      _draft.showHero != saved.showHero ||
      _draft.showPosterMetadata != saved.showPosterMetadata ||
      (_draft.effectiveNavigationChromeScale -
                  saved.effectiveNavigationChromeScale)
              .abs() >
          .001 ||
      _draft.expandNavigationLabelsOnFocus !=
          saved.expandNavigationLabelsOnFocus ||
      _draft.reduceMotion != saved.reduceMotion ||
      _draft.blurEffectsEnabled != saved.blurEffectsEnabled ||
      _draft.defaultLandingPage != saved.defaultLandingPage ||
      TopNavigationDestination.values.any(
        (destination) =>
            _draft.isTopNavigationDestinationVisible(destination) !=
            saved.isTopNavigationDestinationVisible(destination),
      ) ||
      !listEquals(_draft.topNavigationOrder, saved.topNavigationOrder) ||
      !setEquals(_draftShelves, savedShelves) ||
      !listEquals(_draftShelfOrder, savedShelfOrder);

  Future<void> _apply() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final controller = ref.read(settingsPreferencesProvider.notifier);
      final saved = ref.read(settingsPreferencesProvider);
      // Apply canvas scaling last so the editor does not resize while the
      // other preferences are being committed.
      if ((_draft.effectiveContentDensityScale -
                  saved.effectiveContentDensityScale)
              .abs() >
          .001) {
        await controller.setContentDensityScale(
          _draft.effectiveContentDensityScale,
        );
      }
      if ((_draft.effectiveHomeLayoutCompactness -
                  saved.effectiveHomeLayoutCompactness)
              .abs() >
          .001) {
        await controller.setHomeLayoutCompactness(
          _draft.effectiveHomeLayoutCompactness,
        );
      }
      if (_draft.showCardSubtitles != saved.showCardSubtitles) {
        await controller.setShowCardSubtitles(_draft.showCardSubtitles);
      }
      if (_draft.showHero != saved.showHero) {
        await controller.setShowHero(_draft.showHero);
      }
      if (_draft.showPosterMetadata != saved.showPosterMetadata) {
        await controller.setShowPosterMetadata(_draft.showPosterMetadata);
      }
      final savedShelves = ref.read(homeShelfPreferencesProvider);
      for (final shelf in HomeShelf.values) {
        if (_draftShelves.contains(shelf) != savedShelves.contains(shelf)) {
          await ref.read(homeShelfPreferencesProvider.notifier).toggle(shelf);
        }
      }
      for (var index = 0; index < _draftShelfOrder.length; index++) {
        final shelf = _draftShelfOrder[index];
        final currentIndex = ref.read(homeShelfOrderProvider).indexOf(shelf);
        if (currentIndex != index) {
          await ref
              .read(homeShelfOrderProvider.notifier)
              .move(shelf, index - currentIndex);
        }
      }
      if ((_draft.effectiveNavigationChromeScale -
                  saved.effectiveNavigationChromeScale)
              .abs() >
          .001) {
        await controller.setNavigationChromeScale(
          _draft.effectiveNavigationChromeScale,
        );
      }
      if (_draft.expandNavigationLabelsOnFocus !=
          saved.expandNavigationLabelsOnFocus) {
        await controller.setExpandNavigationLabelsOnFocus(
          _draft.expandNavigationLabelsOnFocus,
        );
      }
      if (_draft.reduceMotion != saved.reduceMotion) {
        await controller.setReduceMotion(_draft.reduceMotion);
      }
      if (_draft.blurEffectsEnabled != saved.blurEffectsEnabled) {
        await controller.setBlurEffectsEnabled(_draft.blurEffectsEnabled);
      }
      for (final destination in TopNavigationDestination.values) {
        final draftVisible = _draft.isTopNavigationDestinationVisible(
          destination,
        );
        if (draftVisible !=
            saved.isTopNavigationDestinationVisible(destination)) {
          await controller.setTopNavigationDestinationVisible(
            destination,
            draftVisible,
          );
        }
      }
      if (_draft.defaultLandingPage !=
          ref.read(settingsPreferencesProvider).defaultLandingPage) {
        await controller.setDefaultLandingPage(_draft.defaultLandingPage);
      }
      if (!listEquals(_draft.topNavigationOrder, saved.topNavigationOrder)) {
        await controller.setTopNavigationOrder(_draft.topNavigationOrder);
      }
      if ((_draft.thumbnailScale - saved.thumbnailScale).abs() > .001) {
        await controller.setThumbnailScale(_draft.thumbnailScale);
      }
      if ((_draft.interfaceScale - saved.interfaceScale).abs() > .001) {
        await controller.setInterfaceScale(_draft.interfaceScale);
      }
      if (!mounted) return;
      setState(() {
        _draft = ref.read(settingsPreferencesProvider);
        _draftShelves = {...ref.read(homeShelfPreferencesProvider)};
        _draftShelfOrder = [...ref.read(homeShelfOrderProvider)];
        _edited = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('Display settings applied.'))),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Display settings could not be applied.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reset() {
    const defaults = SettingsPreferences();
    _change(
      _draft.copyWith(
        interfaceScale: defaults.interfaceScale,
        thumbnailScale: defaults.thumbnailScale,
        contentDensity: defaults.contentDensity,
        contentDensityScale: defaults.effectiveContentDensityScale,
        homeLayout: defaults.homeLayout,
        homeLayoutCompactness: defaults.effectiveHomeLayoutCompactness,
        showCardSubtitles: defaults.showCardSubtitles,
        showHero: defaults.showHero,
        showPosterMetadata: defaults.showPosterMetadata,
        navigationChromeSize: defaults.navigationChromeSize,
        navigationChromeScale: defaults.effectiveNavigationChromeScale,
        expandNavigationLabelsOnFocus: defaults.expandNavigationLabelsOnFocus,
        reduceMotion: defaults.reduceMotion,
        blurEffectsEnabled: defaults.blurEffectsEnabled,
        defaultLandingPage: defaults.defaultLandingPage,
        showSearch: defaults.showSearch,
        showHome: defaults.showHome,
        showMyList: defaults.showMyList,
        showDiscover: defaults.showDiscover,
        showCalendar: defaults.showCalendar,
        showWatchTogether: defaults.showWatchTogether,
        showDownloads: defaults.showDownloads,
        showSettings: defaults.showSettings,
        mangaReaderEnabled: defaults.mangaReaderEnabled,
        topNavigationOrder: defaultTopNavigationOrder,
      ),
    );
    _changeShelves({...HomeShelf.values}, [...HomeShelf.values]);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final saved = ref.watch(settingsPreferencesProvider);
    final savedShelves = ref.watch(homeShelfPreferencesProvider);
    final savedShelfOrder = ref.watch(homeShelfOrderProvider);
    if (saved.loaded && !_edited && !_saving) {
      _draft = saved;
      _draftShelves = {...savedShelves};
      _draftShelfOrder = [...savedShelfOrder];
    }
    final changed =
        saved.loaded && _hasChanges(saved, savedShelves, savedShelfOrder);

    return Scaffold(
      key: const ValueKey('display-studio-screen'),
      backgroundColor: palette.background,
      body: SafeArea(
        child: !saved.loaded
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TetoUiSpace.pageCompact,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),
                        TetoStudioHeader(
                          title: 'Display Studio',
                          subtitle:
                              'Preview size, layout, cards, and navigation before applying.',
                          onBack: () => Navigator.maybePop(context),
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final wide = constraints.maxWidth >= 820;
                              final controls = ListView(
                                scrollCacheExtent:
                                    const ScrollCacheExtent.pixels(4000),
                                padding: EdgeInsets.only(
                                  right: wide ? 12 : 0,
                                  bottom: 96,
                                ),
                                children: [
                                  ..._buildControls(context),
                                  const SizedBox(height: TetoUiSpace.section),
                                  TetoStudioActions(
                                    key: const ValueKey(
                                      'display-studio-actions',
                                    ),
                                    applyKey: const ValueKey(
                                      'display-studio-apply',
                                    ),
                                    resetKey: const ValueKey(
                                      'display-studio-reset',
                                    ),
                                    applyFocusNode: _applyFocus,
                                    resetFocusNode: _resetFocus,
                                    onApplyKeyEvent: _applyKey,
                                    onResetKeyEvent: _resetKey,
                                    applyEnabled: changed && !_saving,
                                    // Keep Apply reachable from Reset with
                                    // Left even before any draft edit. The
                                    // idle action cannot change settings.
                                    onApply: _saving
                                        ? null
                                        : changed
                                        ? _apply
                                        : () {},
                                    onReset: _saving ? null : _reset,
                                  ),
                                ],
                              );
                              final preview = _DisplayPreview(
                                draft: _draft,
                                shelfOrder: _draftShelfOrder,
                                enabledShelves: _draftShelves,
                                // The whole app already carries the saved
                                // canvas scale; preview only the draft delta.
                                relativeInterfaceScale:
                                    _draft.interfaceScale /
                                    saved.interfaceScale,
                                phoneMode: _previewPhone,
                                onPhoneModeChanged: (value) =>
                                    setState(() => _previewPhone = value),
                              );
                              if (wide) {
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: controls),
                                    const SizedBox(width: 18),
                                    Expanded(
                                      child: SizedBox(
                                        height: 390,
                                        child: preview,
                                      ),
                                    ),
                                  ],
                                );
                              }
                              return Column(
                                children: [
                                  SizedBox(
                                    height: constraints.maxHeight
                                        .clamp(0, 280)
                                        .toDouble(),
                                    child: preview,
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(child: controls),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  List<Widget> _buildControls(BuildContext context) {
    final order = _draft.topNavigationOrder
        .where(
          (destination) =>
              destination != TopNavigationDestination.downloads ||
              _draft.offlineDownloadsEnabled,
        )
        .toList();
    return [
      TetoStudioSectionTitle(context.tr('Size')),
      _DisplayScaleSlider(
        key: const ValueKey('display-studio-interface-slider'),
        label: context.tr('Interface scale'),
        value: _draft.interfaceScale,
        minimum: .8,
        maximum: 1.2,
        focusNode: _interfaceFocus,
        onChanged: (value) => _change(
          _draft.copyWith(interfaceScale: _percentStep(value, .8, 1.2)),
        ),
      ),
      const SizedBox(height: 12),
      _DisplayScaleSlider(
        key: const ValueKey('display-studio-thumbnail-slider'),
        label: context.tr('Thumbnail size'),
        value: _draft.thumbnailScale,
        minimum: .8,
        maximum: 1.25,
        focusNode: _thumbnailFocus,
        onChanged: (value) => _change(
          _draft.copyWith(thumbnailScale: _percentStep(value, .8, 1.25)),
        ),
      ),
      const SizedBox(height: 18),
      TetoStudioSectionTitle(context.tr('Layout & cards')),
      _DisplayScaleSlider(
        key: const ValueKey('display-studio-density-slider'),
        label: context.tr('Content density'),
        value: _draft.effectiveContentDensityScale,
        minimum: .75,
        maximum: 1.25,
        minimumLabel: context.tr('Compact'),
        maximumLabel: context.tr('Comfortable'),
        focusNode: _densityFocus,
        onChanged: (value) => _change(
          _draft.copyWith(contentDensityScale: _percentStep(value, .75, 1.25)),
        ),
      ),
      const SizedBox(height: 12),
      _DisplayScaleSlider(
        key: const ValueKey('display-studio-layout-slider'),
        label: context.tr('Layout style'),
        value: _draft.effectiveHomeLayoutCompactness,
        minimum: 0,
        maximum: 1,
        minimumLabel: context.tr('Cinematic'),
        maximumLabel: context.tr('Compact'),
        focusNode: _layoutFocus,
        onChanged: (value) => _change(
          _draft.copyWith(homeLayoutCompactness: _percentStep(value, 0, 1)),
        ),
      ),
      const SizedBox(height: 12),
      _StudioSwitchRow(
        key: const ValueKey('display-studio-card-details'),
        label: context.tr('Card details'),
        value: _draft.showCardSubtitles,
        onChanged: (value) =>
            _change(_draft.copyWith(showCardSubtitles: value)),
      ),
      const SizedBox(height: 12),
      _StudioSwitchRow(
        key: const ValueKey('display-studio-featured-hero'),
        label: context.tr('Featured hero'),
        value: _draft.showHero,
        onChanged: (value) => _change(_draft.copyWith(showHero: value)),
      ),
      const SizedBox(height: 12),
      _StudioSwitchRow(
        key: const ValueKey('display-studio-poster-metadata'),
        label: context.tr('Poster metadata'),
        subtitle: context.tr('Show rating and release year on poster covers.'),
        value: _draft.showPosterMetadata,
        onChanged: (value) =>
            _change(_draft.copyWith(showPosterMetadata: value)),
      ),
      const SizedBox(height: 18),
      TetoStudioSectionTitle(context.tr('Effects & motion')),
      _StudioSwitchRow(
        key: const ValueKey('display-studio-blur-effects'),
        label: context.tr('Blur effects'),
        subtitle: context.tr(
          'Soften backgrounds behind navigation, menus, and player controls.',
        ),
        value: _draft.blurEffectsEnabled,
        onChanged: (value) =>
            _change(_draft.copyWith(blurEffectsEnabled: value)),
      ),
      const SizedBox(height: 12),
      _StudioSwitchRow(
        key: const ValueKey('display-studio-reduce-motion'),
        label: context.tr('Reduce motion'),
        subtitle: context.tr(
          'Use instant transitions and keep focused controls still.',
        ),
        value: _draft.reduceMotion,
        onChanged: (value) => _change(_draft.copyWith(reduceMotion: value)),
      ),
      const SizedBox(height: 18),
      TetoStudioSectionTitle(context.tr('Navigation')),
      _DisplayScaleSlider(
        key: const ValueKey('display-studio-navigation-slider'),
        label: context.tr('Navigation size'),
        value: _draft.effectiveNavigationChromeScale,
        minimum: .8,
        maximum: 1.25,
        minimumLabel: context.tr('Small'),
        maximumLabel: context.tr('Large'),
        focusNode: _navigationFocus,
        onChanged: (value) => _change(
          _draft.copyWith(navigationChromeScale: _percentStep(value, .8, 1.25)),
        ),
      ),
      const SizedBox(height: 12),
      _StudioSwitchRow(
        key: const ValueKey('display-studio-expand-navigation-labels'),
        label: context.tr('Expand navigation labels'),
        subtitle: context.tr(
          'Show an animated name beside a navigation icon while it is hovered or focused.',
        ),
        value: _draft.expandNavigationLabelsOnFocus,
        onChanged: (value) =>
            _change(_draft.copyWith(expandNavigationLabelsOnFocus: value)),
      ),
      const SizedBox(height: 12),
      _LandingPageRow(
        key: const ValueKey('display-studio-landing-page'),
        focusNode: _landingFocus,
        value: _draft.defaultLandingPage,
        onPressed: _selectLandingPage,
      ),
      const SizedBox(height: 18),
      _StudioExpandableSection(
        key: const ValueKey('display-studio-menu-order'),
        focusNode: _menuFocus,
        onKeyEvent: _menuKey,
        title: context.tr('Menu order'),
        subtitle: context.tr(
          'Choose which buttons are shown and use the arrows to move them. Settings always remains in the profile menu.',
        ),
        expanded: _menuExpanded,
        onChanged: (value) => setState(() => _menuExpanded = value),
        children: [
          for (var index = 0; index < order.length; index++)
            Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                if (index == order.length - 1 &&
                    _isArrow(event, LogicalKeyboardKey.arrowDown)) {
                  _focusAndReveal(_shelvesFocus);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: _StudioMenuOrderRow(
                key: ValueKey('display-studio-menu-${order[index].name}'),
                label: context.tr(order[index].displayName),
                visible: _draft.isTopNavigationDestinationVisible(order[index]),
                onVisibleChanged: (value) =>
                    _toggleDestination(order[index], value),
                onMoveUp: index == 0 ? null : () => _move(order[index], -1),
                onMoveDown: index == order.length - 1
                    ? null
                    : () => _move(order[index], 1),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      _StudioExpandableSection(
        key: const ValueKey('display-studio-home-shelves'),
        focusNode: _shelvesFocus,
        onKeyEvent: _shelvesKey,
        title: context.tr('Home shelves'),
        subtitle: context.tr('Choose which shelves appear and their order.'),
        expanded: _shelvesExpanded,
        onChanged: (value) => setState(() => _shelvesExpanded = value),
        children: [
          for (var index = 0; index < _draftShelfOrder.length; index++)
            Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                if (index == _draftShelfOrder.length - 1 &&
                    _isArrow(event, LogicalKeyboardKey.arrowDown)) {
                  _focusAvailableAction();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: _StudioMenuOrderRow(
                key: ValueKey(
                  'display-studio-shelf-${_draftShelfOrder[index].name}',
                ),
                label: context.tr(_draftShelfOrder[index].displayName),
                visible: _draftShelves.contains(_draftShelfOrder[index]),
                onVisibleChanged: (value) {
                  final next = {..._draftShelves};
                  value
                      ? next.add(_draftShelfOrder[index])
                      : next.remove(_draftShelfOrder[index]);
                  _changeShelves(next, [..._draftShelfOrder]);
                },
                onMoveUp: index == 0
                    ? null
                    : () => _moveShelf(_draftShelfOrder[index], -1),
                onMoveDown: index == _draftShelfOrder.length - 1
                    ? null
                    : () => _moveShelf(_draftShelfOrder[index], 1),
              ),
            ),
        ],
      ),
    ];
  }
}

class _StudioExpandableSection extends StatelessWidget {
  const _StudioExpandableSection({
    required this.focusNode,
    required this.onKeyEvent,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onChanged,
    required this.children,
    super.key,
  });

  final String title;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final String subtitle;
  final bool expanded;
  final ValueChanged<bool> onChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) => AnimatedContainer(
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
        decoration: TetoBoxStyle.decoration(
          palette,
          focused: focusNode.hasFocus,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: expanded,
              child: TvFocusable(
                focusNode: focusNode,
                onKeyEvent: onKeyEvent,
                onPressed: () => onChanged(!expanded),
                focusScale: 1.005,
                showFocusRing: false,
                borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              subtitle,
                              style: TextStyle(color: palette.mutedText),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: expanded ? .5 : 0,
                        duration: TetoUiMotion.duration(
                          context,
                          TetoUiMotion.reveal,
                        ),
                        child: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: TetoUiMotion.duration(context, TetoUiMotion.reveal),
              curve: TetoUiMotion.curve,
              child: expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Column(children: children),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _LandingPageRow extends StatelessWidget {
  const _LandingPageRow({
    required this.focusNode,
    required this.value,
    required this.onPressed,
    super.key,
  });

  final FocusNode focusNode;
  final LandingPage value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TetoStudioFocusSurface(
    child: TvFocusable(
      focusNode: focusNode,
      onPressed: onPressed,
      showFocusRing: false,
      focusScale: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.tr('Default landing page'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              context.tr(value.displayName),
              style: TextStyle(color: context.appPalette.mutedText),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    ),
  );
}

class _LandingPagePickerDialog extends StatelessWidget {
  const _LandingPagePickerDialog({
    required this.selected,
    required this.options,
  });

  final LandingPage selected;
  final List<LandingPage> options;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 430,
        padding: const EdgeInsets.all(18),
        decoration: TetoBoxStyle.decoration(palette),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('Default landing page'),
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final page in options) ...[
                        if (page != options.first) const SizedBox(height: 8),
                        TvFocusable(
                          key: ValueKey('display-studio-landing-${page.name}'),
                          autofocus: page == selected,
                          onPressed: () => Navigator.of(context).pop(page),
                          focusScale: 1.01,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 13,
                            ),
                            decoration: TetoBoxStyle.decoration(
                              palette,
                              focused: page == selected,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(context.tr(page.displayName)),
                                ),
                                if (page == selected)
                                  Icon(
                                    Icons.check_rounded,
                                    color: palette.accentBright,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudioSwitchRow extends StatefulWidget {
  const _StudioSwitchRow({
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_StudioSwitchRow> createState() => _StudioSwitchRowState();
}

class _StudioSwitchRowState extends State<_StudioSwitchRow> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TetoStudioFocusSurface(
    child: Theme(
      data: Theme.of(context).copyWith(
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
      ),
      child: SwitchListTile.adaptive(
        title: Text(widget.label),
        subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
        value: widget.value,
        onChanged: widget.onChanged,
        focusNode: _focusNode,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
        ),
        tileColor: Colors.transparent,
      ),
    ),
  );
}

class _StudioMenuOrderRow extends StatelessWidget {
  const _StudioMenuOrderRow({
    required this.label,
    required this.visible,
    required this.onVisibleChanged,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final String label;
  final bool visible;
  final ValueChanged<bool> onVisibleChanged;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TetoStudioFocusSurface(
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(
              visible
                  ? Icons.drag_indicator_rounded
                  : Icons.visibility_off_outlined,
              color: palette.mutedText,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: visible ? palette.primaryText : palette.mutedText,
                ),
              ),
            ),
            Switch.adaptive(
              key: ValueKey(
                'display-studio-visible-${label.toLowerCase().replaceAll(' ', '-')}',
              ),
              value: visible,
              onChanged: onVisibleChanged,
            ),
            IconButton(
              tooltip: context.tr('Move up'),
              onPressed: onMoveUp,
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
            ),
            IconButton(
              tooltip: context.tr('Move down'),
              onPressed: onMoveDown,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisplayScaleSlider extends StatefulWidget {
  const _DisplayScaleSlider({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.focusNode,
    required this.onChanged,
    this.minimumLabel,
    this.maximumLabel,
    super.key,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final FocusNode focusNode;
  final ValueChanged<double> onChanged;
  final String? minimumLabel;
  final String? maximumLabel;

  @override
  State<_DisplayScaleSlider> createState() => _DisplayScaleSliderState();
}

class _DisplayScaleSliderState extends State<_DisplayScaleSlider> {
  bool _focused = false;
  bool _adjusting = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final percent = (widget.value * 100).round();
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() {
        _focused = value;
        if (!value) _adjusting = false;
      }),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          setState(() => _adjusting = !_adjusting);
          return KeyEventResult.handled;
        }
        if (_adjusting &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.goBack)) {
          setState(() => _adjusting = false);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (!_adjusting) return KeyEventResult.handled;
          final delta = event.logicalKey == LogicalKeyboardKey.arrowRight
              ? .01
              : -.01;
          widget.onChanged(
            (widget.value + delta).clamp(widget.minimum, widget.maximum),
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        decoration: TetoBoxStyle.decoration(palette, focused: _focused),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '$percent%',
                  style: TextStyle(
                    color: palette.accentBright,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            ExcludeFocus(
              child: Slider(
                value: widget.value.clamp(widget.minimum, widget.maximum),
                min: widget.minimum,
                max: widget.maximum,
                divisions: ((widget.maximum - widget.minimum) * 100).round(),
                label: '$percent%',
                onChanged: widget.onChanged,
              ),
            ),
            if (widget.minimumLabel != null && widget.maximumLabel != null)
              Row(
                children: [
                  Text(
                    widget.minimumLabel!,
                    style: TextStyle(color: palette.mutedText, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    widget.maximumLabel!,
                    style: TextStyle(color: palette.mutedText, fontSize: 12),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _DisplayPreview extends StatelessWidget {
  const _DisplayPreview({
    required this.draft,
    required this.shelfOrder,
    required this.enabledShelves,
    required this.relativeInterfaceScale,
    required this.phoneMode,
    required this.onPhoneModeChanged,
  });

  final SettingsPreferences draft;
  final List<HomeShelf> shelfOrder;
  final Set<HomeShelf> enabledShelves;
  final double relativeInterfaceScale;
  final bool phoneMode;
  final ValueChanged<bool> onPhoneModeChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final destinations = <TopNavigationDestination>[
      for (final destination in draft.topNavigationOrder)
        if (destination != TopNavigationDestination.settings &&
            draft.isTopNavigationDestinationVisible(destination))
          destination,
      if (draft.isTopNavigationDestinationVisible(
        TopNavigationDestination.settings,
      ))
        TopNavigationDestination.settings,
    ];
    return TetoStudioPreviewFrame(
      key: const ValueKey('display-studio-preview'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.tr('Live preview'),
                  style: TextStyle(
                    color: palette.mutedText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SegmentedButton<bool>(
                key: const ValueKey('display-studio-preview-device'),
                segments: [
                  ButtonSegment(value: false, label: Text(context.tr('TV'))),
                  ButtonSegment(value: true, label: Text(context.tr('Phone'))),
                ],
                selected: {phoneMode},
                showSelectedIcon: false,
                onSelectionChanged: (values) =>
                    onPhoneModeChanged(values.single),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: phoneMode ? 250 : double.infinity,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    color: palette.background,
                    child: phoneMode
                        ? Column(
                            children: [
                              Expanded(
                                child: _PreviewHome(
                                  draft: draft,
                                  shelfOrder: shelfOrder,
                                  enabledShelves: enabledShelves,
                                  scale: relativeInterfaceScale,
                                  phoneMode: true,
                                ),
                              ),
                              _PreviewPhoneNavigation(
                                destinations: destinations,
                                size: draft.effectiveNavigationChromeScale,
                              ),
                            ],
                          )
                        : Stack(
                            children: [
                              Row(
                                children: [
                                  _PreviewTvNavigation(
                                    destinations: destinations,
                                    size: draft.effectiveNavigationChromeScale,
                                    scale: relativeInterfaceScale,
                                  ),
                                  Expanded(
                                    child: _PreviewHome(
                                      draft: draft,
                                      shelfOrder: shelfOrder,
                                      enabledShelves: enabledShelves,
                                      scale: relativeInterfaceScale,
                                      phoneMode: false,
                                    ),
                                  ),
                                ],
                              ),
                              if (draft.expandNavigationLabelsOnFocus &&
                                  destinations.isNotEmpty)
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  child: Container(
                                    key: const ValueKey(
                                      'display-preview-expanded-label',
                                    ),
                                    width: 150 * relativeInterfaceScale,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF050505),
                                      border: Border(
                                        right: BorderSide(
                                          color: palette.accentBright
                                              .withValues(alpha: .35),
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: .6,
                                          ),
                                          blurRadius: 12,
                                          offset: const Offset(5, 0),
                                        ),
                                      ],
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      child: Column(
                                        children: [
                                          SizedBox(
                                            height: 32 * relativeInterfaceScale,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 10,
                                                ),
                                                child: ColorFiltered(
                                                  colorFilter: ColorFilter.mode(
                                                    palette.accentBright,
                                                    BlendMode.srcIn,
                                                  ),
                                                  child: Image.asset(
                                                    'assets/branding/tetotv_in_app_mark.png',
                                                    width:
                                                        27 *
                                                        relativeInterfaceScale,
                                                    height:
                                                        27 *
                                                        relativeInterfaceScale,
                                                    fit: BoxFit.contain,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          for (final destination
                                              in destinations)
                                            Expanded(
                                              child: Container(
                                                decoration:
                                                    destination ==
                                                        TopNavigationDestination
                                                            .home
                                                    ? BoxDecoration(
                                                        color: palette.accent
                                                            .withValues(
                                                              alpha: .2,
                                                            ),
                                                        border: Border(
                                                          left: BorderSide(
                                                            color: palette
                                                                .accentBright,
                                                            width: 2,
                                                          ),
                                                        ),
                                                      )
                                                    : null,
                                                child: Row(
                                                  children: [
                                                    SizedBox(
                                                      width:
                                                          43 *
                                                          draft
                                                              .effectiveNavigationChromeScale *
                                                          relativeInterfaceScale,
                                                      child: Icon(
                                                        _previewNavigationIcon(
                                                          destination,
                                                        ),
                                                        color:
                                                            palette.primaryText,
                                                        size:
                                                            16 *
                                                            relativeInterfaceScale,
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: Text(
                                                        context.tr(
                                                          destination
                                                              .displayName,
                                                        ),
                                                        maxLines: 1,
                                                        overflow:
                                                            TextOverflow.fade,
                                                        softWrap: false,
                                                        style: TextStyle(
                                                          color: palette
                                                              .primaryText,
                                                          fontSize:
                                                              10 *
                                                              relativeInterfaceScale,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _previewNavigationIcon(TopNavigationDestination destination) =>
    switch (destination) {
      TopNavigationDestination.home => Icons.home_rounded,
      TopNavigationDestination.search => Icons.search_rounded,
      TopNavigationDestination.myList => Icons.bookmark_rounded,
      TopNavigationDestination.discover => Icons.explore_rounded,
      TopNavigationDestination.calendar => Icons.calendar_month_rounded,
      TopNavigationDestination.watchTogether => Icons.group_rounded,
      TopNavigationDestination.manga => Icons.menu_book_rounded,
      TopNavigationDestination.downloads => Icons.download_rounded,
      TopNavigationDestination.settings => Icons.settings_rounded,
    };

class _PreviewTvNavigation extends StatelessWidget {
  const _PreviewTvNavigation({
    required this.destinations,
    required this.size,
    required this.scale,
  });

  final List<TopNavigationDestination> destinations;
  final double size;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final factor = size * scale;
    return Container(
      key: const ValueKey('display-preview-rail'),
      width: 43 * factor,
      color: const Color(0xFF090909),
      child: Column(
        children: [
          const SizedBox(height: 9),
          ColorFiltered(
            colorFilter: ColorFilter.mode(
              palette.accentBright,
              BlendMode.srcIn,
            ),
            child: Image.asset(
              'assets/branding/tetotv_in_app_mark.png',
              width: 27 * factor,
              height: 27 * factor,
              fit: BoxFit.contain,
              cacheWidth: 120,
            ),
          ),
          const SizedBox(height: 8),
          for (final destination in destinations)
            Expanded(
              child: Center(
                child: Icon(
                  _previewNavigationIcon(destination),
                  key: ValueKey('display-preview-nav-${destination.name}'),
                  color: destination == TopNavigationDestination.home
                      ? palette.accentBright
                      : palette.mutedText,
                  size: 17 * factor,
                ),
              ),
            ),
          const SizedBox(height: 5),
        ],
      ),
    );
  }
}

class _PreviewPhoneNavigation extends StatelessWidget {
  const _PreviewPhoneNavigation({
    required this.destinations,
    required this.size,
  });

  final List<TopNavigationDestination> destinations;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final factor = size;
    return Container(
      height: 31 * factor,
      color: const Color(0xFF090909),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final destination in destinations.take(5))
            Icon(
              _previewNavigationIcon(destination),
              key: ValueKey('display-preview-nav-${destination.name}'),
              color: destination == TopNavigationDestination.home
                  ? palette.accentBright
                  : palette.mutedText,
              size: 17 * factor,
            ),
        ],
      ),
    );
  }
}

class _PreviewHome extends StatelessWidget {
  const _PreviewHome({
    required this.draft,
    required this.shelfOrder,
    required this.enabledShelves,
    required this.scale,
    required this.phoneMode,
  });

  final SettingsPreferences draft;
  final List<HomeShelf> shelfOrder;
  final Set<HomeShelf> enabledShelves;
  final double scale;
  final bool phoneMode;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final compactness = draft.effectiveHomeLayoutCompactness;
    final spacing = draft.effectiveContentDensityScale;
    final cardWidth = (72 - 15 * compactness) * draft.thumbnailScale;
    final imageHeight = (82 - 17 * compactness) * draft.thumbnailScale;
    final previewShelf = shelfOrder.where(enabledShelves.contains).firstOrNull;
    return Padding(
      padding: EdgeInsets.all(phoneMode ? 7 : 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'TetoTV',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: (phoneMode ? 12 : 16) * scale,
                  ),
                ),
              ),
              Container(
                key: const ValueKey('display-preview-profile'),
                width: 18 * scale,
                height: 18 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.accent.withValues(alpha: .4),
                ),
                child: Icon(
                  Icons.settings_rounded,
                  size: 10 * scale,
                  color: palette.primaryText,
                ),
              ),
            ],
          ),
          SizedBox(height: 7 * spacing),
          if (draft.showHero) ...[
            Container(
              key: const ValueKey('display-preview-hero'),
              height: (65 - 23 * compactness) * scale,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: LinearGradient(
                  colors: [
                    palette.accent.withValues(alpha: .8),
                    palette.surface,
                  ],
                ),
              ),
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(7),
              child: Text(
                context.tr('Featured show'),
                style: TextStyle(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w800,
                  fontSize: 9 * scale,
                ),
              ),
            ),
            SizedBox(height: 9 * spacing),
          ],
          Text(
            previewShelf == null
                ? context.tr('No shelves selected')
                : context.tr(previewShelf.displayName),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 10 * scale),
          ),
          SizedBox(height: 7 * spacing),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxHeight < 20) {
                  return const SizedBox.shrink();
                }
                final cardImageHeight = imageHeight
                    .clamp(
                      0.0,
                      (constraints.maxHeight -
                              (draft.showCardSubtitles ? 15 : 8))
                          .clamp(0.0, double.infinity),
                    )
                    .toDouble();
                return ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var index = 0; index < 5; index++) ...[
                          SizedBox(
                            key: ValueKey('display-preview-card-$index'),
                            width: cardWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  height: cardImageHeight,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: palette.accent.withValues(
                                      alpha: .25 + index * .07,
                                    ),
                                    border: Border.all(
                                      color: index == 0
                                          ? palette.accentBright
                                          : palette.mutedText.withValues(
                                              alpha: .12,
                                            ),
                                    ),
                                  ),
                                  child:
                                      draft.showPosterMetadata &&
                                          cardImageHeight >= 28
                                      ? Align(
                                          alignment: Alignment.bottomCenter,
                                          child: Padding(
                                            padding: const EdgeInsets.all(2),
                                            child: PosterMetadataOverlay(
                                              key: ValueKey(
                                                'display-preview-poster-metadata-$index',
                                              ),
                                              score: 8.7,
                                              releaseYear: 2024,
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  height: 4,
                                  width: cardWidth * .8,
                                  color: palette.primaryText.withValues(
                                    alpha: .65,
                                  ),
                                ),
                                if (draft.showCardSubtitles) ...[
                                  const SizedBox(height: 4),
                                  Container(
                                    key: ValueKey(
                                      'display-preview-card-detail-$index',
                                    ),
                                    height: 3,
                                    width: cardWidth * .6,
                                    color: palette.mutedText.withValues(
                                      alpha: .65,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          SizedBox(width: 8 * spacing),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
