import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter/foundation.dart';

typedef LibraryPlaybackProgressCallback =
    FutureOr<void> Function(LibraryPlaybackProgress progress);
typedef LibraryPlaybackStartedCallback =
    FutureOr<void> Function(Duration position);
typedef LibraryPlaybackFinishedCallback =
    FutureOr<void> Function(LibraryPlaybackResult result);

/// The anime-only effects available to private-library media.
///
/// Tracker writes and home checkpoints remain unavailable for every Plex,
/// Jellyfin, and device-file request. A stream selected from TetoTV's unified
/// catalog may opt into navigation and skip timing using only its validated
/// public episode identity; no private server or file identity is involved.
@immutable
class LibraryPlaybackIsolationPolicy {
  const LibraryPlaybackIsolationPolicy._({
    required this.publicCatalogEpisodeLinked,
  });

  static const isolated = LibraryPlaybackIsolationPolicy._(
    publicCatalogEpisodeLinked: false,
  );
  static const catalogLinked = LibraryPlaybackIsolationPolicy._(
    publicCatalogEpisodeLinked: true,
  );

  final bool publicCatalogEpisodeLinked;

  bool get animeTrackingEnabled => false;
  bool get animeCheckpointEnabled => false;
  bool get aniSkipEnabled => publicCatalogEpisodeLinked;
  bool get fillerNavigationEnabled => publicCatalogEpisodeLinked;
  bool get nextEpisodeEnabled => publicCatalogEpisodeLinked;
}

/// Public catalog identity which may be shared with Watch Together.
///
/// This intentionally contains only the AniList episode identity already
/// visible in TetoTV's public catalog. Private library server IDs, item IDs,
/// URLs, headers, filenames, and checkpoint identities have no place in this
/// object and therefore cannot cross the room boundary through it.
@immutable
class LibraryWatchPartyIdentity {
  LibraryWatchPartyIdentity({
    required this.anilistMediaId,
    required this.episode,
    required String title,
    this.episodeCount,
  }) : title = _publicCatalogTitle(title) {
    if (anilistMediaId <= 0 || anilistMediaId > 100000000) {
      throw ArgumentError.value(
        anilistMediaId,
        'anilistMediaId',
        'must identify a public AniList title',
      );
    }
    if (episode <= 0 || episode > 100000) {
      throw ArgumentError.value(episode, 'episode', 'is outside range');
    }
    if (episodeCount case final count?
        when count <= 0 || count > 100000 || count < episode) {
      throw ArgumentError.value(
        count,
        'episodeCount',
        'must include the selected public catalog episode',
      );
    }
  }

  final int anilistMediaId;
  final int episode;
  final String title;
  final int? episodeCount;
}

@immutable
class LibraryExternalSubtitleTrack {
  LibraryExternalSubtitleTrack({
    required this.uri,
    required String label,
    required String contentType,
    String? language,
  }) : label = _boundedLabel(label, 'Subtitles'),
       contentType = _boundedLabel(contentType, 'text/vtt'),
       language = _optionalBoundedLabel(language) {
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw ArgumentError.value(
        uri,
        'uri',
        'External library subtitles require an HTTP(S) server URL.',
      );
    }
  }

  final Uri uri;
  final String label;
  final String? language;
  final String contentType;
}

/// A capability kept entirely inside the app's playback route.
///
/// [source], [headers], and [timelineIdentity] are never copied into Watch
/// Together state. The party layer may receive [watchPartyIdentity] and a
/// one-way timeline digest only. Progress callbacks are best effort and
/// serialized by the player session.
@immutable
class LibraryPlaybackRequest {
  LibraryPlaybackRequest({
    required this.source,
    required String title,
    required String releaseName,
    required String streamLabel,
    required String checkpointKey,
    required String timelineIdentity,
    String sourceProviderId = 'library',
    String sourceProviderName = 'Your media',
    Map<String, String> headers = const {},
    this.artworkUrl,
    this.externalSubtitle,
    List<LibraryExternalSubtitleTrack> externalSubtitleTracks = const [],
    this.mediaContentType,
    this.subtitleContentType,
    this.initialPosition = Duration.zero,
    this.requestedAudio,
    this.onStarted,
    this.onProgress,
    this.onFinished,
    this.playbackLease,
    this.isCompatibilityStream = false,
    this.watchPartyDisplayTitle = 'Private media',
    this.watchPartyIdentity,
  }) : title = _requiredLabel(title, 'title'),
       releaseName = _requiredLabel(releaseName, 'releaseName'),
       streamLabel = _requiredLabel(streamLabel, 'streamLabel'),
       sourceProviderId = _providerId(sourceProviderId),
       sourceProviderName = _boundedLabel(sourceProviderName, 'Your media'),
       checkpointKey = _requiredLabel(checkpointKey, 'checkpointKey'),
       timelineIdentity = _requiredLabel(timelineIdentity, 'timelineIdentity'),
       headers = Map.unmodifiable(headers),
       externalSubtitleTracks = List.unmodifiable(
         externalSubtitleTracks.take(32),
       ) {
    if (!isSupportedLibraryPlaybackUri(source)) {
      throw ArgumentError.value(
        source,
        'source',
        'Library playback accepts only HTTP(S) or Android content URIs.',
      );
    }
    for (final header in headers.entries) {
      if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]+$').hasMatch(header.key) ||
          header.value.contains(RegExp(r'[\r\n]'))) {
        throw ArgumentError.value(
          header.key,
          'headers',
          'contains an invalid HTTP header',
        );
      }
    }
    if (headers.isNotEmpty) {
      for (final track in this.externalSubtitleTracks) {
        if (!_sameNetworkOrigin(source, track.uri)) {
          throw ArgumentError.value(
            track.uri,
            'externalSubtitleTracks',
            'Authenticated subtitles must use the media server origin.',
          );
        }
      }
      final legacySubtitle = Uri.tryParse(externalSubtitle ?? '');
      if (legacySubtitle != null &&
          legacySubtitle.hasScheme &&
          !_sameNetworkOrigin(source, legacySubtitle)) {
        throw ArgumentError.value(
          externalSubtitle,
          'externalSubtitle',
          'Authenticated subtitles must use the media server origin.',
        );
      }
    }
  }

  final Uri source;
  final String title;
  final String releaseName;
  final String streamLabel;
  final String sourceProviderId;
  final String sourceProviderName;
  final String checkpointKey;

  /// Stable local preimage used only to calculate a party timeline digest.
  /// This may be an already-hashed local checkpoint ID or a media-server item
  /// identity. It never leaves the playback coordinator.
  final String timelineIdentity;
  final Map<String, String> headers;
  final String? artworkUrl;
  final String? externalSubtitle;
  final List<LibraryExternalSubtitleTrack> externalSubtitleTracks;
  final String? mediaContentType;
  final String? subtitleContentType;
  final Duration initialPosition;
  final PlaybackAudioPreference? requestedAudio;
  final LibraryPlaybackStartedCallback? onStarted;
  final LibraryPlaybackProgressCallback? onProgress;
  final LibraryPlaybackFinishedCallback? onFinished;
  final PlaybackResourceLease? playbackLease;

  /// Whether the viewer's own media server is already converting this item
  /// to TetoTV's conservative H.264/AAC HLS compatibility profile.
  ///
  /// This flag is local control state only. It prevents a failed compatibility
  /// attempt from recursively requesting another transcode and is never copied
  /// into Watch Together or diagnostics.
  final bool isCompatibilityStream;

  /// The only private-media label eligible to enter room state. Callers must
  /// opt in to sharing a real title; local filenames stay private by default.
  final String watchPartyDisplayTitle;

  /// Present only when this private-library stream was selected from a public
  /// catalog episode. Watch Together may use this sanitized identity to keep
  /// guests on the same episode. It enables only public navigation and skip
  /// timing; tracking, checkpoints, and private source discovery stay isolated.
  final LibraryWatchPartyIdentity? watchPartyIdentity;

  LibraryPlaybackIsolationPolicy get isolation => watchPartyIdentity == null
      ? LibraryPlaybackIsolationPolicy.isolated
      : LibraryPlaybackIsolationPolicy.catalogLinked;

  bool get isContentUri => source.scheme.toLowerCase() == 'content';
}

@immutable
class LibraryPlaybackProgress {
  const LibraryPlaybackProgress({
    required this.position,
    required this.duration,
    required this.playing,
    required this.sampledAt,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final DateTime sampledAt;

  double get fraction => duration <= Duration.zero
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
}

enum LibraryPlaybackEndReason { completed, exited, failed }

enum LibraryPlaybackFailureStage { preparation, playbackStartup }

@immutable
class LibraryPlaybackResult {
  const LibraryPlaybackResult({
    required this.position,
    required this.duration,
    required this.reason,
    required this.started,
    this.error,
    this.failureStage,
  });

  final Duration position;
  final Duration duration;
  final LibraryPlaybackEndReason reason;
  final bool started;
  final String? error;
  final LibraryPlaybackFailureStage? failureStage;

  bool get completed => reason == LibraryPlaybackEndReason.completed;
  bool get failed => reason == LibraryPlaybackEndReason.failed;
}

bool isSupportedLibraryPlaybackUri(Uri source) {
  final scheme = source.scheme.toLowerCase();
  if (!const {'http', 'https', 'content'}.contains(scheme) ||
      source.userInfo.isNotEmpty ||
      source.hasFragment) {
    return false;
  }
  if (scheme == 'content') {
    return source.hasAuthority && source.authority.trim().isNotEmpty;
  }
  return source.hasAuthority && source.host.trim().isNotEmpty;
}

bool _sameNetworkOrigin(Uri left, Uri right) {
  if (!const {'http', 'https'}.contains(left.scheme.toLowerCase()) ||
      !const {'http', 'https'}.contains(right.scheme.toLowerCase())) {
    return false;
  }
  int effectivePort(Uri uri) => uri.hasPort
      ? uri.port
      : uri.scheme.toLowerCase() == 'https'
      ? 443
      : 80;
  return left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      effectivePort(left) == effectivePort(right);
}

String _requiredLabel(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name, 'is empty');
  return normalized;
}

String _providerId(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,79}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'sourceProviderId', 'is invalid');
  }
  return normalized;
}

String _boundedLabel(String value, String fallback) {
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return fallback;
  return String.fromCharCodes(normalized.runes.take(160));
}

String? _optionalBoundedLabel(String? value) {
  if (value == null) return null;
  final normalized = _boundedLabel(value, '');
  return normalized.isEmpty ? null : normalized;
}

String _publicCatalogTitle(String value) {
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || normalized.length > 240) {
    throw ArgumentError.value(value, 'title', 'is not a bounded title');
  }
  return normalized;
}
