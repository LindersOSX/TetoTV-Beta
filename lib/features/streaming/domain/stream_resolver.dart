import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';

class EpisodeReference {
  const EpisodeReference({
    required this.anilistMediaId,
    required this.title,
    required this.episode,
    this.malMediaId,
    this.year,
    this.alternativeTitles = const [],
    this.titleEnglish,
    this.titleRomaji,
    this.status,
    this.format,
    this.episodeCount,
    this.isAdult = false,
    this.coverImageUrl,
    this.startFromBeginning = false,
    this.autoPlay = false,
    this.publicProviderIds = const {},
  });

  final int anilistMediaId;
  final int? malMediaId;
  final int? year;
  final String title;
  final int episode;
  final List<String> alternativeTitles;
  final String? titleEnglish;
  final String? titleRomaji;
  final String? status;
  final String? format;
  final int? episodeCount;
  final bool isAdult;
  final String? coverImageUrl;
  final bool startFromBeginning;
  final bool autoPlay;

  /// Trusted public catalog crosswalks known by the caller.
  ///
  /// Keys and values are validated again by local-library matching. This map
  /// never contains a media-server ID, file identity, URL, or credential.
  /// AniList and MAL retain their dedicated typed fields above.
  final Map<String, String> publicProviderIds;
}

/// Audio intent explicitly advertised by a source adapter.
///
/// [unknown] leaves track selection to the viewer's preference. [multi]
/// means both original and dubbed audio are available, so it is also valid
/// for either viewer preference without forcing one language over the other.
enum ReleaseAudioIntent { unknown, sub, dub, multi }

class ReleaseCandidate {
  const ReleaseCandidate({
    required this.infoHash,
    required this.magnetUri,
    required this.releaseName,
    required this.seeders,
    required this.sourceId,
    this.isBatch = false,
    this.preferredFileIndex,
    this.quality,
    this.codec,
    this.sizeLabel,
    this.provider,
    this.isDubbed = false,
    this.audioIntent = ReleaseAudioIntent.unknown,
    this.hasSubtitles = false,
    this.isHdr = false,
  });

  final String infoHash;
  final String magnetUri;
  final String releaseName;
  final int seeders;
  final String sourceId;
  final bool isBatch;
  final int? preferredFileIndex;
  final String? quality;
  final String? codec;
  final String? sizeLabel;
  final String? provider;
  final bool isDubbed;
  final ReleaseAudioIntent audioIntent;
  final bool hasSubtitles;
  final bool isHdr;
}

/// Returns a stable release-group key for conventional torrent names such as
/// `[SubsPlease] Show - 01`. The group is the closest available equivalent to
/// an uploader/author across episode searches, while [ReleaseCandidate.provider]
/// identifies the repository or source that supplied the result.
String? releaseGroupKey(String releaseName) {
  final match = RegExp(r'^\s*\[([^\[\]]{1,64})\]').firstMatch(releaseName);
  final group = match?.group(1)?.trim().toLowerCase();
  if (group == null || group.isEmpty) return null;
  final normalized = group.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return normalized.isEmpty ? null : normalized;
}

/// Sub releases should start with English captions visible, while releases
/// identified as dubbed should start clean and let the viewer opt in.
bool subtitlesEnabledByDefault(ReleaseCandidate release) => !release.isDubbed;

bool releaseRequiresSoftwareDecoder(ReleaseCandidate release) {
  final codec = release.codec?.toLowerCase() ?? '';
  final name = release.releaseName.toLowerCase();
  final h264 =
      codec.contains('264') ||
      codec.contains('avc') ||
      name.contains('x264') ||
      name.contains('h.264');
  final high10 = RegExp(
    r'(?:hi10p|high[ ._-]?10|10[ ._-]?bit|yuv420p10)',
  ).hasMatch(name);
  return h264 && high10;
}

sealed class StreamResolution {
  const StreamResolution();
}

/// Runtime ownership for resources that must remain alive while an engine is
/// reading them. Implementations must make [close] idempotent.
abstract interface class PlaybackResourceLease {
  Future<void> close();
}

/// Episode identity asserted by a provider's structured title/episode lookup.
///
/// This stays separate from [StreamReady.displayName], which is presentation
/// text and may contain a server ordinal such as `Server - 1` rather than an
/// episode number. Only adapters that received structured provider metadata
/// should populate this value.
class ProviderEpisodeIdentity {
  const ProviderEpisodeIdentity({
    this.episodeNumber,
    this.seasonNumber,
    this.seriesTitle,
  });

  final int? episodeNumber;
  final int? seasonNumber;
  final String? seriesTitle;

  static ProviderEpisodeIdentity? fromFields({
    int? episodeNumber,
    int? seasonNumber,
    String? seriesTitle,
  }) {
    final normalizedTitle = seriesTitle?.trim();
    if (episodeNumber == null &&
        seasonNumber == null &&
        (normalizedTitle == null || normalizedTitle.isEmpty)) {
      return null;
    }
    return ProviderEpisodeIdentity(
      episodeNumber: episodeNumber,
      seasonNumber: seasonNumber,
      seriesTitle: normalizedTitle == null || normalizedTitle.isEmpty
          ? null
          : normalizedTitle,
    );
  }
}

class StreamReady extends StreamResolution {
  const StreamReady({
    required this.uri,
    required this.displayName,
    this.debridService,
    this.headers = const {},
    this.externalSubtitle,
    this.mediaContentType,
    this.subtitleContentType,
    this.externalSubtitleRejected = false,
    this.playbackLease,
    this.providerId,
    this.providerName,
    this.providerEpisodeIdentity,
    this.isDirectTorrent = false,
    this.isDownloaded = false,
  });

  final Uri uri;
  final String displayName;
  final DebridService? debridService;
  final Map<String, String> headers;
  final Uri? externalSubtitle;
  final String? mediaContentType;
  final String? subtitleContentType;
  final bool externalSubtitleRejected;
  final PlaybackResourceLease? playbackLease;
  final String? providerId;
  final String? providerName;
  final ProviderEpisodeIdentity? providerEpisodeIdentity;
  final bool isDirectTorrent;
  final bool isDownloaded;

  bool get isWebStream =>
      debridService == null && !isDirectTorrent && !isDownloaded;
}

class StreamCaching extends StreamResolution {
  const StreamCaching({required this.torrentId, required this.progress});

  final String torrentId;
  final double progress;
}

/// Everything the player needs to recover from a bad host without exposing
/// an unrestricted URL to arbitrary navigation or accepting non-debrid media.
class PlaybackLaunch {
  const PlaybackLaunch({
    required this.stream,
    required this.episode,
    required this.selectedRelease,
    this.requestedAudio,
    this.alternatives = const [],
    this.directAlternatives = const [],
  });

  final StreamReady stream;
  final EpisodeReference episode;
  final ReleaseCandidate selectedRelease;
  final PlaybackAudioPreference? requestedAudio;
  final List<ReleaseCandidate> alternatives;
  final List<PlaybackStreamOption> directAlternatives;
}

/// An already-discovered direct stream that the player can switch to without
/// repeating a provider search. Torrent candidates are deliberately kept in
/// [PlaybackLaunch.alternatives] until a debrid service resolves them.
class PlaybackStreamOption {
  const PlaybackStreamOption({required this.stream, required this.release});

  final StreamReady stream;
  final ReleaseCandidate release;
}

abstract interface class ReleaseSource {
  String get id;

  Future<List<ReleaseCandidate>> search(EpisodeReference episode);
}

abstract interface class StreamResolver {
  Stream<StreamResolution> resolve(EpisodeReference episode);
}

/// Scope of a debrid failure for automatic candidate failover.
///
/// Only [releaseUnavailable] can be repaired by selecting a different
/// torrent. Authentication, account, rate-limit, and provider-service errors
/// apply to every candidate and must stop automatic fan-out.
enum DebridFailureCategory {
  releaseUnavailable,
  authorization,
  account,
  rateLimited,
  serviceUnavailable,
}

/// Implemented by provider exceptions that know whether another torrent can
/// recover the request.
abstract interface class DebridProviderFailure implements Exception {
  DebridFailureCategory get failureCategory;
}

/// A missing, expired, or unrefreshable credential detected before a provider
/// client is created. This keeps all four debrid services on the same terminal
/// authorization path.
class DebridProviderAccessException implements DebridProviderFailure {
  const DebridProviderAccessException(this.service, {this.detail});

  final DebridService service;
  final String? detail;

  @override
  DebridFailureCategory get failureCategory =>
      DebridFailureCategory.authorization;

  @override
  String toString() =>
      detail ??
      '${service.displayName} is not connected. Reconnect it in Accounts.';
}

/// The selected release is not available for immediate playback from the
/// provider's cache. Resolvers use this shared failure so automatic failover
/// and the final user message behave identically for every debrid service.
class DebridCacheMissException implements Exception {
  const DebridCacheMissException(this.service, {this.detail});

  final DebridService service;
  final String? detail;

  @override
  String toString() =>
      detail ??
      'This release is not instantly cached on ${service.displayName}. '
          'TetoTV did not leave a cloud download running.';
}

/// Cleanup could not be confirmed after a debrid resolver created a
/// temporary provider-side item.
///
/// This failure is terminal: trying another release could create more items
/// while the first one may still be present in the user's account.
class DebridCleanupFailureException implements Exception {
  const DebridCleanupFailureException(this.service, {this.cause});

  final DebridService service;
  final Object? cause;

  @override
  String toString() =>
      'TetoTV could not confirm that the temporary item was removed from '
      '${service.displayName}. Automatic failover stopped to avoid adding '
      'more items. Check your ${service.displayName} dashboard and remove '
      'the item before trying again.';
}

bool isTerminalDebridCleanupFailure(Object error) =>
    error is DebridCleanupFailureException;

/// Whether retrying another torrent would only repeat a provider-wide error.
///
/// Cache misses and explicitly release-local provider errors remain eligible
/// for failover. Unclassified non-provider errors retain the historic
/// candidate-local behavior so a malformed release cannot block the list.
bool isTerminalDebridFailoverFailure(Object error) {
  if (isTerminalDebridCleanupFailure(error)) return true;
  if (error is DebridCacheMissException) return false;
  return error is DebridProviderFailure &&
      error.failureCategory != DebridFailureCategory.releaseUnavailable;
}

class SingleReleaseSource implements ReleaseSource {
  const SingleReleaseSource(this.release);

  final ReleaseCandidate release;

  @override
  String get id => release.sourceId;

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async => [
    release,
  ];
}
