import 'dart:io';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/trusted_local_artwork_registry.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class NetworkArtwork extends StatelessWidget {
  const NetworkArtwork({
    required this.url,
    this.fit = BoxFit.cover,
    this.icon = Icons.movie_outlined,
    this.cacheWidth,
    super.key,
  });

  final String? url;
  final BoxFit fit;
  final IconData icon;
  final int? cacheWidth;

  static void precache(BuildContext context, String url, {int? cacheWidth}) {
    final uri = Uri.tryParse(url);
    if (uri != null && TrustedLocalArtworkRegistry.instance.owns(uri)) {
      precacheImage(FileImage(File.fromUri(uri), scale: 1), context);
      return;
    }
    precacheImage(
      CachedNetworkImageProvider(url, maxWidth: cacheWidth ?? 800),
      context,
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = url;
    if (source == null || source.isEmpty) {
      return SizedBox.expand(child: _Fallback(icon: icon));
    }
    final uri = Uri.tryParse(source);
    if (uri != null && TrustedLocalArtworkRegistry.instance.owns(uri)) {
      return SizedBox.expand(
        child: Image.file(
          File.fromUri(uri),
          width: double.infinity,
          height: double.infinity,
          fit: fit,
          cacheWidth: cacheWidth ?? 800,
          errorBuilder: (_, _, _) => _Fallback(icon: icon),
        ),
      );
    }
    if (uri?.scheme == 'file') {
      return SizedBox.expand(child: _Fallback(icon: icon));
    }
    return SizedBox.expand(
      child: CachedNetworkImage(
        imageUrl: source,
        width: double.infinity,
        height: double.infinity,
        fit: fit,
        memCacheWidth: cacheWidth ?? 800,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => const ArtworkSkeleton(),
        errorWidget: (_, _, _) => _Fallback(icon: icon),
      ),
    );
  }
}

/// A fixed-size artwork placeholder. Its parent owns the final dimensions, so
/// poster rows never jump or stretch while an image is downloading.
class ArtworkSkeleton extends StatelessWidget {
  const ArtworkSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Semantics(
      label: 'Loading artwork',
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surfaceRaised,
            gradient: LinearGradient(
              colors: [
                palette.surfaceRaised,
                Colors.white.withValues(alpha: .055),
                palette.surfaceRaised,
              ],
              stops: const [0, .52, 1],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Icon(
              Icons.image_outlined,
              color: Color(0xFF57575F),
              size: 32,
            ),
          ),
        ),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return ColoredBox(
      color: palette.surfaceRaised,
      child: SizedBox.expand(
        child: Center(child: Icon(icon, color: palette.mutedText, size: 42)),
      ),
    );
  }
}
