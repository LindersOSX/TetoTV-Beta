/// A synchronous single-flight gate for completion and remote-control actions
/// that can race toward the same player handoff.
class PlayerHandoffGate {
  bool _entered = false;

  bool get isEntered => _entered;

  bool tryEnter() {
    if (_entered) return false;
    _entered = true;
    return true;
  }

  void leave() {
    _entered = false;
  }
}

enum PlayerFailoverClass { directWeb, debrid }

List<PlayerFailoverClass> playerFailoverClassOrder({
  required bool currentIsWeb,
}) => currentIsWeb
    ? const [PlayerFailoverClass.directWeb, PlayerFailoverClass.debrid]
    : const [PlayerFailoverClass.debrid, PlayerFailoverClass.directWeb];

/// Automatic recovery exhausts same-resolution candidates across both source
/// classes before trying another resolution. The current source class is only
/// the tie-breaker inside each quality tier.
List<bool> playerFailoverSameQualityTiers({
  required int currentQualityHeight,
}) => currentQualityHeight > 0 ? const [true, false] : const [false];

List<int> playerFailoverAudioRankTiers(Iterable<int> ranks) {
  final result = ranks.toSet().toList(growable: false)..sort();
  return result;
}

bool playerFailoverCandidateIsInQualityTier({
  required int candidateQualityHeight,
  required int currentQualityHeight,
  required bool sameQuality,
}) {
  if (currentQualityHeight <= 0) return !sameQuality;
  return (candidateQualityHeight == currentQualityHeight) == sameQuality;
}

bool playerFailoverClassIsAvailable(
  PlayerFailoverClass streamClass, {
  required bool debridAvailable,
}) => streamClass != PlayerFailoverClass.debrid || debridAvailable;

/// Ranks automatic recovery candidates without allowing resolution or source
/// affinity to override the viewer's effective Dub/Sub choice.
///
/// Current normalized quality is a soft rank after authoritative audio and
/// before provider/source affinity. The incoming order remains the final
/// tie-breaker, and manual picker ordering is intentionally independent from
/// this recovery-only policy.
List<T> rankAutomaticPlayerFailoverCandidates<T>({
  required Iterable<T> candidates,
  required int Function(T candidate) audioRank,
  required int Function(T candidate) qualityRank,
  required int Function(T candidate) affinityRank,
}) {
  final indexed = candidates.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final audio = audioRank(left.$2).compareTo(audioRank(right.$2));
    if (audio != 0) return audio;
    final quality = qualityRank(left.$2).compareTo(qualityRank(right.$2));
    if (quality != 0) return quality;
    final affinity = affinityRank(left.$2).compareTo(affinityRank(right.$2));
    return affinity != 0 ? affinity : left.$1.compareTo(right.$1);
  });
  return indexed.map((entry) => entry.$2).toList(growable: false);
}

/// Loads a prewarm dependency without sampling its state after the owning
/// player has been disposed or begun an engine handoff.
Future<List<T>?> loadPlayerPrewarmSnapshot<T>({
  required Future<void> Function() load,
  required Iterable<T> Function() snapshot,
  required bool Function() isActive,
}) async {
  await load();
  if (!isActive()) return null;
  return List<T>.unmodifiable(snapshot());
}

typedef PlayerFailoverAttempt<T> =
    Future<bool> Function(T candidate, Duration resumePosition);

typedef PlayerFailoverDelay = Future<void> Function(Duration duration);

class PlayerMediaReadinessException implements Exception {
  const PlayerMediaReadinessException();

  @override
  String toString() =>
      'No video frames were rendered after the stream was opened.';
}

/// Waits for the player to prove that a newly opened candidate can decode
/// video. `Player.open` only confirms that MPV accepted the URL; it can return
/// before a manifest, segment, or decoder has produced any media.
///
/// The wait is deliberately bounded so a dead Web candidate advances to the
/// next fallback instead of holding the player on a black screen. Tests may
/// inject [delay] to avoid wall-clock waits.
Future<bool> waitForPlayerMediaReadiness({
  required bool Function() hasDecodedVideo,
  required bool Function() isActive,
  int maxPolls = 60,
  Duration pollInterval = const Duration(milliseconds: 200),
  PlayerFailoverDelay delay = Future<void>.delayed,
}) async {
  if (!isActive()) return false;
  if (hasDecodedVideo()) return true;
  if (maxPolls <= 0) return false;
  for (var poll = 0; poll < maxPolls; poll++) {
    await delay(pollInterval);
    if (!isActive()) return false;
    if (hasDecodedVideo()) return true;
  }
  return false;
}

/// Waits only a small, explicit window for a background discovery stream to
/// publish candidates. Tests can inject the delay without using wall-clock
/// time; production uses [Future.delayed].
Future<List<T>> waitForPlayerFailoverCandidates<T>({
  required Iterable<T> Function() snapshot,
  required bool Function() isActive,
  int maxPolls = 4,
  Duration pollInterval = const Duration(milliseconds: 150),
  PlayerFailoverDelay delay = Future<void>.delayed,
}) async {
  var available = snapshot().toList(growable: false);
  if (available.isNotEmpty || maxPolls <= 0) return available;
  for (var poll = 0; poll < maxPolls; poll++) {
    await delay(pollInterval);
    if (!isActive()) return const [];
    available = snapshot().toList(growable: false);
    if (available.isNotEmpty) return available;
  }
  return available;
}

/// Tries a bounded candidate list sequentially and accepts only a result that
/// completed while the owning player is still active.
///
/// Candidate-local preflight/open failures are intentionally isolated so one
/// broken host or decoder cannot prevent the next candidate from being tried.
Future<T?> openFirstViablePlayerCandidate<T>({
  required Iterable<T> candidates,
  required Duration resumePosition,
  required bool Function() isActive,
  required PlayerFailoverAttempt<T> attempt,
  int maxCandidates = 12,
}) async {
  if (maxCandidates <= 0) return null;
  var attempted = 0;
  for (final candidate in candidates) {
    if (attempted++ >= maxCandidates || !isActive()) return null;
    try {
      final opened = await attempt(candidate, resumePosition);
      if (!isActive()) return null;
      if (opened) return candidate;
    } catch (_) {
      if (!isActive()) return null;
      // The next bounded candidate may still be viable.
    }
  }
  return null;
}
