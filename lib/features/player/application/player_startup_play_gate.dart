/// Confirms the requested play intent once a newly opened MPV file is ready.
/// Native open can publish a play state before the file finishes loading; it
/// must not become a permanent paused next episode. This is a one-shot, not an
/// auto-resume watchdog: user/room pauses and stale opens cancel the intent.
class PlayerStartupPlayGate {
  int? _pendingRevision;

  void begin(int revision, {required bool play}) {
    _pendingRevision = play ? revision : null;
  }

  void cancel() => _pendingRevision = null;

  bool take(int revision, {required bool mediaReady}) {
    if (!mediaReady || _pendingRevision != revision) return false;
    _pendingRevision = null;
    return true;
  }
}
