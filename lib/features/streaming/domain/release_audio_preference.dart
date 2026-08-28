import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

bool releaseAdvertisesDualAudio(ReleaseCandidate release) {
  final normalized = release.releaseName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return RegExp(r'\b(?:dual|multi) audio\b').hasMatch(normalized);
}

/// Returns a source's explicit single-language intent, when it has one.
///
/// Modern web adapters carry a typed intent. Legacy torrent adapters can
/// still be understood from their established flags and release labels.
/// Dual/multi-audio is deliberately not a fixed intent: it follows the active
/// picker choice, then the viewer's global preference, unless a per-series
/// manual override exists.
PlaybackAudioPreference? releaseExplicitAudioPreference(
  ReleaseCandidate release,
) {
  switch (release.audioIntent) {
    case ReleaseAudioIntent.sub:
      return PlaybackAudioPreference.sub;
    case ReleaseAudioIntent.dub:
      return PlaybackAudioPreference.dub;
    case ReleaseAudioIntent.multi:
      return null;
    case ReleaseAudioIntent.unknown:
      break;
  }

  if (releaseAdvertisesDualAudio(release)) return null;
  if (release.isDubbed) return PlaybackAudioPreference.dub;

  final normalized = release.releaseName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (RegExp(r'\b(?:sub|subbed|subtitled)\b').hasMatch(normalized) ||
      RegExp(r'\b(?:jpn|japanese|original audio)\b').hasMatch(normalized)) {
    return PlaybackAudioPreference.sub;
  }
  if (RegExp(
    r'\b(?:dub|dubbed|eng audio|english audio)\b',
  ).hasMatch(normalized)) {
    return PlaybackAudioPreference.dub;
  }
  return null;
}

/// Resolves automatic track selection in priority order: a manual series
/// choice, the active picker choice, an explicit single-source label, then the
/// viewer's global default.
PlaybackAudioPreference preferredAudioPreferenceForRelease({
  required ReleaseCandidate release,
  required PlaybackAudioPreference globalPreference,
  PlaybackAudioPreference? requestedAudio,
  String? seriesAudioLanguage,
  bool seriesOverride = false,
}) {
  if (seriesOverride) {
    final manual = playbackAudioPreferenceForLanguage(seriesAudioLanguage);
    if (manual != null) return manual;
  }
  if (requestedAudio != null) return requestedAudio;
  return releaseExplicitAudioPreference(release) ?? globalPreference;
}

String releaseAudioPickerLabel(ReleaseCandidate release) {
  if (release.audioIntent == ReleaseAudioIntent.multi ||
      releaseAdvertisesDualAudio(release)) {
    return 'SUB / DUB';
  }
  return releaseExplicitAudioPreference(release) == PlaybackAudioPreference.dub
      ? 'DUB'
      : 'SUB';
}

/// Whether a torrent can satisfy the requested playback style.
///
/// Dual/multi-audio releases are valid for both preferences. Older source
/// adapters expose them as `isDubbed`, so treating that flag as "dub only"
/// incorrectly hid perfectly usable Japanese tracks from sub viewers.
bool releaseSupportsAudioPreference(
  ReleaseCandidate release,
  PlaybackAudioPreference preference,
) {
  final isMulti =
      release.audioIntent == ReleaseAudioIntent.multi ||
      releaseAdvertisesDualAudio(release);
  if (isMulti) return true;
  return switch (preference) {
    PlaybackAudioPreference.dub =>
      release.audioIntent == ReleaseAudioIntent.dub || release.isDubbed,
    PlaybackAudioPreference.sub =>
      release.audioIntent == ReleaseAudioIntent.sub || !release.isDubbed,
  };
}

/// Lower values are preferred. This is used when optional filters must be
/// relaxed after no matching cached release is available.
int releaseAudioPreferenceRank(
  ReleaseCandidate release,
  PlaybackAudioPreference preference,
) {
  if (!releaseSupportsAudioPreference(release, preference)) return 2;
  final isMulti =
      release.audioIntent == ReleaseAudioIntent.multi ||
      releaseAdvertisesDualAudio(release);
  if (preference == PlaybackAudioPreference.sub && isMulti) {
    // Prefer a known original-audio release, then a dual-audio release.
    return 1;
  }
  return 0;
}

bool subtitlesEnabledForAudioPreference(
  ReleaseCandidate release,
  PlaybackAudioPreference preference,
) => preference.subtitlesPreferred || !release.isDubbed;
