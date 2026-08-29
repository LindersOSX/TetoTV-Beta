import 'dart:async';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/layout/poster_card_geometry.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/home_shelf_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/local_profiles_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:anime_tv/features/tracking/presentation/catalog_tracking_action.dart';
import 'package:anime_tv/features/tracking/presentation/tracking_status_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({this.autofocusNavigation = false, super.key});

  final bool autofocusNavigation;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _connectTracking = [
    _ShelfItem(
      'Connect your tracker',
      'AniList or MAL',
      route: '/settings/accounts',
    ),
  ];

  final _heroFocus = FocusNode(debugLabel: 'home.watch-now');
  final _heroMyListFocus = FocusNode(debugLabel: 'home.hero-my-list');
  final _homeNavFocus = FocusNode(debugLabel: 'home.navigation.home');
  final _searchFocus = FocusNode(debugLabel: 'home.header-search');
  final _profileFocus = FocusNode(debugLabel: 'home.profile-switcher');
  final _homeSearchController = TextEditingController();
  final _scrollController = ScrollController();
  final _verticalRepeatGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );
  final Map<HomeShelf, GlobalKey<_MediaShelfState>> _shelfKeys = {
    for (final shelf in HomeShelf.values)
      shelf: GlobalKey<_MediaShelfState>(debugLabel: 'home.${shelf.name}'),
  };
  bool _catalogFocusSettled = false;
  bool _hasVisibleNavigationAction = true;
  Timer? _heroTimer;
  int _heroIndex = 0;
  DateTime? _lastHomeActivation;
  bool _homeRefreshInProgress = false;
  bool _headerVisibleAtTop = true;
  bool _suppressNextNavigationHeroRestore = false;
  bool? _lastUseSideNavigation;
  bool _lastContentWasHero = true;
  HomeShelf? _lastFocusedShelf;
  int _lastFocusedColumn = 0;
  FocusNode? _lastHeroActionFocus;
  List<HomeShelf> _focusableShelfOrder = const [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleHomeScroll);
    _heroTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      final count = ref.read(trendingAnimeProvider).valueOrNull?.take(5).length;
      if (count == null || count < 2) return;
      final items = ref.read(trendingAnimeProvider).valueOrNull!;
      final nextIndex = ((_heroIndex % count) + 1) % count;
      final nextArtwork =
          items[nextIndex].bannerImageUrl ?? items[nextIndex].coverImageUrl;
      if (nextArtwork != null && nextArtwork.isNotEmpty) {
        NetworkArtwork.precache(context, nextArtwork, cacheWidth: 1280);
      }
      setState(() => _heroIndex = nextIndex);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.autofocusNavigation) {
        _focusNavigationChrome();
      } else if ((ref.read(isTelevisionProvider) ||
              MediaQuery.sizeOf(context).width >
                  MediaQuery.sizeOf(context).height) &&
          _searchFocus.context != null) {
        // Side-rail layouts open at Search, including TV devices whose Android
        // firmware reports a generic landscape device class. Focusing the
        // control only highlights it; the keyboard still opens on activation.
        // Down restores the remembered featured/shelf content focus.
        _searchFocus.requestFocus();
      } else {
        _focusHero();
      }
      unawaited(_runStartup());
    });
  }

  Future<void> _runStartup() async {
    final preferences = ref.read(settingsPreferencesProvider.notifier);
    await preferences.load();
    if (!mounted) return;
    final setup = ref.read(setupProgressProvider.notifier);
    await setup.load();
    if (!mounted) return;
    if (!ref.read(setupProgressProvider).completed) {
      await context.push('/setup/start');
      if (!mounted) return;
    }
    final landingRoute = preferences.takeInitialLandingRoute();
    // A release check can take tens of seconds on a slow or offline TV. Start
    // it in the background so the configured landing page is never held behind
    // network I/O. `_checkForUpdates` already stops UI work after disposal.
    unawaited(_checkForUpdates());
    if (landingRoute != null && mounted) context.go(landingRoute);
  }

  Future<void> _checkForUpdates() async {
    final updater = ref.read(appUpdateControllerProvider.notifier);
    await updater.checkForUpdates(automatic: true, launchInstaller: true);
    if (!mounted) return;
    final notes = await updater.takeInstalledReleaseNotes();
    if (!mounted || notes == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.appPalette.surface,
        title: const Text('What\'s new in TetoTV'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 420),
          child: SingleChildScrollView(child: SelectableText(notes)),
        ),
        actions: [
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _focusHero({bool resetScroll = true}) {
    if (!mounted) return;
    final preferred = _lastHeroActionFocus;
    if (preferred?.context != null) {
      preferred!.requestFocus();
    } else if (_heroFocus.context != null) {
      _heroFocus.requestFocus();
    } else {
      _focusNavigationChrome();
    }
    if (resetScroll && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _focusNavigationChrome() {
    if (_hasVisibleNavigationAction && _homeNavFocus.context != null) {
      _homeNavFocus.requestFocus();
    } else if (_searchFocus.context != null) {
      _searchFocus.requestFocus();
    } else if (_profileFocus.context != null) {
      _profileFocus.requestFocus();
    } else {
      unawaited(_revealAndFocusHeader());
    }
  }

  void _handleHomeScroll() {
    if (!mounted || !_scrollController.hasClients) return;
    final visibleAtTop = _scrollController.offset <= .5;
    if (visibleAtTop == _headerVisibleAtTop) return;
    if (!visibleAtTop && (_searchFocus.hasFocus || _profileFocus.hasFocus)) {
      if (_hasVisibleNavigationAction && _homeNavFocus.context != null) {
        // A pointer/remote scroll can hide the fixed header while Search or
        // Profile still owns focus. Move focus somewhere visible without
        // treating that synthetic transfer like an intentional rail visit;
        // otherwise the rail focus callback immediately scrolls back to the
        // hero and makes lower shelf cards impossible to interact with.
        _suppressNextNavigationHeroRestore = true;
        _homeNavFocus.requestFocus();
      } else {
        unawaited(_revealAndFocusHeader());
      }
    }
    setState(() => _headerVisibleAtTop = visibleAtTop);
  }

  Future<void> _revealAndFocusHeader() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_searchFocus.context != null) {
        _searchFocus.requestFocus();
      } else if (_profileFocus.context != null) {
        _profileFocus.requestFocus();
      }
    });
  }

  void _submitHeaderSearch(String value) {
    final query = value.trim();
    if (query.length < 2) return;
    context.push(
      Uri(path: '/search', queryParameters: {'q': query}).toString(),
    );
  }

  KeyEventResult _handleHeaderProfileKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (_searchFocus.context != null) _searchFocus.requestFocus();
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _restoreContentFocus();
      }
    }
    return KeyEventResult.handled;
  }

  void _rememberHeroFocus(FocusNode node) {
    _lastHeroActionFocus = node;
    _lastContentWasHero = true;
    _lastFocusedShelf = null;
    unawaited(_restoreSponsoredHero());
  }

  KeyEventResult _handleHeroActionKey(FocusNode _, KeyEvent event) {
    // TvFocusable reports its wrapper Focus node here. Resolve the real action
    // from the supplied nodes so horizontal D-pad movement stays deterministic.
    final activeNode = _heroMyListFocus.hasFocus
        ? _heroMyListFocus
        : _heroFocus;
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowUp) {
        if (_searchFocus.context != null) {
          _searchFocus.requestFocus();
        } else if (_profileFocus.context != null) {
          _profileFocus.requestFocus();
        } else {
          _focusNavigationChrome();
        }
      } else if (key == LogicalKeyboardKey.arrowDown) {
        if (_focusableShelfOrder.isNotEmpty) {
          _focusShelf(_focusableShelfOrder.first);
        }
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        if (activeNode == _heroMyListFocus && _heroFocus.context != null) {
          _heroFocus.requestFocus();
        } else if (activeNode == _heroFocus) {
          _focusNavigationChrome();
        }
      } else if (key == LogicalKeyboardKey.arrowRight) {
        if (activeNode == _heroFocus && _heroMyListFocus.context != null) {
          _heroMyListFocus.requestFocus();
        }
      }
    }
    return KeyEventResult.handled;
  }

  Future<void> _restoreSponsoredHero() async {
    if (!mounted ||
        !ref.read(settingsPreferencesProvider).showHero ||
        !_scrollController.hasClients ||
        _scrollController.offset <= .5) {
      return;
    }
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
    );
  }

  void _rememberShelfFocus(HomeShelf shelf, int column) {
    _lastContentWasHero = false;
    _lastFocusedShelf = shelf;
    _lastFocusedColumn = column;
  }

  void _focusShelf(HomeShelf shelf, {int? preferredColumn}) {
    if (!mounted) return;
    final key = _shelfKeys[shelf];
    final state = key?.currentState;
    if (state == null || !state.requestFocus(preferredIndex: preferredColumn)) {
      return;
    }
    final rowContext = key?.currentContext;
    if (rowContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          rowContext,
          alignment: .62,
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _restoreContentFocus() {
    final shelf = _lastFocusedShelf;
    if (!_lastContentWasHero &&
        shelf != null &&
        _focusableShelfOrder.contains(shelf)) {
      _focusShelf(shelf, preferredColumn: _lastFocusedColumn);
      return;
    }
    final preferences = ref.read(settingsPreferencesProvider);
    if (preferences.showHero && _heroFocus.context != null) {
      _focusHero(resetScroll: false);
      return;
    }
    if (_focusableShelfOrder.isNotEmpty) {
      _focusShelf(_focusableShelfOrder.first);
    }
  }

  KeyEventResult _handleShelfVerticalKey(
    KeyEvent event, {
    required int rowIndex,
    required int column,
    required bool showHero,
  }) {
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      _ => 0,
    };
    if (direction == 0) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _verticalRepeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_verticalRepeatGate.accept(event)) return KeyEventResult.handled;

    final targetRow = rowIndex + direction;
    if (targetRow < 0) {
      if (showHero) {
        _focusHero(resetScroll: false);
      } else {
        _focusNavigationChrome();
      }
      return KeyEventResult.handled;
    }
    if (targetRow >= _focusableShelfOrder.length) {
      return KeyEventResult.handled;
    }
    _focusShelf(_focusableShelfOrder[targetRow], preferredColumn: column);
    return KeyEventResult.handled;
  }

  Future<void> _openShelfItem(HomeShelf shelf, _ShelfItem item) async {
    final route =
        item.route ??
        (item.animeId == null
            ? Uri(
                path: '/search',
                queryParameters: {'q': item.title},
              ).toString()
            : '/anime/${item.animeId}');
    await context.push(route);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusShelf(shelf);
    });
  }

  Future<void> _openHero(String route) async {
    await context.push(route);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusHero(resetScroll: false);
    });
  }

  void _handleHomeActivation() {
    final now = DateTime.now();
    final previous = _lastHomeActivation;
    _lastHomeActivation = now;
    if (previous == null ||
        now.difference(previous) > const Duration(milliseconds: 650)) {
      if (_scrollController.hasClients) {
        unawaited(
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      return;
    }
    _lastHomeActivation = null;
    unawaited(_refreshHome());
  }

  Future<void> _refreshHome() async {
    if (_homeRefreshInProgress) return;
    _homeRefreshInProgress = true;
    ref.invalidate(trendingAnimeProvider);
    ref.invalidate(seasonalAnimeProvider);
    ref.invalidate(trackingHomeProvider);
    ref.invalidate(recentPlaybackProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Refreshing Home…'),
        duration: Duration(milliseconds: 1200),
      ),
    );
    try {
      await Future.wait([
        ref.read(trendingAnimeProvider.future),
        ref.read(seasonalAnimeProvider.future),
        ref.read(trackingHomeProvider.future),
        ref.read(recentPlaybackProvider.future),
      ]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Home refreshed.'),
          duration: Duration(milliseconds: 1200),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Some Home shelves could not be refreshed.'),
          duration: Duration(seconds: 3),
        ),
      );
    } finally {
      _homeRefreshInProgress = false;
    }
  }

  Future<void> _removeFromLocalHistory(_ShelfItem item) async {
    final mediaId = item.historyMediaId ?? item.animeId;
    if (mediaId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: context.appPalette.surface,
        title: const Text('Remove from this TV?'),
        content: Text(
          'Remove “${item.title}” from local Watch History and Continue '
          'Watching? AniList and MAL will not be changed.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final database = ref.read(tetoTvDatabaseProvider);
    try {
      await database.removeLocalHistory(mediaId);
      await AndroidTvBridge.instance.removeWatchNext(mediaId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not remove local watch history.')),
      );
      return;
    }
    if (!mounted) return;
    ref.invalidate(recentPlaybackProvider);
    ref.invalidate(latestPlaybackProvider(mediaId));
    ref.invalidate(dismissedContinueWatchingProvider);
  }

  Future<void> _manageShelfItem(_ShelfItem item) async {
    final action = await showDialog<Object>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => _HomeShowActionsDialog(item: item),
    );
    if (!mounted || action == null) return;
    if (action == _HomeShowAction.removeLocal) {
      await _removeFromLocalHistory(item);
      return;
    }
    if (action == _HomeShowAction.open) {
      final route =
          item.route ??
          (item.animeId == null
              ? Uri(
                  path: '/search',
                  queryParameters: {'q': item.title},
                ).toString()
              : '/anime/${item.animeId}');
      if (mounted) await context.push(route);
      return;
    }
    if (action is! TrackingListStatus) return;

    if (item.animeId == null && item.trackingItems.isNotEmpty) {
      var failures = 0;
      for (final tracked in item.trackingItems) {
        try {
          await ref
              .read(trackingStatusControllerProvider.notifier)
              .update(tracked, action);
        } catch (_) {
          failures++;
        }
      }
      if (!mounted) return;
      ref.invalidate(trackingHomeProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failures == 0
                ? '${item.title} moved to ${action.displayName}.'
                : 'Updated ${item.trackingItems.length - failures} of '
                      '${item.trackingItems.length} connected lists.',
          ),
          backgroundColor: failures == 0
              ? context.appPalette.accent
              : const Color(0xFF7D1E32),
        ),
      );
      return;
    }
    if (item.animeId == null) return;

    try {
      final result = await ref
          .read(trackingStatusControllerProvider.notifier)
          .updateCatalogStatus(
            anilistId: item.animeId!,
            malId: item.malMediaId,
            status: action,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.isPartial
                ? '${item.title} updated on ${result.updatedProviderNames}; '
                      'one linked tracker could not be updated.'
                : '${item.title} moved to ${action.displayName} on '
                      '${result.updatedProviderNames}.',
          ),
          backgroundColor: result.isPartial
              ? const Color(0xFF7D1E32)
              : context.appPalette.accent,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error is StateError
          ? error.message.toString()
          : 'Could not update this show. Try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: const Color(0xFF7D1E32),
        ),
      );
    }
  }

  @override
  void dispose() {
    _heroFocus.dispose();
    _heroMyListFocus.dispose();
    _homeNavFocus.dispose();
    _searchFocus.dispose();
    _profileFocus.dispose();
    _homeSearchController.dispose();
    _verticalRepeatGate.reset();
    _scrollController.dispose();
    _heroTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(trendingAnimeProvider, (_, next) {
      if (!_catalogFocusSettled && next.valueOrNull?.isNotEmpty == true) {
        _catalogFocusSettled = true;
        // The hero keeps the same focus node while its artwork loads. Do not
        // steal focus or jump to the top after the user has started navigating.
        if (_heroFocus.hasFocus || FocusManager.instance.primaryFocus == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_heroFocus.hasFocus ||
                FocusManager.instance.primaryFocus == null) {
              _focusHero();
            }
          });
        }
      }
    });

    final trendingAsync = ref.watch(trendingAnimeProvider);
    final seasonalAsync = ref.watch(seasonalAnimeProvider);
    final trending = trendingAsync.valueOrNull;
    final seasonal = seasonalAsync.valueOrNull;
    final tracking = ref.watch(trackingHomeProvider).valueOrNull;
    final localHistory = ref.watch(recentPlaybackProvider).valueOrNull;
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final enabledShelves = ref.watch(homeShelfPreferencesProvider);
    final shelfOrder = ref.watch(homeShelfOrderProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    final accounts = ref.watch(trackingAccountsControllerProvider);
    final localProfiles = ref.watch(localProfilesControllerProvider);
    final isTelevision = ref.watch(isTelevisionProvider);
    final dismissedIds =
        ref.watch(dismissedContinueWatchingProvider).valueOrNull ??
        const <int>{};
    final heroItems =
        trending?.take(5).toList(growable: false) ?? const <AnimeSummary>[];
    final activeHeroIndex = heroItems.isEmpty
        ? 0
        : _heroIndex % heroItems.length;
    final hero = heroItems.isEmpty ? null : heroItems[activeHeroIndex];
    final seasonalItems = seasonal == null || seasonal.isEmpty
        ? const <_ShelfItem>[]
        : seasonal
              .map((anime) => _ShelfItem.fromAnime(anime, titlePreference))
              .toList(growable: false);
    final trendingItems = trending
        ?.skip(1)
        .map((anime) => _ShelfItem.fromAnime(anime, titlePreference))
        .toList(growable: false);
    final plannedItems = tracking?.planToWatch.isNotEmpty == true
        ? tracking!.planToWatch
              .map((item) => _ShelfItem.fromTracked(item, titlePreference))
              .toList(growable: false)
        : const <_ShelfItem>[];
    final completedItems = tracking?.completed
        .map((item) => _ShelfItem.fromTracked(item, titlePreference))
        .toList(growable: false);
    final historyItems = _historyShelfItems(
      localHistory: localHistory,
      tracking: tracking,
    );
    final watchingItems = _mergeContinueWatching(
      localHistory: localHistory,
      trackedWatching: tracking?.watching,
      dismissedIds: dismissedIds,
      titlePreference: titlePreference,
    );
    final followed = <HomeTrackedAnime>[
      ...?tracking?.watching,
      ...?tracking?.planToWatch,
    ];
    final airingItems = seasonal
        ?.where(
          (anime) =>
              anime.nextAiringEpisode != null &&
              _isTrackedAnime(anime, followed),
        )
        .take(20)
        .map(
          (anime) => _ShelfItem.fromAnime(anime, titlePreference).copyWith(
            subtitle: 'Episode ${anime.nextAiringEpisode} airing soon',
          ),
        )
        .toList(growable: false);
    final shelfRows = <_HomeShelfRow>[];
    for (final shelf in shelfOrder) {
      if (!enabledShelves.contains(shelf)) continue;
      switch (shelf) {
        case HomeShelf.tracking:
          shelfRows.add(
            _HomeShelfRow(shelf: shelf, items: watchingItems, landscape: true),
          );
          break;
        case HomeShelf.history:
          if (historyItems != null && historyItems.isNotEmpty) {
            shelfRows.add(_HomeShelfRow(shelf: shelf, items: historyItems));
          }
          break;
        case HomeShelf.recentlyReleased:
          if (seasonalAsync.isLoading) {
            shelfRows.add(
              _HomeShelfRow(shelf: shelf, items: const [], loading: true),
            );
          } else if (seasonalItems.isNotEmpty) {
            shelfRows.add(_HomeShelfRow(shelf: shelf, items: seasonalItems));
          }
          break;
        case HomeShelf.trending:
          if (trendingItems != null && trendingItems.isNotEmpty) {
            shelfRows.add(_HomeShelfRow(shelf: shelf, items: trendingItems));
          }
          break;
        case HomeShelf.planned:
          if (plannedItems.isNotEmpty) {
            shelfRows.add(_HomeShelfRow(shelf: shelf, items: plannedItems));
          }
          break;
        case HomeShelf.airing:
          if (airingItems != null && airingItems.isNotEmpty) {
            shelfRows.add(_HomeShelfRow(shelf: shelf, items: airingItems));
          }
          break;
        case HomeShelf.completed:
          if (completedItems != null && completedItems.isNotEmpty) {
            shelfRows.add(_HomeShelfRow(shelf: shelf, items: completedItems));
          }
          break;
      }
    }

    final focusableRows = shelfRows
        .where((row) => !row.loading && row.items.isNotEmpty)
        .toList(growable: false);
    _focusableShelfOrder = focusableRows
        .map((row) => row.shelf)
        .toList(growable: false);

    final responsivePadding = context.responsiveScreenPadding;
    final contentHorizontalPadding = EdgeInsets.only(
      left: responsivePadding.left,
      right: responsivePadding.right,
    );
    final screenSize = MediaQuery.sizeOf(context);
    final isPhoneLandscape =
        !isTelevision && screenSize.width > screenSize.height;
    final isPhonePortrait = !isTelevision && !isPhoneLandscape;
    final useTvRail =
        isTelevision &&
        preferences.interfaceMode != InterfaceMode.phone &&
        !context.isCompactWidth &&
        screenSize.width >= 840;
    final useSideNavigation = useTvRail || isPhoneLandscape;
    if (_lastUseSideNavigation != null &&
        _lastUseSideNavigation != useSideNavigation) {
      // Changing between Classic and Modern replaces the scroll presentation.
      // The controller can reattach at the top without notifying its listener,
      // so reconcile profile visibility after the new position is laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleHomeScroll());
    }
    _lastUseSideNavigation = useSideNavigation;
    if (useSideNavigation) {
      final settingsInProfileMenu =
          (accounts.profiles.isNotEmpty ||
              localProfiles.activeProfile != null) &&
          !accounts.isLoading &&
          preferences.settingsEntryPlacement ==
              SettingsEntryPlacement.profileMenu;
      _hasVisibleNavigationAction = preferences.topNavigationOrder.any(
        (destination) =>
            preferences.isTopNavigationDestinationVisible(destination) &&
            (destination != TopNavigationDestination.settings ||
                !settingsInProfileMenu),
      );
    } else {
      _hasVisibleNavigationAction = true;
    }
    final railMetrics = isPhoneLandscape
        ? phoneLandscapeNavigationRailMetrics(preferences.navigationChromeSize)
        : homeNavigationRailMetrics(preferences.navigationChromeSize);
    final railWidth = railMetrics.width;
    final heroHeight = isPhoneLandscape
        ? (screenSize.height * .82).clamp(280.0, 360.0)
        : (screenSize.height * .48).clamp(300.0, 440.0);

    List<Widget> buildShelves({required bool tvNavigation}) {
      return [
        for (final row in shelfRows)
          Padding(
            padding: tvNavigation
                ? EdgeInsets.fromLTRB(
                    screenSize.width >= 1400 ? 34 : 28,
                    0,
                    screenSize.width >= 1400 ? 34 : 28,
                    0,
                  )
                : contentHorizontalPadding,
            child: row.loading
                ? _MediaShelfSkeleton(
                    title: row.shelf.displayName,
                    preferences: preferences,
                    modernPosterSizing: tvNavigation,
                  )
                : _MediaShelf(
                    key: _shelfKeys[row.shelf],
                    title: row.shelf.displayName,
                    items: row.items,
                    preferences: preferences,
                    landscape: row.landscape,
                    modernPosterSizing: tvNavigation,
                    onManage: _manageShelfItem,
                    onOpen: (item) => _openShelfItem(row.shelf, item),
                    onFocused: (column) =>
                        _rememberShelfFocus(row.shelf, column),
                    onLeftEdge: tvNavigation ? _focusNavigationChrome : null,
                    onVerticalKey: (event, column) => _handleShelfVerticalKey(
                      event,
                      rowIndex: _focusableShelfOrder.indexOf(row.shelf),
                      column: column,
                      showHero: preferences.showHero,
                    ),
                  ),
          ),
      ];
    }

    final heroRoute = hero == null ? '/search?q=Frieren' : '/anime/${hero.id}';
    final heroPanel = _HeroPanel(
      anime: hero,
      isTelevision: isTelevision,
      isLoading: trendingAsync.isLoading,
      focusNode: _heroFocus,
      myListFocusNode: _heroMyListFocus,
      titlePreference: titlePreference,
      preferences: preferences,
      activeIndex: activeHeroIndex,
      itemCount: heroItems.length,
      height: useSideNavigation ? heroHeight : null,
      onOpen: () => _openHero(heroRoute),
      onManageList: hero == null
          ? null
          : () => unawaited(
              manageCatalogTrackingStatus(
                context: context,
                ref: ref,
                anime: hero,
              ),
            ),
      onActionFocused: _rememberHeroFocus,
      onActionKeyEvent: useSideNavigation ? _handleHeroActionKey : null,
    );

    Widget phoneHeader() => Padding(
      padding: EdgeInsets.fromLTRB(
        responsivePadding.left,
        10,
        responsivePadding.right,
        10,
      ),
      child: HomeTopRightHeader(
        preferences: preferences,
        searchFocusNode: _searchFocus,
        searchController: _homeSearchController,
        profileFocusNode: _profileFocus,
        onSearchSubmitted: _submitHeaderSearch,
        onSearchExitLeft: _focusNavigationChrome,
        onSearchExitRight: () {
          if (_profileFocus.context != null) _profileFocus.requestFocus();
        },
        onSearchExitDown: _restoreContentFocus,
        onProfileKeyEvent: _handleHeaderProfileKey,
        onSearchFocusChanged: (focused) {
          if (focused) unawaited(_restoreSponsoredHero());
        },
        onProfileFocusChanged: (focused) {
          if (focused) unawaited(_restoreSponsoredHero());
        },
        compactMobile: true,
      ),
    );

    return Scaffold(
      backgroundColor: context.appPalette == AppThemePalette.defaults
          ? Colors.black
          : context.appPalette.background,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (useSideNavigation) ...[
              Positioned.fill(
                key: const ValueKey('home-tv-content-region'),
                left: railWidth,
                child: SingleChildScrollView(
                  key: const ValueKey('home-scroll-content'),
                  controller: _scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (isPhoneLandscape) phoneHeader(),
                      if (preferences.showHero) heroPanel,
                      if (!preferences.showHero) const SizedBox(height: 12),
                      ...buildShelves(tvNavigation: useSideNavigation),
                      const SizedBox(height: 46),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: HomeSideNavigation(
                  preferences: preferences,
                  metrics: railMetrics,
                  homeFocusNode: _homeNavFocus,
                  autofocusActive:
                      widget.autofocusNavigation || !preferences.showHero,
                  onHomePressed: _handleHomeActivation,
                  onExitRight: _restoreContentFocus,
                  onFocusChanged: (focused) {
                    if (!focused) return;
                    if (_suppressNextNavigationHeroRestore) {
                      _suppressNextNavigationHeroRestore = false;
                      return;
                    }
                    unawaited(_restoreSponsoredHero());
                  },
                ),
              ),
              if (useTvRail && _headerVisibleAtTop)
                Positioned(
                  right: screenSize.width >= 1400 ? 30 : 22,
                  top: 14,
                  child: RepaintBoundary(
                    key: const ValueKey('home-fixed-profile'),
                    child: HomeTopRightHeader(
                      preferences: preferences,
                      searchFocusNode: _searchFocus,
                      searchController: _homeSearchController,
                      profileFocusNode: _profileFocus,
                      onSearchSubmitted: _submitHeaderSearch,
                      onSearchExitLeft: _focusNavigationChrome,
                      onSearchExitRight: () {
                        if (_profileFocus.context != null) {
                          _profileFocus.requestFocus();
                        }
                      },
                      onSearchExitDown: _restoreContentFocus,
                      onProfileKeyEvent: _handleHeaderProfileKey,
                      onSearchFocusChanged: (focused) {
                        if (focused) unawaited(_restoreSponsoredHero());
                      },
                      onProfileFocusChanged: (focused) {
                        if (focused) unawaited(_restoreSponsoredHero());
                      },
                    ),
                  ),
                ),
            ] else if (isPhonePortrait) ...[
              Positioned.fill(
                bottom: phoneBottomNavigationHeight,
                child: SingleChildScrollView(
                  key: const ValueKey('home-scroll-content'),
                  controller: _scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      phoneHeader(),
                      if (preferences.showHero)
                        Padding(
                          padding: contentHorizontalPadding,
                          child: heroPanel,
                        ),
                      SizedBox(
                        height: preferences.homeLayout == HomeLayout.compact
                            ? 10
                            : 18,
                      ),
                      ...buildShelves(tvNavigation: false),
                      const SizedBox(height: 42),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: PhoneBottomNavigation(
                  preferences: preferences,
                  activeDestination: TopNavigationDestination.home,
                  activeFocusNode: _homeNavFocus,
                  onActivePressed: _handleHomeActivation,
                  onExitUp: _restoreContentFocus,
                ),
              ),
            ] else
              SingleChildScrollView(
                key: const ValueKey('home-scroll-content'),
                controller: _scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: contentHorizontalPadding,
                      child: MainNavigationBar(
                        active: MainNavigationDestination.home,
                        preferences: preferences,
                        homeFocusNode: _homeNavFocus,
                        autofocusActive: !preferences.showHero,
                        onHomePressed: _handleHomeActivation,
                      ),
                    ),
                    if (preferences.showHero)
                      Padding(
                        padding: contentHorizontalPadding,
                        child: heroPanel,
                      ),
                    SizedBox(
                      height: preferences.homeLayout == HomeLayout.compact
                          ? 10
                          : 18,
                    ),
                    ...buildShelves(tvNavigation: false),
                    const SizedBox(height: 42),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeShelfRow {
  const _HomeShelfRow({
    required this.shelf,
    required this.items,
    this.loading = false,
    this.landscape = false,
  });

  final HomeShelf shelf;
  final List<_ShelfItem> items;
  final bool loading;
  final bool landscape;
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.focusNode,
    required this.myListFocusNode,
    required this.titlePreference,
    required this.preferences,
    required this.isTelevision,
    required this.isLoading,
    required this.activeIndex,
    required this.itemCount,
    required this.onOpen,
    required this.onActionFocused,
    this.height,
    this.onManageList,
    this.onActionKeyEvent,
    this.anime,
  });

  final AnimeSummary? anime;
  final FocusNode focusNode;
  final FocusNode myListFocusNode;
  final TitleLanguagePreference titlePreference;
  final SettingsPreferences preferences;
  final bool isTelevision;
  final bool isLoading;
  final int activeIndex;
  final int itemCount;
  final double? height;
  final VoidCallback onOpen;
  final VoidCallback? onManageList;
  final ValueChanged<FocusNode> onActionFocused;
  final FocusOnKeyEventCallback? onActionKeyEvent;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompactWidth;
    final dense = preferences.homeLayout == HomeLayout.compact;
    final cinematicTv = height != null && !compact;
    final shortTvHero = cinematicTv && height! < 380;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final copyWidth = compact
        // Compact Home wraps the hero in the screen gutter, then the hero
        // adds its own 15dp copy gutter. Account for both so a portrait phone
        // never lays out its title beyond the visible card.
        ? screenWidth - 62
        : isTelevision
        // Keep the complete title within roughly the left half of the TV hero
        // so even long localized titles can wrap without covering the subject
        // artwork on the right.
        ? (screenWidth * .48).clamp(360.0, 920.0)
        : screenWidth >= 1400
        ? 660.0
        : screenWidth >= 1100
        ? 570.0
        : 310.0;
    final titleHeight = shortTvHero ? 68.0 : (cinematicTv ? 102.0 : 80.0);
    final displayTitle =
        anime?.displayTitle(titlePreference) ?? 'Frieren: Beyond Journey’s End';
    final facts = <String>[
      if (anime?.seasonYear case final year?) '$year',
      if (anime?.format case final format?) format.replaceAll('_', ' '),
      if (anime?.episodes case final episodes?) '$episodes episodes',
      if (anime?.durationMinutes case final minutes?) '$minutes min',
    ];
    final labels = <({String text, bool accent})>[
      if (anime?.status case final status?)
        (text: _titleCaseLabel(status.replaceAll('_', ' ')), accent: true),
      for (final genre in anime?.genres.take(2) ?? const <String>[])
        (text: genre, accent: false),
    ];
    return Container(
      key: const ValueKey('home-hero'),
      height: height ?? (compact ? (dense ? 360 : 410) : (dense ? 290 : 350)),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: context.appPalette.surface),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF26050C), Color(0xFF080808)],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: isLoading
                ? const ArtworkSkeleton(key: ValueKey('hero-loading'))
                : NetworkArtwork(
                    key: ValueKey('hero-art-${anime?.id ?? 0}'),
                    // AniList does not provide a wide banner for every title.
                    // A cover is still preferable to an apparently missing
                    // carousel background, and BoxFit.cover keeps it usable
                    // in the same hero frame.
                    url: anime?.bannerImageUrl ?? anime?.coverImageUrl,
                    cacheWidth: 1280,
                  ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF030508),
                  Color(0xF0000308),
                  Color(0x82000308),
                  Color(0x12000308),
                ],
                stops: [0, .28, .57, 1],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0x16000000), Color(0xE8000000)],
                begin: Alignment.center,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              cinematicTv ? 34 : (compact ? 15 : 18),
              shortTvHero ? 68 : (cinematicTv ? 78 : (compact ? 24 : 30)),
              cinematicTv ? 28 : (compact ? 15 : 24),
              shortTvHero ? 18 : (cinematicTv ? 28 : (compact ? 18 : 22)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.star_rounded,
                      size: shortTvHero ? 15 : 18,
                      color: context.appPalette.accentBright,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'FEATURED',
                      key: const ValueKey('home-hero-featured-label'),
                      style: TextStyle(
                        color: context.appPalette.accentBright,
                        fontSize: shortTvHero ? 12 : 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.35,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: shortTvHero ? 8 : 12),
                SizedBox(
                  key: ValueKey('hero-title-${anime?.id ?? 0}'),
                  width: copyWidth,
                  height: titleHeight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: Align(
                      key: ValueKey('hero-title-text-${anime?.id ?? 0}'),
                      alignment: Alignment.centerLeft,
                      child: _HeroTitleText(
                        title: displayTitle,
                        width: copyWidth,
                        fitEntireTitle: isTelevision,
                        style: Theme.of(context).textTheme.displaySmall
                            ?.copyWith(
                              color: context.appPalette.primaryText,
                              fontSize: cinematicTv
                                  ? (shortTvHero ? 33 : (dense ? 39 : 46))
                                  : (compact ? 29 : 39),
                              height: .98,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: shortTvHero ? 7 : 9),
                _HeroMetadataLine(score: anime?.score, values: facts),
                if (labels.isNotEmpty) ...[
                  SizedBox(height: shortTvHero ? 6 : 8),
                  _HeroLabelLine(labels: labels),
                ],
                const Spacer(),
                Wrap(
                  spacing: shortTvHero ? 8 : 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _TvButton(
                      key: const ValueKey('home-hero-watch-now'),
                      focusNode: focusNode,
                      autofocus: true,
                      icon: Icons.play_arrow_rounded,
                      label: 'Watch now',
                      onPressed: onOpen,
                      onFocusChanged: (focused) {
                        if (focused) onActionFocused(focusNode);
                      },
                      onKeyEvent: onActionKeyEvent,
                    ),
                    if (onManageList != null)
                      _TvButton(
                        key: const ValueKey('home-hero-my-list'),
                        focusNode: myListFocusNode,
                        primary: false,
                        icon: Icons.add_rounded,
                        label: 'My List',
                        onPressed: onManageList!,
                        onFocusChanged: (focused) {
                          if (focused) onActionFocused(myListFocusNode);
                        },
                        onKeyEvent: onActionKeyEvent,
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (!compact && itemCount > 1)
            Positioned(
              right: 20,
              bottom: 18,
              child: Row(
                children: [
                  for (var index = 0; index < itemCount; index++)
                    _HeroDot(active: index == activeIndex),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroTitleText extends StatelessWidget {
  const _HeroTitleText({
    required this.title,
    required this.width,
    required this.fitEntireTitle,
    required this.style,
  });

  final String title;
  final double width;
  final bool fitEntireTitle;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final titleText = Text(
      title,
      maxLines: fitEntireTitle ? null : 2,
      overflow: fitEntireTitle ? TextOverflow.visible : TextOverflow.ellipsis,
      softWrap: true,
      style: style,
    );
    if (!fitEntireTitle) return titleText;

    return FittedBox(
      key: const ValueKey('home-hero-title-fit'),
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SizedBox(width: width, child: titleText),
    );
  }
}

class _HeroMetadataLine extends StatelessWidget {
  const _HeroMetadataLine({required this.values, this.score});

  final double? score;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    void add(Widget child) {
      if (items.isNotEmpty) items.add(const _HeroBullet());
      items.add(child);
    }

    if (score != null) {
      add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.star_rounded,
              size: 16,
              color: context.appPalette.accentBright,
            ),
            const SizedBox(width: 5),
            _HeroInlineText(score!.toStringAsFixed(1)),
          ],
        ),
      );
    }
    for (final value in values) {
      add(_HeroInlineText(value));
    }
    return Wrap(
      spacing: 9,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }
}

class _HeroLabelLine extends StatelessWidget {
  const _HeroLabelLine({required this.labels});

  final List<({String text, bool accent})> labels;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (final label in labels) {
      if (items.isNotEmpty) items.add(const _HeroBullet());
      items.add(_HeroInlineText(label.text, accent: label.accent));
    }
    return Wrap(
      spacing: 9,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }
}

class _HeroInlineText extends StatelessWidget {
  const _HeroInlineText(this.text, {this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: accent
          ? context.appPalette.accentBright
          : context.appPalette.primaryText.withValues(alpha: .82),
      fontSize: 13,
      fontWeight: accent ? FontWeight.w800 : FontWeight.w600,
    ),
  );
}

class _HeroBullet extends StatelessWidget {
  const _HeroBullet();

  @override
  Widget build(BuildContext context) => Text(
    '•',
    style: TextStyle(
      color: context.appPalette.primaryText.withValues(alpha: .62),
      fontSize: 12,
      fontWeight: FontWeight.w800,
    ),
  );
}

class _HeroDot extends StatelessWidget {
  const _HeroDot({this.active = false});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: active ? 24 : 7,
      height: 7,
      margin: const EdgeInsets.only(left: 5),
      decoration: BoxDecoration(
        color: active ? context.appPalette.accentBright : Colors.white54,
        borderRadius: BorderRadius.circular(99),
      ),
    );
  }
}

({double height, double width}) _posterCardMetrics(
  BuildContext context, {
  required bool dense,
  required bool matchSearchDefault,
  required double availableWidth,
}) {
  if (!dense && matchSearchDefault) {
    final geometry = defaultPosterCardGeometry(availableWidth);
    return (height: geometry.height, width: geometry.width);
  }
  final compact = context.isCompactWidth;
  final screenWidth = MediaQuery.sizeOf(context).width;
  if (screenWidth >= 1600) {
    return (height: dense ? 238 : 278, width: dense ? 144 : 166);
  }
  if (screenWidth >= 1200) {
    return (height: dense ? 205 : 240, width: dense ? 118 : 138);
  }
  return (
    height: dense ? (compact ? 198 : 170) : (compact ? 238 : 205),
    width: dense ? (compact ? 104 : 88) : (compact ? 126 : 106),
  );
}

class _MediaShelf extends StatefulWidget {
  const _MediaShelf({
    required this.title,
    required this.items,
    required this.preferences,
    required this.onOpen,
    required this.onFocused,
    required this.onVerticalKey,
    required this.modernPosterSizing,
    this.landscape = false,
    this.onLeftEdge,
    this.onManage,
    super.key,
  });

  final String title;
  final List<_ShelfItem> items;
  final SettingsPreferences preferences;
  final ValueChanged<_ShelfItem> onOpen;
  final ValueChanged<int> onFocused;
  final KeyEventResult Function(KeyEvent event, int column) onVerticalKey;
  final bool modernPosterSizing;
  final bool landscape;
  final VoidCallback? onLeftEdge;
  final ValueChanged<_ShelfItem>? onManage;

  @override
  State<_MediaShelf> createState() => _MediaShelfState();
}

class _MediaShelfState extends State<_MediaShelf> {
  late final TvShelfFocusController _focusController;
  double _itemExtent = 0;
  double _itemSpacing = 0;

  @override
  void initState() {
    super.initState();
    _focusController = TvShelfFocusController(
      debugLabel: 'home.shelf.${widget.title}',
      itemCount: widget.items.length,
    );
  }

  @override
  void didUpdateWidget(covariant _MediaShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusController.syncItemCount(widget.items.length);
  }

  bool requestFocus({int? preferredIndex}) {
    return _focusController.requestFocus(
      preferredIndex: preferredIndex,
      itemExtent: _itemExtent > 0 ? _itemExtent : null,
      spacing: _itemExtent > 0 ? _itemSpacing : null,
    );
  }

  @override
  void dispose() {
    _focusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildShelf(context, availableWidth: constraints.maxWidth),
  );

  Widget _buildShelf(BuildContext context, {required double availableWidth}) {
    final dense = widget.preferences.homeLayout == HomeLayout.compact;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final posterMetrics = _posterCardMetrics(
      context,
      dense: dense,
      matchSearchDefault: widget.modernPosterSizing,
      availableWidth: availableWidth,
    );
    final spacing = 12 * widget.preferences.contentDensity.spacingScale;
    final width = widget.landscape
        ? (screenWidth >= 1600
                  ? (dense ? 304.0 : 350.0)
                  : dense
                  ? 238.0
                  : 278.0) *
              widget.preferences.thumbnailScale
        : posterMetrics.width * widget.preferences.thumbnailScale;
    final cardHeight = widget.landscape
        ? width * 9 / 16
        : posterMetrics.height * widget.preferences.thumbnailScale;
    final artworkHeight = widget.landscape
        ? cardHeight
        : cardHeight - (widget.preferences.showCardSubtitles ? 60.0 : 46.0);
    _itemExtent = width;
    _itemSpacing = spacing;
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          SizedBox(
            height:
                (MediaQuery.sizeOf(context).width >= 840 ? 2 : 9) *
                widget.preferences.contentDensity.spacingScale,
          ),
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              controller: _focusController.scrollController,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: widget.items.length,
              separatorBuilder: (_, _) => SizedBox(width: spacing),
              itemBuilder: (context, index) {
                final item = widget.items[index];
                return _PosterCard(
                  item: item,
                  width: width,
                  artworkHeight: artworkHeight,
                  preferences: widget.preferences,
                  landscape: widget.landscape,
                  focusNode: _focusController.focusNodeAt(index),
                  onFocusChanged: (focused) {
                    if (!focused) return;
                    _focusController.rememberIndex(index);
                    _focusController.reveal(
                      index: index,
                      itemExtent: width,
                      spacing: spacing,
                    );
                    widget.onFocused(index);
                  },
                  onKeyEvent: (_, event) {
                    final horizontal = _focusController.handleHorizontalKey(
                      event,
                      currentIndex: index,
                      itemExtent: width,
                      spacing: spacing,
                      onLeftEdge: widget.onLeftEdge,
                    );
                    if (horizontal == KeyEventResult.handled) {
                      return horizontal;
                    }
                    return widget.onVerticalKey(event, index);
                  },
                  onPressed: () => widget.onOpen(item),
                  onLongPress: widget.onManage == null
                      ? null
                      : () => widget.onManage!(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaShelfSkeleton extends StatelessWidget {
  const _MediaShelfSkeleton({
    required this.title,
    required this.preferences,
    required this.modernPosterSizing,
  });

  final String title;
  final SettingsPreferences preferences;
  final bool modernPosterSizing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildSkeleton(context, availableWidth: constraints.maxWidth),
  );

  Widget _buildSkeleton(
    BuildContext context, {
    required double availableWidth,
  }) {
    final dense = preferences.homeLayout == HomeLayout.compact;
    final posterMetrics = _posterCardMetrics(
      context,
      dense: dense,
      matchSearchDefault: modernPosterSizing,
      availableWidth: availableWidth,
    );
    final width = posterMetrics.width * preferences.thumbnailScale;
    final cardHeight = posterMetrics.height * preferences.thumbnailScale;
    final artworkHeight =
        cardHeight - (preferences.showCardSubtitles ? 60.0 : 46.0);
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          SizedBox(
            height:
                (MediaQuery.sizeOf(context).width >= 840 ? 2 : 9) *
                preferences.contentDensity.spacingScale,
          ),
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 8,
              separatorBuilder: (_, _) =>
                  SizedBox(width: 10 * preferences.contentDensity.spacingScale),
              itemBuilder: (_, _) => SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: artworkHeight,
                      child: const ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                        child: ArtworkSkeleton(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const SizedBox(
                      height: 24,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: _SkeletonLine(widthFactor: .88),
                      ),
                    ),
                    if (preferences.showCardSubtitles) ...[
                      const SizedBox(height: 5),
                      const _SkeletonLine(widthFactor: .58),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.widthFactor});

  final double widthFactor;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: widthFactor,
    child: Container(
      height: 7,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(99),
      ),
    ),
  );
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.item,
    required this.width,
    required this.artworkHeight,
    required this.onPressed,
    required this.preferences,
    required this.focusNode,
    required this.onFocusChanged,
    required this.onKeyEvent,
    this.landscape = false,
    this.onLongPress,
  });

  final _ShelfItem item;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final double width;
  final double artworkHeight;
  final SettingsPreferences preferences;
  final FocusNode focusNode;
  final ValueChanged<bool> onFocusChanged;
  final FocusOnKeyEventCallback onKeyEvent;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    if (landscape) return _buildLandscape(context);
    return SizedBox(
      key: ValueKey('home-poster-card-${item.animeId ?? item.title}'),
      width: width,
      child: TvFocusable(
        focusNode: focusNode,
        onFocusChanged: onFocusChanged,
        onKeyEvent: onKeyEvent,
        onPressed: onPressed,
        onLongPress: onLongPress,
        focusScale: 1.025,
        borderRadius: BorderRadius.circular(7),
        child: ColoredBox(
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: ValueKey('home-artwork-${item.animeId ?? item.title}'),
                height: artworkHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (item.coverImageUrl == null)
                        ColoredBox(
                          color: context.appPalette.accent,
                          child: const Center(
                            child: Icon(
                              Icons.play_circle_outline_rounded,
                              color: Colors.white,
                              size: 40,
                            ),
                          ),
                        )
                      else
                        NetworkArtwork(
                          url: item.coverImageUrl,
                          cacheWidth: 190,
                        ),
                      if (animeAiringStatusLabel(item.airingStatus) != null)
                        Positioned(
                          left: 5,
                          top: 5,
                          child: PosterAiringStatusBadge(
                            status: item.airingStatus,
                          ),
                        ),
                      if (preferences.showPosterMetadata &&
                          item.hasPosterMetadata)
                        Positioned(
                          left: 4,
                          right: 4,
                          bottom: 4,
                          child: PosterMetadataOverlay(
                            score: item.score,
                            releaseYear: item.releaseYear,
                            durationMinutes: item.durationMinutes,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 24,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appPalette.primaryText,
                      fontSize: 11,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              if (preferences.showCardSubtitles)
                SizedBox(
                  height: 14,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 3, 6, 0),
                    child: Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appPalette.mutedText,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (item.progress != null) ...[
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: item.progress,
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                  color: context.appPalette.accentBright,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandscape(BuildContext context) {
    final episodeMatch = RegExp(
      r'Episode\s+(\d+)',
      caseSensitive: false,
    ).firstMatch(item.subtitle);
    return SizedBox(
      width: width,
      child: TvFocusable(
        focusNode: focusNode,
        onFocusChanged: onFocusChanged,
        onKeyEvent: onKeyEvent,
        onPressed: onPressed,
        onLongPress: onLongPress,
        focusScale: 1.025,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            key: ValueKey('home-continue-card-${item.animeId ?? item.title}'),
            fit: StackFit.expand,
            children: [
              NetworkArtwork(url: item.coverImageUrl, cacheWidth: 560),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Color(0xF2000000)],
                    stops: [.34, 1],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: item.progress == null ? 12 : 19,
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appPalette.primaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
              ),
              if (episodeMatch?.group(1) case final episode?)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .82),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      'EP $episode',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              if (item.progress case final progress?)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
                      color: context.appPalette.accentBright,
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

class _TvButton extends StatelessWidget {
  const _TvButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = true,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChanged,
    this.onKeyEvent,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChanged;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onFocusChanged: onFocusChanged,
      onKeyEvent: onKeyEvent,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(8),
      focusScale: 1.03,
      child: Container(
        constraints: BoxConstraints(minWidth: primary ? 132 : 112),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: primary
              ? context.appPalette.accent
              : Colors.black.withValues(alpha: .48),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: primary
                ? context.appPalette.accentBright.withValues(alpha: .76)
                : context.appPalette.primaryText.withValues(alpha: .2),
            width: 1.1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: Colors.white),
            const SizedBox(width: 7),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<_ShelfItem> _mergeContinueWatching({
  required List<PlaybackCheckpoint>? localHistory,
  required List<HomeTrackedAnime>? trackedWatching,
  required Set<int> dismissedIds,
  required TitleLanguagePreference titlePreference,
}) {
  final merged = <_ShelfItem>[];
  final localAniListIds = <int>{};
  final localMalIds = <int>{};
  final localAniListIndexes = <int, int>{};
  final localMalIndexes = <int, int>{};

  // Recent local playback contains the most useful resume position, so it is
  // deliberately added first and wins whenever the tracker has the same media
  // ID. A local checkpoint must not hide unrelated titles from MAL or AniList.
  for (final checkpoint in localHistory ?? const <PlaybackCheckpoint>[]) {
    if (checkpoint.completed ||
        !localAniListIds.add(checkpoint.anilistMediaId)) {
      continue;
    }
    if (checkpoint.malMediaId case final malId?) localMalIds.add(malId);
    final index = merged.length;
    merged.add(_ShelfItem.fromCheckpoint(checkpoint));
    localAniListIndexes[checkpoint.anilistMediaId] = index;
    if (checkpoint.malMediaId case final malId?) {
      localMalIndexes[malId] = index;
    }
  }

  final seenTrackerIds = <String>{};
  for (final tracked in trackedWatching ?? const <HomeTrackedAnime>[]) {
    final aniListId = tracked.anilistId;
    if (aniListId != null && dismissedIds.contains(aniListId)) continue;

    final matchesLocal = switch (tracked.provider) {
      TrackingProvider.anilist => localAniListIds.contains(
        aniListId ?? tracked.tracked.mediaId,
      ),
      TrackingProvider.myAnimeList => localMalIds.contains(
        tracked.tracked.mediaId,
      ),
    };
    if (matchesLocal) {
      final index = switch (tracked.provider) {
        TrackingProvider.anilist =>
          localAniListIndexes[aniListId ?? tracked.tracked.mediaId],
        TrackingProvider.myAnimeList =>
          localMalIndexes[tracked.tracked.mediaId],
      };
      if (index != null) {
        merged[index] = merged[index].copyWith(
          trackingItems: [...merged[index].trackingItems, tracked],
        );
      }
      continue;
    }

    final trackerKey = '${tracked.provider.name}:${tracked.tracked.mediaId}';
    if (!seenTrackerIds.add(trackerKey)) continue;
    merged.add(_ShelfItem.fromTracked(tracked, titlePreference));
  }

  return merged.isEmpty ? _HomeScreenState._connectTracking : merged;
}

class _ShelfItem {
  const _ShelfItem(
    this.title,
    this.subtitle, {
    this.progress,
    this.animeId,
    this.coverImageUrl,
    this.route,
    this.score,
    this.releaseYear,
    this.durationMinutes,
    this.historyMediaId,
    this.airingStatus,
    this.malMediaId,
    this.trackingItems = const [],
  });

  final String title;
  final String subtitle;
  final double? progress;
  final int? animeId;
  final String? coverImageUrl;
  final String? route;
  final double? score;
  final int? releaseYear;
  final int? durationMinutes;
  final int? historyMediaId;
  final String? airingStatus;
  final int? malMediaId;
  final List<HomeTrackedAnime> trackingItems;

  bool get hasPosterMetadata =>
      score != null || releaseYear != null || durationMinutes != null;

  factory _ShelfItem.fromAnime(
    AnimeSummary anime,
    TitleLanguagePreference titlePreference,
  ) {
    return _ShelfItem(
      anime.displayTitle(titlePreference),
      anime.episodes == null ? '' : '${anime.episodes} episodes',
      animeId: anime.id,
      malMediaId: anime.idMal,
      coverImageUrl: anime.coverImageUrl,
      score: anime.score,
      releaseYear: anime.seasonYear,
      durationMinutes: anime.durationMinutes,
      airingStatus: anime.status,
    );
  }

  factory _ShelfItem.fromCheckpoint(PlaybackCheckpoint checkpoint) {
    return _ShelfItem(
      checkpoint.title,
      'Episode ${checkpoint.episode} • ${_shortDuration(checkpoint.position)}',
      progress: checkpoint.progress,
      animeId: checkpoint.anilistMediaId,
      coverImageUrl: checkpoint.coverImageUrl,
      historyMediaId: checkpoint.anilistMediaId,
      malMediaId: checkpoint.malMediaId,
    );
  }

  _ShelfItem copyWith({
    String? subtitle,
    List<HomeTrackedAnime>? trackingItems,
  }) => _ShelfItem(
    title,
    subtitle ?? this.subtitle,
    progress: progress,
    animeId: animeId,
    coverImageUrl: coverImageUrl,
    route: route,
    score: score,
    releaseYear: releaseYear,
    durationMinutes: durationMinutes,
    historyMediaId: historyMediaId,
    airingStatus: airingStatus,
    malMediaId: malMediaId,
    trackingItems: trackingItems ?? this.trackingItems,
  );

  factory _ShelfItem.fromTracked(
    HomeTrackedAnime item,
    TitleLanguagePreference titlePreference,
  ) {
    final tracked = item.tracked;
    final subtitle = switch (tracked.status) {
      TrackingListStatus.watching =>
        'Episode ${tracked.progress}'
            '${tracked.totalEpisodes == null ? '' : ' of ${tracked.totalEpisodes}'}',
      TrackingListStatus.planToWatch => 'Plan to watch',
      TrackingListStatus.completed =>
        tracked.totalEpisodes == null
            ? 'Completed'
            : '${tracked.totalEpisodes} episodes • Completed',
      TrackingListStatus.dropped => 'Dropped',
      TrackingListStatus.onHold => 'On hold',
    };
    return _ShelfItem(
      tracked.displayTitle(titlePreference),
      subtitle,
      progress: tracked.totalEpisodes == null || tracked.totalEpisodes == 0
          ? null
          : (tracked.progress / tracked.totalEpisodes!).clamp(0, 1),
      animeId: item.anilistId,
      malMediaId: item.provider == TrackingProvider.myAnimeList
          ? tracked.mediaId
          : null,
      coverImageUrl: item.coverImageUrl,
      route: item.anilistId == null
          ? Uri(
              path: '/search',
              queryParameters: {'q': tracked.title},
            ).toString()
          : null,
      airingStatus: tracked.airingStatus,
      trackingItems: [item],
    );
  }
}

enum _HomeShowAction { open, removeLocal }

class _HomeShowActionsDialog extends StatelessWidget {
  const _HomeShowActionsDialog({required this.item});

  final _ShelfItem item;

  @override
  Widget build(BuildContext context) {
    final current = item.trackingItems.isEmpty
        ? null
        : item.trackingItems.first.tracked.status;
    return AlertDialog(
      backgroundColor: context.appPalette.surface,
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.animeId != null || item.trackingItems.isNotEmpty) ...[
              Text(
                item.trackingItems.isEmpty
                    ? 'Add or update this show on your connected AniList and MAL accounts.'
                    : 'Update status on ${item.trackingItems.map((entry) => entry.provider.displayName).join(' and ')}',
                style: TextStyle(color: context.appPalette.mutedText),
              ),
              const SizedBox(height: 14),
              TrackingStatusOptions(
                current: current,
                onSelected: (status) => Navigator.of(context).pop(status),
              ),
            ] else
              Text(
                'Connect AniList or MAL to change this show\'s list status.',
                style: TextStyle(color: context.appPalette.mutedText),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: item.animeId == null && item.trackingItems.isEmpty,
          onPressed: () => Navigator.of(context).pop(_HomeShowAction.open),
          child: const Text('Open show'),
        ),
        if (item.historyMediaId != null)
          FilledButton.tonal(
            onPressed: () =>
                Navigator.of(context).pop(_HomeShowAction.removeLocal),
            child: const Text('Remove locally'),
          ),
      ],
    );
  }
}

List<_ShelfItem>? _historyShelfItems({
  required List<PlaybackCheckpoint>? localHistory,
  required TrackingHomeData? tracking,
}) {
  if (localHistory == null) return null;
  final tracked = <HomeTrackedAnime>[
    ...?tracking?.watching,
    ...?tracking?.planToWatch,
    ...?tracking?.completed,
  ];
  return [
    for (final checkpoint in localHistory)
      _ShelfItem.fromCheckpoint(checkpoint).copyWith(
        trackingItems: [
          for (final item in tracked)
            if ((item.provider == TrackingProvider.anilist &&
                    (item.anilistId ?? item.tracked.mediaId) ==
                        checkpoint.anilistMediaId) ||
                (item.provider == TrackingProvider.myAnimeList &&
                    checkpoint.malMediaId == item.tracked.mediaId))
              item,
        ],
      ),
  ];
}

bool _isTrackedAnime(AnimeSummary anime, List<HomeTrackedAnime> tracked) {
  final normalized = _normalizedAnimeTitle(anime.title);
  return tracked.any((item) {
    if (item.provider == TrackingProvider.anilist &&
        (item.anilistId ?? item.tracked.mediaId) == anime.id) {
      return true;
    }
    if (item.provider == TrackingProvider.myAnimeList &&
        anime.idMal == item.tracked.mediaId) {
      return true;
    }
    return _normalizedAnimeTitle(item.tracked.title) == normalized;
  });
}

String _normalizedAnimeTitle(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

String _titleCaseLabel(String value) {
  final normalized = value.trim().replaceAll('_', ' ').toLowerCase();
  if (normalized.isEmpty) return value;
  return '${normalized[0].toUpperCase()}${normalized.substring(1)}';
}

String _shortDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
