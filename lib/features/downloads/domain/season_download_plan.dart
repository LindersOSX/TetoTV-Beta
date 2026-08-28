import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';

enum SeasonDownloadQuality { best, p2160, p1080, p720, p480 }

extension SeasonDownloadQualityLabel on SeasonDownloadQuality {
  String get displayName => switch (this) {
    SeasonDownloadQuality.best => 'Best available',
    SeasonDownloadQuality.p2160 => '2160p',
    SeasonDownloadQuality.p1080 => '1080p',
    SeasonDownloadQuality.p720 => '720p',
    SeasonDownloadQuality.p480 => '480p',
  };

  int? get targetHeight => switch (this) {
    SeasonDownloadQuality.best => null,
    SeasonDownloadQuality.p2160 => 2160,
    SeasonDownloadQuality.p1080 => 1080,
    SeasonDownloadQuality.p720 => 720,
    SeasonDownloadQuality.p480 => 480,
  };
}

enum SeasonDownloadSourcePolicy { automatic, debrid, web, directTorrent }

extension SeasonDownloadSourcePolicyLabel on SeasonDownloadSourcePolicy {
  String get displayName => switch (this) {
    SeasonDownloadSourcePolicy.automatic => 'Automatic',
    SeasonDownloadSourcePolicy.debrid => 'Debrid',
    SeasonDownloadSourcePolicy.web => 'Web streams',
    SeasonDownloadSourcePolicy.directTorrent => 'Direct torrent',
  };

  String get description => switch (this) {
    SeasonDownloadSourcePolicy.automatic =>
      'Configured Debrid first, then Web streams',
    SeasonDownloadSourcePolicy.debrid => 'Use the configured Debrid service',
    SeasonDownloadSourcePolicy.web => 'Use installed Web providers',
    SeasonDownloadSourcePolicy.directTorrent =>
      'Download through peers without Debrid',
  };
}

class SeasonDownloadPlan {
  const SeasonDownloadPlan({
    required this.anime,
    required this.episodeCount,
    required this.quality,
    required this.sourcePolicy,
    required this.preferredAudio,
  }) : assert(episodeCount > 0);

  final AnimeSummary anime;
  final int episodeCount;
  final SeasonDownloadQuality quality;
  final SeasonDownloadSourcePolicy sourcePolicy;
  final PlaybackAudioPreference preferredAudio;
}

class SeasonDownloadSelection {
  const SeasonDownloadSelection({
    required this.quality,
    required this.sourcePolicy,
  });

  final SeasonDownloadQuality quality;
  final SeasonDownloadSourcePolicy sourcePolicy;
}
