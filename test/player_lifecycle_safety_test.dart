import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();

  String method(String start, String end) {
    final begin = source.indexOf(start);
    expect(begin, greaterThanOrEqualTo(0), reason: start);
    final finish = source.indexOf(end, begin + start.length);
    expect(finish, greaterThan(begin), reason: end);
    return source.substring(begin, finish);
  }

  void expectInOrder(String value, List<String> tokens) {
    var offset = 0;
    for (final token in tokens) {
      final next = value.indexOf(token, offset);
      expect(next, greaterThanOrEqualTo(offset), reason: token);
      offset = next + token.length;
    }
  }

  test('MPV handoff drains playback before releasing the player', () {
    final handoff = method(
      'Future<bool> _prepareForEngineHandoff',
      'void _showAutomaticFailoverNotice',
    );
    expectInOrder(handoff, [
      'await _persistPlayback(position, force: true)',
      'await _progressSubscription?.cancel()',
      '_handoffRelease.release(() async',
      'await _player.stop()',
      'await _detachAndroidVideoOutputBeforeRelease()',
      'await _player.dispose()',
      'await AndroidTvBridge.instance.clearMediaSession()',
    ]);
  });

  test(
    'watch party route handoff preserves the effective resume checkpoint',
    () {
      expect(
        source,
        contains('() => _prepareForEngineHandoff(_effectiveHandoffPosition())'),
      );
      expect(
        source,
        isNot(
          contains('() => _prepareForEngineHandoff(_player.state.position)'),
        ),
      );
    },
  );

  test(
    'startup and dispose cannot regress inherited local or server progress',
    () {
      final positionUpdate = method(
        'void _onPosition(Duration position)',
        'void _reportLibraryPlayback',
      );
      expectInOrder(positionUpdate, [
        'playerResumeTargetReached',
        '_pendingInheritedResume = null',
        'final effectivePosition = effectivePlayerResumePosition(',
        'pendingResume: _pendingInheritedResume',
        '_reportLibraryPlayback(position: effectivePosition)',
        '_persistPlayback(effectivePosition)',
      ]);

      final libraryReport = method(
        'void _reportLibraryPlayback',
        'void _publishWatchPartyPlayback',
      );
      expectInOrder(libraryReport, [
        'final effectivePosition = effectivePlayerResumePosition(',
        'position: position ?? _player.state.position',
        'pendingResume: _pendingInheritedResume',
        'final effectiveDuration = effectivePlayerProgressDuration(',
        'position: effectivePosition',
        'duration: effectiveDuration',
      ]);

      final persistence = method(
        'Future<void> _persistPlayback',
        'Future<void> _updateMediaSession',
      );
      expectInOrder(persistence, [
        'final effectivePosition = effectivePlayerResumePosition(',
        'pendingResume: _pendingInheritedResume',
        '_reportLibraryPlayback(position: effectivePosition, force: force)',
        'final duration = effectivePlayerProgressDuration(',
        'effectivePosition.inMilliseconds / duration.inMilliseconds',
        'position: completed ? duration : effectivePosition',
        'effectivePosition > const Duration(seconds: 30)',
        'position: effectivePosition',
      ]);

      final dispose = source.substring(source.lastIndexOf('void dispose()'));
      expect(
        dispose,
        contains('_persistPlayback(_effectiveHandoffPosition(), force: true)'),
      );
    },
  );

  test('explicit host and user seeks supersede an inherited resume', () {
    final hostBinding = method(
      '_watchPartyHandle = _watchPartyPlayback.bindEngine(',
      '_watchPartyRouteHandoff = ref.read',
    );
    expectInOrder(hostBinding, [
      'seekTo: (position) => _trackPlayerMutation',
      '_pendingInheritedResume = null',
      'await _player.seek(position)',
    ]);

    final userSeek = method(
      'Future<void> _drainSeekQueue()',
      'Future<void> _waitForSeekDrain()',
    );
    expectInOrder(userSeek, [
      'final target = _queuedSeekTarget!',
      '_pendingInheritedResume = null',
      'await _player.seek(target)',
    ]);
  });

  test('watch party player commands join the native release barrier', () {
    final hostBinding = method(
      '_watchPartyHandle = _watchPartyPlayback.bindEngine(',
      '_watchPartyRouteHandoff = ref.read',
    );
    expect(hostBinding, contains('play: () => _trackPlayerMutation'));
    expect(hostBinding, contains('pause: () => _trackPlayerMutation'));
    expect(hostBinding, contains('seekTo: (position) => _trackPlayerMutation'));

    final handoff = method(
      'Future<bool> _prepareForEngineHandoff',
      'void _showAutomaticFailoverNotice',
    );
    expectInOrder(handoff, [
      '_engineHandoffInProgress = true',
      'await _waitForPlayerMutations()',
      'await _detachAndroidVideoOutputBeforeRelease()',
      'await _player.dispose()',
    ]);
    expect(
      RegExp(
        r'_waitForPlayerMutations\(\)\.timeout\(\s*'
        r'_playerMutationReleaseTimeout',
      ).allMatches(source),
      hasLength(2),
      reason: 'handoff and unexpected disposal must both have a bounded drain',
    );
  });

  test('router detaches watch party before closing its playback port', () {
    final routerClass = source.substring(
      source.indexOf('class _TvPlayerScreenRouterState'),
      source.indexOf('class _MpvTvPlayerScreen'),
    );
    final routerDisposeStart = routerClass.indexOf('void dispose()');
    final routerDispose = routerClass.substring(
      routerDisposeStart,
      routerClass.indexOf(
        'Future<void> _adoptPlaybackStream',
        routerDisposeStart,
      ),
    );
    expectInOrder(routerDispose, [
      'await _watchPartyController.detachPlayback(_watchPartyPlayback)',
      'await _watchPartyPlayback.dispose()',
    ]);
  });

  test('MPV dispose unbinds party routing and cancels stream listeners', () {
    final dispose = source.substring(source.lastIndexOf('void dispose()'));
    expectInOrder(dispose, [
      '_watchPartyRouteHandoff.unbind(_watchPartyRouteHandoffOwner)',
      '_watchPartyPlayback.unbindEngine(_watchPartyHandle)',
      '_progressSubscription?.cancel()',
      '_handoffRelease.release(() async',
      'await _detachAndroidVideoOutputBeforeRelease()',
      'await _player.dispose()',
    ]);
  });

  test('player teardown never reads Riverpod after widget disposal begins', () {
    final routerClass = source.substring(
      source.indexOf('class _TvPlayerScreenRouterState'),
      source.indexOf('class _MpvTvPlayerScreen'),
    );
    final routerDisposeStart = routerClass.indexOf('void dispose()');
    final routerDisposeEnd = routerClass.indexOf(
      'Future<void> _adoptPlaybackStream',
      routerDisposeStart,
    );
    final routerDispose = routerClass.substring(
      routerDisposeStart,
      routerDisposeEnd,
    );
    final savePreferences = method(
      'Future<void> _saveSeriesPreferences()',
      'Future<void> _saveDecoderPreference()',
    );
    final mpvDispose = source.substring(source.lastIndexOf('void dispose()'));

    expect(routerDispose, isNot(contains('ref.read')));
    expect(savePreferences, isNot(contains('ref.read')));
    expect(mpvDispose, isNot(contains('ref.read')));
    expect(routerDispose, contains('_watchPartyController.detachPlayback'));
    expect(savePreferences, contains('_database.saveSeriesPreferences'));
  });

  test('removed playback engines cannot be reached from the MPV lifecycle', () {
    expect(source, isNot(contains('VlcTvPlayerScreen')));
    expect(source, isNot(contains('NativeMedia3PlayerScreen')));
    expect(source, isNot(contains('_fallbackToVlc')));
    expect(source, isNot(contains('onSelectEngine')));
  });

  test('automatic decoder reopen failure reaches library recovery first', () {
    final switchDecoder = method(
      'Future<void> _switchDecoder',
      'Future<void> _retryPlayback',
    );
    expectInOrder(switchDecoder, [
      '} catch (error)',
      'automaticDecoderFailureNeedsLibraryRecovery(',
      '_handleLibraryStartupFailure(error)',
      'setState(() => _playbackError = error.toString())',
    ]);
  });

  test('library completion uses the awaited MPV handoff before route pop', () {
    final completion = method(
      'void _handlePlaybackCompleted()',
      'Future<bool> _seekForSkip',
    );
    expectInOrder(completion, [
      'libraryPlayback.markCompleted(',
      '_blockGuestLocalControl(notify: false)',
      'unawaited(_returnToStreamPicker())',
    ]);
    expect(completion, isNot(contains('context.pop()')));
  });

  test(
    'manual episode changes persist position without forcing completion',
    () {
      final replacement = method(
        'Future<bool> _replaceWithResolvedEpisode',
        'Future<void> _playPreviousEpisode',
      );
      expectInOrder(replacement, [
        'await _prepareForEngineHandoff(handoffPosition)',
        'pushReplacement<void>',
      ]);
      expect(replacement, isNot(contains('markCompleted')));
      final previous = method(
        'Future<void> _playPreviousEpisode',
        'Future<void> _playNextEpisode',
      );
      expect(
        previous,
        contains('handoffPosition: _effectiveHandoffPosition()'),
      );
      final next = method(
        'Future<void> _playNextEpisode',
        'Future<void> _syncProgress',
      );
      expect(next, contains('handoffPosition: _effectiveHandoffPosition()'));
      expect(next, isNot(contains('markCompleted')));

      final prepared = method(
        'Future<bool> _openPreparedNextEpisode',
        'Map<String, String> _episodeResolveQuery',
      );
      expectInOrder(prepared, [
        'final handoffPosition = _effectiveHandoffPosition()',
        'await _prepareForEngineHandoff(handoffPosition)',
        'pushReplacement<void>',
      ]);
      expect(prepared, isNot(contains('_markLibraryEpisodeCompleted')));

      final progress = method(
        'void _onPosition(Duration position)',
        'void _reportLibraryPlayback',
      );
      expectInOrder(progress, [
        'trackerUpdateThresholdReached(',
        '_libraryCompletionThresholdHandled = true',
        'libraryPlayback.markCompleted(',
      ]);
    },
  );

  test(
    'catalog-linked library playback gets navigation and skip parity only',
    () {
      expect(
        source,
        contains(
          'widget.libraryPlayback?.request.isolation.nextEpisodeEnabled == true',
        ),
      );
      expect(source, contains('_catalogAnilistMediaId'));
      expect(source, contains('_catalogEpisodeNumber'));
      expect(source, contains('_completeCatalogLinkedLibraryPlayback()'));

      final skipLoad = method(
        'void _scheduleSkipSegmentLoad',
        'Future<int?> _resolveSkipMalMediaId',
      );
      expect(skipLoad, contains('_skipSegmentFeaturesEnabled'));

      final loadSkips = method(
        'Future<void> _loadSkipSegments',
        'Future<List<SkipSegment>> _embeddedChapterSkipsWithRetry',
      );
      expect(
        loadSkips,
        contains('malMediaId == null && _skipSegmentFeaturesEnabled'),
        reason: 'missing/transient catalog-to-MAL mappings must retry',
      );

      final tracking = method(
        'Future<void> _syncProgress',
        'Future<void> _openMedia',
      );
      expect(tracking, contains('if (!_animeFeaturesEnabled'));

      final discovery = method(
        'Future<void> _startWebSourceDiscovery',
        'void _mergeDirectStreamOptions',
      );
      expect(discovery, contains('if (!_animeFeaturesEnabled) return'));
    },
  );

  test('private-library playback cannot enter anime source discovery', () {
    final failover = method(
      'Future<void> _tryNextStream',
      'Future<bool> _switchToNextDirectStream',
    );
    expect(failover, contains('if (widget.libraryPlayback != null) return'));
    expect(
      source.replaceAll(RegExp(r'\s+'), ' '),
      contains(
        '_animeFeaturesEnabled && (_currentStream.isWebStream || '
        '_currentStream.isDirectTorrent)',
      ),
      reason:
          'the HUD picker may switch catalog-linked Web/Direct sources but '
          'must not query anime providers for Plex',
    );
  });

  test('private-library identity never becomes public source affinity', () {
    final routerClass = source.substring(
      source.indexOf('class _TvPlayerScreenRouterState'),
      source.indexOf('class _MpvTvPlayerScreen'),
    );
    final affinity = routerClass.substring(
      routerClass.indexOf('void _scheduleWatchPartyAffinity()'),
      routerClass.indexOf(
        '@override',
        routerClass.indexOf('void _scheduleWatchPartyAffinity()'),
      ),
    );
    expect(affinity, contains('widget.libraryPlayback != null'));
    expect(affinity, contains('const WatchPartyPlaybackAffinity()'));

    final query = method(
      'Map<String, String> _episodeResolveQuery',
      'Future<bool> _replaceWithResolvedEpisode',
    );
    expect(query, contains('final preferredProvider = _animeFeaturesEnabled'));
    expect(query, contains('final preferredSourceId = _animeFeaturesEnabled'));
    expect(query, contains('final preferredAuthor = _animeFeaturesEnabled'));
    expect(
      query,
      contains('final preferredWebProviderId = _animeFeaturesEnabled'),
    );

    final preferences = method(
      'Future<void> _saveSeriesPreferences()',
      'Future<void> _saveDecoderPreference()',
    );
    expect(preferences, contains('if (_animeFeaturesEnabled)'));
    final privateSafePrefix = preferences.substring(
      0,
      preferences.indexOf('if (_animeFeaturesEnabled)'),
    );
    expect(privateSafePrefix, isNot(contains('preferredReleaseProvider:')));
    expect(privateSafePrefix, isNot(contains('preferredReleaseGroup:')));
  });

  test(
    'automatic subtitle selection becomes final only after MPV accepts it',
    () {
      final selection = method(
        'Future<void> _selectPreferredTracks',
        'void _applyAutomaticSubtitleDefaultForRelease',
      );
      expectInOrder(selection, [
        'await _player.setSubtitleTrack(preferred)',
        '_preferredSubtitleSelected = true',
      ]);
      final defaults = method(
        'void _applyAutomaticSubtitleDefaultForRelease',
        'void _onPosition',
      );
      expect(
        defaults,
        contains('if (_seriesPreferences.subtitlePreferenceSet) return'),
      );
    },
  );
}
