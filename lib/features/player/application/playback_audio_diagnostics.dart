import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/player/application/audio_track_selector.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:media_kit/media_kit.dart';

PlaybackDiagnosticAudioIntent playbackDiagnosticAudioIntent(
  PlaybackAudioPreference? preference,
) => switch (preference) {
  PlaybackAudioPreference.sub => PlaybackDiagnosticAudioIntent.sub,
  PlaybackAudioPreference.dub => PlaybackDiagnosticAudioIntent.dub,
  null => PlaybackDiagnosticAudioIntent.unknown,
};

PlaybackDiagnosticAudioPreferenceSource
playbackDiagnosticAudioPreferenceSource({
  required ReleaseCandidate release,
  required bool seriesOverride,
  required PlaybackAudioPreference? requestedAudio,
}) {
  if (seriesOverride) {
    return PlaybackDiagnosticAudioPreferenceSource.seriesOverride;
  }
  if (requestedAudio != null) {
    return PlaybackDiagnosticAudioPreferenceSource.pickerSelection;
  }
  if (releaseExplicitAudioPreference(release) != null) {
    return PlaybackDiagnosticAudioPreferenceSource.sourceLabel;
  }
  return PlaybackDiagnosticAudioPreferenceSource.globalPreference;
}

PlaybackDiagnosticAudioCapability playbackDiagnosticAudioCapability(
  ReleaseCandidate release,
) {
  if (release.audioIntent == ReleaseAudioIntent.multi ||
      releaseAdvertisesDualAudio(release)) {
    return PlaybackDiagnosticAudioCapability.multi;
  }
  return switch (releaseExplicitAudioPreference(release)) {
    PlaybackAudioPreference.sub => PlaybackDiagnosticAudioCapability.sub,
    PlaybackAudioPreference.dub => PlaybackDiagnosticAudioCapability.dub,
    null => PlaybackDiagnosticAudioCapability.unknown,
  };
}

PlaybackDiagnosticAudioLanguage playbackDiagnosticAudioLanguage(
  AudioTrack track,
) {
  if (playerTrackMatchesEnglish(track)) {
    return PlaybackDiagnosticAudioLanguage.english;
  }
  if (playerTrackMatchesJapanese(track)) {
    return PlaybackDiagnosticAudioLanguage.japanese;
  }
  final hasMetadata =
      (track.language ?? '').trim().isNotEmpty ||
      (track.title ?? '').trim().isNotEmpty;
  return hasMetadata
      ? PlaybackDiagnosticAudioLanguage.other
      : PlaybackDiagnosticAudioLanguage.unknown;
}

int playbackDiagnosticAudioTrackCount(Iterable<AudioTrack> tracks) =>
    tracks.where((track) => track.id != 'auto' && track.id != 'no').length;

/// Suppresses repeated snapshots from one MPV open without persisting a track
/// ID. A later matching track, a manual change, or a new media revision still
/// produces a useful diagnostic event.
class PlaybackAudioDiagnosticEventGate {
  int? _mediaRevision;
  String? _trackId;
  bool? _preferenceMatched;

  bool shouldRecord({
    required int mediaRevision,
    required AudioTrack track,
    required bool preferenceMatched,
  }) {
    if (_mediaRevision == mediaRevision &&
        _trackId == track.id &&
        _preferenceMatched == preferenceMatched) {
      return false;
    }
    _mediaRevision = mediaRevision;
    _trackId = track.id;
    _preferenceMatched = preferenceMatched;
    return true;
  }
}
