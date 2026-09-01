import 'dart:typed_data';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Secure artwork loader for covers declared by user-added manga sources.
///
/// Unlike the app's general-purpose artwork widget, this always uses
/// [MangaPageFetchClient]. That client validates and pins every public-HTTPS
/// hop, bounds and verifies the response bytes, and strips credentials when a
/// redirect changes origin.
class MangaArtwork extends ConsumerStatefulWidget {
  const MangaArtwork({
    required this.uri,
    this.sourceId,
    this.sourceUri,
    this.fit = BoxFit.cover,
    this.icon = Icons.menu_book_rounded,
    this.cacheWidth,
    super.key,
  });

  final Uri? uri;
  final String? sourceId;
  final Uri? sourceUri;
  final BoxFit fit;
  final IconData icon;
  final int? cacheWidth;

  @override
  ConsumerState<MangaArtwork> createState() => _MangaArtworkState();
}

class _MangaArtworkState extends ConsumerState<MangaArtwork> {
  late final MangaPageFetchClient _pageClient;
  late final MangaSourceCredentialStore _credentials;
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _pageClient = ref.read(mangaPageFetchClientProvider);
    _credentials = ref.read(mangaSourceCredentialStoreProvider);
    _updateRequest();
  }

  @override
  void didUpdateWidget(covariant MangaArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.sourceUri != widget.sourceUri) {
      _updateRequest();
    }
  }

  void _updateRequest() {
    final uri = widget.uri;
    _bytes = uri == null ? null : _load(uri);
  }

  Future<Uint8List> _load(Uri candidate) async {
    final uri = requireMangaPublicHttpsUri(
      candidate.toString(),
      field: 'Manga artwork URL',
    );
    var headers = const <String, String>{};
    final sourceId = widget.sourceId;
    final sourceCandidate = widget.sourceUri;
    if (sourceId != null && sourceCandidate != null) {
      final sourceUri = requireMangaPublicHttpsUri(
        sourceCandidate.toString(),
        field: 'Manga source URL',
      );
      if (_sameOrigin(sourceUri, uri)) {
        headers = await _credentials.requestHeaders(sourceId);
      }
    }
    return _pageClient.fetch(
      MangaRemotePageResource(uri: uri, headers: headers),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox.expand(child: _MangaArtworkFallback(icon: widget.icon));
    }
    return SizedBox.expand(
      child: FutureBuilder<Uint8List>(
        future: bytes,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _MangaArtworkSkeleton();
          }
          final data = snapshot.data;
          if (snapshot.hasError || data == null || data.isEmpty) {
            return _MangaArtworkFallback(icon: widget.icon);
          }
          return Image.memory(
            data,
            width: double.infinity,
            height: double.infinity,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth ?? 800,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 120),
                child: frame == null
                    ? const _MangaArtworkSkeleton(
                        key: ValueKey('manga-artwork-decoding'),
                      )
                    : child,
              );
            },
            errorBuilder: (_, _, _) => _MangaArtworkFallback(icon: widget.icon),
          );
        },
      ),
    );
  }
}

class _MangaArtworkSkeleton extends StatelessWidget {
  const _MangaArtworkSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading manga artwork',
    child: SizedBox.expand(
      key: const ValueKey('manga-artwork-loading'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.appPalette.surfaceRaised,
          gradient: LinearGradient(
            colors: <Color>[
              context.appPalette.surfaceRaised,
              Colors.white.withValues(alpha: .055),
              context.appPalette.surfaceRaised,
            ],
            stops: const <double>[0, .52, 1],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(
          child: Icon(Icons.image_outlined, color: Color(0xFF57575F), size: 32),
        ),
      ),
    ),
  );
}

class _MangaArtworkFallback extends StatelessWidget {
  const _MangaArtworkFallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.appPalette.surfaceRaised,
    child: SizedBox.expand(
      child: Center(
        child: Icon(icon, color: context.appPalette.mutedText, size: 42),
      ),
    ),
  );
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;
