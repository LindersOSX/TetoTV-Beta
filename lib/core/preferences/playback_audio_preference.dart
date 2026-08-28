/// The viewer's global preference for automatic anime playback.
///
/// A dubbed preference selects an English audio track when one exists. A
/// subtitled preference keeps the original Japanese audio and enables the
/// existing subtitle-selection behavior. Players still fall back to a usable
/// track when the preferred language is absent.
enum PlaybackAudioPreference { dub, sub }

PlaybackAudioPreference? playbackAudioPreferenceForLanguage(String? value) {
  final normalized = (value ?? '').trim().toLowerCase().replaceAll('_', '-');
  if (const {'eng', 'en', 'english', 'en-us', 'en-gb'}.contains(normalized)) {
    return PlaybackAudioPreference.dub;
  }
  if (const {'jpn', 'ja', 'japanese', 'ja-jp'}.contains(normalized)) {
    return PlaybackAudioPreference.sub;
  }
  return null;
}

/// Resolves a show's explicit audio choice without changing the global
/// default used by unrelated titles.
PlaybackAudioPreference effectivePlaybackAudioPreference({
  required PlaybackAudioPreference globalPreference,
  String? seriesAudioLanguage,
  bool seriesOverride = false,
}) {
  if (seriesOverride) {
    final seriesPreference = playbackAudioPreferenceForLanguage(
      seriesAudioLanguage,
    );
    if (seriesPreference != null) return seriesPreference;
  }
  return globalPreference;
}

extension PlaybackAudioPreferenceLabel on PlaybackAudioPreference {
  String get displayName => switch (this) {
    PlaybackAudioPreference.dub => 'Dubbed',
    PlaybackAudioPreference.sub => 'Subtitled',
  };

  String get description => switch (this) {
    PlaybackAudioPreference.dub =>
      'Prefer English audio, with another available track as fallback.',
    PlaybackAudioPreference.sub =>
      'Prefer Japanese audio with English subtitles when available.',
  };

  /// ISO-639-2 code understood consistently by MPV and media servers.
  String get audioLanguage => switch (this) {
    PlaybackAudioPreference.dub => 'eng',
    PlaybackAudioPreference.sub => 'jpn',
  };

  bool get subtitlesPreferred => this == PlaybackAudioPreference.sub;

  static PlaybackAudioPreference fromStorage(String? value) =>
      PlaybackAudioPreference.values.firstWhere(
        (preference) => preference.name == value,
        orElse: () => PlaybackAudioPreference.dub,
      );
}
