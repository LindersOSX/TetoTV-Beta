import 'dart:io';

import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/core/widgets/trusted_local_artwork_registry.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/data/public_catalog_artwork_client.dart';
import 'package:anime_tv/features/downloads/domain/offline_anime_snapshot_codec.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:crypto/crypto.dart';

typedef OfflineCatalogClock = DateTime Function();

class OfflineCatalogSnapshot {
  const OfflineCatalogSnapshot({
    required this.anime,
    required this.updatedAt,
    required this.hasPinnedCover,
    required this.hasPinnedBanner,
    this.artworkWarnings = const [],
  });

  final AnimeSummary anime;
  final DateTime updatedAt;
  final bool hasPinnedCover;
  final bool hasPinnedBanner;

  /// Non-fatal artwork errors. Metadata is still saved so downloads remain
  /// discoverable if a CDN is temporarily unavailable.
  final List<OfflineArtworkWarning> artworkWarnings;
}

class OfflineArtworkWarning {
  const OfflineArtworkWarning({required this.kind, required this.code});

  final OfflineArtworkKind kind;
  final String code;
}

enum OfflineArtworkKind { cover, banner }

/// Persists a complete public catalog snapshot alongside downloaded episodes.
/// Artwork failures never discard the textual snapshot.
class OfflineCatalogSnapshotService {
  OfflineCatalogSnapshotService({
    required this.repository,
    required this.storage,
    PublicCatalogArtworkFetcher? artworkFetcher,
    this.codec = const OfflineAnimeSnapshotCodec(),
    OfflineCatalogClock? clock,
  }) : _artworkFetcher = artworkFetcher ?? PublicCatalogArtworkClient(),
       _clock = clock ?? DateTime.now;

  final DownloadRepository repository;
  final OfflineDownloadStorage storage;
  final PublicCatalogArtworkFetcher _artworkFetcher;
  final OfflineAnimeSnapshotCodec codec;
  final OfflineCatalogClock _clock;

  Future<OfflineCatalogSnapshot> pin(AnimeSummary anime) async {
    final previous = await repository.mediaMetadata(anime.id);
    final previousAnime = previous == null ? null : codec.decode(previous);
    final warnings = <OfflineArtworkWarning>[];

    final cover = await _pinOrRetain(
      mediaId: anime.id,
      kind: OfflineArtworkKind.cover,
      publicUrl: anime.coverImageUrl,
      previousPublicUrl: previousAnime?.coverImageUrl,
      previousRelativePath: previous?.coverRelativePath,
      warnings: warnings,
    );
    final banner = await _pinOrRetain(
      mediaId: anime.id,
      kind: OfflineArtworkKind.banner,
      publicUrl: anime.bannerImageUrl,
      previousPublicUrl: previousAnime?.bannerImageUrl,
      previousRelativePath: previous?.bannerRelativePath,
      warnings: warnings,
    );

    final metadata = codec.encode(
      anime,
      updatedAt: _clock().toUtc(),
      coverRelativePath: cover,
      bannerRelativePath: banner,
    );
    await repository.upsertMediaMetadata(metadata);
    await _deleteReplaced(previous?.coverRelativePath, cover);
    await _deleteReplaced(previous?.bannerRelativePath, banner);
    return _materialize(metadata, warnings: warnings);
  }

  Future<OfflineCatalogSnapshot?> load(int anilistMediaId) async {
    if (anilistMediaId <= 0) return null;
    final metadata = await repository.mediaMetadata(anilistMediaId);
    return metadata == null ? null : _materialize(metadata);
  }

  Future<List<OfflineCatalogSnapshot>> list() async {
    final snapshots = await repository.listMediaMetadata();
    final result = <OfflineCatalogSnapshot>[];
    for (final snapshot in snapshots) {
      result.add(await _materialize(snapshot));
    }
    return List.unmodifiable(result);
  }

  Future<OfflineCatalogSnapshot> _materialize(
    OfflineMediaMetadata metadata, {
    List<OfflineArtworkWarning> warnings = const [],
  }) async {
    final coverUri = await _verifiedLocalArtworkUri(metadata.coverRelativePath);
    final bannerUri = await _verifiedLocalArtworkUri(
      metadata.bannerRelativePath,
    );
    if (coverUri != null) {
      TrustedLocalArtworkRegistry.instance.register(coverUri);
    }
    if (bannerUri != null) {
      TrustedLocalArtworkRegistry.instance.register(bannerUri);
    }
    return OfflineCatalogSnapshot(
      anime: codec.decode(
        metadata,
        verifiedCoverFileUri: coverUri,
        verifiedBannerFileUri: bannerUri,
      ),
      updatedAt: metadata.updatedAt,
      hasPinnedCover: coverUri != null,
      hasPinnedBanner: bannerUri != null,
      artworkWarnings: List.unmodifiable(warnings),
    );
  }

  Future<String?> _pinOrRetain({
    required int mediaId,
    required OfflineArtworkKind kind,
    required String? publicUrl,
    required String? previousPublicUrl,
    required String? previousRelativePath,
    required List<OfflineArtworkWarning> warnings,
  }) async {
    final uri = Uri.tryParse(publicUrl?.trim() ?? '');
    if (uri == null || publicUrl == null) return null;
    try {
      validatePublicArtworkUriSyntax(uri);
      final artwork = await _artworkFetcher.fetch(uri);
      return await _writeArtworkAtomically(mediaId, kind, artwork);
    } on PublicCatalogArtworkException catch (error) {
      warnings.add(OfflineArtworkWarning(kind: kind, code: error.code));
    } on FileSystemException {
      warnings.add(OfflineArtworkWarning(kind: kind, code: 'filesystem_error'));
    }
    if (publicUrl == previousPublicUrl &&
        await _verifiedLocalArtworkUri(previousRelativePath) != null) {
      return previousRelativePath;
    }
    return null;
  }

  Future<String> _writeArtworkAtomically(
    int mediaId,
    OfflineArtworkKind kind,
    PublicCatalogArtwork artwork,
  ) async {
    final digest = sha256.convert(artwork.bytes).toString().substring(0, 20);
    final relativePath =
        'artwork/$mediaId-${kind.name}-$digest.${artwork.fileExtension}';
    final destination = await storage.resolveFile(relativePath);
    if (await destination.exists()) {
      if (await _verifiedLocalArtworkUri(relativePath) == null) {
        throw const PublicCatalogArtworkException(
          'invalid_existing_artwork',
          'The existing offline artwork failed validation.',
        );
      }
      return relativePath;
    }
    if (!await destination.parent.exists()) {
      await destination.parent.create(recursive: true);
    }
    final partial = File(
      '${destination.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.part',
    );
    if (await partial.exists()) await partial.delete();
    try {
      final sink = partial.openWrite(mode: FileMode.writeOnly);
      try {
        sink.add(artwork.bytes);
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await partial.length() != artwork.bytes.length) {
        throw const PublicCatalogArtworkException(
          'short_write',
          'Offline artwork could not be written completely.',
        );
      }
      try {
        await partial.rename(destination.path);
      } on FileSystemException {
        // A simultaneous pin of the same content can win the race safely.
        if (!await destination.exists()) rethrow;
        await partial.delete();
      }
      return relativePath;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<Uri?> _verifiedLocalArtworkUri(String? relativePath) async {
    if (relativePath == null || !relativePath.startsWith('artwork/')) {
      return null;
    }
    try {
      final file = await storage.resolveFile(relativePath);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > PublicCatalogArtworkClient.defaultMaxBytes) {
        return null;
      }
      final bytes = await file.readAsBytes();
      final extension = file.path.split('.').last.toLowerCase();
      final mimeType = switch (extension) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => null,
      };
      PublicCatalogArtwork.validate(bytes: bytes, contentType: mimeType);
      return Uri.file(file.absolute.path);
    } on Object {
      return null;
    }
  }

  Future<void> _deleteReplaced(String? previous, String? current) async {
    if (previous == null || previous == current) return;
    try {
      await storage.deleteRelativeArtifact(previous);
    } on Object {
      // A stale thumbnail is harmless and can be cleaned by a later storage
      // maintenance pass; never roll back a valid metadata snapshot for it.
    }
  }
}
