import 'dart:io';

import 'package:anime_tv/features/downloads/data/hls_offline_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

typedef OfflineDownloadRootResolver = Future<Directory> Function();

class OfflineDownloadStorageException implements Exception {
  const OfflineDownloadStorageException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'OfflineDownloadStorageException($code, $message)';
}

/// Owns all filesystem paths used by persistent episode downloads.
class OfflineDownloadStorage {
  OfflineDownloadStorage({OfflineDownloadRootResolver? resolveRoot})
    : _resolveRoot = resolveRoot ?? _applicationSupportRoot;

  final OfflineDownloadRootResolver _resolveRoot;

  static Future<Directory> _applicationSupportRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'offline_downloads'));
  }

  Future<Directory> root() async {
    final directory = await _resolveRoot();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  String allocateRelativePath(OfflineDownloadRequest request, String jobId) {
    final extension = _safeExtension(
      request.fileExtension ??
          path.extension(request.sourceUri?.path ?? '').replaceFirst('.', ''),
      request.mimeType,
    );
    final safeJob = jobId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final boundedJob = safeJob.isEmpty
        ? 'download'
        : safeJob.substring(0, safeJob.length.clamp(1, 64));
    final mediaId = request.anilistMediaId.toString().padLeft(10, '0');
    final episode = request.episode.toString().padLeft(4, '0');
    return 'shows/anilist-$mediaId/season-0001/'
        'episode-$episode/$boundedJob/media.$extension';
  }

  Future<File> finalFile(DownloadJob job) => resolveFile(job.relativePath);

  Future<File> partFile(DownloadJob job) => resolveFile(job.partRelativePath);

  Future<File> resolveFile(String relativePath) async {
    _validateRelativePath(relativePath);
    final base = await root();
    final resolved = path.normalize(
      path.join(
        base.absolute.path,
        relativePath.replaceAll('/', path.separator),
      ),
    );
    if (!path.isWithin(base.absolute.path, resolved)) {
      throw const OfflineDownloadStorageException(
        'unsafe_path',
        'The download path leaves app-private storage.',
      );
    }
    return File(resolved);
  }

  Future<File> preparePartFile(DownloadJob job) async {
    final file = await partFile(job);
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    return file;
  }

  Future<int> partLength(DownloadJob job) async {
    final file = await partFile(job);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  /// Atomically promotes a validated `.part` file within the same directory.
  Future<File> finalize(DownloadJob job, {int? expectedBytes}) async {
    final partial = await partFile(job);
    if (!await partial.exists()) {
      throw const OfflineDownloadStorageException(
        'missing_partial',
        'The partial download no longer exists.',
      );
    }
    final actual = await partial.length();
    if (actual <= 0) {
      throw const OfflineDownloadStorageException(
        'empty_download',
        'The downloaded file was empty.',
      );
    }
    if (expectedBytes != null && actual != expectedBytes) {
      throw OfflineDownloadStorageException(
        'size_mismatch',
        'Expected $expectedBytes bytes but received $actual.',
      );
    }
    final destination = await finalFile(job);
    if (await destination.exists()) {
      final existingLength = await destination.length();
      if (existingLength == actual) {
        await partial.delete();
        return destination;
      }
      throw const OfflineDownloadStorageException(
        'destination_exists',
        'A different completed file already exists for this job.',
      );
    }
    final promoted = await partial.rename(destination.path);
    final promotedLength = await promoted.length();
    if (promotedLength != actual) {
      throw const OfflineDownloadStorageException(
        'promotion_failed',
        'The completed file failed validation after promotion.',
      );
    }
    return promoted;
  }

  Future<void> deleteJobFiles(DownloadJob job) async {
    final partial = await partFile(job);
    if (_isHlsJob(job)) {
      final segmentDirectory = hlsSegmentDirectoryForPartialFile(partial);
      final base = await root();
      final target = path.normalize(segmentDirectory.absolute.path);
      if (path.isWithin(base.absolute.path, target) &&
          await FileSystemEntity.type(target, followLinks: false) ==
              FileSystemEntityType.directory) {
        await Directory(target).delete(recursive: true);
      }
    }
    final progressiveValidator = File('${partial.path}.validator');
    for (final file in [partial, progressiveValidator, await finalFile(job)]) {
      if (await file.exists()) await file.delete();
      await _deleteEmptyParents(file.parent);
    }
  }

  /// Verifies the complete app-private artifact, including every local HLS
  /// resource referenced by a sanitized offline playlist.
  Future<bool> completedArtifactIsValid(DownloadJob job) async {
    try {
      final playlist = await finalFile(job);
      if (!await playlist.exists()) return false;
      final playlistLength = await playlist.length();
      if (playlistLength <= 0) return false;
      if (!_isHlsJob(job)) {
        return job.expectedBytes == null || playlistLength == job.expectedBytes;
      }
      if (playlistLength > 2 * 1024 * 1024) return false;

      final partial = await partFile(job);
      final segmentDirectory = hlsSegmentDirectoryForPartialFile(partial);
      if (await FileSystemEntity.type(
            segmentDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        return false;
      }
      final expectedDirectory = path.normalize(segmentDirectory.absolute.path);
      final text = await playlist.readAsString();
      if (!text.startsWith('#EXTM3U') || !text.contains('#EXT-X-ENDLIST')) {
        return false;
      }
      final references = <String>[
        for (final line in text.split(RegExp(r'\r?\n')))
          if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
            line.trim(),
        for (final match in RegExp(r'URI="([^"]+)"').allMatches(text))
          match.group(1)!,
      ];
      if (references.isEmpty || references.length > 20001) return false;
      for (final reference in references) {
        final uri = Uri.tryParse(reference);
        if (uri == null ||
            uri.isAbsolute ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.pathSegments.any((segment) => segment == '..')) {
          return false;
        }
        final resolved = path.normalize(
          path.join(playlist.parent.absolute.path, uri.path),
        );
        if (!path.isWithin(expectedDirectory, resolved) ||
            await FileSystemEntity.type(resolved, followLinks: false) !=
                FileSystemEntityType.file ||
            await File(resolved).length() <= 0) {
          return false;
        }
      }
      // HLS transfer progress counts downloaded media resources, while the
      // finished artifact also includes the generated local playlist. A crash
      // between atomic promotion and the database commit can therefore leave
      // a valid bundle whose persisted progress total differs from its
      // physical size. Structural validation above is authoritative; the
      // manager normalizes the completed byte count during recovery.
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on OfflineDownloadStorageException {
      return false;
    }
  }

  /// Physical size used by the Download Manager. HLS includes its sanitized
  /// playlist and every sibling segment rather than reporting only the tiny
  /// playlist file.
  Future<int> completedArtifactSize(DownloadJob job) async {
    final completed = await finalFile(job);
    var total = await completed.length();
    if (!_isHlsJob(job)) return total;
    final segments = hlsSegmentDirectoryForPartialFile(await partFile(job));
    await for (final entity in segments.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const OfflineDownloadStorageException(
          'unsafe_hls_bundle',
          'The offline HLS bundle contains an unsafe entry.',
        );
      }
      total += await File(entity.path).length();
    }
    return total;
  }

  Future<void> deleteRelativeArtifact(String relativePath) async {
    final file = await resolveFile(relativePath);
    if (await file.exists()) await file.delete();
    await _deleteEmptyParents(file.parent);
  }

  Future<int> usedBytes() async {
    final base = await root();
    var total = 0;
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A concurrent cancel/delete may remove a file between listing and
          // stat. The next refresh will report the exact total.
        }
      }
    }
    return total;
  }

  Future<void> _deleteEmptyParents(Directory directory) async {
    final base = await root();
    var current = directory;
    while (path.isWithin(base.path, current.path) &&
        current.path != base.path) {
      if (!await current.exists()) {
        current = current.parent;
        continue;
      }
      if (await current.list(followLinks: false).isEmpty) {
        await current.delete();
        current = current.parent;
      } else {
        break;
      }
    }
  }
}

void _validateRelativePath(String value) {
  final normalized = value.replaceAll('\\', '/');
  final segments = normalized.split('/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
      segments.any((segment) => segment.isEmpty || segment == '..')) {
    throw OfflineDownloadStorageException(
      'unsafe_path',
      'Invalid app-relative download path: $value',
    );
  }
}

String _safeExtension(String raw, String? mimeType) {
  final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  const videoExtensions = {
    'mkv',
    'mp4',
    'webm',
    'm4v',
    'avi',
    'mov',
    'ts',
    'm3u8',
  };
  if (videoExtensions.contains(normalized)) return normalized;
  final mime = mimeType?.toLowerCase();
  if (mime == 'video/mp4') return 'mp4';
  if (mime == 'video/webm') return 'webm';
  if (mime == 'video/x-matroska') return 'mkv';
  return 'mkv';
}

bool _isHlsJob(DownloadJob job) {
  final mime = job.mimeType?.split(';').first.trim().toLowerCase();
  return const {
        'application/vnd.apple.mpegurl',
        'application/x-mpegurl',
        'application/mpegurl',
        'audio/mpegurl',
        'audio/x-mpegurl',
      }.contains(mime) ||
      job.relativePath.toLowerCase().endsWith('.m3u8') ||
      (job.sourceUri?.path.toLowerCase().endsWith('.m3u8') ?? false);
}
