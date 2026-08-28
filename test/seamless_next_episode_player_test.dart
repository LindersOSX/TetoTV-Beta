import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/player/presentation/player_failover_coordinator.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const playerPath = 'lib/features/player/presentation/tv_player_screen.dart';

  test('MPV completion is immediate, gated, and persisted first', () {
    final source = _read(playerPath);
    final completion = _member(source, 'Future<void> _offerNextEpisode()');

    _expectInOrder(completion, const [
      'await _persistPlayback(',
      'if (!mounted || _engineHandoffInProgress) return',
      'if (!_seriesPreferences.autoplayNextEpisode) return',
      'await _playNextEpisode()',
    ]);
    expect(completion, isNot(contains('showDialog')));
    expect(source, isNot(contains('NextEpisodeDialog')));
    expect(source, isNot(contains('Episode complete')));
    expect(source, isNot(contains('Playing the next episode in')));
  });

  test('automatic and manual next requests share one deduplicated handoff', () {
    final source = _read(playerPath);
    final next = _member(source, 'Future<void> _playNextEpisode()');
    _expectInOrder(next, const [
      '_episodeHandoff.tryEnter()',
      'await _openPreparedNextEpisode(',
      'await ref.read(animeDetailsProvider(mediaId).future)',
    ]);
    expect(next, contains('_episodeHandoff.leave()'));

    final mediaAction = _member(source, 'void _handleMediaAction(');
    expect(mediaAction, contains("case 'next':"));
    expect(mediaAction, contains('unawaited(_playNextEpisode())'));
    expect(mediaAction, isNot(contains('_offerNextEpisode')));
  });

  test('late failover streams are closed before a stale handoff returns', () {
    final source = _read(playerPath);
    final resolver = _member(source, 'Future<StreamReady?> _resolveRelease(');

    _expectInOrder(resolver, const [
      'await for (final resolution in resolver.resolve(episode))',
      'if (!mounted || _engineHandoffInProgress) {',
      'await ready.playbackLease?.close()',
      'verifyPlaybackEpisodeIdentity(',
      'await resolution.playbackLease?.close()',
    ]);
  });

  test(
    'single-flight gate admits only one racing next-episode route',
    () async {
      final gate = PlayerHandoffGate();
      final release = Completer<void>();
      var routes = 0;

      Future<void> requestRoute() async {
        if (!gate.tryEnter()) return;
        try {
          await release.future;
          routes++;
        } finally {
          gate.leave();
        }
      }

      final automatic = requestRoute();
      final manual = requestRoute();
      release.complete();
      await Future.wait([automatic, manual]);
      expect(routes, 1);
    },
  );

  test('fallback readiness waits for decoded media, not only open', () async {
    var polls = 0;
    final ready = await waitForPlayerMediaReadiness(
      hasDecodedVideo: () => polls >= 3,
      isActive: () => true,
      maxPolls: 5,
      delay: (_) async => polls++,
    );

    expect(ready, isTrue);
    expect(polls, 3);
  });

  test(
    'fallback readiness times out and leaves the next candidate usable',
    () async {
      var polls = 0;
      final ready = await waitForPlayerMediaReadiness(
        hasDecodedVideo: () => false,
        isActive: () => true,
        maxPolls: 4,
        delay: (_) async => polls++,
      );

      expect(ready, isFalse);
      expect(polls, 4);
    },
  );

  test('fallback readiness stops as soon as its player is inactive', () async {
    var active = true;
    var polls = 0;
    final ready = await waitForPlayerMediaReadiness(
      hasDecodedVideo: () => false,
      isActive: () => active,
      maxPolls: 8,
      delay: (_) async {
        polls++;
        active = false;
      },
    );

    expect(ready, isFalse);
    expect(polls, 1);
  });

  test('pending failover cancellation yields no accepted mutation', () async {
    final pending = Completer<void>();
    var active = true;
    var acceptedMutations = 0;
    final operation = openFirstViablePlayerCandidate<String>(
      candidates: const ['candidate'],
      resumePosition: const Duration(minutes: 12),
      isActive: () => active,
      attempt: (_, _) async {
        await pending.future;
        return true;
      },
    );

    active = false;
    pending.complete();
    final selected = await operation;
    if (selected != null) acceptedMutations++;
    expect(selected, isNull);
    expect(acceptedMutations, 0);
  });

  test('disposal during manifest load never samples prewarm state', () async {
    final pendingLoad = Completer<void>();
    var active = true;
    var snapshotReads = 0;
    final operation = loadPlayerPrewarmSnapshot<String>(
      load: () => pendingLoad.future,
      snapshot: () {
        snapshotReads++;
        return const ['https://source.example/manifest.json'];
      },
      isActive: () => active,
    );

    active = false;
    pendingLoad.complete();
    expect(await operation, isNull);
    expect(snapshotReads, 0);
  });

  test(
    'candidate open failure advances to the next at the exact timestamp',
    () async {
      const resume = Duration(minutes: 17, seconds: 23);
      final attempted = <String>[];
      final positions = <Duration>[];
      final selected = await openFirstViablePlayerCandidate<String>(
        candidates: const ['broken', 'working'],
        resumePosition: resume,
        isActive: () => true,
        attempt: (candidate, position) async {
          attempted.add(candidate);
          positions.add(position);
          if (candidate == 'broken') throw StateError('decoder open failed');
          return true;
        },
      );

      expect(selected, 'working');
      expect(attempted, const ['broken', 'working']);
      expect(positions, const [resume, resume]);
    },
  );

  test('candidate coordinator enforces its explicit bound', () async {
    var attempts = 0;
    final selected = await openFirstViablePlayerCandidate<int>(
      candidates: const [1, 2, 3, 4],
      resumePosition: Duration.zero,
      maxCandidates: 2,
      isActive: () => true,
      attempt: (_, _) async {
        attempts++;
        return false;
      },
    );
    expect(selected, isNull);
    expect(attempts, 2);
  });

  test('failover class policy preserves current class before crossing', () {
    expect(playerFailoverClassOrder(currentIsWeb: true), const [
      PlayerFailoverClass.directWeb,
      PlayerFailoverClass.debrid,
    ]);
    expect(playerFailoverClassOrder(currentIsWeb: false), const [
      PlayerFailoverClass.debrid,
      PlayerFailoverClass.directWeb,
    ]);
  });

  test(
    'authoritative Dub outranks same-provider 4K Sub in both failover classes',
    () async {
      const sub4k = ReleaseCandidate(
        infoHash: 'sub-4k',
        magnetUri: 'magnet:?xt=sub-4k',
        releaseName: '[Preferred] Show 01 2160p Sub',
        seeders: 100,
        sourceId: 'same-source',
        quality: '2160p',
        provider: 'same-provider',
      );
      const dub1080 = ReleaseCandidate(
        infoHash: 'dub-1080',
        magnetUri: 'magnet:?xt=dub-1080',
        releaseName: '[Other] Show 01 1080p Dub',
        seeders: 10,
        sourceId: 'other-source',
        quality: '1080p',
        provider: 'other-provider',
        isDubbed: true,
      );

      final rankedReleases = rankAutomaticPlayerFailoverCandidates(
        candidates: const [sub4k, dub1080],
        audioRank: (candidate) =>
            releaseAudioPreferenceRank(candidate, PlaybackAudioPreference.dub),
        qualityRank: (_) => 0,
        affinityRank: (candidate) =>
            candidate.provider == 'same-provider' ? 0 : 1,
      );
      final attemptedReleases = <String>[];
      final openedRelease = await openFirstViablePlayerCandidate(
        candidates: rankedReleases,
        resumePosition: const Duration(minutes: 9, seconds: 41),
        isActive: () => true,
        attempt: (candidate, _) async {
          attemptedReleases.add(candidate.infoHash);
          return true;
        },
      );

      final subDirect = PlaybackStreamOption(
        stream: StreamReady(
          uri: Uri.parse('https://same.example/sub-4k.m3u8'),
          displayName: '4K Sub',
          providerId: 'same-provider',
        ),
        release: sub4k,
      );
      final dubDirect = PlaybackStreamOption(
        stream: StreamReady(
          uri: Uri.parse('https://other.example/dub-1080.m3u8'),
          displayName: '1080p Dub',
          providerId: 'other-provider',
        ),
        release: dub1080,
      );
      final rankedDirect = rankAutomaticPlayerFailoverCandidates(
        candidates: [subDirect, dubDirect],
        audioRank: (option) => releaseAudioPreferenceRank(
          option.release,
          PlaybackAudioPreference.dub,
        ),
        qualityRank: (_) => 0,
        affinityRank: (option) =>
            option.stream.providerId == 'same-provider' ? 0 : 1,
      );
      final attemptedDirect = <String>[];
      final openedDirect = await openFirstViablePlayerCandidate(
        candidates: rankedDirect,
        resumePosition: const Duration(minutes: 9, seconds: 41),
        isActive: () => true,
        attempt: (candidate, _) async {
          attemptedDirect.add(candidate.release.infoHash);
          return true;
        },
      );

      expect(openedRelease, same(dub1080));
      expect(attemptedReleases, const ['dub-1080']);
      expect(openedDirect, same(dubDirect));
      expect(attemptedDirect, const ['dub-1080']);
    },
  );

  test(
    'active-player fallback keeps current quality first and fails open',
    () async {
      final candidates = [
        (id: 'same-source-4k', height: 2160, affinity: 0),
        (id: 'other-1080', height: 1080, affinity: 3),
        (id: 'other-720', height: 720, affinity: 2),
      ];
      final ranked = rankAutomaticPlayerFailoverCandidates(
        candidates: candidates,
        audioRank: (_) => 0,
        qualityRank: (candidate) => candidate.height == 1080 ? 0 : 1,
        affinityRank: (candidate) => candidate.affinity,
      );
      final attempted = <String>[];
      final opened = await openFirstViablePlayerCandidate(
        candidates: ranked,
        resumePosition: const Duration(minutes: 7),
        isActive: () => true,
        attempt: (candidate, _) async {
          attempted.add(candidate.id);
          return candidate.height != 1080;
        },
      );

      expect(ranked.first.id, 'other-1080');
      expect(ranked, hasLength(3));
      expect(attempted, ['other-1080', 'same-source-4k']);
      expect(opened?.id, 'same-source-4k');
    },
  );

  test(
    'cross-class fallback exhausts same quality before class preference',
    () {
      final candidates =
          <
            ({
              PlayerFailoverClass streamClass,
              String id,
              int height,
              int audio,
            })
          >[
            (
              streamClass: PlayerFailoverClass.debrid,
              id: 'debrid-4k',
              height: 2160,
              audio: 0,
            ),
            (
              streamClass: PlayerFailoverClass.directWeb,
              id: 'web-1080',
              height: 1080,
              audio: 0,
            ),
            (
              streamClass: PlayerFailoverClass.debrid,
              id: 'debrid-1080',
              height: 1080,
              audio: 0,
            ),
          ];
      final planned = <String>[];
      for (final audioRank in playerFailoverAudioRankTiers(
        candidates.map((candidate) => candidate.audio),
      )) {
        for (final sameQuality in playerFailoverSameQualityTiers(
          currentQualityHeight: 1080,
        )) {
          for (final streamClass in playerFailoverClassOrder(
            currentIsWeb: false,
          )) {
            planned.addAll(
              candidates
                  .where(
                    (candidate) =>
                        candidate.audio == audioRank &&
                        candidate.streamClass == streamClass &&
                        playerFailoverCandidateIsInQualityTier(
                          candidateQualityHeight: candidate.height,
                          currentQualityHeight: 1080,
                          sameQuality: sameQuality,
                        ),
                  )
                  .map((candidate) => candidate.id),
            );
          }
        }
      }

      expect(planned, ['debrid-1080', 'web-1080', 'debrid-4k']);
    },
  );

  test('cross-class audio remains authoritative ahead of quality', () {
    final candidates = [
      (
        streamClass: PlayerFailoverClass.directWeb,
        id: 'same-quality-sub',
        height: 1080,
        audio: 1,
      ),
      (
        streamClass: PlayerFailoverClass.debrid,
        id: 'different-quality-dub',
        height: 2160,
        audio: 0,
      ),
    ];
    final planned = <String>[];
    for (final audioRank in playerFailoverAudioRankTiers(
      candidates.map((candidate) => candidate.audio),
    )) {
      for (final sameQuality in playerFailoverSameQualityTiers(
        currentQualityHeight: 1080,
      )) {
        for (final streamClass in playerFailoverClassOrder(
          currentIsWeb: true,
        )) {
          planned.addAll(
            candidates
                .where(
                  (candidate) =>
                      candidate.audio == audioRank &&
                      candidate.streamClass == streamClass &&
                      playerFailoverCandidateIsInQualityTier(
                        candidateQualityHeight: candidate.height,
                        currentQualityHeight: 1080,
                        sameQuality: sameQuality,
                      ),
                )
                .map((candidate) => candidate.id),
          );
        }
      }
    }

    expect(planned, ['different-quality-dub', 'same-quality-sub']);
  });

  test('terminal Debrid failure leaves Web failover available', () {
    expect(
      playerFailoverClassIsAvailable(
        PlayerFailoverClass.debrid,
        debridAvailable: false,
      ),
      isFalse,
    );
    expect(
      playerFailoverClassIsAvailable(
        PlayerFailoverClass.directWeb,
        debridAvailable: false,
      ),
      isTrue,
    );
  });

  test(
    'debrid failure consumes a delayed secure web result at the same timestamp',
    () async {
      const resume = Duration(minutes: 8, seconds: 41);
      final events = <String>[];
      final webCandidates = <String>[];
      final openedPositions = <Duration>[];
      var preflighted = false;
      String? selected;

      for (final streamClass in playerFailoverClassOrder(currentIsWeb: false)) {
        switch (streamClass) {
          case PlayerFailoverClass.debrid:
            events.add('debrid');
            selected = await openFirstViablePlayerCandidate<String>(
              candidates: const ['failed-debrid'],
              resumePosition: resume,
              isActive: () => true,
              attempt: (_, _) async => throw StateError('engine failed'),
            );
          case PlayerFailoverClass.directWeb:
            events.add('web');
            final discovered = await waitForPlayerFailoverCandidates<String>(
              snapshot: () => webCandidates,
              isActive: () => true,
              delay: (_) async {
                webCandidates.add('delayed-web');
              },
            );
            selected = await openFirstViablePlayerCandidate<String>(
              candidates: discovered,
              resumePosition: resume,
              isActive: () => true,
              attempt: (_, position) async {
                preflighted = true;
                openedPositions.add(position);
                return true;
              },
            );
        }
        if (selected != null) break;
      }

      expect(events, const ['debrid', 'web']);
      expect(selected, 'delayed-web');
      expect(preflighted, isTrue);
      expect(openedPositions, const [resume]);
    },
  );

  test(
    'disabled autoplay returns before advancing while manual Next bypasses it',
    () {
      final source = _read(playerPath);
      final completion = _member(source, 'Future<void> _offerNextEpisode()');
      final gate = completion.indexOf('autoplayNextEpisode');
      final disabledReturn = completion.indexOf('return', gate);
      final automaticAdvance = completion.indexOf(
        'await _playNextEpisode()',
        gate,
      );
      expect(gate, greaterThanOrEqualTo(0));
      expect(disabledReturn, greaterThan(gate));
      expect(automaticAdvance, greaterThan(disabledReturn));

      final directNext = _member(source, 'Future<void> _playNextEpisode()');
      expect(directNext, isNot(contains('autoplayNextEpisode')));
    },
  );

  test('next-episode fallback carries current source-affinity hints', () {
    final source = _read(playerPath);
    final query = _member(source, 'Map<String, String> _episodeResolveQuery(');
    expect(query, contains("'preferredAudio': _effectiveAudioPreference.name"));
    expect(query, contains('final preferredProvider = _animeFeaturesEnabled'));
    expect(query, contains('? _currentRelease.provider?.trim()'));
    expect(query, contains('final preferredSourceId = _animeFeaturesEnabled'));
    expect(query, contains('? _currentRelease.sourceId.trim()'));
    expect(query, contains('releaseGroupKey(_currentRelease.releaseName)'));
    expect(
      query,
      contains('final preferredWebProviderId = _animeFeaturesEnabled'),
    );
    expect(
      query,
      contains('final preferredQualityHeight = _animeFeaturesEnabled'),
    );
    for (final name in const [
      'preferredProvider',
      'preferredSourceId',
      'preferredAuthor',
      'preferredWebProviderId',
      'preferredQualityHeight',
    ]) {
      expect(query, contains("'$name': $name"));
    }
    expect(query, contains('preferredProvider.isNotEmpty'));
    expect(query, contains('preferredSourceId.isNotEmpty'));
    expect(query, contains('preferredAuthor.isNotEmpty'));
    expect(query, contains('preferredWebProviderId.isNotEmpty'));
    expect(query, contains('preferredQualityHeight > 0'));
    expect(query, contains(': null'));
    expect(query, contains(": ''"));
    expect(query, contains(': 0'));

    final replacement = _member(
      source,
      'Future<bool> _replaceWithResolvedEpisode(',
    );
    expect(replacement, contains('_episodeResolveQuery(details, episode)'));
    final next = _member(source, 'Future<void> _playNextEpisode()');
    expect(next, contains('await _replaceWithResolvedEpisode('));
  });

  test('MPV preserves the failure timestamp during recovery', () {
    final failover = _member(_read(playerPath), 'Future<void> _tryNextStream(');
    _expectInOrder(failover, const [
      'final position = resumePosition ?? _effectiveHandoffPosition()',
      'await AndroidTvBridge.instance.getDeviceProfile()',
      'await _openMedia(',
      'resume: position',
      'requireDecodedVideo: true',
      'await _switchToNextDirectStream(',
      'position,',
    ]);
  });

  test('MPV direct candidate failures advance in one operation', () {
    final source = _read(playerPath);
    final direct = _member(source, 'Future<bool> _switchToNextDirectStream(');
    _expectInOrder(direct, const [
      'openFirstViablePlayerCandidate(',
      'resumePosition: position',
      'attempt: (candidate, resumePosition) async',
      'try {',
      'await _openMedia(',
      'resume: resumePosition',
      'requireDecodedVideo: true',
      'catch (_)',
      'rethrow',
    ]);
    expect(source, contains('if (propagateFailure) rethrow'));
  });

  test('failover awaits do not mutate MPV after disposal', () {
    final source = _read(playerPath);
    final failover = _member(source, 'Future<void> _tryNextStream(');
    _expectInOrder(failover, const [
      'final tokenService = ref.read(debridTokenServiceProvider)',
      'await AndroidTvBridge.instance.getDeviceProfile()',
      'if (!mounted || _engineHandoffInProgress) return',
      'await _database.recordStreamFailure(',
      'if (!mounted || _engineHandoffInProgress) return',
      'await _switchToNextDirectStream(',
    ]);

    final preflight = _member(
      source,
      'Future<PlaybackStreamOption?> _preflightDirectStream(',
    );
    _expectInOrder(preflight, const [
      'await const WebStreamValidator().validate(',
      'if (!mounted || _engineHandoffInProgress) {',
      'await validated.session?.close()',
      'uri: validated.uri',
      'externalSubtitle: validated.subtitleUri',
      'playbackLease: validated.session',
      'providerEpisodeIdentity: option.stream.providerEpisodeIdentity',
    ]);

    final discovery = _member(source, 'Future<void> _startWebSourceDiscovery(');
    _expectInOrder(discovery, const [
      'final aggregator = ref.read(webStreamAggregatorProvider)',
      'final episode = widget.launch.episode',
      'await _sourceDiscoverySubscription?.cancel()',
      'if (!mounted || _engineHandoffInProgress) return',
      'aggregator',
      '.watchSearchIncrementally(episode)',
    ]);
    final afterCancel = discovery.substring(
      discovery.indexOf('await _sourceDiscoverySubscription?.cancel()'),
    );
    expect(afterCancel, isNot(contains('ref.read')));
  });

  test('MPV reuses one owned ready-to-play next episode', () {
    final source = _read(playerPath);
    final request = _between(
      source,
      'NextEpisodePreparationRequest _nextEpisodePreparationRequest()',
      'void _maybePrewarmNextEpisode(',
    );
    _expectInOrder(request, const [
      'widget.libraryPlayback != null',
      'NextEpisodePreparationRequest.catalogLinkedLibrary(',
      'episode: widget.launch.episode',
      'NextEpisodePreparationRequest(',
      'currentLaunch: PlaybackLaunch(',
      'stream: _currentStream',
      'selectedRelease: _currentRelease',
      'seriesPreferences: _seriesPreferences',
    ]);

    final prewarm = _member(source, 'Future<void> _prewarmNextEpisode()');
    _expectInOrder(prewarm, const [
      'final preparation = ref.read(nextEpisodePreparationControllerProvider)',
      'final outcome = await preparation.warmWithOutcome(',
      '_nextEpisodePreparationRequest()',
      '_prewarmRetry.isCurrent(generation)',
      '_prewarmed = prepared != null',
    ]);

    final prepared = _member(source, 'Future<bool> _openPreparedNextEpisode(');
    _expectInOrder(prepared, const [
      'final prepared = await preparation.take(',
      'currentRequest: _nextEpisodePreparationRequest()',
      'if (!prepared.hasCompatibleEpisodeIdentity)',
      'await prepared.close()',
      'await _prepareForEngineHandoff(handoffPosition)',
      'preparedNextEpisodePlayerLocation(prepared)',
      'extra: prepared.launch',
    ]);
    expect(source, contains('shouldPrepareNextEpisode(position: position'));
    final maybePrewarm = _member(source, 'void _maybePrewarmNextEpisode(');
    expect(maybePrewarm, contains('_catalogEpisodeFeaturesEnabled'));
    expect(maybePrewarm, contains('_catalogEpisodeNumber == null'));
    expect(maybePrewarm, contains('_guestControlsLocked'));
  });

  test('prepared handoff closes its lease whenever ownership is rejected', () {
    final prepared = _member(
      _read(playerPath),
      'Future<bool> _openPreparedNextEpisode(',
    );
    expect(
      RegExp(r'prepared\.close\(\)').allMatches(prepared).length,
      greaterThanOrEqualTo(5),
    );
    _expectInOrder(prepared, const [
      'final prepared = await preparation.take(',
      'if (!prepared.hasCompatibleEpisodeIdentity)',
      'await prepared.close()',
      'if (!mounted || _engineHandoffInProgress)',
      'await prepared.close()',
      'await _prepareForEngineHandoff(handoffPosition)',
      '_preserveNextEpisodePreparation = true',
      'pushReplacement<void>(',
    ]);
  });

  test(
    'MPV prewarm is independent of autoplay and retries stale readiness',
    () {
      final source = _read(playerPath);
      final maybePrewarm = _member(source, 'void _maybePrewarmNextEpisode(');
      _expectInOrder(maybePrewarm, const [
        'shouldPrepareNextEpisode(',
        'if (_prewarmed)',
        '_nextEpisodePreparation.hasReady(_nextEpisodePreparationRequest())',
        '_prewarmed = false',
        '_prewarmRetry.resetGeneration()',
        '_prewarmRetry.canAttempt(DateTime.now())',
        'unawaited(_prewarmNextEpisode())',
      ]);
      expect(maybePrewarm, isNot(contains('autoplayNextEpisode')));
      final prewarm = _member(source, 'Future<void> _prewarmNextEpisode()');
      expect(prewarm, isNot(contains('autoplayNextEpisode')));
      expect(prewarm, contains('_catalogEpisodeFeaturesEnabled'));
      expect(prewarm, contains('_catalogEpisodeNumber == null'));
      expect(prewarm, contains('_guestControlsLocked'));
    },
  );

  test(
    'MPV failover is finite, deduplicated, affinity-ranked, and noticed',
    () {
      final source = _read(playerPath);
      expect(source, contains('final Set<String> _failedDirectStreamKeys'));
      expect(
        source,
        contains('final Set<ReleaseCandidate> _attemptedReleaseAlternatives'),
      );
      final affinity = _member(source, 'int _releaseFailoverAffinity(');
      expect(affinity, contains('sameProvider'));
      expect(affinity, contains('sameSource'));
      expect(affinity, contains('sameAuthor'));

      final wait = _member(
        source,
        'Future<void> _waitForInFlightDirectDiscovery()',
      );
      expect(wait, contains('waitForPlayerFailoverCandidates('));
      expect(wait, contains('snapshot: _remainingDirectFailoverCandidates'));

      final direct = _member(source, 'Future<bool> _switchToNextDirectStream(');
      expect(direct, contains('openFirstViablePlayerCandidate('));
      expect(direct, contains('_showAutomaticFailoverNotice('));
      expect(direct, isNot(contains('_showTrackMessage')));
    },
  );

  test(
    'MPV applies authoritative audio then quality to automatic failover',
    () {
      final source = _read(playerPath);
      final direct = _member(
        source,
        'List<PlaybackStreamOption> _remainingDirectFailoverCandidates()',
      );
      _expectInOrder(direct, const [
        'rankAutomaticPlayerFailoverCandidates(',
        'audioRank:',
        'releaseAudioPreferenceRank(',
        'qualityRank:',
        'automaticQualityAffinityRank(',
        'releaseQualityHeight(',
        'affinityRank:',
      ]);

      final releases = _member(
        source,
        'List<ReleaseCandidate> _remainingReleaseFailoverCandidates()',
      );
      _expectInOrder(releases, const [
        'rankAutomaticPlayerFailoverCandidates(',
        'audioRank:',
        'releaseAudioPreferenceRank(',
        'qualityRank:',
        'automaticQualityAffinityRank(',
        'releaseQualityHeight(',
        'affinityRank:',
      ]);
      expect(direct, contains('_effectiveAudioPreference'));
      expect(releases, contains('_effectiveAudioPreference'));

      final manualPicker = _read(
        'lib/features/player/presentation/player_stream_source_picker.dart',
      );
      expect(
        manualPicker,
        isNot(contains('rankAutomaticPlayerFailoverCandidates')),
      );
      _expectInOrder(manualPicker, const [
        'int comparePlaybackStreamOptions(',
        'final quality = playbackStreamQualityRank(',
        'final provider = leftProvider.compareTo(rightProvider)',
      ]);
    },
  );

  test('MPV applies quality tiers before source-class preference', () {
    final failover = _member(_read(playerPath), 'Future<void> _tryNextStream(');
    _expectInOrder(failover, const [
      'final classOrder = playerFailoverClassOrder(',
      'currentIsWeb: _currentStream.isWebStream',
      'final currentQualityHeight = releaseQualityHeight(',
      'final audioRankTiers = playerFailoverAudioRankTiers(',
      'for (final audioRank in audioRankTiers)',
      'for (final sameQuality in playerFailoverSameQualityTiers(',
      'currentQualityHeight: currentQualityHeight',
      'playerFailoverCandidateIsInQualityTier(',
      'for (final streamClass in classOrder)',
      'switch (streamClass)',
      'playerFailoverClassIsAvailable(',
      'debridAvailable: terminalFailure == null',
    ]);
    expect(failover, isNot(contains('if (terminalFailure != null) break')));
  });

  test('enabled web discovery also runs during debrid playback', () {
    final source = _read(playerPath);
    final discovery = _member(source, 'Future<void> _startWebSourceDiscovery(');
    expect(discovery, contains('webStreamsEnabled'));
    expect(discovery, contains('watchSearchIncrementally(episode)'));
    expect(discovery, isNot(contains('_currentStream.isWebStream')));
    expect(source, contains('unawaited(_startWebSourceDiscovery())'));

    final wait = _member(
      source,
      'Future<void> _waitForInFlightDirectDiscovery()',
    );
    _expectInOrder(wait, const [
      '_remainingDirectFailoverCandidates().isNotEmpty',
      'await _startWebSourceDiscovery()',
      'await waitForPlayerFailoverCandidates(',
    ]);
  });

  test('proxy leases transfer only after MPV accepts candidate playback', () {
    final source = _read(playerPath);
    final adoption = _member(source, 'Future<void> _adoptPlaybackStream(');
    _expectInOrder(adoption, const [
      'final previous = _activeLaunch.stream',
      '_activeLaunch = PlaybackLaunch(',
      'if (!identical(previous.playbackLease, stream.playbackLease))',
      'await previous.playbackLease?.close()',
    ]);

    final routerDispose = _member(source, 'void dispose()');
    expect(
      routerDispose,
      contains('unawaited(_activeLaunch.stream.playbackLease?.close())'),
    );

    final picker = _member(source, 'Future<void> _openStreamSourcePicker()');
    _expectInOrder(picker, const [
      'final option = await _preflightDirectStream(selected)',
      'await _openMedia(',
      'resume: resume',
      'requireDecodedVideo: true',
      'await widget.onStreamAdopted(option.stream, option.release)',
      '} catch (_)',
      'await option.stream.playbackLease?.close()',
    ]);

    final automatic = _member(
      source,
      'Future<bool> _switchToNextDirectStream(',
    );
    _expectInOrder(automatic, const [
      'final option = await _preflightDirectStream(candidate, silent: true)',
      'await _openMedia(',
      'resume: resumePosition',
      'requireDecodedVideo: true',
      'await widget.onStreamAdopted(option.stream, option.release)',
      'preparedOption = null',
      '} catch (_)',
      'await preparedOption?.stream.playbackLease?.close()',
    ]);
  });

  test('failed Debrid fallback closes only the candidate-owned lease', () {
    final failover = _member(_read(playerPath), 'Future<void> _tryNextStream(');
    _expectInOrder(failover, const [
      'StreamReady? resolvedStream',
      'final ready = await _resolveRelease(',
      'resolvedStream = ready',
      'await _openMedia(',
      'await widget.onStreamAdopted(ready, candidate)',
      '} catch (error)',
      'await resolvedStream?.playbackLease?.close()',
      '_currentStream = previousStream',
    ]);
    expect(
      failover,
      isNot(contains('await _currentStream.playbackLease?.close()')),
    );
  });

  test('MPV records one verified open result before a working outcome', () {
    final source = _read(playerPath);
    expect(
      RegExp(r'_playbackDiagnostics\.streamOpened\(').allMatches(source).length,
      1,
      reason: 'all stream-open diagnostics should use the ordered helper',
    );

    final working = _member(source, 'void _recordDiagnosticWorkingOutcome()');
    _expectInOrder(working, const [
      '_diagnosticConfirmedOpenAttempt != _diagnosticStreamOpenAttempt',
      '_diagnosticWorkingOpenAttempt == _diagnosticStreamOpenAttempt',
      '_recordDiagnosticOutcome(PlaybackDiagnosticOutcome.working)',
    ]);

    final opened = _member(source, 'void _recordDiagnosticStreamOpenResult(');
    _expectInOrder(opened, const [
      '_playbackDiagnostics.streamOpened(',
      'if (!succeeded) return',
      '_diagnosticConfirmedOpenAttempt = attempt',
      'if (_videoFrameSeen) _recordDiagnosticWorkingOutcome()',
    ]);

    final openMedia = _member(source, 'Future<void> _openMedia(');
    _expectInOrder(openMedia, const [
      '_videoWatchdog?.cancel()',
      '_performanceWatchdog?.cancel()',
      'if (requireDecodedVideo)',
      '_videoFrameSeen = false',
      'await _configureNativePlayback()',
      'await waitForPlayerMediaReadiness(',
      'throw const PlayerMediaReadinessException()',
      '_recordDiagnosticStreamOpenResult(',
      'succeeded: true',
      '_startVideoWatchdog()',
    ]);

    final bootstrap = _member(source, 'Future<void> _bootstrapPlayback()');
    _expectInOrder(bootstrap, const [
      'await _openMedia(',
      'requireDecodedVideo: _animeFeaturesEnabled',
      'await _tryNextStream(error.toString())',
    ]);

    expect(
      source,
      contains(
        '_mediaOpenInProgress ||\n'
        '          _mediaOpenVerifications > 0 ||\n'
        '          _engineHandoffInProgress',
      ),
      reason:
          'player errors emitted by an opening candidate must not start '
          'a concurrent failover',
    );
  });

  test('MPV direct stream validation proxies subtitle and MIME metadata', () {
    final preflight = _member(
      _read(playerPath),
      'Future<PlaybackStreamOption?> _preflightDirectStream(',
    );
    _expectInOrder(preflight, const [
      'subtitleUri: option.stream.externalSubtitle',
      'externalSubtitle: validated.subtitleUri',
      'mediaContentType: validated.contentType',
      'subtitleContentType: validated.subtitleContentType',
      'externalSubtitleRejected: validated.subtitleRejected',
      'playbackLease: validated.session',
    ]);
  });

  test('validated redirects are deduplicated before MPV opens them', () {
    final direct = _member(
      _read(playerPath),
      'Future<bool> _switchToNextDirectStream(',
    );
    _expectInOrder(direct, const [
      'final option = await _preflightDirectStream(candidate, silent: true)',
      'validatedRedirectWasAlreadyAttempted(',
      'requested: candidate',
      'validated: option',
      'attemptedStreamKeys: _failedDirectStreamKeys',
      'await option.stream.playbackLease?.close()',
      '_failedDirectStreamKeys.add(playbackStreamOptionAttemptKey(option))',
      'await _openMedia(',
      'resume: resumePosition',
      'requireDecodedVideo: true',
    ]);
  });

  test('cross-origin validation strips credentials but preserves Referer', () {
    final proxy = _read(
      'lib/features/marketplace/data/web_playback_proxy.dart',
    );
    _expectInOrder(proxy, const [
      'await validateTarget(target)',
      'if (!_sameOrigin(target, redirected))',
      'sanitizeAddonHeaders(sanitized, stripCredentials: true)',
      'target = redirected',
    ]);

    final stripped = sanitizeWebStreamHeaders(const {
      'Authorization': 'Bearer secret',
      'Cookie': 'session=secret',
      'Referer': 'https://provider.example/',
    }, stripCredentials: true);
    expect(stripped, isNot(contains('Authorization')));
    expect(stripped, isNot(contains('Cookie')));
    expect(stripped['Referer'], 'https://provider.example/');
  });
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

String _member(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing $signature');
  final paramsOpen = source.indexOf('(', start);
  expect(paramsOpen, greaterThanOrEqualTo(0), reason: '$signature parameters');
  var parenDepth = 0;
  var paramsClose = -1;
  for (var index = paramsOpen; index < source.length; index++) {
    final code = source.codeUnitAt(index);
    if (code == 40) parenDepth++;
    if (code == 41 && --parenDepth == 0) {
      paramsClose = index;
      break;
    }
  }
  expect(paramsClose, greaterThanOrEqualTo(0), reason: '$signature parameters');
  final bodyOpen = source.indexOf('{', paramsClose + 1);
  expect(bodyOpen, greaterThanOrEqualTo(0), reason: '$signature body');
  var braceDepth = 0;
  for (var index = bodyOpen; index < source.length; index++) {
    final code = source.codeUnitAt(index);
    if (code == 123) braceDepth++;
    if (code == 125 && --braceDepth == 0) {
      return source.substring(start, index + 1);
    }
  }
  fail('Unclosed $signature');
}

String _between(String source, String startToken, String endToken) {
  final start = source.indexOf(startToken);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing $startToken');
  final end = source.indexOf(endToken, start + startToken.length);
  expect(end, greaterThan(start), reason: 'Missing $endToken');
  return source.substring(start, end);
}

void _expectInOrder(String source, List<String> tokens) {
  var previous = -1;
  for (final token in tokens) {
    final index = source.indexOf(token, previous + 1);
    expect(
      index,
      greaterThan(previous),
      reason: 'Missing/out of order: $token',
    );
    previous = index;
  }
}
