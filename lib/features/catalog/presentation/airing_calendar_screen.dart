import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class AiringCalendarScreen extends ConsumerStatefulWidget {
  const AiringCalendarScreen({this.autofocusNavigation = false, super.key});

  final bool autofocusNavigation;

  @override
  ConsumerState<AiringCalendarScreen> createState() =>
      _AiringCalendarScreenState();
}

class _AiringCalendarScreenState extends ConsumerState<AiringCalendarScreen> {
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _cardWidth = 292.0;
  static const _cardSpacing = 12.0;

  final _backFocus = FocusNode(debugLabel: 'calendar.back');
  final _refreshFocus = FocusNode(debugLabel: 'calendar.refresh');
  final _verticalGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );
  final _headerGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );
  final _dayShelves = <DateTime, TvShelfFocusController>{};

  TvShelfFocusController _shelfFor(DateTime day, int entryCount) {
    final shelf = _dayShelves.putIfAbsent(
      day,
      () => TvShelfFocusController(
        debugLabel: 'calendar.${day.toIso8601String()}',
      ),
    );
    shelf.syncItemCount(entryCount * 2);
    return shelf;
  }

  @override
  void dispose() {
    _backFocus.dispose();
    _refreshFocus.dispose();
    _headerGate.reset();
    _verticalGate.reset();
    for (final shelf in _dayShelves.values) {
      shelf.dispose();
    }
    super.dispose();
  }

  void _focusEntry(
    List<MapEntry<DateTime, List<AiringScheduleEntry>>> groups,
    int row,
    int requestedIndex,
  ) {
    if (row < 0 || row >= groups.length) return;
    final group = groups[row];
    final shelf = _shelfFor(group.key, group.value.length);
    if (shelf.itemCount == 0) return;
    final index = requestedIndex.clamp(0, shelf.itemCount - 1);
    if (!shelf.requestFocus(
      preferredIndex: index,
      revealIndex: index ~/ 2,
      itemExtent: _cardWidth,
      spacing: _cardSpacing,
    )) {
      return;
    }
    final target = shelf.focusNodeAt(index).context;
    if (target != null) {
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: const Duration(milliseconds: 165),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  KeyEventResult _handleHeaderKey(
    KeyEvent event, {
    required FocusNode current,
    required TetoTopLevelLayout layout,
    required List<MapEntry<DateTime, List<AiringScheduleEntry>>> groups,
  }) {
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _headerGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_headerGate.accept(event)) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.arrowRight && current == _backFocus) {
      _refreshFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && current == _refreshFocus) {
      if (groups.isNotEmpty) {
        _focusEntry(groups, 0, 0);
      } else if (layout.usesPersistentNavigation) {
        layout.focusRail();
      } else if (_backFocus.context != null) {
        _backFocus.requestFocus();
      } else {
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && groups.isNotEmpty) {
      _focusEntry(
        groups,
        0,
        current == _refreshFocus && _backFocus.context != null ? 1 : 0,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _handleEntryKey(
    KeyEvent event, {
    required int row,
    required int focusIndex,
    required List<MapEntry<DateTime, List<AiringScheduleEntry>>> groups,
    required TetoTopLevelLayout layout,
  }) {
    final group = groups[row];
    final shelf = _shelfFor(group.key, group.value.length);
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      return shelf.handleHorizontalKey(
        event,
        currentIndex: focusIndex,
        itemExtent: _cardWidth,
        spacing: _cardSpacing,
        // Each visual card contributes a main and reminder focus stop. Reveal
        // the complete card for either one so its focused surface never stays
        // clipped at the shelf edge.
        revealIndexForFocusIndex: (index) => index ~/ 2,
        onLeftEdge: layout.usesPersistentNavigation
            ? layout.focusRail
            : _backFocus.context != null
            ? _backFocus.requestFocus
            : null,
      );
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      _ => 0,
    };
    if (direction == 0) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _verticalGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_verticalGate.accept(event)) return KeyEventResult.handled;
    final nextRow = row + direction;
    if (nextRow < 0) {
      if (layout.usesTvRail || _backFocus.context == null) {
        _refreshFocus.requestFocus();
      } else {
        (focusIndex.isEven ? _backFocus : _refreshFocus).requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (nextRow >= groups.length) return KeyEventResult.handled;
    _focusEntry(groups, nextRow, focusIndex);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(airingWeekProvider);
    final tracking = ref.watch(trackingHomeProvider);
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    var groups = <MapEntry<DateTime, List<AiringScheduleEntry>>>[];
    final scheduleEntries = schedule.valueOrNull;
    final trackingData = tracking.valueOrNull;
    if (scheduleEntries != null && trackingData != null) {
      final followed = <HomeTrackedAnime>[
        ...trackingData.watching,
        ...trackingData.planToWatch,
      ];
      final visibleEntries = scheduleEntries
          .where((entry) => _isFollowed(entry.anime, followed))
          .toList(growable: false);
      final days = <DateTime, List<AiringScheduleEntry>>{};
      for (final entry in visibleEntries) {
        final local = entry.airingAt.toLocal();
        final day = DateTime(local.year, local.month, local.day);
        (days[day] ??= []).add(entry);
      }
      groups = days.entries.toList(growable: false);
    }

    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: TopNavigationDestination.calendar,
      firstContentFocusNode: _refreshFocus,
      autofocusRail: widget.autofocusNavigation,
      builder: (context, layout) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!layout.usesPersistentNavigation)
            MainNavigationBar(
              active: MainNavigationDestination.calendar,
              preferences: preferences,
            ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final phoneHeader =
                  layout.navigationPlacement ==
                      TetoTopLevelNavigationPlacement.phoneLandscapeRail ||
                  layout.usesPhoneBottomNavigation;
              return Row(
                children: [
                  if (preferences.interfaceMode == InterfaceMode.phone) ...[
                    TvFocusable(
                      focusNode: _backFocus,
                      onKeyEvent: (_, event) => _handleHeaderKey(
                        event,
                        current: _backFocus,
                        layout: layout,
                        groups: groups,
                      ),
                      onPressed: () => _returnToPreviousOrHome(context),
                      borderRadius: BorderRadius.circular(9),
                      focusScale: 1.02,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Icon(Icons.arrow_back_rounded),
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Text(
                      'Airing calendar',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontSize: layout.usesTvRail ? 30 : null,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  if (!phoneHeader && !context.isCompactWidth) ...[
                    const SizedBox(width: 12),
                    Text(
                      'Times use your device timezone',
                      style: TextStyle(color: context.appPalette.mutedText),
                    ),
                  ],
                  SizedBox(width: phoneHeader ? 6 : 10),
                  TvFocusable(
                    focusNode: _refreshFocus,
                    autofocus: true,
                    onKeyEvent: (_, event) => _handleHeaderKey(
                      event,
                      current: _refreshFocus,
                      layout: layout,
                      groups: groups,
                    ),
                    onPressed: () {
                      ref.invalidate(airingWeekProvider);
                      ref.invalidate(trackingHomeProvider);
                    },
                    borderRadius: BorderRadius.circular(9),
                    focusScale: 1.02,
                    child: Tooltip(
                      message: 'Refresh calendar',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: context.appPalette.surface.withValues(
                            alpha: .92,
                          ),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: context.appPalette.primaryText.withValues(
                              alpha: .11,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.refresh_rounded, size: 18),
                            if (!phoneHeader) ...[
                              const SizedBox(width: 6),
                              const Text('Refresh'),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Expanded(
            child: schedule.when(
              loading: () => Center(
                child: CircularProgressIndicator(
                  color: context.appPalette.accentBright,
                ),
              ),
              error: (error, _) =>
                  Center(child: Text('Could not load schedule: $error')),
              data: (entries) {
                if (tracking.isLoading) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: context.appPalette.accentBright,
                    ),
                  );
                }
                if (tracking.hasError) {
                  return Center(
                    child: Text(
                      'Your AniList or MAL calendar could not be loaded. '
                      'Check the tracker connection in Settings, then select Refresh.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.appPalette.mutedText),
                    ),
                  );
                }
                if (groups.isEmpty) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 540),
                      child: Text(
                        'No followed shows are airing this week. Add a show '
                        'to Watching or Planning on AniList or MAL, then '
                        'refresh your list.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.appPalette.mutedText),
                      ),
                    ),
                  );
                }
                return ListView(
                  key: const ValueKey('calendar-schedule'),
                  padding: const EdgeInsets.fromLTRB(2, 4, 2, 28),
                  children: [
                    for (var row = 0; row < groups.length; row++) ...[
                      Builder(
                        builder: (context) {
                          final group = groups[row];
                          return Text(
                            '${_weekdays[group.key.weekday - 1]}  ${group.key.month}/${group.key.day}',
                            style: TextStyle(
                              color: context.appPalette.accentBright,
                              fontSize: 14,
                              letterSpacing: .35,
                              fontWeight: FontWeight.w900,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Builder(
                        builder: (context) {
                          final group = groups[row];
                          final shelf = _shelfFor(
                            group.key,
                            group.value.length,
                          );
                          return SizedBox(
                            height: 116,
                            child: ListView.separated(
                              controller: shelf.scrollController,
                              scrollDirection: Axis.horizontal,
                              clipBehavior: Clip.none,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 3,
                              ),
                              itemCount: group.value.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: _cardSpacing),
                              itemBuilder: (context, index) {
                                final entry = group.value[index];
                                final mainIndex = index * 2;
                                final reminderIndex = mainIndex + 1;
                                final time = TimeOfDay.fromDateTime(
                                  entry.airingAt.toLocal(),
                                ).format(context);
                                return SizedBox(
                                  width: _cardWidth,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: context.appPalette.surface
                                          .withValues(alpha: .94),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: context.appPalette.primaryText
                                            .withValues(alpha: .1),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: TvFocusable(
                                            focusNode: shelf.focusNodeAt(
                                              mainIndex,
                                            ),
                                            onFocusChanged: (focused) {
                                              if (focused) {
                                                shelf.rememberIndex(mainIndex);
                                              }
                                            },
                                            onKeyEvent: (_, event) =>
                                                _handleEntryKey(
                                                  event,
                                                  row: row,
                                                  focusIndex: mainIndex,
                                                  groups: groups,
                                                  layout: layout,
                                                ),
                                            onPressed: () => context.push(
                                              '/anime/${entry.anime.id}',
                                            ),
                                            borderRadius:
                                                const BorderRadius.only(
                                                  topLeft: Radius.circular(10),
                                                  bottomLeft: Radius.circular(
                                                    10,
                                                  ),
                                                ),
                                            focusScale: 1.018,
                                            child: Row(
                                              children: [
                                                SizedBox(
                                                  width: 72,
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        const BorderRadius.only(
                                                          topLeft:
                                                              Radius.circular(
                                                                9,
                                                              ),
                                                          bottomLeft:
                                                              Radius.circular(
                                                                9,
                                                              ),
                                                        ),
                                                    child: NetworkArtwork(
                                                      url: entry
                                                          .anime
                                                          .coverImageUrl,
                                                      cacheWidth: 160,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        entry.anime
                                                            .displayTitle(
                                                              titlePreference,
                                                            ),
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 6),
                                                      Text(
                                                        '$time • Episode ${entry.episode}',
                                                        style: TextStyle(
                                                          color: context
                                                              .appPalette
                                                              .accentBright,
                                                          fontSize: 10.5,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 42,
                                          child: TvFocusable(
                                            focusNode: shelf.focusNodeAt(
                                              reminderIndex,
                                            ),
                                            onFocusChanged: (focused) {
                                              if (focused) {
                                                shelf.rememberIndex(
                                                  reminderIndex,
                                                );
                                              }
                                            },
                                            onKeyEvent: (_, event) =>
                                                _handleEntryKey(
                                                  event,
                                                  row: row,
                                                  focusIndex: reminderIndex,
                                                  groups: groups,
                                                  layout: layout,
                                                ),
                                            onPressed: () async {
                                              final saved =
                                                  await AndroidTvBridge.instance
                                                      .scheduleReminder(
                                                        mediaId: entry.anime.id,
                                                        episode: entry.episode,
                                                        title: entry.anime
                                                            .displayTitle(
                                                              titlePreference,
                                                            ),
                                                        airingAt:
                                                            entry.airingAt,
                                                      );
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    saved
                                                        ? 'Reminder set for 10 minutes before airtime.'
                                                        : 'This airing is too soon for a reminder.',
                                                  ),
                                                ),
                                              );
                                            },
                                            borderRadius:
                                                const BorderRadius.only(
                                                  topRight: Radius.circular(10),
                                                  bottomRight: Radius.circular(
                                                    10,
                                                  ),
                                                ),
                                            focusScale: 1.018,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                border: Border(
                                                  left: BorderSide(
                                                    color: context
                                                        .appPalette
                                                        .primaryText
                                                        .withValues(alpha: .08),
                                                  ),
                                                ),
                                              ),
                                              child: Center(
                                                child: Icon(
                                                  Icons
                                                      .notifications_active_outlined,
                                                  size: 19,
                                                  color: context
                                                      .appPalette
                                                      .accentBright,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
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

bool _isFollowed(AnimeSummary anime, List<HomeTrackedAnime> followed) {
  final normalized = _normalizedTitle(anime.title);
  return followed.any((item) {
    if (item.provider == TrackingProvider.anilist &&
        (item.anilistId ?? item.tracked.mediaId) == anime.id) {
      return true;
    }
    if (item.provider == TrackingProvider.myAnimeList &&
        anime.idMal == item.tracked.mediaId) {
      return true;
    }
    return _normalizedTitle(item.tracked.title) == normalized;
  });
}

String _normalizedTitle(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
