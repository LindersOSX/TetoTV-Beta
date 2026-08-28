import 'dart:io';

import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/hls_offline_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';

/// Selects the multi-file HLS downloader only for explicit HLS jobs and leaves
/// ordinary HTTPS files on the existing range-resumable Dio implementation.
final class AdaptiveOfflineDownloadTransferClient
    implements DownloadTransferClient {
  AdaptiveOfflineDownloadTransferClient({
    DownloadTransferClient? standardClient,
    DownloadTransferClient? hlsClient,
  }) : _standardClient = standardClient ?? DioDownloadTransferClient(),
       _hlsClient = hlsClient ?? HlsOfflineDownloadTransferClient();

  final DownloadTransferClient _standardClient;
  final DownloadTransferClient _hlsClient;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) {
    final client = isHlsDownloadJob(job) ? _hlsClient : _standardClient;
    return client.download(
      job: job,
      partialFile: partialFile,
      cancellation: cancellation,
      onProgress: onProgress,
      requestHeaders: requestHeaders,
    );
  }
}

/// HLS is opt-in by a recognized MIME type or an `.m3u8` source path.
bool isHlsDownloadJob(DownloadJob job) {
  final mime = job.mimeType?.split(';').first.trim().toLowerCase();
  if (_hlsMimeTypes.contains(mime)) return true;
  return job.sourceUri?.path.toLowerCase().endsWith('.m3u8') ?? false;
}

const _hlsMimeTypes = {
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
  'application/mpegurl',
  'audio/mpegurl',
  'audio/x-mpegurl',
};
