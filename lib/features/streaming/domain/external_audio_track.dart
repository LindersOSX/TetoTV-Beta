/// One external audio rendition that has crossed into the player boundary.
///
/// Provider URLs and request headers must be replaced by an app-owned proxy
/// URI before this model is constructed. Keeping the player model deliberately
/// small prevents native playback engines from receiving provider credentials.
final class ExternalAudioTrack {
  const ExternalAudioTrack({
    required this.uri,
    this.label,
    this.language,
    this.contentType,
  });

  final Uri uri;
  final String? label;
  final String? language;
  final String? contentType;
}

/// A provider audio reference awaiting [WebStreamValidator] validation.
///
/// This may exist only on an unselected direct-stream alternative. The player
/// must replace it with [ExternalAudioTrack] values before opening media.
final class PendingExternalAudioTrack {
  const PendingExternalAudioTrack({
    required this.uri,
    this.label,
    this.language,
    this.headers = const {},
  });

  final Uri uri;
  final String? label;
  final String? language;
  final Map<String, String> headers;
}

final class ExternalAudioAttachmentResult {
  const ExternalAudioAttachmentResult({
    required this.requestedCount,
    required this.attachedCount,
    required this.failedCount,
    required this.staleCount,
  });

  final int requestedCount;
  final int attachedCount;
  final int failedCount;
  final int staleCount;
}

/// Attaches optional sidecars independently so one unsupported track cannot
/// fail an already-open primary video. The current-open guard is rechecked
/// between every asynchronous native command.
Future<ExternalAudioAttachmentResult> attachOptionalExternalAudioTracks({
  required Iterable<ExternalAudioTrack> tracks,
  required bool Function() isCurrent,
  required Future<void> Function(ExternalAudioTrack track) attach,
}) async {
  final bounded = tracks.take(8).toList(growable: false);
  var attachedCount = 0;
  var failedCount = 0;
  var staleCount = 0;
  for (final track in bounded) {
    if (!isCurrent()) {
      staleCount = bounded.length - attachedCount - failedCount;
      break;
    }
    try {
      await attach(track);
      attachedCount++;
    } catch (_) {
      failedCount++;
    }
  }
  return ExternalAudioAttachmentResult(
    requestedCount: bounded.length,
    attachedCount: attachedCount,
    failedCount: failedCount,
    staleCount: staleCount,
  );
}
