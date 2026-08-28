import 'dart:collection';
import 'dart:convert';

/// Durable public-catalog snapshot retained while a series has downloads.
///
/// The snapshot is deliberately versioned so future catalog model changes do
/// not make already-downloaded shows unopenable while the device is offline.
class OfflineMediaMetadata {
  OfflineMediaMetadata({
    required this.anilistMediaId,
    required this.title,
    required Map<String, Object?> metadata,
    required this.updatedAt,
    this.malMediaId,
    this.coverRelativePath,
    this.bannerRelativePath,
    this.schemaVersion = 1,
  }) : metadata = _immutableJsonMap(metadata) {
    if (anilistMediaId <= 0 || title.trim().isEmpty) {
      throw ArgumentError('Offline metadata requires a media ID and title.');
    }
    _validateOptionalRelativePath(coverRelativePath, 'coverRelativePath');
    _validateOptionalRelativePath(bannerRelativePath, 'bannerRelativePath');
  }

  final int anilistMediaId;
  final int? malMediaId;
  final String title;
  final int schemaVersion;
  final Map<String, Object?> metadata;
  final String? coverRelativePath;
  final String? bannerRelativePath;
  final DateTime updatedAt;

  Map<String, Object?> toDatabase() => {
    'anilist_media_id': anilistMediaId,
    'mal_media_id': malMediaId,
    'title': title,
    'schema_version': schemaVersion,
    'metadata_json': jsonEncode(metadata),
    'cover_relative_path': coverRelativePath,
    'banner_relative_path': bannerRelativePath,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory OfflineMediaMetadata.fromDatabase(Map<String, Object?> row) {
    final decoded = jsonDecode(row['metadata_json']! as String);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Offline media metadata is not an object.');
    }
    return OfflineMediaMetadata(
      anilistMediaId: (row['anilist_media_id']! as num).toInt(),
      malMediaId: (row['mal_media_id'] as num?)?.toInt(),
      title: row['title']! as String,
      schemaVersion: (row['schema_version'] as num?)?.toInt() ?? 1,
      metadata: decoded.cast<String, Object?>(),
      coverRelativePath: row['cover_relative_path'] as String?,
      bannerRelativePath: row['banner_relative_path'] as String?,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at']! as num).toInt(),
        isUtc: true,
      ),
    );
  }
}

/// Optional episode-specific data needed without a catalog request.
class OfflineEpisodeMetadata {
  OfflineEpisodeMetadata({
    required this.anilistMediaId,
    required this.episode,
    required Map<String, Object?> metadata,
    required this.updatedAt,
    this.duration,
    this.schemaVersion = 1,
  }) : metadata = _immutableJsonMap(metadata) {
    if (anilistMediaId <= 0 || episode <= 0) {
      throw ArgumentError('Offline episode identifiers must be positive.');
    }
    if (duration != null && duration! <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration');
    }
  }

  final int anilistMediaId;
  final int episode;
  final int schemaVersion;
  final Duration? duration;
  final Map<String, Object?> metadata;
  final DateTime updatedAt;

  Map<String, Object?> toDatabase() => {
    'anilist_media_id': anilistMediaId,
    'episode': episode,
    'schema_version': schemaVersion,
    'duration_ms': duration?.inMilliseconds,
    'metadata_json': jsonEncode(metadata),
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory OfflineEpisodeMetadata.fromDatabase(Map<String, Object?> row) {
    final decoded = jsonDecode(row['metadata_json']! as String);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Offline episode metadata is not an object.');
    }
    final durationMs = (row['duration_ms'] as num?)?.toInt();
    return OfflineEpisodeMetadata(
      anilistMediaId: (row['anilist_media_id']! as num).toInt(),
      episode: (row['episode']! as num).toInt(),
      schemaVersion: (row['schema_version'] as num?)?.toInt() ?? 1,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      metadata: decoded.cast<String, Object?>(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at']! as num).toInt(),
        isUtc: true,
      ),
    );
  }
}

Map<String, Object?> _immutableJsonMap(Map<String, Object?> value) {
  final decoded = jsonDecode(jsonEncode(value));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Metadata must be a JSON object.');
  }
  return UnmodifiableMapView(decoded.cast<String, Object?>());
}

void _validateOptionalRelativePath(String? value, String name) {
  if (value == null) return;
  final normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
      normalized.split('/').contains('..')) {
    throw ArgumentError.value(value, name, 'must be an app-relative path');
  }
}
