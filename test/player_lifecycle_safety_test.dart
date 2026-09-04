import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anime_tv/features/player/presentation/player_failover_coordinator.dart';

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
      'await _seekWithPerformanceDiagnostics(position, userInitiated: false)',
    ]);

    final userSeek = method(
      'Future<void> _drainSeekQueue()',
      'Future<void> _waitForSeekDrain()',
    );
    expectInOrder(userSeek, [
      'final target = _queuedSeekTarget!',
      '_pendingInheritedResume = null',
      'await _seekWithPerformanceDiagnostics(target)',
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
      'Future<VerifiedSkipSeekResult> _seekForSkip',
    );
    expectInOrder(completion, [
      'libraryPlayback.markCompleted(',
      '_blockGuestLocalControl(notify: false)',
      'unawaited(_returnToStreamPicker())',
    ]);
    expect(completion, isNot(contains('context.pop()')));
  });

  test(
    'failed automatic skip falls back to the manual action without looping',
    () {
      final skipCheck = method(
        'void _checkSkips(Duration position)',
        'void _focusSkipOnce',
      );
      expect(
        skipCheck,
        contains('!_suppressedAutomaticSkipSegments.contains(key)'),
      );

      final autoSkip = method(
        'Future<void> _autoSkipSegment',
        'void _focusSkipOnce',
      );
      expectInOrder(autoSkip, [
        '} catch (_)',
        'if (sourceStillActive)',
        '_suppressedAutomaticSkipSegments.add(segmentKey)',
        '} finally',
        '_checkSkips(_player.state.position)',
      ]);

      final sourceReset = method(
        'void _resetSkipSegmentsForSourceChange()',
        'void _recordSkipSegmentDiagnostic',
      );
      expect(sourceReset, contains('_suppressedAutomaticSkipSegments.clear()'));
    },
  );

  test('verified skip retries are bound to the active source', () {
    final skipSeek = method(
      'Future<VerifiedSkipSeekResult> _seekForSkip',
      'Future<void> _waitForPlayerMutations',
    );
    expect(skipSeek, contains('final expectedStream = _currentStream'));
    expect(skipSeek, contains('final expectedSource = _source'));
    expect(skipSeek, contains('!identical(_currentStream, expectedStream)'));
    expect(skipSeek, contains('_source != expectedSource'));
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
        'Future<bool> _openMedia',
      );
      expect(tracking, contains('if (!_animeFeaturesEnabled'));

      final discovery = method(
        'Future<void> _startWebSourceDiscovery',
        'void _mergeDirectStreamOptions',
      );
      expect(discovery, contains('if (!_animeFeaturesEnabled) return'));
    },
  );

  test('skip timing outages use cache, guarded backoff, and one notice', () {
    final schedule = method(
      'void _scheduleSkipSegmentLoad',
      'Future<int?> _resolveSkipMalMediaId',
    );
    expect(schedule, contains('_skipLoadRetryGate.guard(delay)'));
    expect(schedule, contains('_skipLoadExhaustedTransientFailure'));

    final load = method(
      'Future<void> _loadSkipSegments',
      'Future<List<SkipSegment>> _embeddedChapterSkipsWithRetry',
    );
    expect(load, contains('externalFuture = _aniSkipClient'));
    expect(load, isNot(contains('AniSkipClient()')));
    expect(load, contains('AniSkipLookupSource.staleCache'));
    expect(load, contains("'found_stale_cache'"));
    expect(load, contains('_skipLoadRetryGate.defer(retryDelay)'));
    expect(load, contains("'Intro/outro timing is temporarily unavailable'"));

    final sourceReset = method(
      'void _resetSkipSegmentsForSourceChange()',
      'void _recordSkipSegmentDiagnostic',
    );
    expect(sourceReset, contains('_skipLoadRetryGate.reset()'));
    expect(sourceReset, contains('_skipLoadExhaustedTransientFailure = false'));
    expect(sourceReset, contains('_skipTimingUnavailableNoticeShown = false'));
  });

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

  test('generic preference saves preserve explicit caption intent', () {
    final savePreferences = method(
      'Future<void> _saveSeriesPreferences()',
      'Future<void> _saveDecoderPreference()',
    );

    expect(savePreferences, isNot(contains('_player.state.track.subtitle')));
    expect(savePreferences, isNot(contains('subtitleLanguage:')));
    expect(savePreferences, isNot(contains('subtitleEnabled:')));
    expect(savePreferences, isNot(contains('subtitlePreferenceSet:')));
    expect(savePreferences, contains('subtitleSize: _subtitleSize'));
    expect(savePreferences, contains('subtitlePosition: _subtitlePosition'));
    expect(savePreferences, contains('subtitleDelayMs: _subtitleDelayMs'));
    expect(
      savePreferences,
      contains('_database.saveSeriesPreferences(mediaId, _seriesPreferences)'),
    );
  });

  test('every settled media open safely reapplies the caption preference', () {
    final openCurrentMedia = method(
      'Future<int?> _openCurrentMedia',
      'Future<bool> _openMedia',
    );
    expectInOrder(openCurrentMedia, [
      '_preferredAudioSelected = false',
      '_preferredSubtitleSelected = false',
      'await _tracksSubscription?.cancel()',
      'await _player.open(',
      '_mediaOpenInProgress = false',
      '_player.stream.tracks.listen(',
      'await _selectPreferredTracks(_player.state.tracks)',
    ]);

    final changedTracks = method(
      'void _onTracksChanged',
      'Future<void> _applyPreferredAudio',
    );
    expect(changedTracks, contains('_player.state.tracks'));
    expect(changedTracks, isNot(contains('Tracks tracks')));
    expect(
      changedTracks,
      contains('mediaRevision != _mediaOpenRevision'),
      reason: 'queued events from an old episode cannot select its track IDs',
    );

    final subtitleSelection = method(
      'Future<void> _applyPreferredSubtitle',
      'Future<void> _selectPreferredTracks',
    );
    expect(subtitleSelection, contains('_mediaOpenInProgress'));
    expect(
      subtitleSelection,
      contains(
        'final mediaRevision = expectedMediaRevision ?? _mediaOpenRevision',
      ),
    );
    expect(
      subtitleSelection,
      contains('if (!_seriesPreferences.subtitleEnabled)'),
    );
    expect(subtitleSelection, contains('SubtitleTrack.no()'));
    expect(
      subtitleSelection,
      contains("_player.state.track.subtitle.id == 'no'"),
      reason:
          'a wrong-language default is disabled without locking out a late matching track',
    );
    expectInOrder(subtitleSelection, [
      'if (mediaRevision != _mediaOpenRevision || _mediaOpenInProgress)',
      'await _player.setSubtitleTrack(',
      'if (mediaRevision != _mediaOpenRevision',
      '_preferredSubtitleSelected = true',
    ]);

    final externalSubtitleRegistration = method(
      'Future<void> _applySubtitle({',
      'Future<void> _persistPlayback',
    );
    expect(
      externalSubtitleRegistration,
      contains('expectedMediaRevision: expectedMediaRevision'),
      reason:
          'external captions are published after Player.open, so preference '
          'selection must be retried after registration',
    );
    expect(
      externalSubtitleRegistration,
      contains('bool revisionIsActive()'),
      reason: 'a superseded media open cannot attach its sidecar to the next',
    );
    expect(
      externalSubtitleRegistration,
      contains('expectedStream.externalSubtitleLanguage'),
    );
    expect(
      externalSubtitleRegistration,
      isNot(contains('language: _seriesPreferences.subtitleLanguage')),
      reason:
          'unknown sidecars must not be relabeled as the requested language',
    );
    expect(
      externalSubtitleRegistration,
      isNot(contains('widget.subtitle')),
      reason:
          'a failover stream without a sidecar must not inherit the initial '
          'route subtitle',
    );
    expect(
      externalSubtitleRegistration,
      contains('shouldKeepRegisteredExternalCaption('),
      reason:
          'explicit and globally remembered languages cannot be replaced by '
          'a mismatched sidecar',
    );
    expect(
      externalSubtitleRegistration,
      contains('.preferredCaptionMode'),
      reason: 'only Automatic may retain an unknown provider sidecar',
    );
  });

  test('superseded opens cannot adopt or publish an obsolete source', () {
    final openMedia = method(
      'Future<bool> _openMedia',
      'Future<void> _trackPlayerMutation',
    );
    expect(openMedia, contains('_serializeMediaOpen('));
    expect(openMedia, contains('final expectedStream = _currentStream'));
    expect(openMedia, contains('final expectedSource = _source'));
    expect(openMedia, contains('playerMediaOpenCanCommit('));
    expectInOrder(openMedia, [
      'if (!attemptIsActive()) return',
      '_recordDiagnosticStreamOpenResult(',
      'opened = true',
      'return opened',
    ]);

    for (final adoption in <String>[
      'await widget.onStreamAdopted(ready, candidate)',
      'await widget.onStreamAdopted(option.stream, option.release)',
    ]) {
      final adoptionOffset = source.indexOf(adoption);
      expect(adoptionOffset, greaterThanOrEqualTo(0));
      final beforeAdoption = source.substring(0, adoptionOffset);
      final gateOffset = beforeAdoption.lastIndexOf('if (!opened ||');
      expect(
        gateOffset,
        greaterThanOrEqualTo(0),
        reason: '$adoption must be guarded by the active open result',
      );
      final gate = source.substring(gateOffset, adoptionOffset);
      expect(gate, contains('!failoverIsActive()'));
      expect(gate, contains('identical(_currentStream,'));
      expect(adoptionOffset - gateOffset, lessThan(1500));
    }
  });

  test('manual source selection cancels an in-flight automatic failover', () {
    expect(source, contains('int _sourceSelectionGeneration = 0'));
    expect(source, contains('bool _manualSourceSelectionInProgress = false'));
    final automatic = method(
      'Future<void> _tryNextStream',
      'Future<bool> _switchToNextDirectStream',
    );
    expectInOrder(automatic, [
      'final failoverGeneration = ++_sourceSelectionGeneration',
      'bool failoverIsActive()',
      'playerFailoverGenerationIsActive(',
      'expectedSourceGeneration: failoverGeneration',
    ]);
    expect(automatic, contains('_manualSourceSelectionInProgress'));

    final directFailover = method(
      'Future<bool> _switchToNextDirectStream',
      'Future<void> _waitForInFlightDirectDiscovery',
    );
    expectInOrder(directFailover, [
      'required int expectedSourceGeneration',
      'activeGeneration: _sourceSelectionGeneration',
      'isActive: failoverIsActive',
    ]);

    final manual = method(
      'Future<void> _openStreamSourcePicker()',
      'Future<void> _openPlaybackMenu()',
    );
    expectInOrder(manual, [
      'final manualSelectionStartGeneration = _sourceSelectionGeneration',
      'await _preflightDirectStream(selected)',
      'manualSelectionStartGeneration != _sourceSelectionGeneration',
      '_failingOver',
      '_manualSourceSelectionInProgress = true',
      'final manualSourceGeneration = ++_sourceSelectionGeneration',
      '_currentStream = option.stream',
      '_manualSourceSelectionInProgress = false',
    ]);

    expect(
      playerFailoverGenerationIsActive(
        expectedGeneration: 3,
        activeGeneration: 3,
        manualSourceSelectionInProgress: false,
      ),
      isTrue,
    );
    expect(
      playerFailoverGenerationIsActive(
        expectedGeneration: 3,
        activeGeneration: 3,
        manualSourceSelectionInProgress: true,
      ),
      isFalse,
    );
    expect(
      playerFailoverGenerationIsActive(
        expectedGeneration: 3,
        activeGeneration: 4,
        manualSourceSelectionInProgress: false,
      ),
      isFalse,
    );
  });

  test('every unadopted source candidate closes its playback lease', () {
    final automatic = method(
      'Future<void> _tryNextStream',
      'Future<bool> _switchToNextDirectStream',
    );
    expectInOrder(automatic, [
      'if (!opened ||',
      'await ready.playbackLease?.close()',
      'resolvedStream = null',
    ]);

    final directFailover = method(
      'Future<bool> _switchToNextDirectStream',
      'Future<void> _waitForInFlightDirectDiscovery',
    );
    expectInOrder(directFailover, [
      'if (!opened ||',
      'await option.stream.playbackLease?.close()',
      'preparedOption = null',
    ]);

    final manual = method(
      'Future<void> _openStreamSourcePicker()',
      'Future<void> _openPlaybackMenu()',
    );
    expectInOrder(manual, [
      'if (!opened || !identical(_currentStream, option.stream))',
      'await option.stream.playbackLease?.close()',
    ]);
  });

  test('manual caption choices persist only after MPV accepts them', () {
    final picker = method(
      'Future<void> _openSubtitleTrackPicker()',
      'void _showTrackMessage',
    );
    expectInOrder(picker, [
      'await _trackPlayerMutation(',
      '_serializeMediaOpen(',
      'await _player.setSubtitleTrack(selected)',
      'if (!mounted || _engineHandoffInProgress)',
      '_preferredSubtitleSelected = true',
      'final selectedLanguage = canonicalPlayerTrackLanguage(',
      '_seriesPreferences = _seriesPreferences.copyWith(',
      'subtitleEnabled: selected.id != \'no\'',
      'subtitlePreferenceSet: true',
      'if (_catalogAnilistMediaId == null || !_seriesPreferencesReady)',
      '.setPreferredCaptionSelection(',
      'await _saveSeriesPreferences()',
      '_invalidateNextEpisodePreparation()',
    ]);
  });

  test('all automatic and manual track changes share the media-open queue', () {
    final automatic = method(
      'Future<void> _runTrackedTrackSelection',
      'Future<void> _applyPreferredAudio',
    );
    expect(automatic, contains('_serializeMediaOpen('));
    expect(automatic, contains('mediaRevision != _mediaOpenRevision'));

    final audioPicker = method(
      'Future<void> _openAudioTrackPicker()',
      'Future<void> _skipCurrentSegment()',
    );
    expectInOrder(audioPicker, [
      'final mediaRevision = _mediaOpenRevision',
      '_serializeMediaOpen(',
      'mediaRevision != _mediaOpenRevision',
      'await _player.setAudioTrack(selected)',
      'mediaRevision != _mediaOpenRevision',
      '_preferredAudioSelected = true',
    ]);

    final captionPicker = method(
      'Future<void> _openSubtitleTrackPicker()',
      'void _showTrackMessage',
    );
    expectInOrder(captionPicker, [
      'final mediaRevision = _mediaOpenRevision',
      '_serializeMediaOpen(',
      'mediaRevision != _mediaOpenRevision',
      'await _player.setSubtitleTrack(selected)',
      'mediaRevision != _mediaOpenRevision',
      '_preferredSubtitleSelected = true',
    ]);
  });

  test('global Preferred CC applies only without a per-series choice', () {
    final defaults = method(
      'void _applyCaptionDefaultForRelease',
      'void _onPosition',
    );
    expectInOrder(defaults, [
      'if (_seriesPreferences.subtitlePreferenceSet) return',
      'final preferences = ref.read(settingsPreferencesProvider)',
      'switch (preferences.preferredCaptionMode)',
      'case PreferredCaptionMode.automatic:',
      'preferredLanguage: preferences.preferredCaptionLanguage',
      'case PreferredCaptionMode.enabled:',
      'subtitleLanguage: preferences.preferredCaptionLanguage',
      'subtitleEnabled: true',
      'case PreferredCaptionMode.disabled:',
      'subtitleEnabled: false',
    ]);
    expect(
      defaults,
      isNot(contains('subtitlePreferenceSet: true')),
      reason: 'a global default must never masquerade as a per-series choice',
    );
    expect(
      RegExp(r'_applyCaptionDefaultForRelease\(').allMatches(source).length,
      greaterThanOrEqualTo(5),
      reason:
          'bootstrap, fallback resolution, direct fallback, and manual source '
          'selection must all preserve Preferred CC On/Off',
    );
  });

  test(
    'automatic subtitle defaults cannot replace an explicit caption choice',
    () {
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
