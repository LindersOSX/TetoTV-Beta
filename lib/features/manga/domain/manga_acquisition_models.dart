/// Ephemeral CBZ selection contract shared by the manga hub and downloader.
///
/// Implementations may carry an authorization capability, so they must never
/// be serialized, persisted, logged, or placed in route state.
abstract interface class MangaCbzAcquisitionSource {
  String get sourceId;
  String get publicationId;
  Uri get uri;
  String get mediaType;
  Map<String, String> get headers;
}
