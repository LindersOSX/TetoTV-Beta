/// Do not add a title merely because a stream was selected or prepared.
/// Both engines use actual unpaused playback with decoded video and a nonzero
/// timeline, excluding buffering, provisional seeks, opens and teardown.
bool playbackCanStartTracking({
  required bool playing,
  required bool buffering,
  required bool decodedVideo,
  required bool opening,
  required bool closing,
  required bool provisionalSeek,
  required Duration position,
}) =>
    playing &&
    !buffering &&
    decodedVideo &&
    !opening &&
    !closing &&
    !provisionalSeek &&
    position > Duration.zero;
