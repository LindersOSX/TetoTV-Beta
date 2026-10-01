import 'dart:async';

/// Bounds auxiliary teardown work without declaring the native player released.
///
/// A timed-out command may still complete later. Callers must close their
/// mutation gate first and still await the engine's authoritative dispose;
/// this helper must never be used as that decoder-ownership boundary.
Future<bool> runBestEffortPlayerCleanup(
  Future<void> Function() cleanup, {
  required Duration timeout,
}) async {
  try {
    await Future<void>.sync(cleanup).timeout(timeout);
    return true;
  } catch (_) {
    // Future.timeout continues observing the original future, including late
    // errors, while allowing the next authoritative teardown stage to proceed.
    return false;
  }
}
