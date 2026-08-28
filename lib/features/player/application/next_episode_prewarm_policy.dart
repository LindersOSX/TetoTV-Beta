import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:flutter/foundation.dart';

/// Bounds invisible next-episode retries for one source/audio/settings
/// generation. The first attempt is immediate; persistent misses receive at
/// most three retries before progress ticks become inert.
class NextEpisodePrewarmRetryPolicy {
  NextEpisodePrewarmRetryPolicy({
    this.retryDelays = const [
      Duration(seconds: 15),
      Duration(minutes: 1),
      Duration(minutes: 3),
    ],
  });

  final List<Duration> retryDelays;
  int _generation = 0;
  int _scheduledRetries = 0;
  DateTime? _notBefore;
  bool _exhausted = false;

  int get generation => _generation;
  int get scheduledRetries => _scheduledRetries;
  bool get exhausted => _exhausted;

  bool isCurrent(int generation) => generation == _generation;

  bool canAttempt(DateTime now) =>
      !_exhausted && (_notBefore == null || !now.isBefore(_notBefore!));

  void recordSuccess(int generation) {
    if (!isCurrent(generation)) return;
    _notBefore = null;
  }

  void recordFailure(int generation, DateTime now) {
    if (!isCurrent(generation)) return;
    if (_scheduledRetries >= retryDelays.length) {
      _exhausted = true;
      _notBefore = null;
      return;
    }
    _notBefore = now.add(retryDelays[_scheduledRetries]);
    _scheduledRetries++;
  }

  /// Stops progress ticks for a definitive end-of-series/no-playable-next
  /// result. A source, audio, or ranking-settings change starts a fresh
  /// generation through [resetGeneration].
  void recordTerminal(int generation) {
    if (!isCurrent(generation)) return;
    _exhausted = true;
    _notBefore = null;
  }

  void resetGeneration() {
    _generation++;
    _scheduledRetries = 0;
    _notBefore = null;
    _exhausted = false;
  }
}

/// Only settings consumed by next-episode discovery/ranking advance the
/// retry generation. Cosmetic or player-HUD changes must not restart work.
@immutable
class NextEpisodePrewarmSettingsKey {
  const NextEpisodePrewarmSettingsKey({
    required this.preferredAudio,
    required this.debridProvider,
    required this.debridStreamsEnabled,
    required this.webStreamsEnabled,
    required this.debridStreamSort,
    required this.streamSourcePriority,
    required this.webStreamQuality,
    required this.autoPickSourceEnabled,
    required this.autoPickSourcePriority,
    required this.autoPickQualityPriority,
    required this.autoPickAudio,
  });

  factory NextEpisodePrewarmSettingsKey.fromSettings(
    SettingsPreferences settings,
  ) => NextEpisodePrewarmSettingsKey(
    preferredAudio: settings.preferredAudio,
    debridProvider: settings.debridProvider,
    debridStreamsEnabled: settings.debridStreamsEnabled,
    webStreamsEnabled: settings.webStreamsEnabled,
    debridStreamSort: settings.debridStreamSort,
    streamSourcePriority: settings.streamSourcePriority,
    webStreamQuality: settings.webStreamQuality,
    autoPickSourceEnabled: settings.autoPickSourceEnabled,
    autoPickSourcePriority: settings.effectiveAutoPickSourcePriority,
    autoPickQualityPriority: settings.effectiveAutoPickQualityPriority,
    autoPickAudio: settings.autoPickAudio,
  );

  final PlaybackAudioPreference preferredAudio;
  final DebridService debridProvider;
  final bool debridStreamsEnabled;
  final bool webStreamsEnabled;
  final DebridStreamSort debridStreamSort;
  final StreamSourcePriority streamSourcePriority;
  final WebStreamQualityPreference webStreamQuality;
  final bool autoPickSourceEnabled;
  final List<AutoPickSourcePriority> autoPickSourcePriority;
  final List<AutoPickQuality> autoPickQualityPriority;
  final AutoPickAudio autoPickAudio;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NextEpisodePrewarmSettingsKey &&
          preferredAudio == other.preferredAudio &&
          debridProvider == other.debridProvider &&
          debridStreamsEnabled == other.debridStreamsEnabled &&
          webStreamsEnabled == other.webStreamsEnabled &&
          debridStreamSort == other.debridStreamSort &&
          streamSourcePriority == other.streamSourcePriority &&
          webStreamQuality == other.webStreamQuality &&
          autoPickSourceEnabled == other.autoPickSourceEnabled &&
          listEquals(autoPickSourcePriority, other.autoPickSourcePriority) &&
          listEquals(autoPickQualityPriority, other.autoPickQualityPriority) &&
          autoPickAudio == other.autoPickAudio;

  @override
  int get hashCode => Object.hashAll([
    preferredAudio,
    debridProvider,
    debridStreamsEnabled,
    webStreamsEnabled,
    debridStreamSort,
    streamSourcePriority,
    webStreamQuality,
    autoPickSourceEnabled,
    ...autoPickSourcePriority,
    null,
    ...autoPickQualityPriority,
    autoPickAudio,
  ]);
}
