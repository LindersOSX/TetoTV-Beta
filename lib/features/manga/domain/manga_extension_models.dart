/// One title returned by a sandboxed Seanime `manga-provider` extension.
class MangaExtensionTitle {
  MangaExtensionTitle({
    required this.providerId,
    required this.providerName,
    required this.id,
    required this.title,
    this.language = 'unknown',
    this.year,
    this.image,
    Iterable<String> synonyms = const <String>[],
    Map<String, String> imageHeaders = const <String, String>{},
  }) : synonyms = List<String>.unmodifiable(synonyms),
       imageHeaders = Map<String, String>.unmodifiable(imageHeaders);

  final String providerId;
  final String providerName;
  final String language;
  final String id;
  final String title;
  final List<String> synonyms;
  final int? year;
  final Uri? image;

  /// Ephemeral artwork capability supplied by the extension. Never persisted.
  final Map<String, String> imageHeaders;
}

/// One chapter returned by a sandboxed Seanime `manga-provider` extension.
class MangaExtensionChapter {
  const MangaExtensionChapter({
    required this.id,
    required this.title,
    required this.chapter,
    required this.index,
    this.url,
    this.scanlator,
    this.language,
    this.rating,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String chapter;
  final int index;
  final Uri? url;
  final String? scanlator;
  final String? language;
  final double? rating;
  final DateTime? updatedAt;

  double? get chapterNumber {
    final parsed = double.tryParse(chapter.trim());
    return parsed != null && parsed.isFinite && parsed > 0 && parsed <= 100000
        ? parsed
        : null;
  }
}

/// One image page returned by a sandboxed Seanime manga extension.
class MangaExtensionPage {
  MangaExtensionPage({
    required this.uri,
    required this.index,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers);

  final Uri uri;
  final int index;

  /// Ephemeral request capability. It is retained only by a reader/download
  /// request and is never written to the manga database or diagnostics.
  final Map<String, String> headers;
}
