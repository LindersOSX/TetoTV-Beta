import 'package:anime_tv/features/player/application/next_episode_prewarm_policy.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persistent misses use bounded generation-scoped backoff', () {
    final policy = NextEpisodePrewarmRetryPolicy();
    final started = DateTime.utc(2026, 8, 15, 12);
    final generation = policy.generation;

    expect(policy.canAttempt(started), isTrue);
    policy.recordFailure(generation, started);
    expect(policy.scheduledRetries, 1);
    expect(
      policy.canAttempt(started.add(const Duration(seconds: 14))),
      isFalse,
    );
    expect(policy.canAttempt(started.add(const Duration(seconds: 15))), isTrue);

    final second = started.add(const Duration(seconds: 15));
    policy.recordFailure(generation, second);
    expect(policy.scheduledRetries, 2);
    expect(policy.canAttempt(second.add(const Duration(seconds: 59))), isFalse);
    expect(policy.canAttempt(second.add(const Duration(minutes: 1))), isTrue);

    final third = second.add(const Duration(minutes: 1));
    policy.recordFailure(generation, third);
    expect(policy.scheduledRetries, 3);
    expect(policy.canAttempt(third.add(const Duration(minutes: 2))), isFalse);
    expect(policy.canAttempt(third.add(const Duration(minutes: 3))), isTrue);

    policy.recordFailure(generation, third.add(const Duration(minutes: 3)));
    expect(policy.exhausted, isTrue);
    expect(policy.canAttempt(DateTime.utc(2036)), isFalse);
  });

  test('new generation retries immediately and ignores stale completion', () {
    final policy = NextEpisodePrewarmRetryPolicy();
    final now = DateTime.utc(2026, 8, 15);
    final staleGeneration = policy.generation;
    policy.recordFailure(staleGeneration, now);

    policy.resetGeneration();
    expect(policy.canAttempt(now), isTrue);
    expect(policy.scheduledRetries, 0);
    policy.recordFailure(staleGeneration, now);
    expect(policy.scheduledRetries, 0);

    policy.recordTerminal(policy.generation);
    expect(policy.canAttempt(DateTime.utc(2036)), isFalse);
    policy.resetGeneration();
    expect(policy.canAttempt(now), isTrue);
  });

  test('only next-episode ranking settings change the generation key', () {
    const baseline = SettingsPreferences();
    final baselineKey = NextEpisodePrewarmSettingsKey.fromSettings(baseline);

    expect(
      NextEpisodePrewarmSettingsKey.fromSettings(
        baseline.copyWith(captionTextSize: 48, navigationSounds: false),
      ),
      baselineKey,
    );
    expect(
      NextEpisodePrewarmSettingsKey.fromSettings(
        baseline.copyWith(streamSourcePriority: StreamSourcePriority.webFirst),
      ),
      isNot(baselineKey),
    );
    expect(
      NextEpisodePrewarmSettingsKey.fromSettings(
        baseline.copyWith(
          autoPickSourceEnabled: true,
          autoPickSourceType: AutoPickSourceType.debridOnly,
          autoPickQuality: AutoPickQuality.p1080,
          autoPickAudio: AutoPickAudio.dubOnly,
        ),
      ),
      isNot(baselineKey),
    );
    expect(
      NextEpisodePrewarmSettingsKey.fromSettings(
        baseline.copyWith(
          autoPickQualityPriority: const [
            AutoPickQuality.p480,
            AutoPickQuality.p720,
            AutoPickQuality.p1080,
            AutoPickQuality.p2160,
          ],
        ),
      ),
      isNot(baselineKey),
    );
    expect(
      NextEpisodePrewarmSettingsKey.fromSettings(
        baseline.copyWith(
          autoPickSourcePriority: const [
            AutoPickSourcePriority.web,
            AutoPickSourcePriority.debrid,
          ],
        ),
      ),
      isNot(baselineKey),
    );
  });
}
