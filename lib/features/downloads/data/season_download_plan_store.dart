import 'dart:convert';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/domain/offline_anime_snapshot_codec.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';

/// Durable boundary for the one season preparation TetoTV supports at a time.
///
/// Only public catalog metadata and the user's non-sensitive quality/audio
/// choices are serialized. Resolved media URLs and provider credentials are
/// deliberately resolved again for each episode after restoration.
class SeasonDownloadPlanStore {
  SeasonDownloadPlanStore({
    required this.repository,
    this.codec = const OfflineAnimeSnapshotCodec(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DownloadRepository repository;
  final OfflineAnimeSnapshotCodec codec;
  final DateTime Function() _clock;

  Future<void> save(SeasonDownloadPlan plan) async {
    final snapshot = codec.encode(plan.anime, updatedAt: _clock().toUtc());
    final payload = jsonEncode(<String, Object?>{
      'schema': 1,
      'anilistMediaId': snapshot.anilistMediaId,
      'malMediaId': snapshot.malMediaId,
      'title': snapshot.title,
      'anime': snapshot.metadata,
      'episodeCount': plan.episodeCount,
      'quality': plan.quality.name,
      'sourcePolicy': plan.sourcePolicy.name,
      'preferredAudio': plan.preferredAudio.name,
    });
    await repository.savePendingSeasonDownload(
      anilistMediaId: plan.anime.id,
      planJson: payload,
      updatedAt: _clock().toUtc(),
    );
  }

  Future<SeasonDownloadPlan?> load() async {
    final payload = await repository.pendingSeasonDownloadJson();
    if (payload == null) return null;
    try {
      if (payload.length > 1048576) throw const FormatException('too large');
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
        throw const FormatException('unsupported season plan');
      }
      final mediaId = _positiveInt(decoded['anilistMediaId']);
      final title = _boundedText(decoded['title'], maximum: 500);
      final episodeCount = _positiveInt(decoded['episodeCount']);
      final animeMetadata = decoded['anime'];
      if (mediaId == null ||
          title == null ||
          episodeCount == null ||
          episodeCount > 10000 ||
          animeMetadata is! Map<String, dynamic>) {
        throw const FormatException('invalid season plan');
      }
      final quality = SeasonDownloadQuality.values.firstWhere(
        (value) => value.name == decoded['quality'],
      );
      final sourcePolicy = SeasonDownloadSourcePolicy.values.firstWhere(
        (value) => value.name == decoded['sourcePolicy'],
      );
      final preferredAudio = PlaybackAudioPreference.values.firstWhere(
        (value) => value.name == decoded['preferredAudio'],
      );
      final snapshot = OfflineMediaMetadata(
        anilistMediaId: mediaId,
        malMediaId: _positiveInt(decoded['malMediaId']),
        title: title,
        metadata: animeMetadata.cast<String, Object?>(),
        updatedAt: _clock().toUtc(),
      );
      final anime = codec.decode(snapshot);
      if (anime.id != mediaId) throw const FormatException('media mismatch');
      return SeasonDownloadPlan(
        anime: anime,
        episodeCount: episodeCount,
        quality: quality,
        sourcePolicy: sourcePolicy,
        preferredAudio: preferredAudio,
      );
    } on Object {
      // A damaged or newer incompatible request must not crash every launch or
      // retry forever. The already-completed episode jobs remain untouched.
      await repository.clearPendingSeasonDownload();
      return null;
    }
  }

  Future<void> clear() => repository.clearPendingSeasonDownload();
}

int? _positiveInt(Object? value) {
  final number = switch (value) {
    int value => value,
    num value when value.isFinite => value.toInt(),
    _ => null,
  };
  return number != null && number > 0 ? number : null;
}

String? _boundedText(Object? value, {required int maximum}) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty || text.length > maximum ? null : text;
}
