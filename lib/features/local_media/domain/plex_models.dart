enum PlexMediaType { movie, show, season, episode, unknown }

PlexMediaType plexMediaTypeFromName(String? value) =>
    switch (value?.trim().toLowerCase()) {
      'movie' => PlexMediaType.movie,
      'show' => PlexMediaType.show,
      'season' => PlexMediaType.season,
      'episode' => PlexMediaType.episode,
      _ => PlexMediaType.unknown,
    };

class PlexConnection {
  const PlexConnection({
    required this.baseUri,
    required this.accessToken,
    required this.clientIdentifier,
    this.serverName,
    this.machineIdentifier,
    this.serverVersion,
  });

  final Uri baseUri;
  final String accessToken;
  final String clientIdentifier;
  final String? serverName;
  final String? machineIdentifier;
  final String? serverVersion;

  PlexConnection copyWith({
    Uri? baseUri,
    String? accessToken,
    String? clientIdentifier,
    String? serverName,
    String? machineIdentifier,
    String? serverVersion,
  }) => PlexConnection(
    baseUri: baseUri ?? this.baseUri,
    accessToken: accessToken ?? this.accessToken,
    clientIdentifier: clientIdentifier ?? this.clientIdentifier,
    serverName: serverName ?? this.serverName,
    machineIdentifier: machineIdentifier ?? this.machineIdentifier,
    serverVersion: serverVersion ?? this.serverVersion,
  );

  @override
  String toString() =>
      'PlexConnection(baseUri: $baseUri, accessToken: [redacted])';
}

class PlexServerIdentity {
  const PlexServerIdentity({
    required this.name,
    required this.machineIdentifier,
    required this.version,
  });

  final String name;
  final String machineIdentifier;
  final String version;
}

class PlexLibrary {
  const PlexLibrary({
    required this.key,
    required this.title,
    required this.type,
    this.uuid,
    this.thumb,
    this.art,
  });

  final String key;
  final String title;
  final PlexMediaType type;
  final String? uuid;
  final String? thumb;
  final String? art;

  bool get isMovieLibrary => type == PlexMediaType.movie;
  bool get isShowLibrary => type == PlexMediaType.show;
}

class PlexMediaPart {
  const PlexMediaPart({
    required this.key,
    this.id,
    this.container,
    this.file,
    this.durationMilliseconds,
    this.sizeBytes,
    this.videoCodec,
    this.audioCodec,
    this.videoWidth,
    this.videoHeight,
  });

  final String key;
  final String? id;
  final String? container;
  final String? file;
  final int? durationMilliseconds;
  final int? sizeBytes;
  final String? videoCodec;
  final String? audioCodec;
  final int? videoWidth;
  final int? videoHeight;
}

class PlexMediaItem {
  const PlexMediaItem({
    required this.ratingKey,
    required this.key,
    required this.title,
    required this.type,
    this.summary,
    this.parentTitle,
    this.grandparentTitle,
    this.year,
    this.index,
    this.parentIndex,
    this.durationMilliseconds,
    this.viewOffsetMilliseconds,
    this.thumb,
    this.art,
    this.parentThumb,
    this.grandparentThumb,
    this.parts = const [],
    this.providerIds = const {},
    this.seriesProviderIds = const {},
    this.seriesYear,
  });

  final String ratingKey;
  final String key;
  final String title;
  final PlexMediaType type;
  final String? summary;
  final String? parentTitle;
  final String? grandparentTitle;
  final int? year;
  final int? index;
  final int? parentIndex;
  final int? durationMilliseconds;
  final int? viewOffsetMilliseconds;
  final String? thumb;
  final String? art;
  final String? parentThumb;
  final String? grandparentThumb;
  final List<PlexMediaPart> parts;
  final Map<String, String> providerIds;
  final Map<String, String> seriesProviderIds;
  final int? seriesYear;

  PlexMediaItem withSeriesProviderIds(Map<String, String> value, {int? year}) =>
      PlexMediaItem(
        ratingKey: ratingKey,
        key: key,
        title: title,
        type: type,
        summary: summary,
        parentTitle: parentTitle,
        grandparentTitle: grandparentTitle,
        year: this.year,
        index: index,
        parentIndex: parentIndex,
        durationMilliseconds: durationMilliseconds,
        viewOffsetMilliseconds: viewOffsetMilliseconds,
        thumb: thumb,
        art: art,
        parentThumb: parentThumb,
        grandparentThumb: grandparentThumb,
        parts: parts,
        providerIds: providerIds,
        seriesProviderIds: Map.unmodifiable(value),
        seriesYear: year ?? seriesYear,
      );

  bool get isPlayable =>
      (type == PlexMediaType.movie || type == PlexMediaType.episode) &&
      parts.isNotEmpty;

  bool get isFolder =>
      type == PlexMediaType.show || type == PlexMediaType.season;

  PlexMediaPart? get preferredPart => parts.isEmpty ? null : parts.first;

  String get displayTitle {
    if (type != PlexMediaType.episode) return title;
    final episode = index == null
        ? ''
        : 'E${index!.toString().padLeft(2, '0')} · ';
    return '$episode$title';
  }

  String get secondaryLabel {
    if (type == PlexMediaType.episode) {
      final season = parentIndex == null ? null : 'Season $parentIndex';
      return [grandparentTitle, season].whereType<String>().join(' · ');
    }
    return switch (type) {
      PlexMediaType.movie => year?.toString() ?? 'Movie',
      PlexMediaType.show => 'Show',
      PlexMediaType.season => parentTitle ?? 'Season',
      PlexMediaType.episode => 'Episode',
      PlexMediaType.unknown => 'Media',
    };
  }
}

class PlexPage<T> {
  const PlexPage({
    required this.items,
    required this.totalCount,
    required this.offset,
    required this.nextOffset,
  });

  final List<T> items;
  final int totalCount;
  final int offset;
  final int nextOffset;
}

class PlexException implements Exception {
  const PlexException(this.message);

  final String message;

  @override
  String toString() => message;
}
