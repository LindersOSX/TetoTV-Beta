import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum UnifiedMediaOrigin { device, jellyfin, plex }

class UnifiedMediaSearchItem {
  const UnifiedMediaSearchItem._({
    required this.origin,
    required this.title,
    required this.subtitle,
    this.document,
    this.jellyfinItem,
    this.plexItem,
  });

  factory UnifiedMediaSearchItem.device(LocalMediaDocument document) =>
      UnifiedMediaSearchItem._(
        origin: UnifiedMediaOrigin.device,
        title: document.name,
        subtitle: 'Recently selected on this device',
        document: document,
      );

  factory UnifiedMediaSearchItem.jellyfin(JellyfinMediaItem item) =>
      UnifiedMediaSearchItem._(
        origin: UnifiedMediaOrigin.jellyfin,
        title: item.displayTitle,
        subtitle: item.secondaryLabel,
        jellyfinItem: item,
      );

  factory UnifiedMediaSearchItem.plex(PlexMediaItem item) =>
      UnifiedMediaSearchItem._(
        origin: UnifiedMediaOrigin.plex,
        title: item.displayTitle,
        subtitle: item.secondaryLabel,
        plexItem: item,
      );

  final UnifiedMediaOrigin origin;
  final String title;
  final String subtitle;
  final LocalMediaDocument? document;
  final JellyfinMediaItem? jellyfinItem;
  final PlexMediaItem? plexItem;

  bool get isFolder =>
      jellyfinItem?.isFolder == true || plexItem?.isFolder == true;
}

class UnifiedMediaSearchState {
  const UnifiedMediaSearchState({
    this.query = '',
    this.busy = false,
    this.results = const [],
    this.message,
  });

  final String query;
  final bool busy;
  final List<UnifiedMediaSearchItem> results;
  final String? message;
}

final unifiedMediaSearchControllerProvider =
    StateNotifierProvider.autoDispose<
      UnifiedMediaSearchController,
      UnifiedMediaSearchState
    >((ref) {
      return UnifiedMediaSearchController(
        localMedia: ref.read(localMediaControllerProvider.notifier),
        plex: ref.read(plexControllerProvider.notifier),
        recentDocument: () =>
            ref.read(localMediaControllerProvider).recentLocalDocument,
        hasJellyfin: () =>
            ref.read(localMediaControllerProvider).connection != null,
        hasPlex: () => ref.read(plexControllerProvider).connection != null,
      );
    });

class UnifiedMediaSearchController
    extends StateNotifier<UnifiedMediaSearchState> {
  UnifiedMediaSearchController({
    required LocalMediaController localMedia,
    required PlexController plex,
    required LocalMediaDocument? Function() recentDocument,
    required bool Function() hasJellyfin,
    required bool Function() hasPlex,
  }) : this._(localMedia, plex, recentDocument, hasJellyfin, hasPlex);

  UnifiedMediaSearchController._(
    this._localMedia,
    this._plex,
    this._recentDocument,
    this._hasJellyfin,
    this._hasPlex,
  ) : super(const UnifiedMediaSearchState());

  final LocalMediaController _localMedia;
  final PlexController _plex;
  final LocalMediaDocument? Function() _recentDocument;
  final bool Function() _hasJellyfin;
  final bool Function() _hasPlex;
  int _generation = 0;

  void clear() {
    _generation++;
    state = const UnifiedMediaSearchState();
  }

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.length < 2) {
      state = UnifiedMediaSearchState(
        query: query,
        message: 'Enter at least two characters to search your media.',
      );
      return;
    }
    if (query.length > 200) {
      state = UnifiedMediaSearchState(
        query: query.substring(0, 200),
        message: 'Keep media searches under 200 characters.',
      );
      return;
    }

    final generation = ++_generation;
    state = UnifiedMediaSearchState(query: query, busy: true);
    final results = <UnifiedMediaSearchItem>[];
    final normalized = query.toLowerCase();
    final recent = _recentDocument();
    if (recent != null && recent.name.toLowerCase().contains(normalized)) {
      results.add(UnifiedMediaSearchItem.device(recent));
    }

    var jellyfinResults = const <JellyfinMediaItem>[];
    var plexResults = const <PlexMediaItem>[];
    var jellyfinFailed = false;
    var plexFailed = false;
    final searches = <Future<void>>[];
    if (_hasJellyfin()) {
      searches.add(
        _localMedia
            .search(query)
            .then<void>((items) {
              jellyfinResults = items;
            })
            .onError((_, _) {
              jellyfinFailed = true;
            }),
      );
    }
    if (_hasPlex()) {
      searches.add(
        _plex
            .search(query)
            .then<void>((items) {
              plexResults = items;
            })
            .onError((_, _) {
              plexFailed = true;
            }),
      );
    }
    await Future.wait(searches);
    if (generation != _generation) return;
    results
      ..addAll(jellyfinResults.map(UnifiedMediaSearchItem.jellyfin))
      ..addAll(plexResults.map(UnifiedMediaSearchItem.plex));
    final errors = <String>[
      if (jellyfinFailed) 'Jellyfin was unavailable.',
      if (plexFailed) 'Plex was unavailable.',
    ];

    final hasConnectedServer = _hasJellyfin() || _hasPlex();
    final message = results.isNotEmpty
        ? errors.isEmpty
              ? null
              : '${errors.join(' ')} Showing results from available sources.'
        : errors.isNotEmpty
        ? errors.join(' ')
        : hasConnectedServer
        ? 'No matches were found in your connected media libraries.'
        : 'Connect Jellyfin or Plex, or choose a device video first.';
    state = UnifiedMediaSearchState(
      query: query,
      results: List.unmodifiable(results),
      message: message,
    );
  }
}
