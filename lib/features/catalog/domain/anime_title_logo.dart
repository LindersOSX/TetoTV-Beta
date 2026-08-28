enum AnimeTitleLogoSource { aniZip, fanartTvHd, fanartTv }

/// Transparent show-title artwork used only on a show's detail experience.
///
/// Catalog cards deliberately continue to use text titles. The artwork URL is
/// constrained to HTTPS by the data layer, and every UI consumer must retain a
/// text fallback because clear-logo coverage is not guaranteed.
class AnimeTitleLogo {
  const AnimeTitleLogo({
    required this.url,
    required this.source,
    this.tvdbId,
    this.languageCode,
  });

  final Uri url;
  final AnimeTitleLogoSource source;
  final int? tvdbId;
  final String? languageCode;

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'source': source.name,
    'tvdbId': tvdbId,
    'languageCode': languageCode,
  };

  static AnimeTitleLogo? fromJson(Map<String, dynamic> json) {
    final url = Uri.tryParse(json['url']?.toString() ?? '');
    final sourceName = json['source']?.toString();
    if (!_isSafeArtworkUri(url) || sourceName == null) return null;
    final source = AnimeTitleLogoSource.values
        .where((candidate) => candidate.name == sourceName)
        .firstOrNull;
    if (source == null) return null;
    return AnimeTitleLogo(
      url: url!,
      source: source,
      tvdbId: _positiveInt(json['tvdbId']),
      languageCode: _safeLanguageCode(json['languageCode']),
    );
  }
}

bool isSafeAnimeTitleLogoUri(Uri? uri) => _isSafeArtworkUri(uri);

bool _isSafeArtworkUri(Uri? uri) {
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  if (uri.userInfo.isNotEmpty || uri.hasFragment) return false;
  if (uri.hasPort && uri.port != 443) return false;
  const artworkHosts = <String>{'artworks.thetvdb.com', 'assets.fanart.tv'};
  if (!artworkHosts.contains(uri.host.toLowerCase())) return false;
  final path = uri.path.toLowerCase();
  return path.endsWith('.png') ||
      path.endsWith('.webp') ||
      path.endsWith('.jpg') ||
      path.endsWith('.jpeg');
}

int? _positiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

String? _safeLanguageCode(Object? value) {
  final normalized = value?.toString().trim().toLowerCase() ?? '';
  if (normalized.isEmpty || normalized.length > 12) return null;
  return RegExp(r'^[a-z0-9-]+$').hasMatch(normalized) ? normalized : null;
}
