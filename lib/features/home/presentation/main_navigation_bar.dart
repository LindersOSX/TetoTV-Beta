import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/local_profiles_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

enum MainNavigationDestination {
  home,
  myList,
  discover,
  calendar,
  watchTogether,
  downloads,
}

/// The shared geometry contract for the Modern Layout navigation rail.
///
/// Keeping the black rail surface, divider, logo, and actions in one immutable
/// value prevents the surrounding content inset from drifting away from the
/// selected Small/Medium/Large chrome size.
@immutable
class HomeNavigationRailMetrics {
  const HomeNavigationRailMetrics({
    required this.width,
    required this.actionWidth,
    required this.actionHeight,
    required this.iconSize,
    required this.logoSize,
    required this.actionGap,
  });

  final double width;
  final double actionWidth;
  final double actionHeight;
  final double iconSize;
  final double logoSize;
  final double actionGap;
}

/// Resolves all rail geometry from the persisted chrome size.
///
/// The black surface wraps the logo with a small gutter based on the action
/// spacing. It therefore changes with Small/Medium/Large but does not become
/// disproportionately wide merely because the TV canvas is wider.
HomeNavigationRailMetrics homeNavigationRailMetrics(NavigationChromeSize size) {
  final double actionWidth = switch (size) {
    NavigationChromeSize.small => 30,
    NavigationChromeSize.medium => 38,
    NavigationChromeSize.large => 48,
  };
  final double actionHeight = switch (size) {
    NavigationChromeSize.small => 28,
    NavigationChromeSize.medium => 36,
    NavigationChromeSize.large => 44,
  };
  final double iconSize = switch (size) {
    NavigationChromeSize.small => 17,
    NavigationChromeSize.medium => 20,
    NavigationChromeSize.large => 25,
  };
  final double logoSize = switch (size) {
    NavigationChromeSize.small => 34,
    NavigationChromeSize.medium => 42,
    NavigationChromeSize.large => 52,
  };
  final double actionGap = switch (size) {
    NavigationChromeSize.small => 5,
    NavigationChromeSize.medium => 7,
    NavigationChromeSize.large => 8,
  };
  final width = logoSize + ((actionGap + 2) * 2);

  return HomeNavigationRailMetrics(
    width: width,
    actionWidth: actionWidth,
    actionHeight: actionHeight,
    iconSize: iconSize,
    logoSize: logoSize,
    actionGap: actionGap,
  );
}

double homeNavigationRailWidth(double _, NavigationChromeSize size) =>
    homeNavigationRailMetrics(size).width;

/// Resolves touch-sized rail geometry for a physical phone in landscape.
///
/// A rotated phone has the same left-edge navigation model as television, so
/// the Navigation & logo size preference must still be visible there. The
/// phone-specific values keep every action at least 44 logical pixels in both
/// dimensions instead of reusing the smaller television targets verbatim.
HomeNavigationRailMetrics phoneLandscapeNavigationRailMetrics(
  NavigationChromeSize size,
) => switch (size) {
  NavigationChromeSize.small => const HomeNavigationRailMetrics(
    width: 52,
    actionWidth: 44,
    actionHeight: 44,
    iconSize: 20,
    logoSize: 34,
    actionGap: 4,
  ),
  NavigationChromeSize.medium => const HomeNavigationRailMetrics(
    width: 58,
    actionWidth: 46,
    actionHeight: 44,
    iconSize: 22,
    logoSize: 40,
    actionGap: 4,
  ),
  NavigationChromeSize.large => const HomeNavigationRailMetrics(
    width: 68,
    actionWidth: 54,
    actionHeight: 50,
    iconSize: 26,
    logoSize: 50,
    actionGap: 6,
  ),
};

const double phoneBottomNavigationHeight = 64;

/// Home's fixed TV rail. The existing [MainNavigationBar] remains available
/// to compact layouts and the other top-level screens, while Home can match the
/// reference's icon-first 10-foot layout without changing those screens.
class HomeSideNavigation extends ConsumerStatefulWidget {
  const HomeSideNavigation({
    required this.preferences,
    required this.onExitRight,
    this.activeDestination = TopNavigationDestination.home,
    this.activeFocusNode,
    this.onActivePressed,
    this.autofocusActive = false,
    this.onHomePressed,
    this.homeFocusNode,
    this.onFocusChanged,
    required this.metrics,
    super.key,
  });

  final SettingsPreferences preferences;
  final VoidCallback onExitRight;
  final TopNavigationDestination activeDestination;
  final FocusNode? activeFocusNode;
  final VoidCallback? onActivePressed;
  final bool autofocusActive;
  final VoidCallback? onHomePressed;
  final FocusNode? homeFocusNode;
  final ValueChanged<bool>? onFocusChanged;
  final HomeNavigationRailMetrics metrics;

  @override
  ConsumerState<HomeSideNavigation> createState() => _HomeSideNavigationState();
}

class _HomeSideNavigationState extends ConsumerState<HomeSideNavigation> {
  final _repeatGate = TvDirectionalRepeatGate();
  final _actionsScrollController = ScrollController();
  bool _focusRecoveryScheduled = false;
  int _focusRevealGeneration = 0;
  final _fallbackNodes = <TopNavigationDestination, FocusNode>{
    for (final destination in TopNavigationDestination.values)
      destination: FocusNode(debugLabel: 'home.navigation.${destination.name}'),
  };
  List<TopNavigationDestination> _visibleDestinations = const [];
  TopNavigationDestination? _activeFocusDestination;

  TopNavigationDestination? _nearestVisibleDestination() {
    if (_visibleDestinations.isEmpty) return null;
    final order = widget.preferences.topNavigationOrder;
    final activeIndex = order.indexOf(widget.activeDestination);
    if (activeIndex < 0) return _visibleDestinations.first;
    for (var distance = 1; distance < order.length; distance++) {
      final after = activeIndex + distance;
      if (after < order.length && _visibleDestinations.contains(order[after])) {
        return order[after];
      }
      final before = activeIndex - distance;
      if (before >= 0 && _visibleDestinations.contains(order[before])) {
        return order[before];
      }
    }
    return _visibleDestinations.first;
  }

  void _recoverDetachedFocusAfterBuild() {
    if (!widget.autofocusActive || _focusRecoveryScheduled) return;
    _focusRecoveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusRecoveryScheduled = false;
      if (!mounted || !widget.autofocusActive) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary.context != null) return;
      final destination = _activeFocusDestination;
      if (destination == null) {
        widget.onExitRight();
      } else {
        _nodeFor(destination).requestFocus();
      }
    });
  }

  FocusNode _nodeFor(TopNavigationDestination destination) {
    if (destination == _activeFocusDestination) {
      final activeNode =
          widget.activeFocusNode ??
          (widget.activeDestination == TopNavigationDestination.home
              ? widget.homeFocusNode
              : null);
      if (activeNode != null) return activeNode;
    }
    if (destination == TopNavigationDestination.home &&
        widget.homeFocusNode != null) {
      return widget.homeFocusNode!;
    }
    return _fallbackNodes[destination]!;
  }

  KeyEventResult _handleNavigationKey(
    TopNavigationDestination destination,
    KeyEvent event,
  ) {
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        if (_repeatGate.accept(event)) widget.onExitRight();
      } else if (event is KeyUpEvent) {
        _repeatGate.accept(event);
      }
      return KeyEventResult.handled;
    }
    final offset = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowLeft => 0,
      _ => null,
    };
    if (offset == null) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _repeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (offset == 0 || !_repeatGate.accept(event)) {
      return KeyEventResult.handled;
    }
    final current = _visibleDestinations.indexOf(destination);
    if (current < 0) return KeyEventResult.handled;
    final next = (current + offset).clamp(0, _visibleDestinations.length - 1);
    if (next != current) _nodeFor(_visibleDestinations[next]).requestFocus();
    return KeyEventResult.handled;
  }

  void _activateDestination(TopNavigationDestination destination) {
    if (destination == widget.activeDestination &&
        widget.onActivePressed != null) {
      widget.onActivePressed!();
      return;
    }
    switch (destination) {
      case TopNavigationDestination.search:
        context.push('/search');
      case TopNavigationDestination.home:
        (widget.onHomePressed ?? () => context.go('/'))();
      case TopNavigationDestination.myList:
        context.go('/my-list');
      case TopNavigationDestination.discover:
        context.go('/discover');
      case TopNavigationDestination.calendar:
        context.go('/calendar');
      case TopNavigationDestination.watchTogether:
        context.go('/watch-together');
      case TopNavigationDestination.downloads:
        context.go('/downloads');
      case TopNavigationDestination.settings:
        context.push('/settings/accounts');
    }
  }

  void _revealFocusedAction(BuildContext actionContext) {
    final generation = ++_focusRevealGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _focusRevealGeneration) return;
      if (!actionContext.mounted || !_actionsScrollController.hasClients) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          actionContext,
          alignment: .5,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  void dispose() {
    _focusRevealGeneration++;
    _repeatGate.reset();
    _actionsScrollController.dispose();
    for (final entry in _fallbackNodes.entries) {
      if (entry.key == TopNavigationDestination.home &&
          identical(entry.value, widget.homeFocusNode)) {
        continue;
      }
      entry.value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final localProfiles = ref.watch(localProfilesControllerProvider);
    final hasProfile =
        accounts.profiles.isNotEmpty || localProfiles.activeProfile != null;
    final settingsInProfileMenu =
        hasProfile &&
        !accounts.isLoading &&
        widget.preferences.settingsEntryPlacement ==
            SettingsEntryPlacement.profileMenu;
    final configuredDestinations = widget.preferences.topNavigationOrder
        .where(
          (destination) =>
              widget.preferences.isTopNavigationDestinationVisible(
                destination,
              ) &&
              (destination != TopNavigationDestination.settings ||
                  !settingsInProfileMenu),
        )
        .toList(growable: false);
    final showBottomSettings = configuredDestinations.contains(
      TopNavigationDestination.settings,
    );
    // Settings is a fixed utility action on television. Keep every viewer-
    // ordered destination in its configured order, then append Settings to
    // the focus sequence so Up/Down continues to mirror the visible rail even
    // though the utility action is anchored at the bottom.
    _visibleDestinations = [
      for (final destination in configuredDestinations)
        if (destination != TopNavigationDestination.settings) destination,
      if (showBottomSettings) TopNavigationDestination.settings,
    ];
    final regularDestinations = _visibleDestinations
        .where(
          (destination) => destination != TopNavigationDestination.settings,
        )
        .toList(growable: false);
    // Settings may deliberately live under the profile menu. When that makes
    // the current destination absent from the rail, attach the screen-owned
    // focus node to the nearest deterministic visible action instead. LEFT
    // from Settings content can then enter the rail without resurrecting the
    // hidden Settings icon or landing on a detached FocusNode.
    _activeFocusDestination =
        _visibleDestinations.contains(widget.activeDestination)
        ? widget.activeDestination
        : _nearestVisibleDestination();
    _recoverDetachedFocusAfterBuild();
    final metrics = widget.metrics;

    return Container(
      key: const ValueKey('main-navigation'),
      width: metrics.width,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .96),
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: .11)),
        ),
      ),
      child: Column(
        children: [
          SizedBox(height: metrics.actionGap + 5),
          _HomeRailWordmark(metrics: metrics),
          SizedBox(height: metrics.actionGap + 2),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                key: const ValueKey('home-navigation-actions-scroll'),
                controller: _actionsScrollController,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final destination in regularDestinations) ...[
                      _HomeRailAction(
                        key: _navigationKey(destination),
                        destination: destination,
                        metrics: metrics,
                        active: destination == widget.activeDestination,
                        autofocus:
                            widget.autofocusActive &&
                            destination == _activeFocusDestination,
                        focusNode: _nodeFor(destination),
                        onKeyEvent: (_, event) =>
                            _handleNavigationKey(destination, event),
                        onFocused: _revealFocusedAction,
                        onFocusChanged: widget.onFocusChanged,
                        onPressed: () => _activateDestination(destination),
                      ),
                      SizedBox(height: metrics.actionGap),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (showBottomSettings)
            Padding(
              key: const ValueKey('home-navigation-bottom-settings'),
              padding: EdgeInsets.only(top: metrics.actionGap + 4, bottom: 4),
              child: _HomeRailAction(
                key: _navigationKey(TopNavigationDestination.settings),
                destination: TopNavigationDestination.settings,
                metrics: metrics,
                active:
                    widget.activeDestination ==
                    TopNavigationDestination.settings,
                autofocus:
                    widget.autofocusActive &&
                    _activeFocusDestination ==
                        TopNavigationDestination.settings,
                focusNode: _nodeFor(TopNavigationDestination.settings),
                onKeyEvent: (_, event) => _handleNavigationKey(
                  TopNavigationDestination.settings,
                  event,
                ),
                // The fixed utility action is already fully visible and is
                // intentionally outside the scrollable destination group.
                onFocused: (_) {},
                onFocusChanged: widget.onFocusChanged,
                onPressed: () =>
                    _activateDestination(TopNavigationDestination.settings),
              ),
            ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// Persistent primary navigation for a physical phone held in portrait.
///
/// The destination list and route behavior are shared with the TV rail, while
/// the geometry is intentionally different: every item has a 48dp touch
/// target, the row can be swiped on unusually narrow phones, and the selected
/// route uses the same Teto fade without conflating selection with keyboard or
/// gamepad focus.
class PhoneBottomNavigation extends ConsumerStatefulWidget {
  const PhoneBottomNavigation({
    required this.preferences,
    required this.activeDestination,
    this.onActivePressed,
    this.onExitUp,
    this.activeFocusNode,
    super.key,
  });

  final SettingsPreferences preferences;
  final TopNavigationDestination activeDestination;
  final VoidCallback? onActivePressed;
  final VoidCallback? onExitUp;
  final FocusNode? activeFocusNode;

  @override
  ConsumerState<PhoneBottomNavigation> createState() =>
      _PhoneBottomNavigationState();
}

class _PhoneBottomNavigationState extends ConsumerState<PhoneBottomNavigation> {
  final _scrollController = ScrollController();
  final _nodes = <TopNavigationDestination, FocusNode>{
    for (final destination in TopNavigationDestination.values)
      destination: FocusNode(
        debugLabel: 'phone.navigation.${destination.name}',
      ),
  };

  FocusNode _nodeFor(TopNavigationDestination destination) =>
      destination == widget.activeDestination && widget.activeFocusNode != null
      ? widget.activeFocusNode!
      : _nodes[destination]!;

  void _activate(TopNavigationDestination destination) {
    if (destination == widget.activeDestination &&
        widget.onActivePressed != null) {
      widget.onActivePressed!();
      return;
    }
    _activateTopNavigationDestination(context, destination);
  }

  KeyEventResult _handleKey(
    List<TopNavigationDestination> destinations,
    TopNavigationDestination destination,
    KeyEvent event,
  ) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        widget.onExitUp?.call();
      }
      return KeyEventResult.handled;
    }
    final offset = switch (key) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => null,
    };
    if (offset == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final current = destinations.indexOf(destination);
      final next = (current + offset).clamp(0, destinations.length - 1);
      if (next != current) _nodeFor(destinations[next]).requestFocus();
    }
    return KeyEventResult.handled;
  }

  void _reveal(BuildContext actionContext) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !actionContext.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          actionContext,
          alignment: .5,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final localProfiles = ref.watch(localProfilesControllerProvider);
    final hasProfile =
        accounts.profiles.isNotEmpty || localProfiles.activeProfile != null;
    final settingsInProfileMenu =
        hasProfile &&
        !accounts.isLoading &&
        widget.preferences.settingsEntryPlacement ==
            SettingsEntryPlacement.profileMenu;
    final destinations = widget.preferences.topNavigationOrder
        .where(
          (destination) =>
              widget.preferences.isTopNavigationDestinationVisible(
                destination,
              ) &&
              (destination != TopNavigationDestination.settings ||
                  !settingsInProfileMenu),
        )
        .toList(growable: false);

    return Material(
      key: const ValueKey('phone-bottom-navigation'),
      color: Colors.black.withValues(alpha: .97),
      child: Container(
        height: phoneBottomNavigationHeight,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: .11)),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            key: const ValueKey('phone-bottom-navigation-scroll'),
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final destination in destinations)
                    Builder(
                      builder: (actionContext) => _PhoneBottomAction(
                        key: _navigationKey(destination),
                        destination: destination,
                        active: destination == widget.activeDestination,
                        focusNode: _nodeFor(destination),
                        onFocused: () => _reveal(actionContext),
                        onKeyEvent: (_, event) =>
                            _handleKey(destinations, destination, event),
                        onPressed: () => _activate(destination),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhoneBottomAction extends StatelessWidget {
  const _PhoneBottomAction({
    required this.destination,
    required this.active,
    required this.focusNode,
    required this.onFocused,
    required this.onKeyEvent,
    required this.onPressed,
    super.key,
  });

  final TopNavigationDestination destination;
  final bool active;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = destination.displayName;
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 48,
        height: phoneBottomNavigationHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (active)
              IgnorePointer(
                child: DecoratedBox(
                  key: ValueKey('phone-nav-active-${destination.name}'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        context.appPalette.accent.withValues(alpha: .34),
                        context.appPalette.accent.withValues(alpha: .10),
                        Colors.transparent,
                      ],
                      stops: const [0, .58, 1],
                    ),
                    border: Border(
                      top: BorderSide(
                        color: context.appPalette.accentBright,
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ),
            Center(
              child: TvFocusable(
                focusNode: focusNode,
                onKeyEvent: onKeyEvent,
                onFocusChanged: (focused) {
                  if (focused) onFocused();
                },
                onPressed: onPressed,
                borderRadius: BorderRadius.circular(9),
                focusScale: 1.025,
                child: Semantics(
                  label: label,
                  selected: active,
                  button: true,
                  excludeSemantics: true,
                  child: SizedBox(
                    width: 44,
                    height: 48,
                    child: Icon(
                      _navigationIcon(destination),
                      size: 23,
                      color: context.appPalette.primaryText,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _activateTopNavigationDestination(
  BuildContext context,
  TopNavigationDestination destination,
) {
  switch (destination) {
    case TopNavigationDestination.search:
      context.push('/search');
    case TopNavigationDestination.home:
      context.go('/');
    case TopNavigationDestination.myList:
      context.go('/my-list');
    case TopNavigationDestination.discover:
      context.go('/discover');
    case TopNavigationDestination.calendar:
      context.go('/calendar');
    case TopNavigationDestination.watchTogether:
      context.go('/watch-together');
    case TopNavigationDestination.downloads:
      context.go('/downloads');
    case TopNavigationDestination.settings:
      context.push('/settings/accounts');
  }
}

Key _navigationKey(TopNavigationDestination destination) =>
    switch (destination) {
      TopNavigationDestination.search => const ValueKey('main-nav-search'),
      TopNavigationDestination.home => const ValueKey('main-nav-home'),
      TopNavigationDestination.myList => const ValueKey('main-nav-my-list'),
      TopNavigationDestination.discover => const ValueKey('main-nav-discover'),
      TopNavigationDestination.calendar => const ValueKey('main-nav-calendar'),
      TopNavigationDestination.watchTogether => const ValueKey(
        'main-nav-watch-together',
      ),
      TopNavigationDestination.downloads => const ValueKey(
        'main-nav-downloads',
      ),
      TopNavigationDestination.settings => const ValueKey('main-nav-settings'),
    };

IconData _navigationIcon(TopNavigationDestination destination) =>
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

class _HomeRailWordmark extends StatelessWidget {
  const _HomeRailWordmark({required this.metrics});

  final HomeNavigationRailMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('main-nav-wordmark'),
      label: 'Teto TV',
      image: true,
      child: SizedBox(
        width: metrics.logoSize,
        height: metrics.logoSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.asset(
              'assets/branding/tetotv_icon.png',
              width: metrics.logoSize,
              height: metrics.logoSize,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
            const Positioned(
              left: 0,
              top: 0,
              child: Offstage(
                child: Text('Teto', key: ValueKey('main-nav-wordmark-teto')),
              ),
            ),
            const Positioned(
              right: 0,
              top: 0,
              child: Offstage(
                child: Text('TV', key: ValueKey('main-nav-wordmark-tv')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeRailAction extends StatelessWidget {
  const _HomeRailAction({
    required this.destination,
    required this.metrics,
    required this.active,
    required this.autofocus,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onFocused,
    this.onFocusChanged,
    required this.onPressed,
    super.key,
  });

  final TopNavigationDestination destination;
  final HomeNavigationRailMetrics metrics;
  final bool active;
  final bool autofocus;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<BuildContext> onFocused;
  final ValueChanged<bool>? onFocusChanged;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = destination.displayName;
    return Tooltip(
      message: label,
      child: SizedBox(
        width: metrics.width,
        height: metrics.actionHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (active)
              IgnorePointer(
                child: DecoratedBox(
                  key: ValueKey('main-nav-active-${destination.name}'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        context.appPalette.accent.withValues(alpha: .34),
                        context.appPalette.accent.withValues(alpha: .12),
                        Colors.transparent,
                      ],
                      stops: const [0, .56, 1],
                    ),
                    border: Border(
                      left: BorderSide(
                        color: context.appPalette.accentBright,
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.center,
              child: TvFocusable(
                autofocus: autofocus,
                focusNode: focusNode,
                onKeyEvent: onKeyEvent,
                onFocusChanged: (focused) {
                  if (focused) onFocused(context);
                  onFocusChanged?.call(focused);
                },
                onPressed: onPressed,
                borderRadius: BorderRadius.circular(8),
                focusScale: 1.035,
                child: Semantics(
                  label: label,
                  selected: active,
                  button: true,
                  excludeSemantics: true,
                  child: SizedBox(
                    width: metrics.actionWidth,
                    height: metrics.actionHeight,
                    child: Icon(
                      _navigationIcon(destination),
                      color: context.appPalette.primaryText,
                      size: metrics.iconSize,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixed Home header shown over the featured artwork on television layouts.
///
/// Search is always available. The identity control is added only when a
/// tracker or local profile exists, so an unlinked TV never loses its search
/// shortcut merely because there is no profile to display.
class HomeTopRightHeader extends ConsumerWidget {
  const HomeTopRightHeader({
    required this.preferences,
    required this.searchFocusNode,
    required this.searchController,
    required this.onSearchSubmitted,
    this.profileFocusNode,
    this.onSearchExitLeft,
    this.onSearchExitRight,
    this.onSearchExitDown,
    this.onProfileKeyEvent,
    this.onSearchFocusChanged,
    this.onProfileFocusChanged,
    this.compactMobile = false,
    super.key,
  });

  final SettingsPreferences preferences;
  final FocusNode searchFocusNode;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchSubmitted;
  final FocusNode? profileFocusNode;
  final VoidCallback? onSearchExitLeft;
  final VoidCallback? onSearchExitRight;
  final VoidCallback? onSearchExitDown;
  final FocusOnKeyEventCallback? onProfileKeyEvent;
  final ValueChanged<bool>? onSearchFocusChanged;
  final ValueChanged<bool>? onProfileFocusChanged;
  final bool compactMobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final localProfiles = ref.watch(localProfilesControllerProvider);
    final hasProfile =
        accounts.profiles.isNotEmpty || localProfiles.activeProfile != null;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final searchWidth = switch (screenWidth) {
      >= 1400 => 380.0,
      >= 1100 => 340.0,
      >= 940 => 300.0,
      _ => 260.0,
    };

    if (compactMobile) {
      return SizedBox(
        key: const ValueKey('home-top-right-header'),
        width: double.infinity,
        height: 56,
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                key: const ValueKey('home-header-search'),
                height: 56,
                child: TvTextInput(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  labelText: 'Search',
                  hintText: 'Search',
                  keyboardTitle: 'Search anime',
                  variant: TvTextInputVariant.headerSearch,
                  compactHeader: true,
                  restoreFocusAfterSubmit: false,
                  onSubmitted: onSearchSubmitted,
                  onFocusChanged: onSearchFocusChanged,
                  onExitLeft: onSearchExitLeft,
                  onExitRight: onSearchExitRight,
                  onExitDown: onSearchExitDown,
                ),
              ),
            ),
            if (hasProfile) ...[
              const SizedBox(width: 10),
              SizedBox(
                width: 52,
                child: TetoProfileSwitcher(
                  key: const ValueKey('home-profile-switcher'),
                  preferences: preferences,
                  focusNode: profileFocusNode,
                  onKeyEvent: onProfileKeyEvent,
                  onFocusChanged: onProfileFocusChanged,
                  compactAvatar: true,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Row(
      key: const ValueKey('home-top-right-header'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: const ValueKey('home-header-search'),
          width: searchWidth,
          height: 42,
          child: TvTextInput(
            controller: searchController,
            focusNode: searchFocusNode,
            labelText: 'Search',
            hintText: 'Search',
            keyboardTitle: 'Search anime',
            variant: TvTextInputVariant.headerSearch,
            restoreFocusAfterSubmit: false,
            onSubmitted: onSearchSubmitted,
            onFocusChanged: onSearchFocusChanged,
            onExitLeft: onSearchExitLeft,
            onExitRight: onSearchExitRight,
            onExitDown: onSearchExitDown,
          ),
        ),
        if (hasProfile) ...[
          const SizedBox(width: 20),
          TetoProfileSwitcher(
            key: const ValueKey('home-profile-switcher'),
            preferences: preferences,
            focusNode: profileFocusNode,
            onKeyEvent: onProfileKeyEvent,
            onFocusChanged: onProfileFocusChanged,
            compactAvatar: true,
          ),
        ],
      ],
    );
  }
}

/// The shared profile control used by every top-level TetoTV header.
///
/// Top-level television and phone headers use the same avatar-only trigger.
/// The full identity and profile actions remain available in its menu, while
/// the compact surface keeps header geometry consistent across devices.
class TetoProfileSwitcher extends ConsumerWidget {
  const TetoProfileSwitcher({
    required this.preferences,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChanged,
    this.compactAvatar = true,
    super.key,
  });

  final SettingsPreferences preferences;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;
  final bool compactAvatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final localProfiles = ref.watch(localProfilesControllerProvider);
    final profiles = [
      for (final provider in TrackingProvider.values)
        ?accounts.profiles[provider],
    ];
    final activeProfile = profiles
        .where((profile) => profile.provider == preferences.trackingProvider)
        .firstOrNull;
    final primaryProfile = activeProfile ?? profiles.firstOrNull;
    final activeLocalProfile = localProfiles.activeProfile;
    if (primaryProfile == null && activeLocalProfile == null) {
      return const SizedBox.shrink();
    }
    final savedProfiles = [
      for (final provider in TrackingProvider.values)
        ...?accounts.savedProfiles[provider],
    ];
    final showSettings =
        !accounts.isLoading &&
        preferences.settingsEntryPlacement ==
            SettingsEntryPlacement.profileMenu;

    return SizedBox(
      width: compactAvatar ? 52 : 190,
      height: compactAvatar ? 52 : 46,
      child: _ProfileMenuButton(
        trackerProfile: primaryProfile,
        localProfile: activeLocalProfile,
        savedProfiles: savedProfiles,
        localProfiles: localProfiles.profiles,
        activeProfileIds: accounts.activeProfileIds,
        activeLocalProfileId: localProfiles.activeProfileId,
        isLoading: accounts.isLoading,
        showSettings: showSettings,
        focusNode: focusNode,
        onKeyEvent: onKeyEvent,
        onFocusChanged: onFocusChanged,
        compactAvatar: compactAvatar,
        onSwitch: (profile) async {
          final switched = await ref
              .read(trackingAccountsControllerProvider.notifier)
              .switchProfile(profile);
          if (!switched) return;
          await ref
              .read(localProfilesControllerProvider.notifier)
              .clearSelection();
          await ref
              .read(settingsPreferencesProvider.notifier)
              .setTrackingProvider(profile.provider);
        },
        onSwitchLocal: (profile) => ref
            .read(localProfilesControllerProvider.notifier)
            .activate(profile),
        onManage: () => context.push('/settings/accounts?section=tracking'),
        onSettings: () => context.push('/settings/accounts'),
      ),
    );
  }
}

/// Compatibility wrapper retained for callers that still refer to the Home
/// control by its former name.
class HomeProfileSwitcher extends StatelessWidget {
  const HomeProfileSwitcher({
    required this.preferences,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChanged,
    this.compactHeader = true,
    super.key,
  });

  final SettingsPreferences preferences;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;
  final bool compactHeader;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('home-profile-switcher'),
    child: TetoProfileSwitcher(
      preferences: preferences,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      onFocusChanged: onFocusChanged,
      compactAvatar: compactHeader,
    ),
  );
}

/// Keeps primary navigation stable while presenting the active shared-TV
/// tracker identity as a compact menu at the far right of the row.
class MainNavigationBar extends ConsumerWidget {
  const MainNavigationBar({
    required this.active,
    required this.preferences,
    this.onHomePressed,
    this.homeFocusNode,
    this.activeFocusNode,
    this.onActivePressed,
    this.autofocusActive = false,
    super.key,
  });

  final MainNavigationDestination active;
  final SettingsPreferences preferences;
  final VoidCallback? onHomePressed;
  final FocusNode? homeFocusNode;
  final FocusNode? activeFocusNode;
  final VoidCallback? onActivePressed;
  final bool autofocusActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final localProfiles = ref.watch(localProfilesControllerProvider);
    final profiles = [
      for (final provider in TrackingProvider.values)
        ?accounts.profiles[provider],
    ];
    final activeProfile = profiles
        .where((profile) => profile.provider == preferences.trackingProvider)
        .firstOrNull;
    final primaryProfile = activeProfile ?? profiles.firstOrNull;
    final activeLocalProfile = localProfiles.activeProfile;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final normalTvLayout = width >= 700;
        final showWordmark = width >= 900;
        final showProfile =
            (primaryProfile != null || activeLocalProfile != null) &&
            width >= 700;
        final settingsInProfileMenu =
            showProfile &&
            !accounts.isLoading &&
            preferences.settingsEntryPlacement ==
                SettingsEntryPlacement.profileMenu;
        final visibleDestinations = preferences.topNavigationOrder
            .where(
              (destination) =>
                  preferences.isTopNavigationDestinationVisible(destination) &&
                  (destination != TopNavigationDestination.settings ||
                      !settingsInProfileMenu),
            )
            .toList(growable: false);
        // Header height depends only on width, never on asynchronously loaded
        // account data, so linking/loading a tracker cannot shift the screen.
        final headerHeight = width >= 760 ? 96.0 : 62.0;

        return SizedBox(
          key: const ValueKey('main-navigation'),
          width: double.infinity,
          height: headerHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (showWordmark) ...[
                const _TetoTvWordmark(),
                const SizedBox(width: 8),
              ],
              for (
                var index = 0;
                index < visibleDestinations.length;
                index++
              ) ...[
                if (index > 0) SizedBox(width: normalTvLayout ? 4 : 2),
                _navigationAction(
                  context: context,
                  destination: visibleDestinations[index],
                  active: active,
                  settingsCompact: width < 1200,
                  dense: width < 500,
                  autofocusActive: autofocusActive,
                  homeFocusNode: homeFocusNode,
                  activeFocusNode: activeFocusNode,
                  onActivePressed: onActivePressed,
                  onHomePressed: onHomePressed,
                ),
              ],
              const Spacer(),
              if (showProfile) ...[
                SizedBox(width: normalTvLayout ? 8 : 4),
                TetoProfileSwitcher(
                  preferences: preferences,
                  compactAvatar: true,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

Widget _navigationAction({
  required BuildContext context,
  required TopNavigationDestination destination,
  required MainNavigationDestination active,
  required bool settingsCompact,
  required bool dense,
  required bool autofocusActive,
  required FocusNode? homeFocusNode,
  required FocusNode? activeFocusNode,
  required VoidCallback? onActivePressed,
  required VoidCallback? onHomePressed,
}) => switch (destination) {
  TopNavigationDestination.search => _NavigationAction(
    key: const ValueKey('main-nav-search'),
    icon: Icons.search_rounded,
    label: 'Search',
    compact: true,
    dense: dense,
    onPressed: () => context.push('/search'),
  ),
  TopNavigationDestination.home => _NavigationAction(
    key: const ValueKey('main-nav-home'),
    icon: Icons.home_rounded,
    label: 'Home',
    compact: true,
    dense: dense,
    active: active == MainNavigationDestination.home,
    autofocus: autofocusActive && active == MainNavigationDestination.home,
    focusNode: active == MainNavigationDestination.home
        ? activeFocusNode ?? homeFocusNode
        : homeFocusNode,
    onPressed: active == MainNavigationDestination.home
        ? onActivePressed ?? onHomePressed ?? () => context.go('/')
        : onHomePressed ?? () => context.go('/'),
  ),
  TopNavigationDestination.myList => _NavigationAction(
    key: const ValueKey('main-nav-my-list'),
    icon: Icons.video_library_rounded,
    label: 'My List',
    compact: false,
    dense: dense,
    active: active == MainNavigationDestination.myList,
    autofocus: autofocusActive && active == MainNavigationDestination.myList,
    focusNode: active == MainNavigationDestination.myList
        ? activeFocusNode
        : null,
    onPressed: active == MainNavigationDestination.myList
        ? onActivePressed ?? () {}
        : () => context.go('/my-list'),
  ),
  TopNavigationDestination.discover => _NavigationAction(
    key: const ValueKey('main-nav-discover'),
    icon: Icons.explore_rounded,
    label: 'Discover',
    compact: true,
    dense: dense,
    active: active == MainNavigationDestination.discover,
    autofocus: autofocusActive && active == MainNavigationDestination.discover,
    focusNode: active == MainNavigationDestination.discover
        ? activeFocusNode
        : null,
    onPressed: active == MainNavigationDestination.discover
        ? onActivePressed ?? () {}
        : () => context.go('/discover'),
  ),
  TopNavigationDestination.calendar => _NavigationAction(
    key: const ValueKey('main-nav-calendar'),
    icon: Icons.calendar_month_rounded,
    label: 'Calendar',
    compact: true,
    dense: dense,
    active: active == MainNavigationDestination.calendar,
    autofocus: autofocusActive && active == MainNavigationDestination.calendar,
    focusNode: active == MainNavigationDestination.calendar
        ? activeFocusNode
        : null,
    onPressed: active == MainNavigationDestination.calendar
        ? onActivePressed ?? () {}
        : () => context.go('/calendar'),
  ),
  TopNavigationDestination.watchTogether => _NavigationAction(
    key: const ValueKey('main-nav-watch-together'),
    icon: Icons.person_outline_rounded,
    label: 'Watch Party',
    compact: true,
    dense: dense,
    active: active == MainNavigationDestination.watchTogether,
    autofocus:
        autofocusActive && active == MainNavigationDestination.watchTogether,
    focusNode: active == MainNavigationDestination.watchTogether
        ? activeFocusNode
        : null,
    onPressed: active == MainNavigationDestination.watchTogether
        ? onActivePressed ?? () {}
        : () => context.go('/watch-together'),
  ),
  TopNavigationDestination.downloads => _NavigationAction(
    key: const ValueKey('main-nav-downloads'),
    icon: Icons.download_rounded,
    label: 'Downloads',
    compact: true,
    dense: dense,
    active: active == MainNavigationDestination.downloads,
    autofocus: autofocusActive && active == MainNavigationDestination.downloads,
    focusNode: active == MainNavigationDestination.downloads
        ? activeFocusNode
        : null,
    onPressed: active == MainNavigationDestination.downloads
        ? onActivePressed ?? () {}
        : () => context.go('/downloads'),
  ),
  TopNavigationDestination.settings => _NavigationAction(
    key: const ValueKey('main-nav-settings'),
    icon: Icons.settings_rounded,
    label: 'Settings',
    compact: settingsCompact,
    dense: dense,
    onPressed: () => context.push('/settings/accounts'),
  ),
};

class _TetoTvWordmark extends StatelessWidget {
  const _TetoTvWordmark();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w900,
      letterSpacing: -.45,
    );
    return Semantics(
      key: const ValueKey('main-nav-wordmark'),
      label: 'Teto TV',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Teto',
            key: const ValueKey('main-nav-wordmark-teto'),
            style: style.copyWith(color: context.appPalette.primaryText),
          ),
          const SizedBox(width: 4),
          Text(
            'TV',
            key: const ValueKey('main-nav-wordmark-tv'),
            style: style.copyWith(color: context.appPalette.accent),
          ),
        ],
      ),
    );
  }
}

class _ProfileMenuButton extends StatelessWidget {
  const _ProfileMenuButton({
    required this.trackerProfile,
    required this.localProfile,
    required this.savedProfiles,
    required this.localProfiles,
    required this.activeProfileIds,
    required this.activeLocalProfileId,
    required this.isLoading,
    required this.showSettings,
    required this.onSwitch,
    required this.onSwitchLocal,
    required this.onManage,
    required this.onSettings,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChanged,
    this.compactAvatar = false,
  });

  final TrackingAccountProfile? trackerProfile;
  final LocalProfile? localProfile;
  final List<StoredTrackingProfile> savedProfiles;
  final List<LocalProfile> localProfiles;
  final Map<TrackingProvider, String> activeProfileIds;
  final String? activeLocalProfileId;
  final bool isLoading;
  final bool showSettings;
  final Future<void> Function(StoredTrackingProfile profile) onSwitch;
  final Future<bool> Function(LocalProfile profile) onSwitchLocal;
  final VoidCallback onManage;
  final VoidCallback onSettings;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;
  final bool compactAvatar;

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final availableMenuWidth = (overlay.size.width - 24).clamp(200.0, 430.0);
    final result = await showMenu<String>(
      context: context,
      color: context.appPalette.surface,
      elevation: 14,
      constraints: BoxConstraints(
        minWidth: availableMenuWidth,
        maxWidth: availableMenuWidth,
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy + box.size.height + 4,
          box.size.width,
          box.size.height,
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 106,
          child: _ProfileMenuStats(
            trackerProfile: trackerProfile,
            localProfile: localProfile,
          ),
        ),
        const PopupMenuDivider(),
        for (final local in localProfiles)
          PopupMenuItem<String>(
            key: ValueKey('main-nav-switch-local-profile-${local.id}'),
            value: 'local:${local.id}',
            height: 52,
            child: Row(
              children: [
                Icon(
                  activeLocalProfileId == local.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 19,
                  color: activeLocalProfileId == local.id
                      ? context.appPalette.accentBright
                      : context.appPalette.mutedText,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    local.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                const _LocalProfileBadge(),
              ],
            ),
          ),
        for (final saved in savedProfiles)
          PopupMenuItem<String>(
            key: ValueKey(
              'main-nav-switch-profile-${saved.provider.slug}-${saved.id}',
            ),
            value: '${saved.provider.slug}:${saved.id}',
            height: 52,
            child: Row(
              children: [
                Icon(
                  localProfile == null &&
                          saved.provider == trackerProfile?.provider &&
                          activeProfileIds[saved.provider] == saved.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 19,
                  color:
                      localProfile == null &&
                          saved.provider == trackerProfile?.provider &&
                          activeProfileIds[saved.provider] == saved.id
                      ? context.appPalette.accentBright
                      : context.appPalette.mutedText,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    saved.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                _ProviderBadge(provider: saved.provider, compact: true),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          key: ValueKey('main-nav-manage-profiles'),
          value: 'manage',
          height: 48,
          child: Row(
            children: [
              Icon(Icons.manage_accounts_rounded, size: 20),
              SizedBox(width: 10),
              Text(
                'Add or manage profiles',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        if (showSettings) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            key: ValueKey('main-nav-profile-settings'),
            value: 'settings',
            height: 48,
            child: Row(
              children: [
                Icon(Icons.settings_rounded, size: 20),
                SizedBox(width: 10),
                Text('Settings', style: TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ],
    );
    if (result == null) return;
    if (result == 'manage') {
      onManage();
      return;
    }
    if (result == 'settings') {
      onSettings();
      return;
    }
    final selectedLocal = localProfiles
        .where((item) => 'local:${item.id}' == result)
        .firstOrNull;
    if (selectedLocal != null) {
      if (activeLocalProfileId == selectedLocal.id) return;
      await onSwitchLocal(selectedLocal);
      return;
    }
    final selected = savedProfiles
        .where((item) => '${item.provider.slug}:${item.id}' == result)
        .firstOrNull;
    if (selected == null) return;
    if (localProfile == null &&
        selected.provider == trackerProfile?.provider &&
        activeProfileIds[selected.provider] == selected.id) {
      return;
    }
    await onSwitch(selected);
  }

  @override
  Widget build(BuildContext context) {
    final local = localProfile;
    final tracker = trackerProfile;
    final displayName = local?.displayName ?? tracker?.username ?? 'Profile';
    final slug = local != null ? 'local' : tracker!.provider.slug;
    final identityLabel = local != null
        ? '$displayName, local profile.'
        : '$displayName, ${tracker!.provider.displayName} profile.';
    return Builder(
      builder: (buttonContext) => Semantics(
        key: const ValueKey('main-nav-profile-summary'),
        button: true,
        onTap: isLoading ? null : () => _openMenu(buttonContext),
        label:
            '$identityLabel '
            'Open statistics and switch profiles${showSettings ? ', or open Settings' : ''}.',
        excludeSemantics: true,
        child: TvFocusable(
          focusNode: focusNode,
          onKeyEvent: onKeyEvent,
          onFocusChanged: onFocusChanged,
          onPressed: isLoading ? () {} : () => _openMenu(buttonContext),
          borderRadius: BorderRadius.circular(compactAvatar ? 999 : 9),
          focusScale: compactAvatar ? 1.01 : 1.02,
          child: Container(
            key: ValueKey('main-nav-profile-$slug'),
            padding: EdgeInsets.symmetric(
              horizontal: compactAvatar ? 4 : 5,
              vertical: compactAvatar ? 4 : 4,
            ),
            child: Row(
              mainAxisSize: compactAvatar ? MainAxisSize.min : MainAxisSize.max,
              mainAxisAlignment: compactAvatar
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (local != null)
                  _LocalProfileAvatar(
                    size: compactAvatar ? 40 : 36,
                    circular: compactAvatar,
                  )
                else
                  _ProfileAvatar(
                    profile: tracker!,
                    size: compactAvatar ? 40 : 36,
                    circular: compactAvatar,
                  ),
                if (!compactAvatar) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      key: const ValueKey('teto-profile-username'),
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appPalette.primaryText,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    key: const ValueKey('teto-profile-chevron'),
                    Icons.arrow_drop_down_rounded,
                    size: 20,
                    color: context.appPalette.mutedText,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileMenuStats extends StatelessWidget {
  const _ProfileMenuStats({
    required this.trackerProfile,
    required this.localProfile,
  });

  final TrackingAccountProfile? trackerProfile;
  final LocalProfile? localProfile;

  @override
  Widget build(BuildContext context) {
    if (localProfile case final local?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              const _LocalProfileAvatar(size: 34, identify: false),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  local.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appPalette.primaryText,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const _LocalProfileBadge(),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            'Stored only on this device • no tracker login required',
            style: TextStyle(
              color: context.appPalette.mutedText,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }
    final profile = trackerProfile!;
    final scoreMaximum = profile.provider == TrackingProvider.anilist
        ? 100
        : 10;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            _ProfileAvatar(profile: profile, size: 34, identify: false),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                profile.username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.appPalette.primaryText,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            _ProviderBadge(provider: profile.provider, compact: true),
          ],
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 12,
          runSpacing: 7,
          children: [
            _TrackerMenuStat(
              icon: Icons.video_library_outlined,
              text: profile.animeCount == null
                  ? '— titles'
                  : '${_readableCount(profile.animeCount!)} titles',
            ),
            _TrackerMenuStat(
              icon: Icons.play_circle_outline_rounded,
              text: profile.episodesWatched == null
                  ? '— episodes'
                  : '${_readableCount(profile.episodesWatched!)} episodes',
            ),
            _TrackerMenuStat(
              icon: Icons.schedule_rounded,
              text: profile.minutesWatched == null
                  ? '— watched'
                  : _watchedDuration(profile.minutesWatched!),
            ),
            _TrackerMenuStat(
              icon: Icons.star_rounded,
              text: profile.meanScore == null
                  ? 'Mean —/$scoreMaximum'
                  : 'Mean ${profile.meanScore!.toStringAsFixed(1)}/$scoreMaximum',
            ),
          ],
        ),
      ],
    );
  }
}

class _LocalProfileBadge extends StatelessWidget {
  const _LocalProfileBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: context.appPalette.secondaryAccent.withValues(alpha: .18),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      'LOCAL',
      style: TextStyle(
        color: context.appPalette.secondaryAccent,
        fontSize: 8,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _TrackerMenuStat extends StatelessWidget {
  const _TrackerMenuStat({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: context.appPalette.mutedText),
      const SizedBox(width: 4),
      Text(
        text,
        style: TextStyle(
          color: context.appPalette.mutedText,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _ProviderBadge extends StatelessWidget {
  const _ProviderBadge({required this.provider, this.compact = false});

  final TrackingProvider provider;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: context.appPalette.accent.withValues(alpha: .24),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        provider.displayName,
        style: TextStyle(
          color: context.appPalette.accentBright,
          fontSize: compact ? 8 : 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

String _readableCount(int value) {
  if (value < 10000) return '$value';
  if (value < 1000000) {
    final digits = value >= 100000 ? 0 : 1;
    return '${(value / 1000).toStringAsFixed(digits)}K';
  }
  final digits = value >= 10000000 ? 0 : 1;
  return '${(value / 1000000).toStringAsFixed(digits)}M';
}

String _watchedDuration(int minutes) {
  if (minutes < 60) return '${minutes}m watched';
  return '${(minutes / 60).round()}h watched';
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.profile,
    required this.size,
    this.identify = true,
    this.circular = false,
  });

  final TrackingAccountProfile profile;
  final double size;
  final bool identify;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: identify
          ? ValueKey('main-nav-profile-avatar-${profile.provider.slug}')
          : null,
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(6),
        color: context.appPalette.surfaceRaised,
        border: circular
            ? Border.all(color: context.appPalette.accentBright, width: 2)
            : null,
      ),
      child: NetworkArtwork(
        url: profile.avatarUrl,
        cacheWidth: (size * 2).round(),
        icon: Icons.person_rounded,
      ),
    );
  }
}

class _LocalProfileAvatar extends StatelessWidget {
  const _LocalProfileAvatar({
    required this.size,
    this.identify = true,
    this.circular = false,
  });

  final double size;
  final bool identify;
  final bool circular;

  @override
  Widget build(BuildContext context) => Container(
    key: identify ? const ValueKey('main-nav-profile-avatar-local') : null,
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: circular ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circular ? null : BorderRadius.circular(6),
      color: context.appPalette.secondaryAccent.withValues(alpha: .18),
      border: circular
          ? Border.all(color: context.appPalette.accentBright, width: 2)
          : null,
    ),
    child: Icon(
      Icons.person_rounded,
      size: size * .62,
      color: context.appPalette.secondaryAccent,
    ),
  );
}

class _NavigationAction extends StatelessWidget {
  const _NavigationAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.compact = false,
    this.dense = false,
    this.autofocus = false,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool active;
  final bool compact;
  final bool dense;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: compact ? label : '',
      child: TvFocusable(
        autofocus: autofocus,
        focusNode: focusNode,
        onPressed: onPressed,
        borderRadius: BorderRadius.circular(7),
        focusScale: 1.02,
        child: Container(
          padding: EdgeInsets.symmetric(
            // Eight destinations still fit the 330px Classic Layout header.
            // Every destination remains present and focusable instead of being
            // clipped or silently hidden on compact phones.
            horizontal: dense ? 4 : (compact ? 8 : 11),
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: active
                ? context.appPalette.accent.withValues(alpha: .13)
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: active
                    ? context.appPalette.accentBright
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: active
                    ? context.appPalette.accentBright
                    : context.appPalette.primaryText,
              ),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(label, style: Theme.of(context).textTheme.labelLarge),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
