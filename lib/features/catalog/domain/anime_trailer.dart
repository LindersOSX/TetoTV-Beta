import 'package:flutter/foundation.dart';

/// Trailer hosts which can be embedded inside TetoTV.
enum AnimeTrailerProvider { youtube, dailymotion }

@immutable
class AnimeTrailer {
  const AnimeTrailer._({
    required this.provider,
    required this.videoId,
    this.thumbnailUrl,
  });

  final AnimeTrailerProvider provider;
  final String videoId;
  final String? thumbnailUrl;

  static AnimeTrailer? tryCreate({
    required Object? provider,
    required Object? videoId,
    Object? thumbnailUrl,
  }) {
    final normalizedProvider = provider?.toString().trim().toLowerCase();
    final normalizedId = videoId?.toString().trim() ?? '';
    final parsedProvider = switch (normalizedProvider) {
      'youtube' => AnimeTrailerProvider.youtube,
      'dailymotion' => AnimeTrailerProvider.dailymotion,
      _ => null,
    };
    if (parsedProvider == null || !_validId(parsedProvider, normalizedId)) {
      return null;
    }
    return AnimeTrailer._(
      provider: parsedProvider,
      videoId: normalizedId,
      thumbnailUrl: _safeThumbnail(thumbnailUrl),
    );
  }

  static bool _validId(AnimeTrailerProvider provider, String value) =>
      switch (provider) {
        AnimeTrailerProvider.youtube => RegExp(
          r'^[A-Za-z0-9_-]{11}$',
        ).hasMatch(value),
        AnimeTrailerProvider.dailymotion => RegExp(
          r'^[A-Za-z0-9]{5,16}$',
        ).hasMatch(value),
      };

  static String? _safeThumbnail(Object? value) {
    final uri = Uri.tryParse(value?.toString().trim() ?? '');
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.hasFragment) {
      return null;
    }
    return uri.toString();
  }
}
