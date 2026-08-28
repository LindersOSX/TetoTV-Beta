import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/application/unified_media_search_controller.dart';
import 'package:anime_tv/features/local_media/data/jellyfin_client.dart';
import 'package:anime_tv/features/local_media/data/plex_client.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/library_tv_player_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class LocalMediaScreen extends ConsumerStatefulWidget {
  const LocalMediaScreen({
    this.activeDestination = TopNavigationDestination.settings,
    this.managementOnly = false,
    this.openLibraryPlayer,
    super.key,
  });

  final TopNavigationDestination activeDestination;
  final bool managementOnly;

  /// Test seam for inspecting the private-library request without starting a
  /// native MPV process. Production navigation always uses
  /// [LibraryTvPlayerScreen].
  @visibleForTesting
  final Future<void> Function(LibraryPlaybackRequest request)?
  openLibraryPlayer;

  @override
  ConsumerState<LocalMediaScreen> createState() => _LocalMediaScreenState();
}

class _LocalMediaScreenState extends ConsumerState<LocalMediaScreen> {
  static const _mediaRowExtent = 92.0;

  final _addressController = TextEditingController(text: 'http://');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'local-media.jellyfin.address');
  final _usernameFocus = FocusNode(debugLabel: 'local-media.jellyfin.username');
  final _passwordFocus = FocusNode(debugLabel: 'local-media.jellyfin.password');
  final _plexAddressController = TextEditingController(text: 'http://');
  final _plexTokenController = TextEditingController();
  final _plexAddressFocus = FocusNode(debugLabel: 'local-media.plex.address');
  final _plexTokenFocus = FocusNode(debugLabel: 'local-media.plex.token');
  final _searchController = TextEditingController();
  final _pageScrollController = ScrollController();
  final _searchResultsScrollController = ScrollController();
  final _jellyfinItemsScrollController = ScrollController();
  final _plexItemsScrollController = ScrollController();
  final _contentRootFocus = FocusNode(
    debugLabel: 'local-media.content-root',
    canRequestFocus: false,
  );
  final _contentEntryFocus = FocusNode(
    debugLabel: 'local-media.content-entry',
    skipTraversal: true,
  );
  final _backFocus = FocusNode(debugLabel: 'local-media.back');
  final _searchFocus = FocusNode(debugLabel: 'local-media.unified-search');
  final _searchActionFocus = FocusNode(debugLabel: 'local-media.search-action');
  final _clearSearchFocus = FocusNode(debugLabel: 'local-media.clear-search');
  final _chooseVideoFocus = FocusNode(debugLabel: 'local-media.choose-video');
  final _recentVideoFocus = FocusNode(debugLabel: 'local-media.recent-video');
  final _jellyfinConnectFocus = FocusNode(
    debugLabel: 'local-media.jellyfin.connect',
  );
  final _jellyfinUpFocus = FocusNode(debugLabel: 'local-media.jellyfin.up');
  final _jellyfinRefreshFocus = FocusNode(
    debugLabel: 'local-media.jellyfin.refresh',
  );
  final _jellyfinDisconnectFocus = FocusNode(
    debugLabel: 'local-media.jellyfin.disconnect',
  );
  final _jellyfinLoadMoreFocus = FocusNode(
    debugLabel: 'local-media.jellyfin.load-more',
  );
  final _plexConnectFocus = FocusNode(debugLabel: 'local-media.plex.connect');
  final _plexUpFocus = FocusNode(debugLabel: 'local-media.plex.up');
  final _plexRefreshFocus = FocusNode(debugLabel: 'local-media.plex.refresh');
  final _plexDisconnectFocus = FocusNode(
    debugLabel: 'local-media.plex.disconnect',
  );
  final _plexLoadMoreFocus = FocusNode(
    debugLabel: 'local-media.plex.load-more',
  );
  final _searchResultFocusNodes = <FocusNode>[];
  final _jellyfinItemFocusNodes = <FocusNode>[];
  final _plexItemFocusNodes = <FocusNode>[];
  final _directionalRepeatGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );
  FocusNode? _lastContentFocus;
  int _focusRequestGeneration = 0;
  bool _hydratedFields = false;
  bool _hydratedPlexFields = false;
  bool _openingPlayer = false;

  @override
  void initState() {
    super.initState();
    _contentEntryFocus.addListener(_handleContentEntryFocus);
    FocusManager.instance.addListener(_handlePrimaryFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_handlePrimaryFocusChanged);
    _contentEntryFocus.removeListener(_handleContentEntryFocus);
    _addressController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _addressFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _plexAddressController.dispose();
    _plexTokenController.dispose();
    _plexAddressFocus.dispose();
    _plexTokenFocus.dispose();
    _searchController.dispose();
    _pageScrollController.dispose();
    _searchResultsScrollController.dispose();
    _jellyfinItemsScrollController.dispose();
    _plexItemsScrollController.dispose();
    _contentRootFocus.dispose();
    _contentEntryFocus.dispose();
    _backFocus.dispose();
    _searchFocus.dispose();
    _searchActionFocus.dispose();
    _clearSearchFocus.dispose();
    _chooseVideoFocus.dispose();
    _recentVideoFocus.dispose();
    _jellyfinConnectFocus.dispose();
    _jellyfinUpFocus.dispose();
    _jellyfinRefreshFocus.dispose();
    _jellyfinDisconnectFocus.dispose();
    _jellyfinLoadMoreFocus.dispose();
    _plexConnectFocus.dispose();
    _plexUpFocus.dispose();
    _plexRefreshFocus.dispose();
    _plexDisconnectFocus.dispose();
    _plexLoadMoreFocus.dispose();
    for (final node in _searchResultFocusNodes) {
      node.dispose();
    }
    for (final node in _jellyfinItemFocusNodes) {
      node.dispose();
    }
    for (final node in _plexItemFocusNodes) {
      node.dispose();
    }
    _directionalRepeatGate.reset();
    super.dispose();
  }

  void _syncFocusNodes(
    List<FocusNode> nodes,
    int count,
    String debugLabel, {
    required FocusNode emptyFallback,
  }) {
    final primaryFocus = FocusManager.instance.primaryFocus;
    final primaryIndex = primaryFocus == null
        ? -1
        : nodes.indexOf(primaryFocus);
    final rememberedIndex = _lastContentFocus == null
        ? -1
        : nodes.indexOf(_lastContentFocus!);
    final displacedIndex = primaryIndex >= 0 ? primaryIndex : rememberedIndex;
    final lostListFocus = displacedIndex >= count;
    while (nodes.length < count) {
      nodes.add(FocusNode(debugLabel: '$debugLabel.${nodes.length}'));
    }
    while (nodes.length > count) {
      final removed = nodes.removeLast();
      WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
    }
    if (lostListFocus) {
      final replacement = count == 0
          ? emptyFallback
          : nodes[displacedIndex.clamp(0, count - 1)];
      _lastContentFocus = replacement;
      _scheduleLostFocusRecovery(replacement, towardEnd: false);
    }
  }

  void _scheduleLostFocusRecovery(FocusNode target, {required bool towardEnd}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = FocusManager.instance.primaryFocus;
      final currentContext = current?.context;
      final hasUsableFocus =
          current != null &&
          current is! FocusScopeNode &&
          currentContext != null &&
          currentContext.mounted &&
          current != _contentEntryFocus &&
          current != _contentRootFocus;
      // Do not steal focus if the viewer moved to the navigation rail, a
      // dialog, or another still-mounted control while the request ran.
      if (hasUsableFocus) return;
      _focusAndReveal(target, towardEnd: towardEnd);
    });
  }

  void _handlePrimaryFocusChanged() {
    if (!mounted) return;
    final current = FocusManager.instance.primaryFocus;
    if (current == null ||
        identical(current, _contentEntryFocus) ||
        identical(current, _contentRootFocus) ||
        identical(current, _backFocus) ||
        !current.ancestors.contains(_contentRootFocus)) {
      return;
    }
    _lastContentFocus = current;
  }

  void _handleContentEntryFocus() {
    if (!_contentEntryFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_contentEntryFocus.hasFocus) return;
      _restoreContentFocus();
    });
  }

  void _restoreContentFocus() {
    final target = _lastContentFocus;
    if (target != null) {
      _focusAndReveal(target, towardEnd: true);
    } else {
      _focusAndReveal(
        widget.managementOnly ? _chooseVideoFocus : _searchFocus,
        towardEnd: false,
      );
    }
  }

  _NestedFocusTarget? _nestedTargetFor(FocusNode node) {
    var index = _searchResultFocusNodes.indexOf(node);
    if (index >= 0) {
      return _NestedFocusTarget(
        controller: _searchResultsScrollController,
        index: index,
      );
    }
    index = _jellyfinItemFocusNodes.indexOf(node);
    if (index >= 0) {
      return _NestedFocusTarget(
        controller: _jellyfinItemsScrollController,
        index: index,
      );
    }
    index = _plexItemFocusNodes.indexOf(node);
    if (index >= 0) {
      return _NestedFocusTarget(
        controller: _plexItemsScrollController,
        index: index,
      );
    }
    return null;
  }

  void _focusAndReveal(FocusNode node, {required bool towardEnd}) {
    final generation = ++_focusRequestGeneration;
    unawaited(
      _materializeFocusTarget(
        node,
        generation: generation,
        towardEnd: towardEnd,
      ),
    );
  }

  Future<void> _materializeFocusTarget(
    FocusNode node, {
    required int generation,
    required bool towardEnd,
  }) async {
    for (var attempt = 0; attempt < 14; attempt++) {
      if (!mounted || generation != _focusRequestGeneration) return;
      final targetContext = node.context;
      if (targetContext != null && targetContext.mounted) {
        node.requestFocus();
        await Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          alignmentPolicy: towardEnd
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return;
      }

      final nested = _nestedTargetFor(node);
      if (nested != null && nested.controller.hasClients) {
        final position = nested.controller.position;
        final targetOffset = (nested.index * _mediaRowExtent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((targetOffset - position.pixels).abs() > .5) {
          position.jumpTo(targetOffset);
        }
      } else if (_pageScrollController.hasClients) {
        final position = _pageScrollController.position;
        final step = position.viewportDimension * .72;
        final targetOffset = (position.pixels + (towardEnd ? step : -step))
            .clamp(position.minScrollExtent, position.maxScrollExtent);
        if ((targetOffset - position.pixels).abs() > .5) {
          position.jumpTo(targetOffset);
        }
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    final fallbackFocus = widget.managementOnly
        ? _chooseVideoFocus
        : _searchFocus;
    final fallbackContext = fallbackFocus.context;
    if (mounted &&
        generation == _focusRequestGeneration &&
        node != fallbackFocus &&
        fallbackContext != null &&
        fallbackContext.mounted) {
      fallbackFocus.requestFocus();
      await Scrollable.ensureVisible(
        fallbackContext,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
  }

  List<List<FocusNode>> _focusRows(
    LocalMediaState state,
    PlexState plexState,
    UnifiedMediaSearchState searchState,
  ) {
    final rows = <List<FocusNode>>[
      if (!widget.managementOnly) ...[
        [
          _searchFocus,
          _searchActionFocus,
          if (searchState.query.isNotEmpty) _clearSearchFocus,
        ],
        for (final node in _searchResultFocusNodes.take(
          searchState.results.length,
        ))
          [node],
      ],
      [
        _chooseVideoFocus,
        if (!widget.managementOnly && state.recentLocalDocument != null)
          _recentVideoFocus,
      ],
    ];

    if (state.connection == null) {
      rows.addAll([
        [_addressFocus],
        [_usernameFocus],
        [_passwordFocus],
        [_jellyfinConnectFocus],
      ]);
    } else {
      rows.add([
        if (!widget.managementOnly && state.breadcrumbs.isNotEmpty)
          _jellyfinUpFocus,
        _jellyfinRefreshFocus,
        _jellyfinDisconnectFocus,
      ]);
      if (!widget.managementOnly) {
        rows.addAll(
          _jellyfinItemFocusNodes
              .take(state.items.length)
              .map((node) => [node]),
        );
        if (state.nextStartIndex < state.totalCount) {
          rows.add([_jellyfinLoadMoreFocus]);
        }
      }
    }

    if (plexState.connection == null) {
      rows.addAll([
        [_plexAddressFocus],
        [_plexTokenFocus],
        [_plexConnectFocus],
      ]);
    } else {
      final browsingItems = plexState.locations.isNotEmpty;
      rows.add([
        if (!widget.managementOnly && browsingItems) _plexUpFocus,
        _plexRefreshFocus,
        _plexDisconnectFocus,
      ]);
      final rowCount = browsingItems
          ? plexState.items.length
          : plexState.libraries.length;
      if (!widget.managementOnly) {
        rows.addAll(_plexItemFocusNodes.take(rowCount).map((node) => [node]));
        if (browsingItems && plexState.nextOffset < plexState.totalCount) {
          rows.add([_plexLoadMoreFocus]);
        }
      }
    }
    return rows;
  }

  ({int row, int column})? _focusPosition(
    FocusNode node,
    List<List<FocusNode>> rows,
  ) {
    for (var row = 0; row < rows.length; row++) {
      final column = rows[row].indexOf(node);
      if (column >= 0) return (row: row, column: column);
    }
    return null;
  }

  void _hydrateFields(LocalMediaState state) {
    if (_hydratedFields || !state.loaded) return;
    _hydratedFields = true;
    final connection = state.connection;
    if (connection == null) return;
    _addressController.text = connection.baseUri.toString();
    _usernameController.text = connection.username;
  }

  void _hydratePlexFields(PlexState state) {
    if (_hydratedPlexFields || !state.loaded) return;
    _hydratedPlexFields = true;
    final connection = state.connection;
    if (connection != null) {
      _plexAddressController.text = connection.baseUri.toString();
    }
  }

  Future<void> _pickAndPlay() async {
    final controller = ref.read(localMediaControllerProvider.notifier);
    final document = await controller.pickLocalVideo();
    if (document != null && mounted) await _playDocument(document);
  }

  Future<void> _addLocalVideo() async {
    final document = await ref
        .read(localMediaControllerProvider.notifier)
        .pickLocalVideo();
    if (document == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${document.name} was added as an episode-source candidate.',
        ),
      ),
    );
  }

  Future<void> _playDocument(LocalMediaDocument document) => _openPlayer(
    source: document.uri,
    title: document.name,
    releaseName: document.name,
    streamLabel: 'Local device media',
    sourceProviderId: 'library-device',
    sourceProviderName: 'Local device',
    headers: const {},
    mediaContentType: document.mimeType,
  );

  Future<void> _playJellyfin(JellyfinMediaItem item) async {
    final controller = ref.read(localMediaControllerProvider.notifier);
    final playSessionId = controller.createPlaybackSessionId();
    final requestedAudio = ref.read(settingsPreferencesProvider).preferredAudio;
    final plan = controller.playbackPlan(
      item,
      playSessionId: playSessionId,
      requestedAudio: requestedAudio,
    );
    await _openPlayer(
      source: plan.uri,
      title: item.displayTitle,
      releaseName: item.seriesName?.isNotEmpty == true
          ? '${item.seriesName} — ${item.displayTitle}'
          : item.displayTitle,
      streamLabel:
          'Jellyfin • ${item.secondaryLabel}'
          '${plan.isTranscode ? ' • compatibility stream' : ''}',
      sourceProviderId: 'library-jellyfin',
      sourceProviderName: 'Jellyfin',
      headers: plan.headers,
      mediaContentType: plan.mediaContentType,
      externalSubtitle: plan.externalSubtitleUri?.toString(),
      externalSubtitleTracks: plan.externalSubtitleTracks
          .map(
            (track) => LibraryExternalSubtitleTrack(
              uri: track.uri,
              label: track.label,
              language: track.language,
              contentType: track.contentType,
            ),
          )
          .toList(growable: false),
      subtitleContentType: plan.subtitleContentType,
      artworkUrl: controller.imageUri(item)?.toString(),
      serverResumePosition: controller.serverResumePosition(item),
      onStarted: (position) => controller.reportPlaybackStarted(
        item,
        playSessionId: playSessionId,
        position: position,
        playMethod: plan.method,
      ),
      onProgress: (position, paused) => controller.reportPlaybackProgress(
        item,
        playSessionId: playSessionId,
        position: position,
        paused: paused,
        playMethod: plan.method,
      ),
      onStopped: (position) => controller.reportPlaybackStopped(
        item,
        playSessionId: playSessionId,
        position: position,
        playMethod: plan.method,
      ),
    );
  }

  Future<void> _playPlex(PlexMediaItem item) async {
    final controller = ref.read(plexControllerProvider.notifier);
    try {
      final playable = await controller.preparePlayableItem(item);
      final source = controller.playbackUri(playable);
      final series = playable.grandparentTitle?.trim();
      await _openPlayer(
        source: source,
        title: playable.displayTitle,
        releaseName: series?.isNotEmpty == true
            ? '$series — ${playable.displayTitle}'
            : playable.displayTitle,
        streamLabel: 'Plex • ${playable.secondaryLabel}',
        sourceProviderId: 'library-plex',
        sourceProviderName: 'Plex',
        headers: controller.playbackHeaders(),
        artworkUrl: controller.imageUri(playable)?.toString(),
        serverResumePosition: controller.serverResumePosition(playable),
        onStarted: (position) => controller.reportTimeline(
          playable,
          position: position,
          playing: true,
        ),
        onProgress: (position, paused) => controller.reportTimeline(
          playable,
          position: position,
          playing: !paused,
        ),
        onStopped: (position) => controller.reportTimeline(
          playable,
          position: position,
          playing: false,
        ),
      );
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }

  Future<void> _openPlayer({
    required Uri source,
    required String title,
    required String releaseName,
    required String streamLabel,
    required String sourceProviderId,
    required String sourceProviderName,
    required Map<String, String> headers,
    String? artworkUrl,
    String? mediaContentType,
    String? externalSubtitle,
    List<LibraryExternalSubtitleTrack> externalSubtitleTracks = const [],
    String? subtitleContentType,
    Duration serverResumePosition = Duration.zero,
    Future<void> Function(Duration position)? onStarted,
    Future<void> Function(Duration position, bool paused)? onProgress,
    Future<void> Function(Duration position)? onStopped,
  }) async {
    if (_openingPlayer) return;
    setState(() => _openingPlayer = true);
    final controller = ref.read(localMediaControllerProvider.notifier);
    try {
      var resume = await controller.resumePosition(source);
      if (serverResumePosition > resume) resume = serverResumePosition;
      final checkpointId = controller.checkpointId(source);
      final writeback = _LibraryPlaybackWriteback(
        saveLocal: (position) =>
            controller.saveResumePosition(source, position),
        writeServer: onProgress,
      );
      final request = LibraryPlaybackRequest(
        source: source,
        title: title,
        releaseName: releaseName,
        streamLabel: streamLabel,
        sourceProviderId: sourceProviderId,
        sourceProviderName: sourceProviderName,
        checkpointKey: 'local:$checkpointId',
        timelineIdentity: checkpointId,
        headers: headers,
        artworkUrl: artworkUrl,
        externalSubtitle: externalSubtitle,
        externalSubtitleTracks: externalSubtitleTracks,
        mediaContentType: mediaContentType,
        subtitleContentType: subtitleContentType,
        initialPosition: resume,
        requestedAudio: ref.read(settingsPreferencesProvider).preferredAudio,
        onStarted: onStarted,
        onProgress: writeback.handle,
        onFinished: (result) async {
          if (result.completed) {
            await controller.clearResumePosition(source);
          } else {
            await controller.saveResumePosition(source, result.position);
          }
          if (result.started && onStopped != null) {
            await onStopped(result.position);
          }
          if (result.failed && mounted) {
            _showMessage(
              'This library video could not be played by the selected engine.',
            );
          }
        },
      );
      if (!mounted) return;
      final openLibraryPlayer = widget.openLibraryPlayer;
      if (openLibraryPlayer != null) {
        await openLibraryPlayer(request);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'library-player'),
            builder: (_) => LibraryTvPlayerScreen(request: request),
          ),
        );
      }
    } catch (_) {
      if (mounted) _showMessage('This library video could not be opened.');
    } finally {
      if (mounted) setState(() => _openingPlayer = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _searchAllMedia() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await ref
        .read(unifiedMediaSearchControllerProvider.notifier)
        .search(_searchController.text);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final searchState = ref.read(unifiedMediaSearchControllerProvider);
      final target =
          searchState.results.isNotEmpty && _searchResultFocusNodes.isNotEmpty
          ? _searchResultFocusNodes.first
          : _searchActionFocus;
      _scheduleLostFocusRecovery(target, towardEnd: false);
    });
  }

  Future<void> _activateSearchResult(UnifiedMediaSearchItem result) async {
    final document = result.document;
    if (document != null) {
      await _playDocument(document);
      return;
    }
    final jellyfin = result.jellyfinItem;
    if (jellyfin != null) {
      if (jellyfin.isFolder) {
        await ref
            .read(localMediaControllerProvider.notifier)
            .openFolder(jellyfin);
      } else {
        await _playJellyfin(jellyfin);
      }
      return;
    }
    final plex = result.plexItem;
    if (plex == null) return;
    if (plex.isFolder) {
      await ref.read(plexControllerProvider.notifier).openFolder(plex);
    } else {
      await _playPlex(plex);
    }
  }

  void _focusNavigationOrBack(TetoTopLevelLayout layout) {
    // Once focus leaves this screen, its key-up packet is delivered to the
    // rail/back target instead. Do not let a stale held key throttle the next
    // content move when the viewer returns.
    _directionalRepeatGate.reset();
    if (layout.usesPersistentNavigation) {
      layout.focusRail();
    } else if (_backFocus.context != null) {
      _backFocus.requestFocus();
    }
  }

  KeyEventResult _handleNavigation(
    KeyEvent event,
    TetoTopLevelLayout layout,
    LocalMediaState state,
    PlexState plexState,
    UnifiedMediaSearchState searchState,
  ) {
    final key = event.logicalKey;
    final isHorizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    final isVertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!isHorizontal && !isVertical) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      _directionalRepeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_directionalRepeatGate.accept(event)) {
      return KeyEventResult.handled;
    }

    final current = FocusManager.instance.primaryFocus;
    if (current == null || current == _contentEntryFocus) {
      return KeyEventResult.handled;
    }
    if (current == _backFocus) {
      if (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.arrowDown) {
        _restoreContentFocus();
      }
      return KeyEventResult.handled;
    }

    final rows = _focusRows(state, plexState, searchState);
    final position = _focusPosition(current, rows);
    if (position == null) return KeyEventResult.handled;

    if (isHorizontal) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (position.column == 0) {
          _focusNavigationOrBack(layout);
        } else {
          _focusAndReveal(
            rows[position.row][position.column - 1],
            towardEnd: false,
          );
        }
      } else if (position.column + 1 < rows[position.row].length) {
        _focusAndReveal(
          rows[position.row][position.column + 1],
          towardEnd: true,
        );
      }
      return KeyEventResult.handled;
    }

    final movingDown = key == LogicalKeyboardKey.arrowDown;
    final targetRow = position.row + (movingDown ? 1 : -1);
    if (targetRow < 0) {
      if (!layout.usesPersistentNavigation && _backFocus.context != null) {
        _focusAndReveal(_backFocus, towardEnd: false);
      }
      return KeyEventResult.handled;
    }
    if (targetRow >= rows.length) return KeyEventResult.handled;
    final targetColumn = position.column.clamp(0, rows[targetRow].length - 1);
    _focusAndReveal(rows[targetRow][targetColumn], towardEnd: movingDown);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localMediaControllerProvider);
    final plexState = ref.watch(plexControllerProvider);
    final searchState = ref.watch(unifiedMediaSearchControllerProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    _hydrateFields(state);
    _hydratePlexFields(plexState);
    _syncFocusNodes(
      _searchResultFocusNodes,
      widget.managementOnly ? 0 : searchState.results.length,
      'local-media.search-result',
      emptyFallback: _searchActionFocus,
    );
    _syncFocusNodes(
      _jellyfinItemFocusNodes,
      state.connection == null || widget.managementOnly
          ? 0
          : state.items.length,
      'local-media.jellyfin.item',
      emptyFallback: state.connection == null
          ? _jellyfinConnectFocus
          : _jellyfinRefreshFocus,
    );
    final plexRowCount = plexState.connection == null || widget.managementOnly
        ? 0
        : plexState.locations.isNotEmpty
        ? plexState.items.length
        : plexState.libraries.length;
    _syncFocusNodes(
      _plexItemFocusNodes,
      plexRowCount,
      'local-media.plex.item',
      emptyFallback: plexState.connection == null
          ? _plexConnectFocus
          : _plexRefreshFocus,
    );
    ref.listen(localMediaControllerProvider, (previous, next) {
      if (next.message != null && next.message != previous?.message) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showMessage(next.message!);
        });
      }
    });
    ref.listen(plexControllerProvider, (previous, next) {
      if (next.message != null && next.message != previous?.message) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showMessage(next.message!);
        });
      }
    });
    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: widget.activeDestination,
      firstContentFocusNode: _contentEntryFocus,
      fallbackContentFocusNode: widget.managementOnly
          ? _chooseVideoFocus
          : _searchFocus,
      onActiveDestinationPressed: _restoreContentFocus,
      resizeToAvoidBottomInset: true,
      builder: (context, layout) => Focus(
        focusNode: _contentRootFocus,
        canRequestFocus: false,
        onKeyEvent: (_, event) =>
            _handleNavigation(event, layout, state, plexState, searchState),
        child: Padding(
          padding: layout.usesSideNavigation
              ? EdgeInsets.zero
              : context.responsiveScreenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Focus(
                focusNode: _contentEntryFocus,
                skipTraversal: true,
                child: const SizedBox.shrink(),
              ),
              Row(
                children: [
                  if (!layout.usesSideNavigation) ...[
                    _ActionButton(
                      label: 'Back',
                      icon: Icons.arrow_back_rounded,
                      focusNode: _backFocus,
                      onPressed: context.pop,
                    ),
                    const SizedBox(width: 16),
                  ],
                  Expanded(
                    child: Text(
                      widget.managementOnly ? 'Media sources' : 'Your media',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontSize: layout.usesTvRail ? 30 : null,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  if (state.busy ||
                      plexState.busy ||
                      (!widget.managementOnly && searchState.busy) ||
                      _openingPlayer)
                    SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: context.appPalette.accentBright,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  key: const ValueKey('local-media-page-scroll'),
                  controller: _pageScrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
                  ),
                  children: [
                    if (!widget.managementOnly) ...[
                      _buildUnifiedSearch(searchState, layout),
                      const SizedBox(height: 16),
                    ],
                    _SectionCard(
                      title: 'LOCAL FILES',
                      subtitle: widget.managementOnly
                          ? 'Add videos with Android’s secure file picker. Matching episodes appear in the normal source picker.'
                          : 'Choose a video with Android’s secure file picker. Android does not let apps silently scan your device.',
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _ActionButton(
                            label: widget.managementOnly
                                ? 'Add local video'
                                : 'Choose video',
                            icon: Icons.video_file_rounded,
                            focusNode: _chooseVideoFocus,
                            autofocus: widget.managementOnly,
                            onPressed: state.busy
                                ? null
                                : widget.managementOnly
                                ? _addLocalVideo
                                : _pickAndPlay,
                          ),
                          if (!widget.managementOnly)
                            if (state.recentLocalDocument case final recent?)
                              _ActionButton(
                                label: 'Play ${recent.name}',
                                icon: Icons.replay_rounded,
                                focusNode: _recentVideoFocus,
                                onPressed: _openingPlayer
                                    ? null
                                    : () => _playDocument(recent),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: 'JELLYFIN SERVER',
                      subtitle: state.connection == null
                          ? 'Connect to a Jellyfin server on your home network or an HTTPS server. Your password is used once and is never saved. HTTPS is recommended.'
                          : '${state.connection!.serverName} • ${state.connection!.username} • Jellyfin ${state.connection!.serverVersion}',
                      child: state.connection == null
                          ? _buildConnectionForm(state, layout)
                          : widget.managementOnly
                          ? _buildJellyfinManagement(state, layout)
                          : _buildLibrary(state, layout),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: 'PLEX MEDIA SERVER',
                      subtitle: plexState.connection == null
                          ? 'Connect with a Plex server address and X-Plex-Token. The token is stored in Android secure storage and is never placed in a media or artwork URL.'
                          : '${plexState.connection!.serverName ?? 'Plex Media Server'} • Plex ${plexState.connection!.serverVersion ?? 'unknown'}',
                      child: plexState.connection == null
                          ? _buildPlexConnectionForm(plexState, layout)
                          : widget.managementOnly
                          ? _buildPlexManagement(plexState, layout)
                          : _buildPlexLibrary(plexState, layout),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnifiedSearch(
    UnifiedMediaSearchState searchState,
    TetoTopLevelLayout layout,
  ) => _SectionCard(
    title: 'SEARCH YOUR MEDIA',
    subtitle:
        'Search connected Jellyfin and Plex libraries together. Your recently selected device video is included when its name matches.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final input = TvTextInput(
              controller: _searchController,
              focusNode: _searchFocus,
              autofocus: true,
              labelText: 'Title or keyword',
              keyboardTitle: 'Search your media libraries',
              onSubmitted: (_) => _searchAllMedia(),
            );
            final actions = Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _ActionButton(
                  label: 'Search',
                  icon: Icons.search_rounded,
                  focusNode: _searchActionFocus,
                  onPressed: searchState.busy ? null : _searchAllMedia,
                ),
                if (searchState.query.isNotEmpty)
                  _ActionButton(
                    label: 'Clear',
                    icon: Icons.close_rounded,
                    focusNode: _clearSearchFocus,
                    onPressed: searchState.busy
                        ? null
                        : () {
                            _searchController.clear();
                            ref
                                .read(
                                  unifiedMediaSearchControllerProvider.notifier,
                                )
                                .clear();
                            _searchFocus.requestFocus();
                          },
                  ),
              ],
            );
            if (constraints.maxWidth < 720) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [input, const SizedBox(height: 12), actions],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: input),
                const SizedBox(width: 12),
                actions,
              ],
            );
          },
        ),
        if (searchState.message case final message?) ...[
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
        ],
        if (searchState.results.isNotEmpty) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: (searchState.results.length * 92.0).clamp(92.0, 460.0),
            child: ListView.separated(
              key: const ValueKey('unified-media-results'),
              controller: _searchResultsScrollController,
              itemCount: searchState.results.length,
              itemBuilder: (context, index) {
                final result = searchState.results[index];
                return _UnifiedMediaRow(
                  key: ValueKey('unified-media-${result.origin.name}-$index'),
                  focusNode: _searchResultFocusNodes[index],
                  result: result,
                  jellyfinImageUri: result.jellyfinItem == null
                      ? null
                      : ref
                            .read(localMediaControllerProvider.notifier)
                            .imageUri(result.jellyfinItem!),
                  jellyfinImageLoader: ref
                      .read(localMediaControllerProvider.notifier)
                      .imageBytes,
                  plexImageUri: result.plexItem == null
                      ? null
                      : ref
                            .read(plexControllerProvider.notifier)
                            .imageUri(result.plexItem!),
                  plexImageLoader: ref
                      .read(plexControllerProvider.notifier)
                      .imageBytes,
                  onExitLeft: () => _focusNavigationOrBack(layout),
                  onPressed: _openingPlayer
                      ? null
                      : () => _activateSearchResult(result),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(height: 10),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _buildConnectionForm(
    LocalMediaState state,
    TetoTopLevelLayout layout,
  ) => Column(
    children: [
      TvTextInput(
        controller: _addressController,
        focusNode: _addressFocus,
        labelText: 'Server address',
        hintText: '192.168.1.20:8096 or https://jellyfin.example.com',
        keyboardTitle: 'Jellyfin server address',
      ),
      const SizedBox(height: 12),
      TvTextInput(
        controller: _usernameController,
        focusNode: _usernameFocus,
        labelText: 'Username',
        keyboardTitle: 'Jellyfin username',
      ),
      const SizedBox(height: 12),
      TvTextInput(
        controller: _passwordController,
        focusNode: _passwordFocus,
        labelText: 'Password',
        keyboardTitle: 'Jellyfin password',
        obscureText: true,
        onSubmitted: (_) => _connectJellyfin(),
      ),
      const SizedBox(height: 14),
      Align(
        alignment: Alignment.centerLeft,
        child: _ActionButton(
          label: 'Connect Jellyfin',
          icon: Icons.lan_rounded,
          focusNode: _jellyfinConnectFocus,
          onExitLeft: () => _focusNavigationOrBack(layout),
          onPressed: state.busy ? null : _connectJellyfin,
        ),
      ),
    ],
  );

  Future<void> _connectJellyfin() async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final address = normalizeJellyfinServerUri(_addressController.text);
      if (address?.scheme == 'http') {
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Use an unencrypted local connection?'),
            content: const Text(
              'HTTP is limited to a numeric private-network address, but your '
              'Jellyfin password and video traffic are not encrypted. Use HTTPS '
              'when your server supports it.',
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Connect on private network'),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
      }
      await ref
          .read(localMediaControllerProvider.notifier)
          .connect(
            address: _addressController.text,
            username: _usernameController.text,
            password: _passwordController.text,
          );
      if (!mounted) return;
      _passwordController.clear();
    } finally {
      if (mounted) {
        final connected =
            ref.read(localMediaControllerProvider).connection != null;
        _scheduleLostFocusRecovery(
          connected ? _jellyfinRefreshFocus : _jellyfinConnectFocus,
          towardEnd: false,
        );
      }
    }
  }

  Widget _buildLibrary(LocalMediaState state, TetoTopLevelLayout layout) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (state.breadcrumbs.isNotEmpty)
                _ActionButton(
                  label: 'Up',
                  icon: Icons.arrow_upward_rounded,
                  focusNode: _jellyfinUpFocus,
                  onExitLeft: () => _focusNavigationOrBack(layout),
                  onPressed: state.busy
                      ? null
                      : ref.read(localMediaControllerProvider.notifier).goUp,
                ),
              _ActionButton(
                label: 'Refresh',
                icon: Icons.refresh_rounded,
                focusNode: _jellyfinRefreshFocus,
                onExitLeft: state.breadcrumbs.isEmpty
                    ? () => _focusNavigationOrBack(layout)
                    : null,
                onPressed: state.busy
                    ? null
                    : ref.read(localMediaControllerProvider.notifier).refresh,
              ),
              _ActionButton(
                label: 'Disconnect',
                icon: Icons.link_off_rounded,
                focusNode: _jellyfinDisconnectFocus,
                onPressed: state.busy
                    ? null
                    : ref
                          .read(localMediaControllerProvider.notifier)
                          .disconnect,
              ),
            ],
          ),
          if (state.breadcrumbs.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              state.breadcrumbs.map((crumb) => crumb.name).join('  /  '),
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 14),
          if (state.items.isNotEmpty)
            SizedBox(
              height: (state.items.length * 92.0).clamp(92.0, 520.0),
              child: ListView.separated(
                key: const ValueKey('jellyfin-library-list'),
                controller: _jellyfinItemsScrollController,
                itemCount: state.items.length,
                itemBuilder: (context, index) {
                  final item = state.items[index];
                  return _MediaRow(
                    key: ValueKey('jellyfin-item-${item.id}'),
                    focusNode: _jellyfinItemFocusNodes[index],
                    item: item,
                    imageUri: ref
                        .read(localMediaControllerProvider.notifier)
                        .imageUri(item),
                    imageLoader: ref
                        .read(localMediaControllerProvider.notifier)
                        .imageBytes,
                    onExitLeft: () => _focusNavigationOrBack(layout),
                    onPressed: state.busy || _openingPlayer
                        ? null
                        : item.isFolder
                        ? () => ref
                              .read(localMediaControllerProvider.notifier)
                              .openFolder(item)
                        : () => _playJellyfin(item),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(height: 10),
              ),
            ),
          if (state.nextStartIndex < state.totalCount)
            _ActionButton(
              label: 'Load more (${state.items.length} of ${state.totalCount})',
              icon: Icons.expand_more_rounded,
              focusNode: _jellyfinLoadMoreFocus,
              onExitLeft: () => _focusNavigationOrBack(layout),
              onPressed: state.busy
                  ? null
                  : ref.read(localMediaControllerProvider.notifier).loadMore,
            ),
        ],
      );

  Widget _buildJellyfinManagement(
    LocalMediaState state,
    TetoTopLevelLayout layout,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${state.totalCount} library items are available to episode matching.',
        style: TextStyle(color: context.appPalette.mutedText, fontSize: 12),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _ActionButton(
            label: 'Test & refresh',
            icon: Icons.refresh_rounded,
            focusNode: _jellyfinRefreshFocus,
            onExitLeft: () => _focusNavigationOrBack(layout),
            onPressed: state.busy
                ? null
                : ref.read(localMediaControllerProvider.notifier).refresh,
          ),
          _ActionButton(
            label: 'Disconnect',
            icon: Icons.link_off_rounded,
            focusNode: _jellyfinDisconnectFocus,
            onPressed: state.busy
                ? null
                : ref.read(localMediaControllerProvider.notifier).disconnect,
          ),
        ],
      ),
    ],
  );

  Widget _buildPlexConnectionForm(PlexState state, TetoTopLevelLayout layout) =>
      Column(
        children: [
          TvTextInput(
            controller: _plexAddressController,
            focusNode: _plexAddressFocus,
            labelText: 'Server address',
            hintText: '192.168.1.20:32400 or https://plex.example.com',
            keyboardTitle: 'Plex server address',
          ),
          const SizedBox(height: 12),
          TvTextInput(
            controller: _plexTokenController,
            focusNode: _plexTokenFocus,
            labelText: 'X-Plex-Token',
            keyboardTitle: 'Plex access token',
            obscureText: true,
            onSubmitted: (_) => _connectPlex(),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: _ActionButton(
              label: 'Connect Plex',
              icon: Icons.connected_tv_rounded,
              focusNode: _plexConnectFocus,
              onExitLeft: () => _focusNavigationOrBack(layout),
              onPressed: state.busy ? null : _connectPlex,
            ),
          ),
        ],
      );

  Future<void> _connectPlex() async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final address = normalizePlexServerUri(_plexAddressController.text);
      if (address?.scheme == 'http') {
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Use an unencrypted local connection?'),
            content: const Text(
              'HTTP is limited to a numeric private-network address, but your '
              'Plex access token and video traffic are not encrypted. Use HTTPS '
              'when your server supports it.',
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Connect on private network'),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
      }
      await ref
          .read(plexControllerProvider.notifier)
          .connect(
            address: _plexAddressController.text,
            token: _plexTokenController.text,
          );
      if (mounted) _plexTokenController.clear();
    } finally {
      if (mounted) {
        final connected = ref.read(plexControllerProvider).connection != null;
        _scheduleLostFocusRecovery(
          connected ? _plexRefreshFocus : _plexConnectFocus,
          towardEnd: false,
        );
      }
    }
  }

  Widget _buildPlexLibrary(PlexState state, TetoTopLevelLayout layout) {
    final controller = ref.read(plexControllerProvider.notifier);
    final browsingItems = state.locations.isNotEmpty;
    final rowCount = browsingItems
        ? state.items.length
        : state.libraries.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (browsingItems)
              _ActionButton(
                label: 'Up',
                icon: Icons.arrow_upward_rounded,
                focusNode: _plexUpFocus,
                onExitLeft: () => _focusNavigationOrBack(layout),
                onPressed: state.busy ? null : controller.goUp,
              ),
            _ActionButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              focusNode: _plexRefreshFocus,
              onExitLeft: browsingItems
                  ? null
                  : () => _focusNavigationOrBack(layout),
              onPressed: state.busy ? null : controller.refresh,
            ),
            _ActionButton(
              label: 'Disconnect',
              icon: Icons.link_off_rounded,
              focusNode: _plexDisconnectFocus,
              onPressed: state.busy ? null : controller.disconnect,
            ),
          ],
        ),
        if (browsingItems) ...[
          const SizedBox(height: 14),
          Text(
            state.locations.map((location) => location.label).join('  /  '),
            style: Theme.of(context).textTheme.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (rowCount > 0) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: (rowCount * 92.0).clamp(92.0, 520.0),
            child: ListView.separated(
              key: const ValueKey('plex-library-list'),
              controller: _plexItemsScrollController,
              itemCount: rowCount,
              itemBuilder: (context, index) {
                if (!browsingItems) {
                  final library = state.libraries[index];
                  return _PlexBrowseRow(
                    key: ValueKey('plex-library-${library.key}'),
                    focusNode: _plexItemFocusNodes[index],
                    title: library.title,
                    subtitle: library.isMovieLibrary ? 'Movies' : 'TV shows',
                    isFolder: true,
                    imageUri: controller.libraryImageUri(library),
                    imageLoader: controller.imageBytes,
                    progress: null,
                    onExitLeft: () => _focusNavigationOrBack(layout),
                    onPressed: state.busy
                        ? null
                        : () => controller.openLibrary(library),
                  );
                }
                final item = state.items[index];
                return _PlexBrowseRow(
                  key: ValueKey('plex-item-${item.ratingKey}'),
                  focusNode: _plexItemFocusNodes[index],
                  title: item.displayTitle,
                  subtitle: item.secondaryLabel,
                  isFolder: item.isFolder,
                  imageUri: controller.imageUri(item),
                  imageLoader: controller.imageBytes,
                  progress: _plexProgress(item),
                  onExitLeft: () => _focusNavigationOrBack(layout),
                  onPressed: state.busy || _openingPlayer
                      ? null
                      : item.isFolder
                      ? () => controller.openFolder(item)
                      : item.isPlayable
                      ? () => _playPlex(item)
                      : null,
                );
              },
              separatorBuilder: (_, _) => const SizedBox(height: 10),
            ),
          ),
        ],
        if (browsingItems && state.nextOffset < state.totalCount) ...[
          const SizedBox(height: 12),
          _ActionButton(
            label: 'Load more (${state.items.length} of ${state.totalCount})',
            icon: Icons.expand_more_rounded,
            focusNode: _plexLoadMoreFocus,
            onExitLeft: () => _focusNavigationOrBack(layout),
            onPressed: state.busy ? null : controller.loadMore,
          ),
        ],
      ],
    );
  }

  Widget _buildPlexManagement(PlexState state, TetoTopLevelLayout layout) {
    final controller = ref.read(plexControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${state.totalCount} library items are available to episode matching.',
          style: TextStyle(color: context.appPalette.mutedText, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _ActionButton(
              label: 'Test & refresh',
              icon: Icons.refresh_rounded,
              focusNode: _plexRefreshFocus,
              onExitLeft: () => _focusNavigationOrBack(layout),
              onPressed: state.busy ? null : controller.refresh,
            ),
            _ActionButton(
              label: 'Disconnect',
              icon: Icons.link_off_rounded,
              focusNode: _plexDisconnectFocus,
              onPressed: state.busy ? null : controller.disconnect,
            ),
          ],
        ),
      ],
    );
  }
}

class _NestedFocusTarget {
  const _NestedFocusTarget({required this.controller, required this.index});

  final ScrollController controller;
  final int index;
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.appPalette.surface.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: context.appPalette.accent.withValues(alpha: .26),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: context.appPalette.accentBright,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

double? _jellyfinProgress(JellyfinMediaItem item) =>
    _normalizedProgress(position: item.resumePosition, duration: item.duration);

double? _plexProgress(PlexMediaItem item) => _normalizedProgress(
  position: Duration(milliseconds: item.viewOffsetMilliseconds ?? 0),
  duration: item.durationMilliseconds == null
      ? null
      : Duration(milliseconds: item.durationMilliseconds!),
);

double? _unifiedProgress(UnifiedMediaSearchItem result) {
  final jellyfin = result.jellyfinItem;
  if (jellyfin != null) return _jellyfinProgress(jellyfin);
  final plex = result.plexItem;
  return plex == null ? null : _plexProgress(plex);
}

class _LibraryPlaybackWriteback {
  _LibraryPlaybackWriteback({
    required this.saveLocal,
    required this.writeServer,
  });

  static const _interval = Duration(seconds: 10);

  final Future<void> Function(Duration position) saveLocal;
  final Future<void> Function(Duration position, bool paused)? writeServer;
  DateTime? _lastWrittenAt;
  bool? _lastPlaying;

  Future<void> handle(LibraryPlaybackProgress progress) async {
    final stateChanged = _lastPlaying != progress.playing;
    final elapsed = _lastWrittenAt == null
        ? null
        : progress.sampledAt.difference(_lastWrittenAt!);
    if (!stateChanged &&
        elapsed != null &&
        !elapsed.isNegative &&
        elapsed < _interval) {
      return;
    }
    _lastWrittenAt = progress.sampledAt;
    _lastPlaying = progress.playing;
    await Future.wait<void>([
      saveLocal(progress.position),
      if (writeServer case final callback?)
        callback(progress.position, !progress.playing),
    ]);
  }
}

double? _normalizedProgress({
  required Duration position,
  required Duration? duration,
}) {
  if (duration == null ||
      duration <= Duration.zero ||
      position <= Duration.zero) {
    return null;
  }
  final value = position.inMilliseconds / duration.inMilliseconds;
  if (!value.isFinite || value <= 0 || value >= .98) return null;
  return value.clamp(0, 1);
}

class _MediaProgressBar extends StatelessWidget {
  const _MediaProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(999),
    child: LinearProgressIndicator(
      value: value,
      minHeight: 4,
      backgroundColor: context.appPalette.surfaceRaised,
      color: context.appPalette.accentBright,
    ),
  );
}

class _UnifiedMediaRow extends StatelessWidget {
  const _UnifiedMediaRow({
    super.key,
    required this.focusNode,
    required this.result,
    required this.jellyfinImageUri,
    required this.jellyfinImageLoader,
    required this.plexImageUri,
    required this.plexImageLoader,
    required this.onExitLeft,
    required this.onPressed,
  });

  final FocusNode focusNode;
  final UnifiedMediaSearchItem result;
  final Uri? jellyfinImageUri;
  final Future<Uint8List> Function(Uri uri) jellyfinImageLoader;
  final Uri? plexImageUri;
  final Future<Uint8List> Function(Uri uri) plexImageLoader;
  final VoidCallback onExitLeft;
  final VoidCallback? onPressed;

  String get _originLabel => switch (result.origin) {
    UnifiedMediaOrigin.device => 'DEVICE',
    UnifiedMediaOrigin.jellyfin => 'JELLYFIN',
    UnifiedMediaOrigin.plex => 'PLEX',
  };

  IconData get _originIcon => switch (result.origin) {
    UnifiedMediaOrigin.device => Icons.video_file_rounded,
    UnifiedMediaOrigin.jellyfin => Icons.live_tv_rounded,
    UnifiedMediaOrigin.plex => Icons.connected_tv_rounded,
  };

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onPressed == null ? .55 : 1,
    child: TvFocusable(
      focusNode: focusNode,
      onPressed: onPressed ?? () {},
      onKeyEvent: (_, event) => _handleExitLeft(event, onExitLeft),
      child: Container(
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.appPalette.selectableSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox.square(dimension: 64, child: _artwork(context)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.appPalette.accent.withValues(
                            alpha: .18,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          child: Text(
                            _originLabel,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: context.appPalette.accentBright,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: .7,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          result.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    result.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (_unifiedProgress(result) case final progress?) ...[
                    const SizedBox(height: 6),
                    _MediaProgressBar(value: progress),
                  ],
                ],
              ),
            ),
            Icon(
              result.isFolder
                  ? Icons.chevron_right_rounded
                  : Icons.play_arrow_rounded,
              color: context.appPalette.accentBright,
              size: 30,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _artwork(BuildContext context) {
    if (result.origin == UnifiedMediaOrigin.plex) {
      return _PlexArtwork(uri: plexImageUri, loader: plexImageLoader);
    }
    if (result.origin == UnifiedMediaOrigin.jellyfin &&
        jellyfinImageUri != null) {
      return _JellyfinArtwork(
        uri: jellyfinImageUri,
        loader: jellyfinImageLoader,
      );
    }
    return ColoredBox(
      color: context.appPalette.surfaceRaised,
      child: Icon(_originIcon),
    );
  }
}

class _MediaRow extends StatelessWidget {
  const _MediaRow({
    super.key,
    required this.focusNode,
    required this.item,
    required this.imageUri,
    required this.imageLoader,
    required this.onExitLeft,
    required this.onPressed,
  });

  final FocusNode focusNode;
  final JellyfinMediaItem item;
  final Uri? imageUri;
  final Future<Uint8List> Function(Uri uri) imageLoader;
  final VoidCallback onExitLeft;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onPressed == null ? .55 : 1,
    child: TvFocusable(
      focusNode: focusNode,
      onPressed: onPressed ?? () {},
      onKeyEvent: (_, event) => _handleExitLeft(event, onExitLeft),
      child: Container(
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.appPalette.selectableSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 64,
                height: 64,
                child: _JellyfinArtwork(uri: imageUri, loader: imageLoader),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    item.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.secondaryLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (_jellyfinProgress(item) case final progress?) ...[
                    const SizedBox(height: 6),
                    _MediaProgressBar(value: progress),
                  ],
                ],
              ),
            ),
            Icon(
              item.isFolder
                  ? Icons.chevron_right_rounded
                  : Icons.play_arrow_rounded,
              color: context.appPalette.accentBright,
              size: 30,
            ),
          ],
        ),
      ),
    ),
  );
}

class _PlexBrowseRow extends StatelessWidget {
  const _PlexBrowseRow({
    super.key,
    required this.focusNode,
    required this.title,
    required this.subtitle,
    required this.isFolder,
    required this.imageUri,
    required this.imageLoader,
    required this.progress,
    required this.onExitLeft,
    required this.onPressed,
  });

  final FocusNode focusNode;
  final String title;
  final String subtitle;
  final bool isFolder;
  final Uri? imageUri;
  final Future<Uint8List> Function(Uri uri) imageLoader;
  final double? progress;
  final VoidCallback onExitLeft;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onPressed == null ? .55 : 1,
    child: TvFocusable(
      focusNode: focusNode,
      onPressed: onPressed ?? () {},
      onKeyEvent: (_, event) => _handleExitLeft(event, onExitLeft),
      child: Container(
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.appPalette.selectableSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 64,
                height: 64,
                child: _PlexArtwork(uri: imageUri, loader: imageLoader),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (progress case final value?) ...[
                    const SizedBox(height: 6),
                    _MediaProgressBar(value: value),
                  ],
                ],
              ),
            ),
            Icon(
              isFolder ? Icons.chevron_right_rounded : Icons.play_arrow_rounded,
              color: context.appPalette.accentBright,
              size: 30,
            ),
          ],
        ),
      ),
    ),
  );
}

class _JellyfinArtwork extends StatefulWidget {
  const _JellyfinArtwork({required this.uri, required this.loader});

  final Uri? uri;
  final Future<Uint8List> Function(Uri uri) loader;

  @override
  State<_JellyfinArtwork> createState() => _JellyfinArtworkState();
}

class _JellyfinArtworkState extends State<_JellyfinArtwork> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _JellyfinArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) _load();
  }

  void _load() {
    final uri = widget.uri;
    _bytes = uri == null ? null : widget.loader(uri);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const _MediaArtworkPlaceholder();
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        final value = snapshot.data;
        if (value == null || value.isEmpty) {
          return const _MediaArtworkPlaceholder();
        }
        return Image.memory(
          value,
          cacheWidth: 128,
          cacheHeight: 128,
          filterQuality: FilterQuality.low,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const _MediaArtworkPlaceholder(),
        );
      },
    );
  }
}

class _PlexArtwork extends StatefulWidget {
  const _PlexArtwork({required this.uri, required this.loader});

  final Uri? uri;
  final Future<Uint8List> Function(Uri uri) loader;

  @override
  State<_PlexArtwork> createState() => _PlexArtworkState();
}

class _PlexArtworkState extends State<_PlexArtwork> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PlexArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) _load();
  }

  void _load() {
    final uri = widget.uri;
    _bytes = uri == null ? null : widget.loader(uri);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const _MediaArtworkPlaceholder();
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        final value = snapshot.data;
        if (value == null || value.isEmpty) {
          return const _MediaArtworkPlaceholder();
        }
        return Image.memory(
          value,
          cacheWidth: 128,
          cacheHeight: 128,
          filterQuality: FilterQuality.low,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const _MediaArtworkPlaceholder(),
        );
      },
    );
  }
}

class _MediaArtworkPlaceholder extends StatelessWidget {
  const _MediaArtworkPlaceholder();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.appPalette.surfaceRaised,
    child: const Icon(Icons.movie_rounded),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.onExitLeft,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onExitLeft;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onPressed == null ? .5 : 1,
    child: TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed ?? () {},
      onKeyEvent: onExitLeft == null
          ? null
          : (_, event) => _handleExitLeft(event, onExitLeft!),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: context.appPalette.selectableSurface,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

KeyEventResult _handleExitLeft(KeyEvent event, VoidCallback onExit) {
  if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
    return KeyEventResult.ignored;
  }
  if (event is KeyDownEvent) onExit();
  return KeyEventResult.handled;
}
