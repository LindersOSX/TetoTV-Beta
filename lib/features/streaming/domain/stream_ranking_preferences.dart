import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

/// The viewer's default ordering for torrent/debrid results.
///
/// These are ranking preferences, never hard filters. Audio compatibility is
/// intentionally evaluated before every mode so a quality/size preference
/// cannot silently override the selected Dub/Sub playback style.
enum DebridStreamSort { bestQuality, mostSeeded, largestSize, smallestSize }

extension DebridStreamSortLabel on DebridStreamSort {
  String get displayName => switch (this) {
    DebridStreamSort.bestQuality => 'Best quality',
    DebridStreamSort.mostSeeded => 'Most seeded',
    DebridStreamSort.largestSize => 'Largest size',
    DebridStreamSort.smallestSize => 'Smallest size',
  };

  String get description => switch (this) {
    DebridStreamSort.bestQuality => 'Highest resolution first',
    DebridStreamSort.mostSeeded => 'Most available peers first',
    DebridStreamSort.largestSize => 'Largest release first',
    DebridStreamSort.smallestSize => 'Smallest release first',
  };
}

enum StreamSourcePriority { debridFirst, webFirst }

extension StreamSourcePriorityLabel on StreamSourcePriority {
  String get displayName => switch (this) {
    StreamSourcePriority.debridFirst => 'Debrid first',
    StreamSourcePriority.webFirst => 'Web first',
  };

  String get description => switch (this) {
    StreamSourcePriority.debridFirst => 'Prefer cached torrent releases',
    StreamSourcePriority.webFirst => 'Prefer installed Web providers',
  };
}

enum StreamSourceClass { debrid, web }

/// Preferred Web quality is a soft ranking. A usable stream at another
/// quality remains visible and can still be selected or used as failover.
enum WebStreamQualityPreference { bestAvailable, p2160, p1080, p720, p480 }

extension WebStreamQualityPreferenceLabel on WebStreamQualityPreference {
  String get displayName => switch (this) {
    WebStreamQualityPreference.bestAvailable => 'Best available',
    WebStreamQualityPreference.p2160 => '4K',
    WebStreamQualityPreference.p1080 => '1080p',
    WebStreamQualityPreference.p720 => '720p',
    WebStreamQualityPreference.p480 => '480p',
  };

  String get description => switch (this) {
    WebStreamQualityPreference.bestAvailable => 'Highest quality first',
    WebStreamQualityPreference.p2160 => 'Rank 4K closest',
    WebStreamQualityPreference.p1080 => 'Rank 1080p closest',
    WebStreamQualityPreference.p720 => 'Rank 720p closest',
    WebStreamQualityPreference.p480 => 'Rank 480p closest',
  };

  int? get targetHeight => switch (this) {
    WebStreamQualityPreference.bestAvailable => null,
    WebStreamQualityPreference.p2160 => 2160,
    WebStreamQualityPreference.p1080 => 1080,
    WebStreamQualityPreference.p720 => 720,
    WebStreamQualityPreference.p480 => 480,
  };
}

int compareStreamSourceClasses(
  StreamSourceClass left,
  StreamSourceClass right,
  StreamSourcePriority priority, {
  int leftAudioRank = 0,
  int rightAudioRank = 0,
}) {
  final audio = leftAudioRank.compareTo(rightAudioRank);
  if (audio != 0) return audio;
  if (left == right) return 0;
  final preferred = switch (priority) {
    StreamSourcePriority.debridFirst => StreamSourceClass.debrid,
    StreamSourcePriority.webFirst => StreamSourceClass.web,
  };
  return left == preferred ? -1 : 1;
}

int compareReleaseCandidates(
  ReleaseCandidate left,
  ReleaseCandidate right, {
  required DebridStreamSort sort,
  required PlaybackAudioPreference preferredAudio,
}) {
  final audio = releaseAudioPreferenceRank(
    left,
    preferredAudio,
  ).compareTo(releaseAudioPreferenceRank(right, preferredAudio));
  if (audio != 0) return audio;

  final primary = switch (sort) {
    DebridStreamSort.bestQuality => _compareReleaseQuality(left, right),
    DebridStreamSort.mostSeeded => right.seeders.compareTo(left.seeders),
    DebridStreamSort.largestSize => _compareReleaseSize(
      left,
      right,
      largestFirst: true,
    ),
    DebridStreamSort.smallestSize => _compareReleaseSize(
      left,
      right,
      largestFirst: false,
    ),
  };
  if (primary != 0) return primary;

  final quality = _compareReleaseQuality(left, right);
  if (quality != 0) return quality;
  final seeders = right.seeders.compareTo(left.seeders);
  if (seeders != 0) return seeders;
  final name = left.releaseName.toLowerCase().compareTo(
    right.releaseName.toLowerCase(),
  );
  if (name != 0) return name;
  return left.infoHash.toLowerCase().compareTo(right.infoHash.toLowerCase());
}

List<ReleaseCandidate> rankReleaseCandidates(
  Iterable<ReleaseCandidate> candidates, {
  required DebridStreamSort sort,
  required PlaybackAudioPreference preferredAudio,
}) => [...candidates]
  ..sort(
    (left, right) => compareReleaseCandidates(
      left,
      right,
      sort: sort,
      preferredAudio: preferredAudio,
    ),
  );

int compareWebStreamCandidates(
  WebStreamResult left,
  WebStreamResult right, {
  required WebStreamQualityPreference quality,
  required PlaybackAudioPreference preferredAudio,
}) {
  final leftAudio = webStreamAudioPreferenceRank(left, preferredAudio);
  final rightAudio = webStreamAudioPreferenceRank(right, preferredAudio);
  final audio = leftAudio.compareTo(rightAudio);
  if (audio != 0) return audio;

  final preferredQuality = _compareWebQuality(left, right, quality);
  if (preferredQuality != 0) return preferredQuality;
  final provider = left.providerName.toLowerCase().compareTo(
    right.providerName.toLowerCase(),
  );
  if (provider != 0) return provider;
  final title = left.title.toLowerCase().compareTo(right.title.toLowerCase());
  if (title != 0) return title;
  return left.uri.toString().compareTo(right.uri.toString());
}

List<WebStreamResult> rankWebStreamCandidates(
  Iterable<WebStreamResult> candidates, {
  required WebStreamQualityPreference quality,
  required PlaybackAudioPreference preferredAudio,
}) => [...candidates]
  ..sort(
    (left, right) => compareWebStreamCandidates(
      left,
      right,
      quality: quality,
      preferredAudio: preferredAudio,
    ),
  );

int releaseQualityHeight(ReleaseCandidate release) =>
    _qualityHeight('${release.quality ?? ''} ${release.releaseName}');

int webStreamQualityHeight(WebStreamResult stream) =>
    _qualityHeight('${stream.quality ?? ''} ${stream.title}');

/// Soft affinity for keeping automatic fallback at the current stream's
/// normalized resolution. Unknown or unavailable quality never filters a
/// candidate; it only removes the affinity advantage.
int automaticQualityAffinityRank(
  int candidateHeight,
  int? preferredQualityHeight,
) {
  if (preferredQualityHeight == null || preferredQualityHeight <= 0) return 0;
  return candidateHeight == preferredQualityHeight ? 0 : 1;
}

double? releaseSizeBytes(ReleaseCandidate release) {
  final value = release.sizeLabel?.trim().toUpperCase();
  if (value == null || value.isEmpty) return null;
  final match = RegExp(
    r'(\d+(?:\.\d+)?)\s*(TB|GB|MB|KB|B)\b',
  ).firstMatch(value);
  final amount = double.tryParse(match?.group(1) ?? '');
  if (amount == null || !amount.isFinite || amount < 0) return null;
  return amount *
      switch (match!.group(2)) {
        'TB' => 1099511627776,
        'GB' => 1073741824,
        'MB' => 1048576,
        'KB' => 1024,
        _ => 1,
      };
}

int _compareReleaseQuality(ReleaseCandidate left, ReleaseCandidate right) =>
    releaseQualityHeight(right).compareTo(releaseQualityHeight(left));

int _compareReleaseSize(
  ReleaseCandidate left,
  ReleaseCandidate right, {
  required bool largestFirst,
}) {
  final leftSize = releaseSizeBytes(left);
  final rightSize = releaseSizeBytes(right);
  // Unknown sizes remain usable but never outrank a known size.
  if (leftSize == null || rightSize == null) {
    if (leftSize == rightSize) return 0;
    return leftSize == null ? 1 : -1;
  }
  return largestFirst
      ? rightSize.compareTo(leftSize)
      : leftSize.compareTo(rightSize);
}

/// Authoritative Dub/Sub rank for a Web result. This is public so callers
/// comparing Web and Debrid source classes can keep audio ahead of the
/// viewer's source-class preference.
int webStreamAudioPreferenceRank(
  WebStreamResult stream,
  PlaybackAudioPreference preference,
) {
  final supported = switch (preference) {
    PlaybackAudioPreference.dub => stream.supportsDubAudio,
    PlaybackAudioPreference.sub => stream.supportsSubAudio,
  };
  if (supported) return 0;
  // Unknown remains a visible All-filter fallback, but it never outranks a
  // source whose provider explicitly reported the requested capability.
  if (!stream.hasKnownAudioCapability) return 1;
  return 2;
}

int _compareWebQuality(
  WebStreamResult left,
  WebStreamResult right,
  WebStreamQualityPreference preference,
) {
  final leftHeight = webStreamQualityHeight(left);
  final rightHeight = webStreamQualityHeight(right);
  if (preference.targetHeight case final target?) {
    final leftDistance = leftHeight == 0
        ? 1 << 30
        : (leftHeight - target).abs();
    final rightDistance = rightHeight == 0
        ? 1 << 30
        : (rightHeight - target).abs();
    final distance = leftDistance.compareTo(rightDistance);
    if (distance != 0) return distance;
  }
  return rightHeight.compareTo(leftHeight);
}

int _qualityHeight(String source) {
  final value = source.toLowerCase();
  if (value.contains('8k') || value.contains('4320')) return 4320;
  if (value.contains('4k') || value.contains('uhd') || value.contains('2160')) {
    return 2160;
  }
  if (value.contains('2k') || value.contains('1440')) return 1440;
  if (value.contains('full hd') || value.contains('1080')) return 1080;
  if (value.contains('720') || RegExp(r'\bhd\b').hasMatch(value)) return 720;
  if (value.contains('576')) return 576;
  if (value.contains('480')) return 480;
  if (value.contains('360')) return 360;
  if (value.contains('240')) return 240;
  return 0;
}

/// Compatibility score shared by the visible resolver and invisible
/// next-episode preparation. Lower values are safer for the current TV.
int tvPlaybackCompatibilityScore(
  ReleaseCandidate release, {
  TvDeviceProfile? device,
  int previousFailures = 0,
}) {
  final codec = release.codec?.toUpperCase();
  final codecRank = switch (codec) {
    'H.264' => 0,
    null => 1,
    'HEVC' => 2,
    'AV1' => 3,
    _ => 1,
  };
  final resolutionPenalty = switch (release.quality?.toLowerCase()) {
    '4k' || '2160p' => 2,
    '1440p' => 1,
    _ => 0,
  };
  final unsupportedCodec =
      device != null && !device.supportsCodec(release.codec) ? 12 : 0;
  final unsupportedHdr = release.isHdr && device != null && !device.hasHdr
      ? 8
      : 0;
  final softwareOnlyProfile = releaseRequiresSoftwareDecoder(release) ? 6 : 0;
  return codecRank +
      resolutionPenalty +
      (release.isHdr ? 2 : 0) +
      unsupportedCodec +
      unsupportedHdr +
      softwareOnlyProfile +
      previousFailures * 5;
}

/// Hard safety signals for invisible playback. Viewer-selected quality stays
/// meaningful on capable TVs; only a known unsupported codec/HDR path,
/// software-only profile, or observed failures outrank that preference.
int automaticPlaybackSafetyScore(
  ReleaseCandidate release, {
  TvDeviceProfile? device,
  int previousFailures = 0,
}) {
  final hasCapabilityInventory = device?.codecs.isNotEmpty == true;
  final unsupportedCodec =
      hasCapabilityInventory && !device!.supportsCodec(release.codec) ? 12 : 0;
  final unsupportedHdr =
      release.isHdr && hasCapabilityInventory && !device!.hasHdr ? 8 : 0;
  final softwareOnlyProfile = releaseRequiresSoftwareDecoder(release) ? 6 : 0;
  return unsupportedCodec +
      unsupportedHdr +
      softwareOnlyProfile +
      previousFailures * 5;
}

/// Optional per-series picker filters. Automatic preparation first tries
/// matches, then keeps non-matches as fail-open fallbacks.
bool automaticReleaseMatchesFilters(
  ReleaseCandidate release, {
  String language = 'all',
  String quality = 'any',
  String codec = 'any',
  String hdr = 'any',
  bool allowBatch = true,
}) {
  if (language == 'dub' &&
      !releaseSupportsAudioPreference(release, PlaybackAudioPreference.dub)) {
    return false;
  }
  if (language == 'sub' &&
      !releaseSupportsAudioPreference(release, PlaybackAudioPreference.sub)) {
    return false;
  }
  if (!allowBatch && release.isBatch) return false;
  final qualityText = '${release.quality ?? ''} ${release.releaseName}'
      .toLowerCase();
  if (quality == 'p2160' &&
      !qualityText.contains('2160') &&
      !qualityText.contains('4k')) {
    return false;
  }
  if (quality == 'p1080' && !qualityText.contains('1080')) return false;
  if (quality == 'p720' && !qualityText.contains('720')) return false;
  final codecText = '${release.codec ?? ''} ${release.releaseName}'
      .toLowerCase();
  if (codec == 'h264' &&
      !codecText.contains('264') &&
      !codecText.contains('avc')) {
    return false;
  }
  if (codec == 'hevc' &&
      !codecText.contains('hevc') &&
      !codecText.contains('265')) {
    return false;
  }
  if (codec == 'av1' && !codecText.contains('av1')) return false;
  if (hdr == 'hdr' && !release.isHdr) return false;
  if (hdr == 'sdr' && release.isHdr) return false;
  return true;
}

int compareAutomaticStreamReleases(
  ReleaseCandidate left,
  ReleaseCandidate right, {
  TvDeviceProfile? device,
  Map<String, int> failureCounts = const {},
  String sortMode = 'compatibility',
  String? preferredProvider,
  String? preferredReleaseGroup,
  PlaybackAudioPreference? preferredAudio,
  DebridStreamSort? rankingPreference,
}) {
  if (preferredAudio != null) {
    final audio = releaseAudioPreferenceRank(
      left,
      preferredAudio,
    ).compareTo(releaseAudioPreferenceRank(right, preferredAudio));
    if (audio != 0) return audio;
  }
  if (rankingPreference != null && preferredAudio != null) {
    final ranked = compareReleaseCandidates(
      left,
      right,
      sort: rankingPreference,
      preferredAudio: preferredAudio,
    );
    if (ranked != 0) return ranked;
  }
  final group = _automaticReleaseGroupRank(
    left,
    preferredReleaseGroup,
  ).compareTo(_automaticReleaseGroupRank(right, preferredReleaseGroup));
  if (group != 0) return group;
  final preferred = _automaticProviderRank(
    left,
    preferredProvider,
  ).compareTo(_automaticProviderRank(right, preferredProvider));
  if (preferred != 0) return preferred;
  switch (sortMode) {
    case 'seeders':
      final seeders = right.seeders.compareTo(left.seeders);
      if (seeders != 0) return seeders;
      break;
    case 'size':
      final size = _automaticReleaseSizeMb(
        left,
      ).compareTo(_automaticReleaseSizeMb(right));
      if (size != 0) return size;
      break;
    default:
      final compatibility =
          tvPlaybackCompatibilityScore(
            left,
            device: device,
            previousFailures: failureCounts[left.infoHash.toLowerCase()] ?? 0,
          ).compareTo(
            tvPlaybackCompatibilityScore(
              right,
              device: device,
              previousFailures:
                  failureCounts[right.infoHash.toLowerCase()] ?? 0,
            ),
          );
      if (compatibility != 0) return compatibility;
      break;
  }
  return right.seeders.compareTo(left.seeders);
}

int automaticWebStreamQualityRank(WebStreamResult stream) {
  final value = '${stream.quality ?? ''} ${stream.title}'.toLowerCase();
  if (value.contains('4320') || value.contains('8k')) return 7;
  if (value.contains('2160') || value.contains('4k') || value.contains('uhd')) {
    return 6;
  }
  if (value.contains('1440') || value.contains('2k')) return 5;
  if (value.contains('1080') || value.contains('full hd')) return 4;
  if (value.contains('720') || RegExp(r'\bhd\b').hasMatch(value)) return 3;
  if (value.contains('576')) return 2;
  if (value.contains('480') || value.contains('360')) return 1;
  return 0;
}

int compareAutomaticWebStreamsByQuality(
  WebStreamResult left,
  WebStreamResult right,
) {
  final quality = automaticWebStreamQualityRank(
    right,
  ).compareTo(automaticWebStreamQualityRank(left));
  if (quality != 0) return quality;
  final provider = left.providerName.compareTo(right.providerName);
  return provider != 0 ? provider : left.title.compareTo(right.title);
}

int compareAutomaticWebStreamsByAudioAndQuality(
  WebStreamResult left,
  WebStreamResult right,
  PlaybackAudioPreference preferredAudio,
) {
  final audio = webStreamAudioPreferenceRank(
    left,
    preferredAudio,
  ).compareTo(webStreamAudioPreferenceRank(right, preferredAudio));
  return audio != 0 ? audio : compareAutomaticWebStreamsByQuality(left, right);
}

int compareAutomaticAutoplayWebStreams(
  WebStreamResult left,
  WebStreamResult right, {
  required PlaybackAudioPreference preferredAudio,
  String? preferredWebProviderId,
  int? preferredQualityHeight,
  WebStreamQualityPreference qualityPreference =
      WebStreamQualityPreference.bestAvailable,
}) {
  final audio = webStreamAudioPreferenceRank(
    left,
    preferredAudio,
  ).compareTo(webStreamAudioPreferenceRank(right, preferredAudio));
  if (audio != 0) return audio;
  final qualityAffinity =
      automaticQualityAffinityRank(
        webStreamQualityHeight(left),
        preferredQualityHeight,
      ).compareTo(
        automaticQualityAffinityRank(
          webStreamQualityHeight(right),
          preferredQualityHeight,
        ),
      );
  if (qualityAffinity != 0) return qualityAffinity;
  final preferredId = _boundedAutomaticHint(
    preferredWebProviderId,
    maxLength: 160,
  );
  if (preferredId != null) {
    final provider = (left.providerId == preferredId ? 0 : 1).compareTo(
      right.providerId == preferredId ? 0 : 1,
    );
    if (provider != 0) return provider;
  }
  final quality = compareWebStreamCandidates(
    left,
    right,
    quality: qualityPreference,
    preferredAudio: preferredAudio,
  );
  if (quality != 0) return quality;
  final providerId = left.providerId.compareTo(right.providerId);
  if (providerId != 0) return providerId;
  return left.uri.toString().compareTo(right.uri.toString());
}

int compareAutomaticAutoplayReleases(
  ReleaseCandidate left,
  ReleaseCandidate right, {
  TvDeviceProfile? device,
  Map<String, int> failureCounts = const {},
  String sortMode = 'compatibility',
  String? preferredProvider,
  String? preferredAuthor,
  String? preferredSourceId,
  String? existingPreferredProvider,
  String? existingPreferredReleaseGroup,
  PlaybackAudioPreference? preferredAudio,
  DebridStreamSort? rankingPreference,
  int? preferredQualityHeight,
}) {
  if (preferredAudio != null) {
    final audio = releaseAudioPreferenceRank(
      left,
      preferredAudio,
    ).compareTo(releaseAudioPreferenceRank(right, preferredAudio));
    if (audio != 0) return audio;
  }
  // Automatic playback must not repeatedly choose a source this TV cannot
  // decode (or one whose recent playback history is failing) merely because
  // it has a larger resolution label. Manual picker ordering remains driven
  // by the viewer's selected sort mode.
  final safety =
      automaticPlaybackSafetyScore(
        left,
        device: device,
        previousFailures: failureCounts[left.infoHash.toLowerCase()] ?? 0,
      ).compareTo(
        automaticPlaybackSafetyScore(
          right,
          device: device,
          previousFailures: failureCounts[right.infoHash.toLowerCase()] ?? 0,
        ),
      );
  if (safety != 0) return safety;
  final qualityAffinity =
      automaticQualityAffinityRank(
        releaseQualityHeight(left),
        preferredQualityHeight,
      ).compareTo(
        automaticQualityAffinityRank(
          releaseQualityHeight(right),
          preferredQualityHeight,
        ),
      );
  if (qualityAffinity != 0) return qualityAffinity;
  final affinity =
      _automaticReleaseAffinityRank(
        left,
        preferredProvider: preferredProvider,
        preferredAuthor: preferredAuthor,
        preferredSourceId: preferredSourceId,
      ).compareTo(
        _automaticReleaseAffinityRank(
          right,
          preferredProvider: preferredProvider,
          preferredAuthor: preferredAuthor,
          preferredSourceId: preferredSourceId,
        ),
      );
  if (affinity != 0) return affinity;
  final global = compareAutomaticStreamReleases(
    left,
    right,
    device: device,
    failureCounts: failureCounts,
    sortMode: sortMode,
    preferredProvider: existingPreferredProvider,
    preferredReleaseGroup: existingPreferredReleaseGroup,
    preferredAudio: preferredAudio,
    rankingPreference: rankingPreference,
  );
  if (global != 0) return global;
  return left.infoHash.compareTo(right.infoHash);
}

/// Returns strict per-series matches first and bounded fail-open candidates
/// second. Each group uses the exact automatic resolver comparator.
List<ReleaseCandidate> rankAutomaticAutoplayReleases(
  Iterable<ReleaseCandidate> input, {
  required String language,
  required String quality,
  required String codec,
  required String hdr,
  required bool allowBatch,
  required PlaybackAudioPreference preferredAudio,
  required DebridStreamSort rankingPreference,
  TvDeviceProfile? device,
  Map<String, int> failureCounts = const {},
  String sortMode = 'compatibility',
  String? preferredProvider,
  String? preferredAuthor,
  String? preferredSourceId,
  String? existingPreferredProvider,
  String? existingPreferredReleaseGroup,
  int? preferredQualityHeight,
}) {
  final strict = <ReleaseCandidate>[];
  final fallback = <ReleaseCandidate>[];
  for (final release in input) {
    if (automaticReleaseMatchesFilters(
      release,
      language: language,
      quality: quality,
      codec: codec,
      hdr: hdr,
      allowBatch: allowBatch,
    )) {
      strict.add(release);
    } else {
      fallback.add(release);
    }
  }
  int compare(ReleaseCandidate left, ReleaseCandidate right) =>
      compareAutomaticAutoplayReleases(
        left,
        right,
        device: device,
        failureCounts: failureCounts,
        sortMode: sortMode,
        preferredProvider: preferredProvider,
        preferredAuthor: preferredAuthor,
        preferredSourceId: preferredSourceId,
        existingPreferredProvider: existingPreferredProvider,
        existingPreferredReleaseGroup: existingPreferredReleaseGroup,
        preferredAudio: preferredAudio,
        rankingPreference: rankingPreference,
        preferredQualityHeight: preferredQualityHeight,
      );
  strict.sort(compare);
  fallback.sort(compare);
  return [...strict, ...fallback];
}

List<WebStreamResult> rankAutomaticAutoplayWebStreams(
  Iterable<WebStreamResult> input, {
  required String language,
  required String quality,
  required PlaybackAudioPreference preferredAudio,
  required WebStreamQualityPreference qualityPreference,
  String? preferredWebProviderId,
  int? preferredQualityHeight,
}) {
  final strict = <WebStreamResult>[];
  final fallback = <WebStreamResult>[];
  final seen = <String>{};
  for (final stream in input) {
    final key = '${stream.providerId}\u0000${stream.uri}';
    if (!seen.add(key)) continue;
    (automaticWebStreamMatchesFilters(
              stream,
              language: language,
              quality: quality,
            )
            ? strict
            : fallback)
        .add(stream);
  }
  int compare(WebStreamResult left, WebStreamResult right) =>
      compareAutomaticAutoplayWebStreams(
        left,
        right,
        preferredAudio: preferredAudio,
        preferredWebProviderId: preferredWebProviderId,
        preferredQualityHeight: preferredQualityHeight,
        qualityPreference: qualityPreference,
      );
  strict.sort(compare);
  fallback.sort(compare);
  return [...strict, ...fallback];
}

/// Optional per-series Web filters used by both the visible resolver and the
/// hidden next-episode preparer. Callers must exhaust matching candidates
/// before entering their fail-open pool.
bool automaticWebStreamMatchesFilters(
  WebStreamResult stream, {
  required String language,
  required String quality,
}) {
  final languageMatches = webStreamMatchesAudioFilter(stream, language);
  final height = webStreamQualityHeight(stream);
  final qualityMatches = switch (quality) {
    'p2160' => height == 2160,
    'p1080' => height == 1080,
    'p720' => height == 720,
    _ => true,
  };
  return languageMatches && qualityMatches;
}

/// Shared audio predicate for manual and automatic Web stream filtering.
///
/// A dual-audio result deliberately satisfies both controls; known Sub-only
/// and Dub-only results remain exclusive, while unknown results stay visible
/// only when no audio filter is selected.
bool webStreamMatchesAudioFilter(WebStreamResult stream, String filter) =>
    switch (filter.trim().toLowerCase()) {
      'dub' => stream.supportsDubAudio,
      'sub' => stream.supportsSubAudio,
      _ => true,
    };

int _automaticReleaseAffinityRank(
  ReleaseCandidate release, {
  required String? preferredProvider,
  required String? preferredAuthor,
  required String? preferredSourceId,
}) {
  final provider = _normalizedAutomaticProviderHint(preferredProvider);
  final sourceId = _boundedAutomaticHint(preferredSourceId, maxLength: 160);
  final author = _normalizedAutomaticAuthorHint(preferredAuthor);
  final sameProvider =
      provider != null &&
      _normalizedAutomaticProviderHint(release.provider) == provider;
  final sameSource = sourceId != null && release.sourceId == sourceId;
  final sameAuthor =
      author != null && releaseGroupKey(release.releaseName) == author;
  if ((sameProvider || sameSource) && sameAuthor) return 0;
  if (sameProvider || sameSource) return 1;
  if (sameAuthor) return 2;
  return 3;
}

String? _normalizedAutomaticProviderHint(String? value) =>
    _boundedAutomaticHint(value, maxLength: 160)?.toLowerCase();

String? _normalizedAutomaticAuthorHint(String? value) {
  final hint = _boundedAutomaticHint(value, maxLength: 96);
  if (hint == null) return null;
  final extracted = releaseGroupKey(hint);
  if (extracted != null) return extracted;
  final normalized = hint
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return normalized.isEmpty ? null : normalized;
}

String? _boundedAutomaticHint(String? value, {required int maxLength}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed.length > maxLength) {
    return null;
  }
  return trimmed;
}

int _automaticProviderRank(
  ReleaseCandidate release,
  String? preferredProvider,
) {
  if (preferredProvider == null || preferredProvider.isEmpty) return 1;
  return release.provider?.toLowerCase() == preferredProvider.toLowerCase()
      ? 0
      : 1;
}

int _automaticReleaseGroupRank(
  ReleaseCandidate release,
  String? preferredGroup,
) {
  if (preferredGroup == null || preferredGroup.isEmpty) return 1;
  return releaseGroupKey(release.releaseName) == preferredGroup.toLowerCase()
      ? 0
      : 1;
}

double _automaticReleaseSizeMb(ReleaseCandidate release) {
  final value = release.sizeLabel?.toUpperCase() ?? '';
  final amount = double.tryParse(
    RegExp(r'[\d.]+').firstMatch(value)?.group(0) ?? '',
  );
  if (amount == null) return double.maxFinite;
  if (value.contains('TB')) return amount * 1024 * 1024;
  if (value.contains('GB')) return amount * 1024;
  if (value.contains('KB')) return amount / 1024;
  return amount;
}
