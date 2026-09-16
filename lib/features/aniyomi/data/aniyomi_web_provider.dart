import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/preferences/caption_language.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

typedef AniyomiRuntimeRequest =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);
typedef AniyomiRuntimeRequestStarter =
    AniyomiRequestHandle Function(Map<String, dynamic> request);
typedef AniyomiProviderDiagnostic = void Function(Map<String, Object?> fields);

const _maximumAniyomiSearchQueries = 5;

/// Restricted anime adapter for the separately approved developer-mode runtime.
/// No native code is loaded here. [request] must recheck developer opt-in and
/// extension approval at dispatch, and enforce the supplied timeoutMs against
/// its worker (including queued requests). Production supplies [startRequest]
/// so cancellation terminates only the queue entry owned by this adapter.
class AniyomiWebProvider implements WebStreamingProvider {
  const AniyomiWebProvider({
    required this.extensionId,
    required this.sourceId,
    required this.name,
    required this.request,
    this.startRequest,
    this.validateResultTarget = validatePublicNetworkTarget,
    this.runtimeLimit = const Duration(seconds: 28),
    this.preferredSubtitleLanguage = 'eng',
    this.preferredAudio = PlaybackAudioPreference.dub,
    this.preferredAudioLanguage = 'auto',
    this.onDiagnostic,
  });

  final String extensionId;
  final String sourceId;
  @override
  final String name;
  final AniyomiRuntimeRequest request;
  final AniyomiRuntimeRequestStarter? startRequest;
  final Future<void> Function(Uri uri) validateResultTarget;
  final Duration runtimeLimit;
  final String preferredSubtitleLanguage;
  final PlaybackAudioPreference preferredAudio;
  final String preferredAudioLanguage;
  final AniyomiProviderDiagnostic? onDiagnostic;

  @override
  String get id => 'aniyomi:anime:source:$sourceId';

  @override
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  }) async {
    final trace = _AniyomiProviderTrace(onDiagnostic);
    try {
      cancellation?.throwIfCancelled();
      if (episode.episode < 1 ||
          !_validSourceId(sourceId) ||
          extensionId.isEmpty ||
          extensionId.length > 256) {
        trace.fail(stage: 'validation', reason: 'invalid_payload');
        throw const FormatException('Invalid Aniyomi discovery identity.');
      }
      final budget = _DiscoveryBudget(runtimeLimit, cancellation);
      final titles = <String>[];
      final titleKeys = <String>{};
      for (final title in <String?>[
        episode.title,
        episode.titleEnglish,
        episode.titleRomaji,
        episode.titleNative,
        ...episode.alternativeTitles.take(24),
      ]) {
        final text = _text(title, max: 256);
        if (text != null && titleKeys.add(_titleKey(text))) titles.add(text);
      }
      trace.titleAliasCount = titles.length;
      if (titles.isEmpty) {
        trace.noMatch(stage: 'title_matching', reason: 'catalog_title_missing');
        return const [];
      }

      Future<Map<String, dynamic>> call(
        String operation,
        Map<String, dynamic> arguments,
      ) async {
        trace.beginOperation(operation);
        budget.check();
        late final Map<String, dynamic> result;
        try {
          final payload = <String, dynamic>{
            'operation': operation,
            'extensionId': extensionId,
            'sourceId': sourceId,
            // Native enforces an independent ten-second ceiling per
            // operation. The longer workflow budget lets a slow search and
            // details request finish sequentially while the stream picker is
            // already displaying faster providers in the background.
            'timeoutMs': budget.remaining.inMilliseconds.clamp(1, 10000),
            ...arguments,
          };
          AniyomiRequestHandle? handle;
          result = await budget.wait(
            () {
              handle = startRequest?.call(payload);
              return handle?.result ?? request(payload);
            },
            cancelOperation: startRequest == null
                ? null
                : () => handle?.cancel() ?? Future.value(),
          );
        } on AniyomiFailure catch (failure) {
          trace.captureNativeFailure(failure);
          if (operation == 'search' &&
              failure.code == 'extension_execution_failed' &&
              failure.stage == 'source_search' &&
              failure.cause == 'invalid_input' &&
              failure.brokerFailure == null) {
            // An extension can reject one alias while constructing its search
            // request (for example, non-ASCII text in an ordinary HTTP header).
            // Try another catalog alias, never a modified or repeated query.
            // Broker, approval, capability and cancellation failures stay fatal.
            throw _AniyomiSearchAliasFailure(failure);
          }
          throw AniyomiWebProviderFailure.fromNative(
            operation: operation,
            failure: failure,
          );
        }
        _checkResponse(result);
        trace.captureSuccessfulOperation(operation, result);
        return result;
      }

      // No fuzzy search, first-result, season-stripping, or ordinal fallback.
      // Distinct exact-title URLs are ambiguous and are not auto-selected.
      final candidates = <String, _AniyomiTitleCandidate>{};
      _AniyomiSearchAliasFailure? lastAliasFailure;
      for (final query in titles.take(_maximumAniyomiSearchQueries)) {
        trace.searchQueryCount++;
        late final Map<String, dynamic> response;
        try {
          response = await call('search', {'query': query, 'page': 1});
        } on _AniyomiSearchAliasFailure catch (failure) {
          lastAliasFailure = failure;
          continue;
        }
        final searchItems = _items(response, 'items', maximum: 100);
        trace.searchResultCount += searchItems.length;
        for (final item in searchItems) {
          final title = _text(item['title'], max: 256);
          final url = _locator(item['url']);
          if (title == null ||
              url == null ||
              !_catalogTitleMatches(title, titleKeys)) {
            continue;
          }
          final year = item['year'];
          if (episode.year != null && year is int && year != episode.year) {
            continue;
          }
          final titleVariant = _providerTitleVariant(title);
          final next = _AniyomiTitleCandidate(
            url: url,
            item: item,
            variant: titleVariant,
          );
          final current = candidates[url];
          if (current == null || _compareTitleCandidates(next, current) < 0) {
            candidates[url] = next;
          }
        }
        trace.exactTitleMatchCount = candidates.length;
        if (candidates.isNotEmpty) break;
      }
      if (candidates.isEmpty) {
        if (lastAliasFailure != null) {
          // A later empty alias does not turn a failed search into a confirmed
          // catalog miss, nor inherit an unrelated alias's HTTP diagnostics.
          trace.beginOperation('search');
          trace.captureNativeFailure(lastAliasFailure.nativeFailure);
          throw lastAliasFailure;
        }
        trace.noMatch(stage: 'title_matching', reason: 'no_exact_title_match');
        return const [];
      }
      final rankedCandidates = candidates.values.toList(growable: false)
        ..sort(_compareTitleCandidates);
      final selectedCandidate = rankedCandidates.first;
      if (rankedCandidates.length > 1 &&
          _sameTitleCandidateRank(selectedCandidate, rankedCandidates[1])) {
        trace.noMatch(stage: 'title_matching', reason: 'ambiguous_title_match');
        return const [];
      }
      final selectedUrl = selectedCandidate.url;
      final response = await call('details', {
        'url': selectedUrl,
        'title': selectedCandidate.item['title'],
      });
      final rawDetails = response['item'];
      if (rawDetails is! Map) _invalidResponse();
      final details = Map<String, dynamic>.from(rawDetails);
      final catalogTitle = _text(selectedCandidate.item['title'], max: 256)!;
      final selectedTitle = titles.firstWhere(
        (title) =>
            _titleKey(title) == _providerComparableTitleKey(catalogTitle),
        orElse: () => episode.title,
      );
      final detailsTitle = _text(details['title'], max: 256);
      if (detailsTitle == null ||
          !_catalogTitleMatches(detailsTitle, titleKeys)) {
        // Search already selected one exact/decorated catalog identity. Many
        // providers return a localized or canonical title from their details
        // parser, and relative/absolute canonical locators commonly differ.
        // Treat that provider-owned metadata as advisory instead of dropping
        // the already unambiguous series selection.
        trace.detailsMetadataMismatchCount++;
      }
      final detailUrl = _locator(details['url']);
      if (detailUrl != null && detailUrl != selectedUrl) {
        trace.detailsMetadataMismatchCount++;
      }
      if (episode.year != null &&
          details['year'] is int &&
          details['year'] != episode.year) {
        trace.noMatch(stage: 'title_matching', reason: 'details_year_mismatch');
        return const [];
      }
      final requestedSeason = catalogSeasonNumber(episode);
      var episodeOwnerUrl = detailUrl ?? selectedUrl;
      var episodeOwnerTitle = detailsTitle ?? catalogTitle;
      final usesSeasonContainer =
          details['fetchType'] == 'seasons' ||
          selectedCandidate.item['fetchType'] == 'seasons';
      if (usesSeasonContainer) {
        // A season-container result cannot be mapped to the first returned
        // child. Without an explicit catalog season, there is no trustworthy
        // season identity to send to the extension.
        if (requestedSeason == null) {
          trace.noMatch(stage: 'episode_lookup', reason: 'episode_not_found');
          return const [];
        }
        final seasons = await call('seasons', {
          'url': episodeOwnerUrl,
          'title': episodeOwnerTitle,
          'targetSeason': requestedSeason,
        });
        final matchingSeasons = <String, Map<String, dynamic>>{};
        for (final season in _items(seasons, 'seasons', maximum: 16)) {
          final url = _locator(season['url']);
          if (url == null ||
              !_isExactRequestedSeason(season, requestedSeason)) {
            continue;
          }
          matchingSeasons[url] = season;
        }
        if (matchingSeasons.length != 1) {
          trace.noMatch(stage: 'episode_lookup', reason: 'episode_not_found');
          return const [];
        }
        final selectedSeason = matchingSeasons.values.single;
        episodeOwnerUrl = matchingSeasons.keys.single;
        episodeOwnerTitle =
            _text(selectedSeason['title'], max: 256) ?? episodeOwnerTitle;
      }
      final episodes = await call('episodes', {
        // Details and season parsers may canonicalize an opaque relative
        // locator. Always use their returned locator, never the stale search
        // DTO, for the next provider operation.
        'url': episodeOwnerUrl,
        'title': episodeOwnerTitle,
        // The isolated runtime can now select a small, conservative candidate
        // set from very large provider episode lists. The Dart boundary still
        // performs the authoritative identity/ambiguity checks below.
        'targetEpisode': episode.episode,
        'targetSeason': ?requestedSeason,
      });
      final matching = <String, Map<String, dynamic>>{};
      final chapterItems = _items(episodes, 'chapters', maximum: 4096);
      trace.episodeCount = chapterItems.length;
      for (final chapter in chapterItems) {
        final number = chapter['number'];
        final url = _locator(chapter['url']);
        if (url == null) continue;
        final label = _text(chapter['name'], max: 256) ?? '';
        final assessment = assessEpisodeIdentityLabel(
          label: label,
          requestedEpisode: episode.episode,
          requestedSeason: requestedSeason,
        );
        final numberAssessment = assessEpisodeIdentityLabel(
          label: label,
          requestedEpisode: episode.episode,
        );
        final hasExactNumber =
            number is num && number.isFinite && number == episode.episode;
        final hasUsableDifferentNumber =
            number is num && number.isFinite && number > 0 && !hasExactNumber;
        if (hasUsableDifferentNumber ||
            assessment.isMismatch ||
            numberAssessment.isMismatch) {
          continue;
        }
        if (!hasExactNumber) {
          // Older and several current extensions leave SEpisode.number at
          // its sentinel value and encode the episode only in the label.
          // Accept only an explicit season-aware label match; unknown labels
          // remain excluded and duplicate matches remain fail-closed below.
          if (!numberAssessment.isMatch) continue;
          trace.episodeLabelFallbackCount++;
        }
        matching[url] = chapter;
      }
      trace.exactEpisodeMatchCount = matching.length;
      if (matching.length != 1) {
        trace.noMatch(
          stage: 'episode_lookup',
          reason: matching.isEmpty
              ? 'episode_not_found'
              : 'ambiguous_episode_match',
        );
        return const [];
      }
      final chapter = matching.values.single;
      final videos = await call('videos', {
        'url': matching.keys.single,
        'title': chapter['name'] is String ? chapter['name'] : selectedTitle,
        // Aniyomi normally waits for a hoster-picker selection before loading
        // `Hoster.lazy` rows. TetoTV flattens providers into one stream list,
        // so resolve only a bounded sorted prefix inside this request's
        // isolated worker and existing cancellation/deadline boundary.
        'resolveLazyHosters': true,
        'lazyHosterLimit': 8,
      });
      final result = <WebStreamResult>[];
      final seen = <String>{};
      final videoItems = _items(videos, 'videos', maximum: 64);
      trace.rawVideoCount = videoItems.length;
      for (final video in videoItems) {
        budget.check();
        // Native-player arguments cannot cross this boundary. External audio
        // tracks are instead validated below and later replaced with opaque,
        // app-owned proxy URLs before either playback engine sees them.
        if (_requiresNativePlaybackArguments(video)) {
          trace.unsupportedPlaybackCount++;
          continue;
        }
        final uri = safePublicHttpsUri(video['url']);
        if (uri == null) {
          trace.invalidMediaUrlCount++;
          continue;
        }
        if (!await _allowed(uri, budget)) {
          trace.unsafeMediaTargetCount++;
          continue;
        }
        final streamHeaders = sanitizeAddonHeaders(
          video['headers'],
          maximumValueLength: 1024,
        );
        final tracks = _tracks(video['subtitleTracks']);
        final preferred = canonicalCaptionLanguageCode(
          preferredSubtitleLanguage,
        );
        final preferredTracks = tracks.where(
          (track) => track.language == preferred,
        );
        final englishTracks = tracks.where((track) => track.language == 'eng');
        final choices = preferredTracks.isNotEmpty
            ? preferredTracks
            : englishTracks;
        Uri? subtitleUri;
        String? subtitleLanguage;
        for (final track in choices) {
          if (await _allowed(track.uri, budget)) {
            subtitleUri = track.uri;
            subtitleLanguage = track.language;
            break;
          }
        }
        final externalAudioTracks = <WebExternalAudioTrack>[];
        final rawAudioTrackCount = switch (video['audioTracks']) {
          final List<Object?> tracks => tracks.length,
          _ => 0,
        };
        final audioTrackCandidates = _audioTracks(video['audioTracks']);
        trace.externalAudioTrackCount += rawAudioTrackCount;
        trace.rejectedExternalAudioCount +=
            rawAudioTrackCount - audioTrackCandidates.length;
        for (final track in audioTrackCandidates.take(8)) {
          if (!await _allowed(track.uri, budget)) {
            trace.rejectedExternalAudioCount++;
            continue;
          }
          externalAudioTracks.add(
            WebExternalAudioTrack(
              uri: track.uri,
              label: track.label,
              language: track.language,
              // Aniyomi Track does not expose independent headers. Preserve
              // ordinary routing headers, but never copy video credentials to
              // an external-audio origin controlled by another host.
              headers: sanitizeAddonHeaders(
                streamHeaders,
                stripCredentials: !_sameHttpsOrigin(uri, track.uri),
              ),
            ),
          );
        }
        if (audioTrackCandidates.length > 8) {
          trace.rejectedExternalAudioCount += audioTrackCandidates.length - 8;
        }
        final quality = _text(video['quality'], max: 120);
        final videoAudioCapability = aniyomiDeclaredAudioCapability(quality);
        final declaredAudioCapability =
            videoAudioCapability == WebStreamAudioCapability.unknown
            ? selectedCandidate.variant.capability
            : videoAudioCapability;
        final trackAudioCapability = webStreamAudioCapabilityFromWire({
          'audioTracks': [
            for (final track in externalAudioTracks)
              {'language': track.language, 'label': track.label},
          ],
        });
        final audioCapability = mergeWebStreamAudioCapabilities(
          declaredAudioCapability,
          trackAudioCapability,
        );
        final declaredAudioLanguages =
            videoAudioCapability == WebStreamAudioCapability.unknown ||
                selectedCandidate.variant.capability ==
                    WebStreamAudioCapability.unknown ||
                videoAudioCapability == selectedCandidate.variant.capability ||
                videoAudioCapability == WebStreamAudioCapability.subAndDub ||
                selectedCandidate.variant.capability ==
                    WebStreamAudioCapability.subAndDub
            ? List.unmodifiable(selectedCandidate.variant.audioLanguages)
            : const <String>[];
        final audioLanguages = <String>{
          ...declaredAudioLanguages,
          ...webStreamAudioLanguagesFromWire({
            'audioTracks': [
              for (final track in externalAudioTracks)
                {'language': track.language, 'label': track.label},
            ],
          }),
        }.take(24).toList(growable: false);
        final streamCandidate = WebStreamResult(
          providerId: id,
          providerName: name,
          title: quality ?? name,
          quality: quality,
          uri: uri,
          headers: streamHeaders,
          subtitleUri: subtitleUri,
          subtitleLanguage: subtitleLanguage,
          externalAudioTracks: List.unmodifiable(externalAudioTracks),
          // A selected catalog variant or per-video Sub/Dub label can provide
          // audio evidence. Source/package language and subtitle tracks cannot.
          audioCapability: audioCapability,
          audioLanguages: audioLanguages,
          matchedEpisodeNumber: episode.episode,
          matchedSeasonNumber: requestedSeason,
          matchedSeriesTitle: selectedTitle,
        );
        if (seen.add(webStreamPlaybackVariantKey(streamCandidate))) {
          result.add(streamCandidate);
        }
      }
      trace.playableVideoCount = result.length;
      if (result.isEmpty) {
        trace.fail(stage: 'stream_extraction', reason: 'empty_sources');
        throw const AniyomiWebProviderFailure(
          stage: 'stream_extraction',
          reason: 'empty_sources',
        );
      }
      budget.check();
      trace.succeed();
      return List.unmodifiable(result);
    } on WebProviderSearchCancelled {
      trace.cancel();
      rethrow;
    } on TimeoutException {
      trace.fail(stage: trace.stage, reason: 'timeout');
      rethrow;
    } on AniyomiWebProviderFailure catch (failure) {
      trace.fail(stage: failure.stage, reason: failure.reason);
      rethrow;
    } on FormatException {
      trace.fail(stage: trace.stage, reason: 'invalid_response');
      rethrow;
    } catch (_) {
      trace.fail(stage: trace.stage, reason: 'provider_error');
      rethrow;
    } finally {
      trace.emit();
    }
  }

  int _compareTitleCandidates(
    _AniyomiTitleCandidate left,
    _AniyomiTitleCandidate right,
  ) {
    final leftRank = _titleCandidateRank(left.variant);
    final rightRank = _titleCandidateRank(right.variant);
    final language = leftRank.$1.compareTo(rightRank.$1);
    if (language != 0) return language;
    final audio = leftRank.$2.compareTo(rightRank.$2);
    if (audio != 0) return audio;
    return 0;
  }

  bool _sameTitleCandidateRank(
    _AniyomiTitleCandidate left,
    _AniyomiTitleCandidate right,
  ) => _titleCandidateRank(left.variant) == _titleCandidateRank(right.variant);

  (int, int) _titleCandidateRank(_AniyomiTitleVariant variant) {
    final requestedLanguage = preferredPlaybackAudioLanguage(
      globalPreference: preferredAudio,
      globalLanguage: preferredAudioLanguage,
    );
    final languageRank = variant.audioLanguages.contains(requestedLanguage)
        ? 0
        : variant.audioLanguages.isEmpty
        ? 1
        : 2;
    final supportsRequestedMode = switch (preferredAudio) {
      PlaybackAudioPreference.dub => variant.capability.supportsDub,
      PlaybackAudioPreference.sub => variant.capability.supportsSub,
    };
    final audioRank = supportsRequestedMode
        ? 0
        : variant.capability == WebStreamAudioCapability.unknown
        ? 1
        : 2;
    return (languageRank, audioRank);
  }

  Future<bool> _allowed(Uri uri, _DiscoveryBudget budget) async {
    try {
      await budget.wait(() => validateResultTarget(uri));
      return true;
    } on WebProviderSearchCancelled {
      rethrow;
    } on TimeoutException {
      // Public-host lookup has its own shorter timeout. Reject this target
      // only; sibling streams/tracks must still pass the same validation.
      // A workflow deadline or cancellation must never be swallowed here.
      budget.check();
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Fixed, privacy-safe metadata for a native Aniyomi operation failure.
///
/// Provider exception messages never cross the native boundary. The marker
/// format is shared with Web-provider diagnostics so the normal aggregator can
/// report which phase failed without importing or retaining third-party data.
class AniyomiWebProviderFailure implements Exception {
  const AniyomiWebProviderFailure({
    required this.stage,
    required this.reason,
    this.requiresLocalProxy = false,
  });

  factory AniyomiWebProviderFailure.fromNative({
    required String operation,
    required AniyomiFailure failure,
  }) => AniyomiWebProviderFailure(
    stage: switch (operation) {
      'search' => 'search',
      'details' => 'title_matching',
      'seasons' || 'episodes' || 'chapters' => 'episode_lookup',
      'videos' => 'stream_extraction',
      _ => 'runtime',
    },
    reason: _aniyomiFailureReason(failure),
    requiresLocalProxy: failure.code == 'extension_local_proxy_required',
  );

  final String stage;
  final String reason;
  final bool requiresLocalProxy;

  @override
  String toString() {
    final message = requiresLocalProxy
        ? 'This extension requires its own local streaming server, which '
              'TetoTV does not support yet. Try another extension.'
        : 'Aniyomi provider operation failed.';
    return '$message [stage=$stage; reason=$reason]';
  }
}

final class _AniyomiSearchAliasFailure extends AniyomiWebProviderFailure {
  const _AniyomiSearchAliasFailure(this.nativeFailure)
    : super(stage: 'search', reason: 'invalid_response');

  final AniyomiFailure nativeFailure;
}

String _aniyomiFailureReason(AniyomiFailure failure) {
  final brokerReason = switch (failure.brokerFailure) {
    'policy' => 'unsafe_target',
    'network' => 'network',
    'unsupported' => 'runtime_api',
    'invalid' => 'invalid_response',
    _ => null,
  };
  if (brokerReason != null) return brokerReason;
  return switch (failure.code) {
    'request_deadline_exceeded' ||
    'worker_busy' ||
    'extension_hoster_timeout' => 'timeout',
    'invalid_request' => 'invalid_payload',
    'extension_result_too_large' => 'response_limit',
    'invalid_or_revoked_extension_result' => 'invalid_response',
    _ when failure.cause == 'security_denied' => 'unsafe_target',
    'unsupported_extension_capability' ||
    'extension_local_proxy_required' ||
    'unsupported_extension_abi' ||
    'unsupported_api' => 'runtime_api',
    _ when failure.cause == 'io' => 'network',
    _ when failure.cause == 'invalid_input' => 'invalid_response',
    _ => 'provider_error',
  };
}

/// Returns only an audio mode the extension explicitly placed in its video
/// label. Aniyomi's source language, subtitles, and package language do not
/// describe spoken audio and deliberately remain [WebStreamAudioCapability.unknown].
WebStreamAudioCapability aniyomiDeclaredAudioCapability(String? label) {
  final normalized = label?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return WebStreamAudioCapability.unknown;
  final declaresSub = RegExp(
    r'(?:^|[^a-z])sub(?:bed)?(?:$|[^a-z])',
  ).hasMatch(normalized);
  final declaresDub = RegExp(
    r'(?:^|[^a-z])dub(?:bed)?(?:$|[^a-z])',
  ).hasMatch(normalized);
  if (declaresSub && declaresDub) return WebStreamAudioCapability.subAndDub;
  if (declaresDub) return WebStreamAudioCapability.dub;
  if (declaresSub) return WebStreamAudioCapability.sub;
  return WebStreamAudioCapability.unknown;
}

final class _DiscoveryBudget {
  _DiscoveryBudget(this.limit, this.cancellation);
  final Duration limit;
  final WebProviderCancellation? cancellation;
  final Stopwatch _clock = Stopwatch()..start();
  Duration get remaining => limit - _clock.elapsed;

  void check() {
    cancellation?.throwIfCancelled();
    if (remaining <= Duration.zero) {
      throw TimeoutException('Aniyomi discovery exceeded its deadline.', limit);
    }
  }

  Future<T> wait<T>(
    Future<T> Function() operation, {
    Future<void> Function()? cancelOperation,
  }) async {
    check();
    final completed = Future<T>.sync(operation);
    Future<void>? cancellationWork;
    Future<void> cancelOnce() async {
      if (cancellationWork != null) return cancellationWork!;
      Future<void> run() async {
        try {
          await cancelOperation?.call();
        } catch (_) {
          // Cancellation is best-effort and must not replace its fixed marker.
        }
      }

      cancellationWork = run();
      return cancellationWork!;
    }

    Future<T> guardedCompleted() async {
      try {
        final value = await completed;
        if (cancellation?.isCancelled == true) {
          await cancelOnce();
          throw const WebProviderSearchCancelled();
        }
        return value;
      } catch (error, stack) {
        if (cancellation?.isCancelled == true) {
          await cancelOnce();
          throw const WebProviderSearchCancelled();
        }
        Error.throwWithStackTrace(error, stack);
      }
    }

    final cancelled = Completer<T>();
    final removeCancellationListener = cancellation?.addListener(() {
      unawaited(
        cancelOnce().whenComplete(() {
          if (!cancelled.isCompleted) {
            cancelled.completeError(
              const WebProviderSearchCancelled(),
              StackTrace.current,
            );
          }
        }),
      );
    });
    late final T result;
    try {
      result =
          await Future.any<T>([
            guardedCompleted(),
            if (cancellation != null) cancelled.future,
          ]).timeout(
            remaining,
            onTimeout: () async {
              await cancelOnce();
              throw TimeoutException(
                'Aniyomi discovery exceeded its deadline.',
                limit,
              );
            },
          );
    } finally {
      removeCancellationListener?.call();
    }
    check();
    return result;
  }
}

String _diagnosticStageForOperation(String operation) => switch (operation) {
  'search' => 'search',
  'details' => 'title_matching',
  'seasons' || 'episodes' || 'chapters' => 'episode_lookup',
  'videos' => 'stream_extraction',
  _ => 'runtime',
};

/// One privacy-safe execution breadcrumb for an Aniyomi source attempt.
///
/// Counts and fixed reason codes are enough to distinguish an empty provider
/// catalog from a title mismatch, episode mismatch, broken extractor, or a
/// stream TetoTV deliberately rejected. It never receives a title, URL,
/// header, cookie, provider exception, account value, or media payload.
final class _AniyomiProviderTrace {
  _AniyomiProviderTrace(this._recorder);

  final AniyomiProviderDiagnostic? _recorder;
  String stage = 'validation';
  String? _outcome;
  String? _reason;
  bool _emitted = false;

  int titleAliasCount = 0;
  int searchQueryCount = 0;
  int searchResultCount = 0;
  int exactTitleMatchCount = 0;
  int episodeCount = 0;
  int exactEpisodeMatchCount = 0;
  int episodeLabelFallbackCount = 0;
  int rawVideoCount = 0;
  int playableVideoCount = 0;
  int unsupportedPlaybackCount = 0;
  int externalAudioTrackCount = 0;
  int rejectedExternalAudioCount = 0;
  int invalidMediaUrlCount = 0;
  int unsafeMediaTargetCount = 0;
  int detailsMetadataMismatchCount = 0;
  Map<String, Object?> _nativeFailure = const {};
  Map<String, Object?> _brokerContext = const {};
  final Map<String, int> _resultCounts = {};
  final Map<String, Object?> _httpContext = {};

  void beginOperation(String operation) {
    stage = _diagnosticStageForOperation(operation);
    _nativeFailure = const {};
    _brokerContext = const {};
    final prefix = switch (operation) {
      'search' => 'search_',
      'episodes' || 'chapters' => 'episode_',
      'videos' => 'video_',
      _ => null,
    };
    if (prefix != null) {
      _resultCounts.removeWhere((key, _) => key.startsWith(prefix));
      _httpContext.removeWhere((key, _) => key.startsWith(prefix));
    }
  }

  void captureSuccessfulOperation(
    String operation,
    Map<String, dynamic> response,
  ) {
    final redirectCount = _boundedDiagnosticCount(
      response['broker_redirect_count'],
      maximum: 3,
    );
    final sizeBucket = response['broker_response_size_bucket'];
    final statusClass = response['broker_status_class'];
    if (redirectCount != null &&
        sizeBucket is String &&
        _brokerSizeBuckets.contains(sizeBucket) &&
        statusClass is String &&
        _brokerStatusClasses.contains(statusClass)) {
      _brokerContext = {
        'broker_redirect_count': redirectCount,
        'broker_response_size_bucket': sizeBucket,
        'broker_status_class': statusClass,
      };
    }

    final prefix = switch (operation) {
      'search' => 'search',
      'episodes' || 'chapters' => 'episode',
      'videos' => 'video',
      _ => null,
    };
    if (prefix == null) return;
    // The host overwrites this envelope after extension execution. Providers
    // can catch HTTP exceptions and still return an empty/successful result;
    // preserve the host's bounded evidence without changing that result or
    // treating untrusted exception text as a diagnostic field.
    final http = response['httpDiagnostics'];
    if (http is Map) {
      final requestCount = _boundedDiagnosticCount(
        http['requestCount'],
        maximum: 16,
      );
      final failureCount = _boundedDiagnosticCount(
        http['failureCount'],
        maximum: 64,
      );
      if (requestCount != null) {
        _httpContext['${prefix}_http_request_count'] = requestCount;
      }
      // This is a fixed host contract, not a provider-supplied arbitrary limit.
      if (http['requestLimit'] == 16) {
        _httpContext['${prefix}_http_request_limit'] = 16;
      }
      if (failureCount != null) {
        _httpContext['${prefix}_http_failure_count'] = failureCount;
      }
      final limitHit = http['requestLimitHit'];
      if (limitHit is bool) {
        _httpContext['${prefix}_http_request_limit_hit'] = limitHit;
      }
      final lastFailure = http['lastFailure'];
      if (_httpFailureReasons.contains(lastFailure)) {
        _httpContext['${prefix}_http_last_failure'] = lastFailure;
      }
    }
    for (final entry in const {
      'originalCount': 'original_count',
      'returnedCount': 'returned_count',
      'filteredCount': 'filtered_count',
      'truncatedCount': 'truncated_count',
      'discardedVideoCount': 'discarded_count',
    }.entries) {
      final value = _boundedDiagnosticCount(
        response[entry.key],
        maximum:
            operation == 'videos' &&
                const {
                  'originalCount',
                  'truncatedCount',
                  'discardedVideoCount',
                }.contains(entry.key)
            ? _maximumAniyomiAggregateVideos
            : 100000,
      );
      if (value != null) _resultCounts['${prefix}_${entry.value}'] = value;
    }
    if (operation == 'videos') {
      for (final entry in const {
        'originalHosterCount': 'video_original_hoster_count',
        'visitedHosterCount': 'video_visited_hoster_count',
        'lazyHosterCount': 'video_lazy_hoster_count',
        'attemptedLazyHosterCount': 'video_attempted_lazy_hoster_count',
        'resolvedLazyHosterCount': 'video_resolved_lazy_hoster_count',
        'failedLazyHosterCount': 'video_failed_lazy_hoster_count',
        'deferredHosterCount': 'video_deferred_hoster_count',
        'discardedHosterCount': 'video_discarded_hoster_count',
        'truncatedHosterCount': 'video_truncated_hoster_count',
        'discardedTrackCount': 'video_discarded_track_count',
        'localHlsBridgeCount': 'video_local_hls_bridge_count',
      }.entries) {
        final value = _boundedDiagnosticCount(
          response[entry.key],
          maximum: 100000,
        );
        if (value != null) _resultCounts[entry.value] = value;
      }
    }
  }

  void captureNativeFailure(AniyomiFailure failure) {
    final fields = failure.diagnosticFields;
    _nativeFailure = {
      'native_code': fields['code'] ?? 'native_failure',
      'native_stage': fields['stage'] ?? 'unknown',
      'native_reason_code': fields['reason_code'] ?? 'execution',
      ...failure.brokerDiagnosticFields,
    };
  }

  void noMatch({required String stage, required String reason}) =>
      _finish(outcome: 'no_match', stage: stage, reason: reason);

  void fail({required String stage, required String reason}) =>
      _finish(outcome: 'failure', stage: stage, reason: reason);

  void cancel() =>
      _finish(outcome: 'cancelled', stage: stage, reason: 'request_cancelled');

  void succeed() => _finish(
    outcome: 'success',
    stage: 'complete',
    reason: 'streams_returned',
  );

  void _finish({
    required String outcome,
    required String stage,
    required String reason,
  }) {
    if (_outcome != null) return;
    _outcome = _diagnosticOutcomes.contains(outcome) ? outcome : 'failure';
    this.stage = _diagnosticStages.contains(stage) ? stage : 'runtime';
    _reason = _diagnosticReasons.contains(reason) ? reason : 'provider_error';
  }

  void emit() {
    if (_emitted) return;
    _emitted = true;
    if (_outcome == null) {
      _finish(outcome: 'failure', stage: stage, reason: 'provider_error');
    }
    final recorder = _recorder;
    if (recorder == null) return;
    try {
      recorder({
        'event': 'provider_attempt',
        'outcome': _outcome!,
        'stage': stage,
        'reason_code': _reason!,
        ..._brokerContext,
        ..._nativeFailure,
        ..._resultCounts,
        ..._httpContext,
        'title_alias_count': titleAliasCount.clamp(0, 32),
        'search_query_count': searchQueryCount.clamp(
          0,
          _maximumAniyomiSearchQueries,
        ),
        'search_result_count': searchResultCount.clamp(
          0,
          100 * _maximumAniyomiSearchQueries,
        ),
        'exact_title_match_count': exactTitleMatchCount.clamp(0, 100),
        'episode_count': episodeCount.clamp(0, 4096),
        'exact_episode_match_count': exactEpisodeMatchCount.clamp(0, 4096),
        'episode_label_fallback_count': episodeLabelFallbackCount.clamp(
          0,
          4096,
        ),
        'details_metadata_mismatch_count': detailsMetadataMismatchCount.clamp(
          0,
          2,
        ),
        'raw_video_count': rawVideoCount.clamp(0, 64),
        'playable_video_count': playableVideoCount.clamp(0, 64),
        'rejected_unsupported_playback_count': unsupportedPlaybackCount.clamp(
          0,
          64,
        ),
        // Retain the old field for report-schema compatibility. It now means
        // tracks rejected by the bounded public-network/player boundary.
        'ignored_external_audio_count': rejectedExternalAudioCount.clamp(0, 64),
        'external_audio_track_count': externalAudioTrackCount.clamp(0, 64),
        'rejected_external_audio_count': rejectedExternalAudioCount.clamp(
          0,
          64,
        ),
        'rejected_invalid_media_url_count': invalidMediaUrlCount.clamp(0, 64),
        'rejected_unsafe_media_target_count': unsafeMediaTargetCount.clamp(
          0,
          64,
        ),
      });
    } catch (_) {
      // Diagnostics must never alter provider execution.
    }
  }
}

const _diagnosticOutcomes = {'success', 'no_match', 'failure', 'cancelled'};
const _maximumAniyomiAggregateVideos = 64 * 4096;
const _brokerSizeBuckets = {
  'none',
  'lt64k',
  '64to128k',
  '128to256k',
  'over256k',
};
const _brokerStatusClasses = {'none', '1xx', '2xx', '3xx', '4xx', '5xx'};
const _httpFailureReasons = {
  'policy',
  'network',
  'unsupported',
  'invalid',
  'none',
};

int? _boundedDiagnosticCount(Object? value, {required int maximum}) {
  if (value is! num || !value.isFinite) return null;
  final integer = value.toInt();
  if (value.toDouble() != integer.toDouble() || integer < 0) return null;
  return integer.clamp(0, maximum);
}

const _diagnosticStages = {
  'validation',
  'search',
  'title_matching',
  'episode_lookup',
  'stream_extraction',
  'complete',
  'runtime',
};
const _diagnosticReasons = {
  'streams_returned',
  'catalog_title_missing',
  'ambiguous_title_match',
  'no_exact_title_match',
  'details_title_mismatch',
  'details_locator_mismatch',
  'details_year_mismatch',
  'episode_not_found',
  'ambiguous_episode_match',
  'empty_sources',
  'invalid_payload',
  'invalid_response',
  'unsafe_target',
  'network',
  'runtime_api',
  'response_limit',
  'timeout',
  'request_cancelled',
  'provider_error',
};

List<Map<String, dynamic>> _items(
  Map<String, dynamic> response,
  String key, {
  required int maximum,
}) {
  final values = response[key];
  if (values is! List ||
      values.length > maximum ||
      values.any((value) => value is! Map)) {
    _invalidResponse();
  }
  // StandardMessageCodec preserves nested maps as Map<Object?, Object?>,
  // unlike JSON decoding. _checkResponse already validates every key.
  return values
      .map((value) => Map<String, dynamic>.from(value as Map))
      .toList();
}

void _checkResponse(Map<String, dynamic> response) {
  var count = 0;
  void inspect(Object? value, int depth) {
    if (++count > 50000 || depth > 16) _invalidResponse();
    if (value is String && value.length > 4096) _invalidResponse();
    if (value is num && !value.isFinite) _invalidResponse();
    if (value is List) {
      for (final child in value) {
        inspect(child, depth + 1);
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) _invalidResponse();
        inspect(entry.key, depth + 1);
        inspect(entry.value, depth + 1);
      }
    } else if (value != null &&
        value is! String &&
        value is! num &&
        value is! bool) {
      _invalidResponse();
    }
  }

  inspect(response, 0);
  if (utf8.encode(jsonEncode(response)).length > 2 * 1024 * 1024) {
    _invalidResponse();
  }
}

String? _text(Object? value, {required int max}) =>
    value is String &&
        value.trim().isNotEmpty &&
        value.length <= max &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
    ? value.trim()
    : null;

String _titleKey(String title) => title
    .toLowerCase()
    // Provider catalogs frequently omit punctuation used by AniList (for
    // example `Steins;Gate` versus `Steins Gate`). Keep every Unicode letter
    // and number so sequel/season digits remain strict identity evidence,
    // while treating presentation punctuation as spacing only.
    .replaceAll(RegExp(r"['’]", unicode: true), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

bool _catalogTitleMatches(String providerTitle, Set<String> titleKeys) {
  final exact = _titleKey(providerTitle);
  if (titleKeys.contains(exact)) return true;
  return titleKeys.contains(_providerComparableTitleKey(providerTitle));
}

/// Removes only explicit provider presentation labels from the end of a title.
/// It deliberately does not perform fuzzy, prefix, sequel, or numeric matching.
/// This covers `Title (Dub)` or `Title (Uncensored)` without allowing `Title`
/// to select `Title 2`, another season, or the first vaguely similar search hit.
String _providerComparableTitleKey(String title) {
  return _providerTitleVariant(title).baseKey;
}

final RegExp _providerVariantSuffix = RegExp(
  r'''\s*(?:[\[(]\s*(?:(?:multi|dual)\s*[- ]?audio|(?:english|eng|japanese|jpn|spanish|spa|latino|castellano|portuguese|por|french|fre|fra|german|ger|deu|hindi|hin)(?:\s+(?:sub(?:bed)?|dub(?:bed)?))?|sub(?:bed)?|dub(?:bed)?|soft\s*sub|hard\s*sub)(?:\s*[/,+&]\s*(?:(?:multi|dual)\s*[- ]?audio|(?:english|eng|japanese|jpn|spanish|spa|latino|castellano|portuguese|por|french|fre|fra|german|ger|deu|hindi|hin)(?:\s+(?:sub(?:bed)?|dub(?:bed)?))?|sub(?:bed)?|dub(?:bed)?|soft\s*sub|hard\s*sub))*\s*[\])]|[-–—:]\s*(?:sub(?:bed)?|dub(?:bed)?|(?:multi|dual)\s*[- ]?audio))\s*$''',
  caseSensitive: false,
);

// A release cut is presentation metadata, not a different series or an audio
// declaration. Keep this vocabulary bracketed and narrow: canonical words,
// sequel/season/year labels and other editions are never stripped.
final RegExp _providerCutSuffix = RegExp(
  r'\s*(?:\(\s*(?:un)?censored\s*\)|\[\s*(?:un)?censored\s*\])\s*$',
  caseSensitive: false,
);

_AniyomiTitleVariant _providerTitleVariant(String title) {
  var comparable = title.trim();
  final labels = <String>[];
  // A few catalogs append more than one marker, for example [English] [Dub].
  for (var ignored = 0; ignored < 3; ignored++) {
    final audioMatch = _providerVariantSuffix.firstMatch(comparable);
    final match = audioMatch ?? _providerCutSuffix.firstMatch(comparable);
    if (match == null || match.start <= 0) break;
    final stripped = comparable.substring(0, match.start).trimRight();
    if (stripped.isEmpty) break;
    if (audioMatch != null) labels.add(match.group(0)!);
    comparable = stripped;
  }
  final normalized = labels.join(' ').toLowerCase();
  final languages = <String>{};
  for (final match in _providerVariantLanguage.allMatches(normalized)) {
    final language = canonicalCaptionLanguageCode(match.group(0));
    if (language.isNotEmpty) languages.add(language);
  }
  final declaresSub = RegExp(
    r'(?:^|[^a-z])sub(?:bed)?(?:$|[^a-z])',
  ).hasMatch(normalized);
  final declaresDub = RegExp(
    r'(?:^|[^a-z])dub(?:bed)?(?:$|[^a-z])',
  ).hasMatch(normalized);
  final declaresMultiple = RegExp(
    r'(?:^|[^a-z])(?:multi|dual)\s*[- ]?audio(?:$|[^a-z])',
  ).hasMatch(normalized);
  final capability = declaresMultiple || declaresSub && declaresDub
      ? WebStreamAudioCapability.subAndDub
      : declaresDub
      ? WebStreamAudioCapability.dub
      : declaresSub
      ? WebStreamAudioCapability.sub
      : languages.contains('eng') && languages.contains('jpn')
      ? WebStreamAudioCapability.subAndDub
      : languages.length == 1 && languages.contains('eng')
      ? WebStreamAudioCapability.dub
      : languages.length == 1 && languages.contains('jpn')
      ? WebStreamAudioCapability.sub
      : WebStreamAudioCapability.unknown;
  // `English Sub` describes subtitle language, not English spoken audio.
  // Standalone language variants and Dub variants are safe audio evidence.
  final audioLanguages = declaresSub && !declaresDub && !declaresMultiple
      ? languages.where((language) => language == 'jpn').toSet()
      : languages;
  return _AniyomiTitleVariant(
    baseKey: _titleKey(comparable),
    capability: capability,
    audioLanguages: Set.unmodifiable(audioLanguages),
  );
}

final RegExp _providerVariantLanguage = RegExp(
  r'\b(?:english|eng|japanese|jpn|spanish|spa|latino|castellano|portuguese|por|french|fre|fra|german|ger|deu|hindi|hin)\b',
  caseSensitive: false,
);

final class _AniyomiTitleVariant {
  const _AniyomiTitleVariant({
    required this.baseKey,
    required this.capability,
    required this.audioLanguages,
  });

  final String baseKey;
  final WebStreamAudioCapability capability;
  final Set<String> audioLanguages;
}

final class _AniyomiTitleCandidate {
  const _AniyomiTitleCandidate({
    required this.url,
    required this.item,
    required this.variant,
  });

  final String url;
  final Map<String, dynamic> item;
  final _AniyomiTitleVariant variant;
}

bool _isExactRequestedSeason(Map<String, dynamic> season, int requestedSeason) {
  final number = season['seasonNumber'];
  if (number is num && number.isFinite && number >= 0) {
    return number.toDouble() == requestedSeason.toDouble();
  }
  final title = _text(season['title'], max: 256);
  if (title == null) return false;
  final expressions = <RegExp>[
    RegExp(r'\bseason\s*0*(\d{1,3})\b', caseSensitive: false),
    RegExp(r'\b0*(\d{1,3})(?:st|nd|rd|th)\s+season\b', caseSensitive: false),
    RegExp(r'\bs0*(\d{1,3})(?=\s*e\d|\b)', caseSensitive: false),
  ];
  for (final expression in expressions) {
    final parsed = int.tryParse(expression.firstMatch(title)?.group(1) ?? '');
    if (parsed != null) return parsed == requestedSeason;
  }
  return false;
}

String? _locator(Object? value) {
  final text = _text(value, max: 2048);
  if (text == null || text.contains('\\')) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      (uri.hasScheme && safePublicHttpsUri(text) == null) ||
      (!uri.hasScheme && uri.hasAuthority)) {
    return null;
  }
  return text;
}

bool _validSourceId(String value) {
  if (!RegExp(r'^-?(?:0|[1-9][0-9]{0,18})$').hasMatch(value) || value == '-0') {
    return false;
  }
  final number = BigInt.tryParse(value);
  return number != null &&
      number >= BigInt.parse('-9223372036854775808') &&
      number <= BigInt.parse('9223372036854775807');
}

bool _requiresNativePlaybackArguments(Map<String, dynamic> video) {
  for (final key in ['mpvArgs', 'ffmpegStreamArgs', 'ffmpegVideoArgs']) {
    final value = video[key];
    if (value != null && (value is! List || value.isNotEmpty)) return true;
  }
  return false;
}

List<({Uri uri, String language})> _tracks(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.length > 64) _invalidResponse();
  final result = <({Uri uri, String language})>[];
  for (final raw in value) {
    if (raw is! Map) _invalidResponse();
    final uri = safePublicHttpsUri(raw['url']);
    final label = _text(raw['lang'], max: 80);
    final language = canonicalCaptionLanguageCode(label);
    if (uri != null && language.isNotEmpty) {
      result.add((uri: uri, language: language));
    }
  }
  return result;
}

List<({Uri uri, String? label, String? language})> _audioTracks(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.length > 64) _invalidResponse();
  final result = <({Uri uri, String? label, String? language})>[];
  final seen = <String>{};
  for (final raw in value) {
    if (raw is! Map) _invalidResponse();
    final uri = safePublicHttpsUri(raw['url']);
    if (uri == null || !seen.add(uri.toString())) continue;
    final label = _text(raw['lang'] ?? raw['label'], max: 80);
    final canonical = canonicalCaptionLanguageCode(label);
    result.add((
      uri: uri,
      label: label,
      language: canonical.isEmpty ? null : canonical,
    ));
  }
  return result;
}

bool _sameHttpsOrigin(Uri left, Uri right) {
  if (left.scheme.toLowerCase() != 'https' ||
      right.scheme.toLowerCase() != 'https' ||
      left.host.toLowerCase() != right.host.toLowerCase()) {
    return false;
  }
  final leftPort = left.hasPort ? left.port : 443;
  final rightPort = right.hasPort ? right.port : 443;
  return leftPort == rightPort;
}

Never _invalidResponse() => throw const FormatException(
  'Invalid or oversized Aniyomi runtime response.',
);
