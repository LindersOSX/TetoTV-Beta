import 'dart:io';

import 'package:anime_tv/features/downloads/domain/download_job.dart';

class DownloadedEpisodeAsset {
  const DownloadedEpisodeAsset({required this.job, required this.file});

  final DownloadJob job;
  final File file;

  Uri get playbackUri => file.absolute.uri;
}

/// Process-local capability registry for typed player navigation.
///
/// A URI is registered only after the repository and filesystem agree that a
/// job is completed. The router can therefore reject arbitrary `file:` URIs
/// synchronously while still allowing an issued downloaded episode.
class DownloadedPlaybackRegistry {
  DownloadedPlaybackRegistry._();

  static final instance = DownloadedPlaybackRegistry._();

  final Map<String, String> _jobByUri = {};

  void register(DownloadedEpisodeAsset asset) {
    _jobByUri[_key(asset.playbackUri)] = asset.job.id;
  }

  void unregisterJob(String jobId) {
    _jobByUri.removeWhere((_, value) => value == jobId);
  }

  bool ownsUri(Uri uri) => _jobByUri.containsKey(_key(uri));

  String? jobIdForUri(Uri uri) => _jobByUri[_key(uri)];

  void clearForTesting() => _jobByUri.clear();
}

String _key(Uri uri) => uri.normalizePath().toString();
