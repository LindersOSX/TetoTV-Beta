import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

typedef WatchPartyPlaybackCommand = Future<void> Function();
typedef WatchPartySeekCommand = Future<void> Function(Duration position);

/// Identifies one concrete player instance attached to a party session.
///
/// A new generation is issued whenever MPV takes ownership.
/// Late progress and commands from the previous engine are therefore inert.
class WatchPartyPlaybackEngineHandle {
  const WatchPartyPlaybackEngineHandle._({
    required this.engine,
    required this.checkpointKey,
    required this.generation,
  });

  final String engine;
  final String checkpointKey;
  final int generation;
}

class _WatchPartyPlaybackDriver {
  const _WatchPartyPlaybackDriver({
    required this.handle,
    required this.play,
    required this.pause,
    required this.seekTo,
  });

  final WatchPartyPlaybackEngineHandle handle;
  final WatchPartyPlaybackCommand play;
  final WatchPartyPlaybackCommand pause;
  final WatchPartySeekCommand seekTo;
}

/// Stable playback port owned by the player router rather than an engine.
///
/// Keeping the port above the engine widgets lets an active room survive an
/// MPV route handoff. Only public episode identity, playback timing, and
/// a one-way SHA-256 timeline fingerprint leave this boundary.
class WatchPartyPlaybackCoordinator implements WatchPartyPlaybackPort {
  factory WatchPartyPlaybackCoordinator({
    required EpisodeReference episode,
    required ReleaseCandidate release,
    PlaybackAudioPreference? requestedAudio,
  }) => WatchPartyPlaybackCoordinator._(
    episode: episode,
    release: release,
    requestedAudio: requestedAudio,
    checkpointKey: '${episode.anilistMediaId}:${episode.episode}',
  );

  /// Publishes only a sanitized public catalog identity for a locally served
  /// episode selected from the public resolver.
  ///
  /// No local item ID, filename, URL, header, checkpoint, or release
  /// fingerprint is retained or serialized through this coordinator.
  factory WatchPartyPlaybackCoordinator.publicCatalogEpisode({
    required int anilistMediaId,
    required int episode,
    required String title,
  }) {
    final safeTitle = _boundedWatchPartyTitle(title);
    if (anilistMediaId <= 0 || anilistMediaId > 100000000) {
      throw ArgumentError.value(anilistMediaId, 'anilistMediaId');
    }
    if (episode <= 0 || episode > 100000) {
      throw ArgumentError.value(episode, 'episode');
    }
    if (safeTitle == null) {
      throw ArgumentError.value(title, 'title');
    }
    return WatchPartyPlaybackCoordinator._(
      episode: EpisodeReference(
        anilistMediaId: anilistMediaId,
        episode: episode,
        title: safeTitle,
      ),
      checkpointKey: '$anilistMediaId:$episode',
    );
  }

  /// Creates a privacy boundary for Plex, Jellyfin, and local-file playback.
  ///
  /// [timelineIdentity] is a local preimage. Only its SHA-256 digest is exposed
  /// by [media]; the source URI, request headers, server token, and filename are
  /// never retained in the party model.
  factory WatchPartyPlaybackCoordinator.privateMedia({
    required String checkpointKey,
    required String timelineIdentity,
    String displayTitle = 'Private media',
  }) => WatchPartyPlaybackCoordinator._(
    checkpointKey: checkpointKey,
    privateDisplayTitle:
        _boundedWatchPartyTitle(displayTitle) ?? 'Private media',
    privateTimelineIdentity: timelineIdentity,
  );

  WatchPartyPlaybackCoordinator._({
    required this.checkpointKey,
    this._episode,
    this._release,
    this._requestedAudio,
    this._privateDisplayTitle,
    this._privateTimelineIdentity,
  });

  final StreamController<WatchPartyPlaybackSample> _samples =
      StreamController<WatchPartyPlaybackSample>.broadcast(sync: true);
  final String checkpointKey;
  EpisodeReference? _episode;
  ReleaseCandidate? _release;
  PlaybackAudioPreference? _requestedAudio;
  final String? _privateDisplayTitle;
  final String? _privateTimelineIdentity;
  _WatchPartyPlaybackDriver? _driver;
  WatchPartyPlaybackSample? _lastSample;
  List<WatchPartyTimelineAnchor> _timelineAnchors = const [];
  int _generation = 0;
  bool _disposed = false;

  @override
  Stream<WatchPartyPlaybackSample> get snapshots => _samples.stream;

  WatchPartyMedia get media => _mediaFor(Duration.zero);

  WatchPartyPlaybackEngineHandle bindEngine({
    required String engine,
    required WatchPartyPlaybackCommand play,
    required WatchPartyPlaybackCommand pause,
    required WatchPartySeekCommand seekTo,
  }) {
    if (_disposed) throw StateError('Watch Party playback is already closed.');
    final handle = WatchPartyPlaybackEngineHandle._(
      engine: engine,
      checkpointKey: checkpointKey,
      generation: ++_generation,
    );
    _driver = _WatchPartyPlaybackDriver(
      handle: handle,
      play: play,
      pause: pause,
      seekTo: seekTo,
    );
    return handle;
  }

  bool isCurrent(WatchPartyPlaybackEngineHandle handle) =>
      !_disposed && identical(_driver?.handle, handle);

  void unbindEngine(WatchPartyPlaybackEngineHandle handle) {
    if (!isCurrent(handle)) return;
    _driver = null;
  }

  void updateMedia({
    required EpisodeReference episode,
    required ReleaseCandidate release,
    PlaybackAudioPreference? requestedAudio,
  }) {
    if (_disposed || _privateTimelineIdentity != null || _release == null) {
      return;
    }
    _episode = episode;
    _release = release;
    _requestedAudio = requestedAudio;
    // Timeline markers belong to one concrete release. Keeping the previous
    // release's boundaries here would make a source fallback advertise a
    // false cross-source alignment until the new demuxer finishes loading.
    _timelineAnchors = const [];
    _lastSample = null;
  }

  void updateRequestedAudio(PlaybackAudioPreference preference) {
    if (_disposed || _privateTimelineIdentity != null || _release == null) {
      return;
    }
    _requestedAudio = preference;
    _lastSample = null;
  }

  /// Publishes only public timeline boundaries used to align different cuts.
  ///
  /// The player converts chapter/AniSkip data into these generic markers, so
  /// no chapter title, provider response, media identifier, or URL crosses the
  /// Watch Party privacy boundary.
  void updateTimelineAnchors(Iterable<WatchPartyTimelineAnchor> anchors) {
    if (_disposed) return;
    final normalized = anchors.toList(growable: false)
      ..sort((left, right) => left.position.compareTo(right.position));
    if (listEquals(_timelineAnchors, normalized)) return;
    _timelineAnchors = List<WatchPartyTimelineAnchor>.unmodifiable(normalized);
  }

  void publish(
    WatchPartyPlaybackEngineHandle handle, {
    required Duration position,
    required Duration duration,
    required bool playing,
    required bool ready,
    DateTime? sampledAt,
  }) {
    if (!isCurrent(handle) || _samples.isClosed) return;
    final safeDuration = duration.isNegative ? Duration.zero : duration;
    final upperBound = safeDuration > Duration.zero
        ? safeDuration
        : const Duration(hours: 24);
    final safePosition = position.isNegative
        ? Duration.zero
        : position > upperBound
        ? upperBound
        : position;
    final sample = WatchPartyPlaybackSample(
      media: _mediaFor(safeDuration),
      position: safePosition,
      duration: safeDuration,
      playing: playing,
      ready: ready,
      sampledAt: (sampledAt ?? DateTime.now()).toUtc(),
    );
    _lastSample = sample;
    _samples.add(sample);
  }

  void republish(WatchPartyPlaybackEngineHandle handle) {
    final sample = _lastSample;
    if (sample == null || !isCurrent(handle)) return;
    publish(
      handle,
      position: sample.position,
      duration: sample.duration,
      playing: sample.playing,
      ready: sample.ready,
    );
  }

  @override
  Future<void> play() => _run((driver) => driver.play());

  @override
  Future<void> pause() => _run((driver) => driver.pause());

  @override
  Future<void> seekTo(Duration position) => _run(
    (driver) => driver.seekTo(
      position.isNegative
          ? Duration.zero
          : position > const Duration(hours: 24)
          ? const Duration(hours: 24)
          : position,
    ),
  );

  Future<void> _run(
    Future<void> Function(_WatchPartyPlaybackDriver driver) command,
  ) async {
    final driver = _driver;
    if (_disposed || driver == null) return;
    await command(driver);
  }

  WatchPartyMedia _mediaFor(Duration duration) {
    final timelineProfile = WatchPartyTimelineProfile.tryCreate(
      duration: duration,
      anchors: _timelineAnchors,
    );
    final privateIdentity = _privateTimelineIdentity;
    if (privateIdentity != null) {
      return WatchPartyMedia(
        kind: 'private',
        title: _privateDisplayTitle ?? 'Private media',
        timelineFingerprint: watchPartyPrivateTimelineFingerprint(
          timelineIdentity: privateIdentity,
          duration: duration,
        ),
        timelineProfile: timelineProfile,
      );
    }
    final episode = _episode!;
    final release = _release;
    return WatchPartyMedia(
      kind: 'anilist',
      title: _boundedWatchPartyTitle(episode.title) ?? 'Watch Party',
      anilistId: episode.anilistMediaId,
      episode: episode.episode,
      titleEnglish: _boundedWatchPartyTitle(episode.titleEnglish),
      titleRomaji: _boundedWatchPartyTitle(episode.titleRomaji),
      year: episode.year,
      coverUrl: episode.coverImageUrl,
      timelineFingerprint: release == null
          ? null
          : watchPartyTimelineFingerprint(release: release, duration: duration),
      timelineProfile: timelineProfile,
      sourceDescriptor: release == null
          ? null
          : WatchPartySourceDescriptor.tryForRelease(
              release,
              requestedAudio: _requestedAudio,
            ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _driver = null;
    await _samples.close();
  }
}

String? _boundedWatchPartyTitle(String? value) {
  if (value == null) return null;
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return null;
  if (normalized.length <= 160) return normalized;
  var end = 160;
  final last = normalized.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return normalized.substring(0, end);
}

/// Produces a release/timeline discriminator without transmitting a URL,
/// header, token, magnet, or raw torrent hash.
String watchPartyTimelineFingerprint({
  required ReleaseCandidate release,
  Duration duration = Duration.zero,
}) {
  String normalized(String? value) =>
      value.orEmpty.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  final isTorrent = release.magnetUri.trim().isNotEmpty;
  final canonical = <String>[
    'tetotv-timeline-v1',
    isTorrent ? 'torrent' : 'direct',
    if (isTorrent) normalized(release.infoHash),
    normalized(release.sourceId),
    normalized(release.provider),
    normalized(release.releaseName),
    normalized(release.quality),
    normalized(release.codec),
    '${release.preferredFileIndex ?? -1}',
    release.isBatch ? 'batch' : 'single',
    release.audioIntent == ReleaseAudioIntent.unknown
        ? (release.isDubbed ? 'dub' : 'sub')
        : release.audioIntent.name,
    duration > Duration.zero ? '${duration.inSeconds}s' : 'duration-pending',
  ].join('\u001f');
  return sha256.convert(utf8.encode(canonical)).toString();
}

String watchPartyPrivateTimelineFingerprint({
  required String timelineIdentity,
  Duration duration = Duration.zero,
}) {
  final canonical = <String>[
    'tetotv-private-timeline-v1',
    timelineIdentity,
    duration > Duration.zero ? '${duration.inSeconds}s' : 'duration-pending',
  ].join('\u001f');
  return sha256.convert(utf8.encode(canonical)).toString();
}

extension on String? {
  String get orEmpty => this ?? '';
}
