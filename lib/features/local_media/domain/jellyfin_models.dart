class JellyfinConnection {
  const JellyfinConnection({
    required this.baseUri,
    required this.serverName,
    required this.serverVersion,
    required this.userId,
    required this.username,
    required this.accessToken,
    required this.deviceId,
  });

  final Uri baseUri;
  final String serverName;
  final String serverVersion;
  final String userId;
  final String username;
  final String accessToken;
  final String deviceId;
}

class JellyfinServerInfo {
  const JellyfinServerInfo({
    required this.name,
    required this.version,
    required this.id,
  });

  final String name;
  final String version;
  final String id;
}

class JellyfinMediaItem {
  const JellyfinMediaItem({
    required this.id,
    required this.name,
    required this.type,
    this.seriesName,
    this.productionYear,
    this.seasonNumber,
    this.episodeNumber,
    this.runTimeTicks,
    this.primaryImageTag,
    this.mediaSourceId,
    this.container,
    this.videoCodec,
    this.videoBitDepth,
    this.videoWidth,
    this.videoHeight,
    this.audioCodec,
    this.supportsDirectPlay,
    this.audioStreams = const [],
    this.subtitleStreams = const [],
    this.overview,
    this.playbackPositionTicks,
    this.played = false,
    this.providerIds = const {},
    this.seriesProviderIds = const {},
    this.seriesProductionYear,
  });

  final String id;
  final String name;
  final String type;
  final String? seriesName;
  final int? productionYear;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? runTimeTicks;
  final String? primaryImageTag;
  final String? mediaSourceId;
  final String? container;
  final String? videoCodec;
  final int? videoBitDepth;
  final int? videoWidth;
  final int? videoHeight;
  final String? audioCodec;
  final bool? supportsDirectPlay;
  final List<JellyfinAudioStream> audioStreams;
  final List<JellyfinSubtitleStream> subtitleStreams;
  final String? overview;
  final int? playbackPositionTicks;
  final bool played;

  /// Public catalog identifiers returned by Jellyfin for this item.
  ///
  /// Only bounded provider IDs are retained by the client. Episode provider
  /// IDs identify the episode itself, so [seriesProviderIds] is populated by
  /// bounded hierarchy traversal when the parent Series is authoritative.
  final Map<String, String> providerIds;
  final Map<String, String> seriesProviderIds;
  final int? seriesProductionYear;

  JellyfinMediaItem withSeriesProviderIds(
    Map<String, String> value, {
    int? productionYear,
  }) => JellyfinMediaItem(
    id: id,
    name: name,
    type: type,
    seriesName: seriesName,
    productionYear: this.productionYear,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    runTimeTicks: runTimeTicks,
    primaryImageTag: primaryImageTag,
    mediaSourceId: mediaSourceId,
    container: container,
    videoCodec: videoCodec,
    videoBitDepth: videoBitDepth,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    audioCodec: audioCodec,
    supportsDirectPlay: supportsDirectPlay,
    audioStreams: audioStreams,
    subtitleStreams: subtitleStreams,
    overview: overview,
    playbackPositionTicks: playbackPositionTicks,
    played: played,
    providerIds: providerIds,
    seriesProviderIds: Map.unmodifiable(value),
    seriesProductionYear: productionYear ?? seriesProductionYear,
  );

  Duration get resumePosition => Duration(
    microseconds: ((playbackPositionTicks ?? 0).clamp(0, 1 << 53) / 10).round(),
  );

  Duration? get duration => runTimeTicks == null
      ? null
      : Duration(microseconds: (runTimeTicks!.clamp(0, 1 << 53) / 10).round());

  bool get isPlayable => const {'Movie', 'Episode', 'Video'}.contains(type);
  bool get isFolder => !isPlayable;

  String get displayTitle {
    if (type == 'Episode' && seriesName?.isNotEmpty == true) {
      final episode = episodeNumber == null
          ? ''
          : 'E${episodeNumber!.toString().padLeft(2, '0')} · ';
      return '$episode$name';
    }
    return name;
  }

  String get secondaryLabel {
    if (type == 'Episode') {
      final season = seasonNumber == null ? null : 'Season $seasonNumber';
      return [seriesName, season].whereType<String>().join(' · ');
    }
    return type;
  }
}

class JellyfinAudioStream {
  const JellyfinAudioStream({
    required this.index,
    this.language,
    this.isDefault = false,
  });

  final int index;
  final String? language;
  final bool isDefault;
}

class JellyfinSubtitleStream {
  const JellyfinSubtitleStream({
    required this.index,
    required this.label,
    this.language,
    this.isDefault = false,
    this.isForced = false,
  });

  final int index;
  final String label;
  final String? language;
  final bool isDefault;
  final bool isForced;
}

class JellyfinPlaybackSubtitleTrack {
  const JellyfinPlaybackSubtitleTrack({
    required this.uri,
    required this.label,
    required this.contentType,
    this.language,
  });

  final Uri uri;
  final String label;
  final String? language;
  final String contentType;
}

enum JellyfinPlayMethod {
  directPlay('DirectPlay'),
  transcode('Transcode');

  const JellyfinPlayMethod(this.serverValue);

  final String serverValue;
}

/// A token-free URL paired with the authenticated headers needed to read it.
///
/// TetoTV deliberately keeps the Jellyfin token out of the URL because URLs
/// can appear in player diagnostics and server access logs. Playback keeps
/// these headers inside an app-owned loopback proxy and rejects redirects or
/// manifest resources that leave the configured server origin.
class JellyfinPlaybackPlan {
  const JellyfinPlaybackPlan({
    required this.uri,
    required this.headers,
    required this.method,
    required this.playSessionId,
    this.mediaContentType,
    this.externalSubtitleTracks = const [],
  });

  final Uri uri;
  final Map<String, String> headers;
  final JellyfinPlayMethod method;
  final String playSessionId;
  final String? mediaContentType;
  final List<JellyfinPlaybackSubtitleTrack> externalSubtitleTracks;

  Uri? get externalSubtitleUri => externalSubtitleTracks.firstOrNull?.uri;
  String? get subtitleContentType =>
      externalSubtitleTracks.firstOrNull?.contentType;
  String? get externalSubtitleLabel =>
      externalSubtitleTracks.firstOrNull?.label;
  String? get externalSubtitleLanguage =>
      externalSubtitleTracks.firstOrNull?.language;

  bool get isTranscode => method == JellyfinPlayMethod.transcode;
}

class JellyfinLibraryPage {
  const JellyfinLibraryPage({
    required this.items,
    required this.totalCount,
    required this.nextStartIndex,
  });

  final List<JellyfinMediaItem> items;
  final int totalCount;
  final int nextStartIndex;
}

class JellyfinException implements Exception {
  const JellyfinException(this.message);

  final String message;

  @override
  String toString() => message;
}
