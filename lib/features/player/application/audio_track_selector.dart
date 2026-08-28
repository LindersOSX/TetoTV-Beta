import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:media_kit/media_kit.dart';

/// Native MPV properties applied before a source opens.
///
/// `alang` makes MPV's first automatic choice match TetoTV's intent instead
/// of briefly (or permanently) accepting the container default. The later
/// media_kit track pass remains necessary for files whose language tag is
/// missing and whose useful language exists only in the track title.
Map<String, String> mpvPreferredAudioStartupProperties(String language) {
  final normalized = language.trim().toLowerCase().replaceAll('_', '-');
  final priority = switch (normalized) {
    'eng' || 'en' || 'english' || 'en-us' || 'en-gb' => 'eng,en',
    'jpn' || 'ja' || 'jp' || 'japanese' || 'ja-jp' => 'jpn,ja',
    'spa' || 'es' || 'spanish' => 'spa,es',
    'fra' || 'fre' || 'fr' || 'french' => 'fra,fre,fr',
    _ when RegExp(r'^[a-z]{2,3}(?:-[a-z]{2})?$').hasMatch(normalized) =>
      normalized,
    _ => null,
  };
  if (priority == null) return const {};
  return {'alang': priority, 'aid': 'auto'};
}

/// Gives a demuxer a short, bounded window to finish publishing its track
/// list. Some Android backends announce the default audio stream first and
/// add the remaining embedded streams a few frames later. Opening the picker
/// from that first snapshot makes a dual-audio file look Japanese-only.
Future<T> waitForStableTrackSnapshot<T>({
  required Future<T> Function() read,
  required Object Function(T snapshot) signature,
  required bool Function(T snapshot) hasTracks,
  bool Function(T snapshot)? isComplete,
  Duration pollInterval = const Duration(milliseconds: 200),
  Duration minimumWait = const Duration(milliseconds: 800),
  Duration maximumWait = const Duration(seconds: 2),
}) async {
  var latest = await read();
  var latestSignature = signature(latest);
  var stableSamples = 0;
  var elapsed = Duration.zero;
  while (elapsed < maximumWait) {
    await Future<void>.delayed(pollInterval);
    elapsed += pollInterval;
    final next = await read();
    final nextSignature = signature(next);
    if (nextSignature == latestSignature) {
      stableSamples++;
    } else {
      stableSamples = 0;
      latestSignature = nextSignature;
    }
    latest = next;
    final complete = isComplete?.call(latest) ?? hasTracks(latest);
    if (elapsed >= minimumWait && complete && stableSamples >= 2) {
      break;
    }
  }
  return latest;
}

/// Release names are hints, not proof, but a dual/multi-audio label tells the
/// picker to give a slow demuxer longer to publish its second embedded track.
bool releaseAdvertisesMultipleAudio(String releaseName) {
  final normalized = releaseName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return RegExp(r'\b(?:dual|multi)(?: audio)?\b').hasMatch(normalized) ||
      RegExp(r'\b(?:eng|english) (?:jpn|japanese)\b').hasMatch(normalized) ||
      RegExp(r'\b(?:jpn|japanese) (?:eng|english)\b').hasMatch(normalized);
}

String mediaKitAudioTrackSignature(Iterable<AudioTrack> tracks) => tracks
    .where((track) => track.id != 'auto' && track.id != 'no')
    .map(
      (track) => [
        track.id,
        track.title ?? '',
        track.language ?? '',
        track.codec ?? '',
        track.channelscount ?? 0,
      ].join('\u001f'),
    )
    .join('\u001e');

String mediaKitSubtitleTrackSignature(Iterable<SubtitleTrack> tracks) => tracks
    .where((track) => track.id != 'auto' && track.id != 'no')
    .map(
      (track) =>
          [track.id, track.title ?? '', track.language ?? ''].join('\u001f'),
    )
    .join('\u001e');

String? mediaKitAudioTrackDetail(AudioTrack track) {
  final values = <String>[];
  if (playerTrackMatchesEnglish(track)) {
    values.add('English');
  } else if (playerTrackMatchesJapanese(track)) {
    values.add('Japanese');
  } else if (track.language case final language?) {
    values.add(language);
  }
  if (track.codec case final codec?) values.add(codec.toUpperCase());
  if (track.channelscount case final channels?) {
    values.add('$channels channel${channels == 1 ? '' : 's'}');
  }
  return values.isEmpty ? null : values.join(' / ');
}

bool playerTrackMatchesEnglish(AudioTrack track) {
  final language = (track.language ?? '').trim().toLowerCase();
  final title = (track.title ?? '').trim().toLowerCase();
  return const {'en', 'eng', 'en-us', 'en-gb'}.contains(language) ||
      title.contains('english') ||
      title.contains('dub') ||
      title.contains('eng ');
}

bool playerTrackMatchesJapanese(AudioTrack track) {
  final language = (track.language ?? '').trim().toLowerCase();
  final title = (track.title ?? '').trim().toLowerCase();
  return const {'ja', 'jpn', 'jp', 'ja-jp'}.contains(language) ||
      title.contains('japanese') ||
      title.contains('original audio') ||
      title.contains('original language');
}

bool playerTrackMatchesAudioLanguage(AudioTrack track, String language) {
  final normalized = language.trim().toLowerCase().replaceAll('_', '-');
  if (const {'eng', 'en', 'english', 'en-us', 'en-gb'}.contains(normalized)) {
    return playerTrackMatchesEnglish(track);
  }
  if (const {'jpn', 'ja', 'japanese', 'ja-jp'}.contains(normalized)) {
    return playerTrackMatchesJapanese(track);
  }
  final trackLanguage = (track.language ?? '').trim().toLowerCase().replaceAll(
    '_',
    '-',
  );
  final title = (track.title ?? '').trim().toLowerCase();
  return trackLanguage == normalized ||
      trackLanguage.split('-').first == normalized.split('-').first ||
      title.contains(normalized);
}

bool _isCommentaryAudioTrack(AudioTrack track) {
  final title = (track.title ?? '').toLowerCase();
  return title.contains('commentary') ||
      title.contains('descriptive') ||
      title.contains('description');
}

/// Selects a stable per-series language while avoiding commentary tracks.
AudioTrack? preferredAudioTrackForLanguage(
  Iterable<AudioTrack> tracks, {
  required String language,
  bool preferSurround = false,
  bool allowFallback = true,
}) {
  final available = tracks
      .where((track) => track.id != 'auto' && track.id != 'no')
      .toList(growable: false);
  if (available.isEmpty) return null;

  int score(AudioTrack track) {
    var value = playerTrackMatchesAudioLanguage(track, language) ? 100 : 0;
    if (track.isDefault == true) value += 10;
    if (preferSurround) value += (track.channelscount ?? 0).clamp(0, 8) * 2;
    if (_isCommentaryAudioTrack(track)) {
      value -= 150;
    }
    return value;
  }

  final ranked = available.indexed.toList()
    ..sort((left, right) {
      final byScore = score(right.$2).compareTo(score(left.$2));
      return byScore != 0 ? byScore : left.$1.compareTo(right.$1);
    });
  final selected = ranked.first.$2;
  if (playerTrackMatchesAudioLanguage(selected, language)) return selected;
  if (allowFallback) return selected;

  // `allowFallback: false` keeps discovery active, but it must not leave
  // playback on an arbitrary/container-default track. Select deterministic
  // normal dialogue provisionally; the player upgrades it if the requested
  // language appears in a later track snapshot.
  return selected;
}

bool playerTrackMatchesAudioPreference(
  AudioTrack track,
  PlaybackAudioPreference preference,
) => switch (preference) {
  PlaybackAudioPreference.dub => playerTrackMatchesEnglish(track),
  PlaybackAudioPreference.sub => playerTrackMatchesJapanese(track),
};

/// Selects a deterministic track for the global dub/sub preference.
///
/// A missing preferred language falls back to the container default (or the
/// first non-commentary track) so episode transitions do not depend on which
/// order a specific player backend happens to publish its track list.
AudioTrack? preferredAudioTrack(
  Iterable<AudioTrack> tracks, {
  required PlaybackAudioPreference preference,
  bool preferSurround = false,
  bool allowFallback = true,
}) {
  final available = tracks
      .where((track) => track.id != 'auto' && track.id != 'no')
      .toList(growable: false);
  if (available.isEmpty) return null;

  int score(AudioTrack track) {
    var value = playerTrackMatchesAudioPreference(track, preference) ? 100 : 0;
    if (track.isDefault == true) value += 10;
    if (preferSurround) {
      value += (track.channelscount ?? 0).clamp(0, 8) * 2;
    }
    if (_isCommentaryAudioTrack(track)) {
      value -= 150;
    }
    return value;
  }

  final ranked = available.indexed.toList()
    ..sort((left, right) {
      final byScore = score(right.$2).compareTo(score(left.$2));
      return byScore != 0 ? byScore : left.$1.compareTo(right.$1);
    });
  final selected = ranked.first.$2;
  if (playerTrackMatchesAudioPreference(selected, preference)) return selected;
  if (allowFallback) return selected;
  return selected;
}

AudioTrack? preferredDubAudioTrack(
  Iterable<AudioTrack> tracks, {
  bool preferSurround = false,
}) {
  final selected = preferredAudioTrack(
    tracks,
    preference: PlaybackAudioPreference.dub,
    preferSurround: preferSurround,
    allowFallback: false,
  );
  return selected != null &&
          playerTrackMatchesEnglish(selected) &&
          !_isCommentaryAudioTrack(selected)
      ? selected
      : null;
}
