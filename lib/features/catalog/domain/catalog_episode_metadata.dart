/// Optional, episode-specific presentation metadata supplied by the catalog.
///
/// Every field except [episode] is nullable because many titles have only
/// partial episode data. Callers must keep their generic episode fallbacks.
class CatalogEpisodeMetadata {
  const CatalogEpisodeMetadata({
    required this.episode,
    this.title,
    this.thumbnailUrl,
    this.synopsis,
    this.durationMinutes,
  });

  final int episode;
  final String? title;
  final String? thumbnailUrl;
  final String? synopsis;
  final int? durationMinutes;
}
