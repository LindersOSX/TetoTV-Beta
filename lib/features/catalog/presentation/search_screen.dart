import 'dart:async';

import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_grid.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/presentation/catalog_tracking_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({
    this.initialQuery,
    this.autofocusNavigation = false,
    super.key,
  });

  final String? initialQuery;
  final bool autofocusNavigation;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _queryController = TextEditingController();
  final _backFocusNode = FocusNode(debugLabel: 'search.back');
  final _searchFocusNode = FocusNode(debugLabel: 'search_input');
  final _voiceFocusNode = FocusNode(debugLabel: 'search.voice');
  final _firstResultFocusNode = FocusNode(debugLabel: 'search.result.first');
  final _headerRepeatGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );
  Timer? _debounce;
  AsyncValue<List<AnimeSummary>> _results = const AsyncData([]);
  var _searchGeneration = 0;
  var _hasSearched = false;
  var _voiceSearching = false;
  var _searchEditing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.length >= 2) {
      _queryController.text = initial;
      Future.microtask(() => _search(initial));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _headerRepeatGate.reset();
    _queryController.dispose();
    _backFocusNode.dispose();
    _searchFocusNode.dispose();
    _voiceFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  void _queueSearch(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      _searchGeneration++;
      setState(() {
        _hasSearched = false;
        _results = const AsyncData([]);
      });
      return;
    }
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(query));
  }

  void _submitSearch(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      _queueSearch(query);
      return;
    }
    unawaited(_search(query, focusFirstResult: true));
  }

  Future<void> _search(String query, {bool focusFirstResult = false}) async {
    if (!mounted) return;
    final normalized = query.trim();
    if (normalized.length < 2) return;
    final generation = ++_searchGeneration;
    setState(() {
      _hasSearched = true;
      _results = const AsyncLoading();
    });
    try {
      final results = await ref.read(catalogClientProvider).search(normalized);
      if (mounted && generation == _searchGeneration) {
        setState(() => _results = AsyncData(results));
        if (focusFirstResult && results.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _firstResultFocusNode.context != null) {
              _firstResultFocusNode.requestFocus();
            }
          });
        }
      }
    } catch (error, stackTrace) {
      if (mounted && generation == _searchGeneration) {
        unawaited(
          recordAnonymousHandledError(
            area: AnonymousErrorArea.catalog,
            error: error,
            stack: stackTrace,
          ),
        );
        setState(() => _results = AsyncError(error, stackTrace));
      }
    }
  }

  Future<void> _voiceSearch() async {
    if (_voiceSearching) return;
    setState(() => _voiceSearching = true);
    String? query;
    String? failure;
    try {
      query = await AndroidTvBridge.instance.voiceSearch();
    } on PlatformException catch (error) {
      failure = error.message;
    } catch (_) {
      failure = 'Voice search could not start on this device.';
    }
    if (!mounted) return;
    setState(() => _voiceSearching = false);
    if (query == null || query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failure ??
                'No title was recognized. Check the microphone permission and try again.',
          ),
          backgroundColor: context.appPalette.surfaceRaised,
          duration: const Duration(seconds: 5),
        ),
      );
      _searchFocusNode.requestFocus();
      return;
    }
    _queryController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _submitSearch(query);
  }

  Future<void> _manageAnime(AnimeSummary anime) =>
      manageCatalogTrackingStatus(context: context, ref: ref, anime: anime);

  KeyEventResult _handleHeaderNavigation(
    KeyEvent event,
    TetoTopLevelLayout layout,
  ) {
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    final current = FocusManager.instance.primaryFocus;
    if (current == _searchFocusNode && _searchEditing) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      _headerRepeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_headerRepeatGate.accept(event)) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (current == _searchFocusNode) {
        if (layout.usesPersistentNavigation) {
          layout.focusRail();
        } else if (_backFocusNode.context != null) {
          _backFocusNode.requestFocus();
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      }
      if (current == _voiceFocusNode) {
        _searchFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (current == _backFocusNode) {
        _searchFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (current == _searchFocusNode) {
        _voiceFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown &&
        (_results.valueOrNull?.isNotEmpty ?? false) &&
        _firstResultFocusNode.context != null) {
      _firstResultFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: TopNavigationDestination.search,
      firstContentFocusNode: _searchFocusNode,
      autofocusRail: widget.autofocusNavigation,
      onActiveDestinationPressed: _searchFocusNode.requestFocus,
      resizeToAvoidBottomInset: true,
      builder: (context, layout) {
        final responsivePadding = context.responsiveScreenPadding;
        return Padding(
          padding: layout.usesSideNavigation
              ? EdgeInsets.zero
              : EdgeInsets.only(
                  top: responsivePadding.top,
                  bottom: responsivePadding.bottom,
                ),
          child: Focus(
            canRequestFocus: false,
            onKeyEvent: (_, event) => _handleHeaderNavigation(event, layout),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final back =
                        preferences.interfaceMode == InterfaceMode.phone
                        ? TvFocusable(
                            focusNode: _backFocusNode,
                            onPressed: () => _returnToPreviousOrHome(context),
                            borderRadius: BorderRadius.circular(10),
                            focusScale: 1.02,
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.appPalette.surface.withValues(
                                  alpha: .92,
                                ),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: context.appPalette.primaryText
                                      .withValues(alpha: .11),
                                ),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(10),
                                child: Icon(Icons.arrow_back_rounded, size: 20),
                              ),
                            ),
                          )
                        : null;
                    final input = TvTextInput(
                      focusNode: _searchFocusNode,
                      controller: _queryController,
                      labelText: 'Search',
                      hintText: 'Title, synonym, or Japanese name',
                      keyboardTitle: 'Search anime',
                      autofocus: true,
                      onChanged: _queueSearch,
                      onSubmitted: _submitSearch,
                      onEditingChanged: (editing) => _searchEditing = editing,
                    );
                    final voice = TvFocusable(
                      focusNode: _voiceFocusNode,
                      onPressed: () => unawaited(_voiceSearch()),
                      borderRadius: BorderRadius.circular(12),
                      focusScale: 1.02,
                      child: Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: context.appPalette.surface.withValues(
                            alpha: .92,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: context.appPalette.primaryText.withValues(
                              alpha: .11,
                            ),
                          ),
                        ),
                        child: Icon(
                          _voiceSearching
                              ? Icons.graphic_eq_rounded
                              : Icons.mic_rounded,
                          color: context.appPalette.accentBright,
                          size: 25,
                        ),
                      ),
                    );
                    if (constraints.maxWidth < 620) {
                      return Column(
                        children: [
                          Row(
                            children: [
                              if (back != null) ...[
                                back,
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(
                                  'Search anime',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              voice,
                            ],
                          ),
                          const SizedBox(height: 10),
                          input,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        if (back != null) ...[back, const SizedBox(width: 18)],
                        Text(
                          'Search anime',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontSize: layout.usesTvRail ? 30 : null,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(width: 28),
                        Expanded(child: input),
                        const SizedBox(width: 10),
                        voice,
                      ],
                    );
                  },
                ),
                SizedBox(height: context.isCompactWidth ? 20 : 34),
                Text(
                  !_hasSearched
                      ? 'Start typing to search anime'
                      : 'Results for “${_queryController.text.trim()}”',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 18),
                Expanded(child: _resultsBody(titlePreference, layout)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _resultsBody(
    TitleLanguagePreference titlePreference,
    TetoTopLevelLayout layout,
  ) {
    return _results.when(
      loading: () => Center(
        child: CircularProgressIndicator(
          color: context.appPalette.secondaryAccent,
        ),
      ),
      error: (error, _) => _SearchMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Search failed',
        body: error is StateError
            ? error.message.toString()
            : 'The catalog could not be reached. Please try again.',
      ),
      data: (items) {
        if (items.isEmpty) {
          return _hasSearched
              ? const _SearchMessage(
                  icon: Icons.search_off_rounded,
                  title: 'No matches found',
                  body: 'Try another title, spelling, or Japanese name.',
                )
              : const _SearchMessage(
                  icon: Icons.manage_search_rounded,
                  title: 'Find your next show',
                  body: 'Search results will appear here.',
                );
        }
        // Keep the denser touch-first phone presentation unchanged. Expanded
        // layouts use CatalogGrid for deterministic remote movement, focus
        // restoration after details, and an explicit escape to the TV rail.
        if (context.isCompactWidth) {
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisExtent: 225,
              crossAxisSpacing: 10,
              mainAxisSpacing: 14,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final anime = items[index];
              return _SearchCard(
                anime: anime,
                titlePreference: titlePreference,
                focusNode: index == 0 ? _firstResultFocusNode : null,
                onPressed: () => context.push('/anime/${anime.id}'),
                onLongPress: () => unawaited(_manageAnime(anime)),
              );
            },
          );
        }
        return CatalogGrid(
          items: items,
          titlePreference: titlePreference,
          autofocus: false,
          firstFocusNode: _firstResultFocusNode,
          onNavigateLeftFromFirstColumn: layout.usesPersistentNavigation
              ? layout.focusRail
              : null,
          onNavigateUpFromFirstRow: _searchFocusNode.requestFocus,
          onLongPress: (anime) => unawaited(_manageAnime(anime)),
        );
      },
    );
  }
}

void _returnToPreviousOrHome(BuildContext context) {
  if (Navigator.of(context).canPop()) {
    context.pop();
    return;
  }
  context.go('/');
}

class _SearchCard extends StatelessWidget {
  const _SearchCard({
    required this.anime,
    required this.titlePreference,
    required this.onPressed,
    required this.onLongPress,
    this.focusNode,
  });

  final AnimeSummary anime;
  final TitleLanguagePreference titlePreference;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 122,
        height: 225,
        child: TvFocusable(
          focusNode: focusNode,
          onPressed: onPressed,
          onLongPress: onLongPress,
          child: ColoredBox(
            color: Colors.black,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetworkArtwork(url: anime.coverImageUrl, cacheWidth: 210),
                      if (animeAiringStatusLabel(anime.status) != null)
                        Positioned(
                          left: 5,
                          top: 5,
                          child: PosterAiringStatusBadge(status: anime.status),
                        ),
                      if (anime.score != null ||
                          anime.seasonYear != null ||
                          anime.durationMinutes != null)
                        Positioned(
                          left: 5,
                          right: 5,
                          bottom: 5,
                          child: PosterMetadataOverlay(
                            score: anime.score,
                            releaseYear: anime.seasonYear,
                            durationMinutes: anime.durationMinutes,
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 7, 6, 3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        anime.displayTitle(titlePreference),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1.05,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (anime.episodes case final episodes?) ...[
                        const SizedBox(height: 4),
                        Text(
                          '$episodes episodes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appPalette.mutedText,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 60, color: context.appPalette.mutedText),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
