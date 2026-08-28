import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/application/next_episode_preparation_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

@immutable
class WatchPartyPlaybackAffinity {
  const WatchPartyPlaybackAffinity({
    this.preferredProvider,
    this.preferredAuthor,
    this.preferredSourceId,
    this.preferredWebProviderId,
    this.preferredQualityHeight,
    this.preferredAudio,
  });

  final String? preferredProvider;
  final String? preferredAuthor;
  final String? preferredSourceId;
  final String? preferredWebProviderId;
  final int? preferredQualityHeight;
  final PlaybackAudioPreference? preferredAudio;
}

final watchPartyPlaybackAffinityProvider =
    StateNotifierProvider<
      WatchPartyPlaybackAffinityController,
      WatchPartyPlaybackAffinity?
    >((_) => WatchPartyPlaybackAffinityController());

/// Registers affinity for only the currently mounted player router.
///
/// The opaque owner prevents a late disposal from an old player route from
/// clearing the hints already registered by its replacement.
class WatchPartyPlaybackAffinityController
    extends StateNotifier<WatchPartyPlaybackAffinity?> {
  WatchPartyPlaybackAffinityController() : super(null);

  Object? _owner;
  bool _disposed = false;

  void bind(Object owner, WatchPartyPlaybackAffinity affinity) {
    if (_disposed) return;
    _owner = owner;
    state = affinity;
  }

  void unbind(Object owner) {
    if (_disposed) return;
    if (!identical(_owner, owner)) return;
    _owner = null;
    state = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _owner = null;
    super.dispose();
  }
}

typedef WatchPartyPlayerRouteHandoff = Future<bool> Function();

final watchPartyPlayerRouteHandoffProvider =
    Provider<WatchPartyPlayerRouteHandoffController>(
      (_) => WatchPartyPlayerRouteHandoffController(),
    );

/// Joins decoder/surface teardown before the global follower replaces a
/// player route. Each mounted player owns one opaque registration so a late
/// disposal from an old engine cannot clear its replacement's barrier.
class WatchPartyPlayerRouteHandoffController {
  Object? _owner;
  WatchPartyPlayerRouteHandoff? _handoff;
  Future<bool>? _inFlight;

  bool get hasActivePlayer => _handoff != null;

  void bind(Object owner, WatchPartyPlayerRouteHandoff handoff) {
    _owner = owner;
    _handoff = handoff;
  }

  void unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _handoff = null;
  }

  Future<bool> releaseActivePlayer() {
    final active = _inFlight;
    if (active != null) return active;
    final owner = _owner;
    final handoff = _handoff;
    if (owner == null || handoff == null) return Future<bool>.value(true);
    final operation = _run(owner, handoff);
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
  }

  Future<bool> _run(Object owner, WatchPartyPlayerRouteHandoff handoff) async {
    try {
      final released = await handoff();
      return released && identical(_owner, owner);
    } catch (_) {
      return false;
    }
  }
}

@immutable
class WatchPartyMediaFollowRequest {
  const WatchPartyMediaFollowRequest({
    required this.location,
    required this.roomCode,
    required this.anilistId,
    required this.episode,
    required this.revision,
    required this.sessionGeneration,
    this.sourceFingerprint,
    this.sourceKey,
  });

  final String location;
  final String roomCode;
  final int anilistId;
  final int episode;
  final int revision;
  final int sessionGeneration;
  final String? sourceFingerprint;
  final String? sourceKey;
  String get eventKey =>
      '$roomCode:$sessionGeneration:$anilistId:$episode:$revision';
  String get mediaKey =>
      '$roomCode:$sessionGeneration:$anilistId:$episode:'
      '${sourceKey ?? sourceFingerprint ?? 'any'}';
}

/// Keeps only the newest host-media request until the next navigation frame.
/// This prevents a rapid E2 -> E3 change from starting a stale E2 route.
class WatchPartyMediaFollowQueue {
  WatchPartyMediaFollowRequest? _latest;

  void add(WatchPartyMediaFollowRequest request) {
    final current = _latest;
    if (current == null ||
        request.sessionGeneration > current.sessionGeneration ||
        request.sessionGeneration == current.sessionGeneration &&
            request.revision >= current.revision) {
      _latest = request;
    }
  }

  WatchPartyMediaFollowRequest? takeLatest() {
    final value = _latest;
    _latest = null;
    return value;
  }

  bool get hasPending => _latest != null;
}

/// Caps automatic retry churn when a mounted player cannot release its
/// decoder yet. A different host target starts with a fresh, short backoff.
class WatchPartyMediaFollowRetryBudget {
  WatchPartyMediaFollowRetryBudget({
    this.maximumAttempts = 3,
    this.recoveryDelay = const Duration(seconds: 5),
  }) : assert(maximumAttempts > 0 && maximumAttempts <= 8),
       assert(recoveryDelay > Duration.zero);

  final int maximumAttempts;
  final Duration recoveryDelay;
  String? _mediaKey;
  int _attempts = 0;

  bool observe(WatchPartyMediaFollowRequest request) {
    if (_mediaKey == request.mediaKey) return false;
    _mediaKey = request.mediaKey;
    _attempts = 0;
    return true;
  }

  Duration? nextDelay(WatchPartyMediaFollowRequest request) {
    observe(request);
    if (_attempts >= maximumAttempts) return null;
    final delay = Duration(milliseconds: 200 * (1 << _attempts));
    _attempts += 1;
    return delay;
  }

  void reset(WatchPartyMediaFollowRequest request) {
    if (_mediaKey != request.mediaKey) return;
    _mediaKey = null;
    _attempts = 0;
  }
}

/// Converts authenticated room snapshots into catalog-only navigation.
///
/// Room tokens, host stream URLs, headers, magnets, and timeline fingerprints
/// are intentionally absent from both the request and its route.
class WatchPartyGuestMediaFollowPlanner {
  WatchPartySession? _session;
  int _sessionGeneration = 0;
  int _highestRevision = -1;
  String? _activeTargetKey;

  WatchPartyMediaFollowRequest? evaluate(
    WatchPartyState party, {
    WatchPartyPlaybackAffinity? affinity,
  }) {
    final session = party.session;
    if (!identical(session, _session)) {
      _session = session;
      _sessionGeneration++;
      _highestRevision = -1;
      _activeTargetKey = null;
    }
    if (session == null || session.role != WatchPartyRole.guest) return null;
    final snapshot = party.snapshot;
    if (snapshot == null || snapshot.roomCode != session.roomCode) return null;
    if (snapshot.revision < _highestRevision) return null;
    _highestRevision = snapshot.revision;

    final target = _safeCatalogTarget(snapshot.media);
    if (target == null) return null;
    // Never navigate away from a private/local playback attachment. Private
    // rooms also fail [_safeCatalogTarget], so neither side can route local
    // media based on unverifiable metadata.
    if (party.attachedMedia?.kind == 'private') return null;

    final sourceDescriptor = target.media.sourceDescriptor;
    final sourceFingerprint = sourceDescriptor?.fingerprint;
    final sourceKey = sourceDescriptor?.sourceKey;
    final targetKey =
        '${session.roomCode}:$_sessionGeneration:'
        '${target.anilistId}:${target.episode}:'
        '${sourceKey ?? sourceFingerprint ?? 'any'}';
    final attached = party.attachedMedia;
    final attachedToTargetEpisode =
        attached?.kind == 'anilist' &&
        attached?.anilistId == target.anilistId &&
        attached?.episode == target.episode;
    final sameSource =
        sourceDescriptor == null ||
        attached?.sourceDescriptor == sourceDescriptor;
    if (attachedToTargetEpisode && sameSource) {
      _activeTargetKey = targetKey;
      return null;
    }
    if (_activeTargetKey == targetKey) return null;
    _activeTargetKey = targetKey;
    return WatchPartyMediaFollowRequest(
      location: watchPartyCatalogFollowLocation(
        target.media,
        affinity: affinity,
      ),
      roomCode: session.roomCode,
      anilistId: target.anilistId,
      episode: target.episode,
      revision: snapshot.revision,
      sessionGeneration: _sessionGeneration,
      sourceFingerprint: sourceFingerprint,
      sourceKey: sourceKey,
    );
  }

  /// Releases only the exact target claimed by [evaluate] so the follower may
  /// retry after a failed decoder handoff. A stale timer can never reopen an
  /// older episode or a previous room generation.
  bool releaseFailedTarget(WatchPartyMediaFollowRequest request) {
    if (!ownsTarget(request)) return false;
    _activeTargetKey = null;
    return true;
  }

  /// A late route failure must not disturb a newer host target or room.
  bool ownsTarget(WatchPartyMediaFollowRequest request) =>
      request.sessionGeneration == _sessionGeneration &&
      _activeTargetKey == request.mediaKey;
}

typedef _SafeCatalogTarget = ({
  WatchPartyMedia media,
  int anilistId,
  int episode,
});

_SafeCatalogTarget? _safeCatalogTarget(WatchPartyMedia? media) {
  if (media == null || media.kind != 'anilist') return null;
  final anilistId = media.anilistId;
  final episode = media.episode;
  if (anilistId == null ||
      anilistId <= 0 ||
      anilistId > 100000000 ||
      episode == null ||
      episode <= 0 ||
      episode > 100000) {
    return null;
  }
  return (media: media, anilistId: anilistId, episode: episode);
}

String watchPartyCatalogFollowLocation(
  WatchPartyMedia media, {
  WatchPartyPlaybackAffinity? affinity,
}) {
  final target = _safeCatalogTarget(media);
  if (target == null) {
    throw ArgumentError.value(media, 'media', 'Expected a catalog episode');
  }
  final title = _boundedRouteText(media.title, maxLength: 240) ?? 'Anime';
  final titleEnglish = _boundedRouteText(media.titleEnglish, maxLength: 240);
  final titleRomaji = _boundedRouteText(media.titleRomaji, maxLength: 240);
  final year = media.year != null && media.year! >= 1900 && media.year! <= 2200
      ? media.year
      : null;
  final cover = _safePublicCover(media.coverUrl);
  final quality = affinity?.preferredQualityHeight;
  final sourceDescriptor = media.sourceDescriptor;
  final preferredQuality = sourceDescriptor?.qualityHeight ?? quality;
  final safeQuality =
      preferredQuality != null &&
          preferredQuality >= 144 &&
          preferredQuality <= 4320
      ? preferredQuality
      : null;
  final provider = _boundedRouteText(
    affinity?.preferredProvider,
    maxLength: 160,
  );
  final author = _boundedRouteText(affinity?.preferredAuthor, maxLength: 96);
  final sourceId = _boundedRouteText(
    affinity?.preferredSourceId,
    maxLength: 160,
  );
  final webProviderId = _boundedRouteText(
    affinity?.preferredWebProviderId,
    maxLength: 160,
  );
  final yearText = year?.toString();
  final qualityText = safeQuality?.toString();
  final preferredAudio =
      sourceDescriptor?.audio.name ?? affinity?.preferredAudio?.name;
  final query = <String, String>{
    'anilistId': '${target.anilistId}',
    'episode': '${target.episode}',
    'title': title,
    'titleEnglish': ?titleEnglish,
    'titleRomaji': ?titleRomaji,
    'year': ?yearText,
    'cover': ?cover,
    'autoplay': '1',
    'watchPartyFollow': '1',
    'preferredProvider': ?provider,
    'preferredAuthor': ?author,
    'preferredSourceId': ?sourceId,
    'preferredWebProviderId': ?webProviderId,
    'preferredQualityHeight': ?qualityText,
    'preferredAudio': ?preferredAudio,
    'watchPartySourceClass': ?sourceDescriptor?.sourceClass.name,
    'watchPartySourceFingerprint': ?sourceDescriptor?.fingerprint,
    'watchPartySourceKey': ?sourceDescriptor?.sourceKey,
  };
  return Uri(path: '/resolve', queryParameters: query).toString();
}

String? _boundedRouteText(String? value, {required int maxLength}) {
  final normalized = value
      ?.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > maxLength) {
    return null;
  }
  return normalized;
}

String? _safePublicCover(String? value) {
  final bounded = _boundedRouteText(value, maxLength: 2048);
  final uri = Uri.tryParse(bounded ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

/// Lives above GoRouter's pages so a replacement from player -> resolver does
/// not drop the listener. Newer host revisions can therefore replace a stale
/// in-flight resolver while the room session remains alive.
typedef WatchPartyRouteReplacement =
    Future<void> Function(String location, {Object? extra});

typedef WatchPartyPreparedTargetReader =
    Future<PreparedNextEpisode?> Function({
      required int mediaId,
      required int episode,
    });

class WatchPartyMediaFollowScope extends ConsumerStatefulWidget {
  const WatchPartyMediaFollowScope({
    required this.router,
    required this.child,
    this.routeReplacement,
    this.preparedTargetReader,
    super.key,
  });

  final GoRouter router;
  final Widget child;

  /// Narrow injection seams used by route-failure tests. Production callers
  /// use GoRouter and the preparation controller directly.
  final WatchPartyRouteReplacement? routeReplacement;
  final WatchPartyPreparedTargetReader? preparedTargetReader;

  @override
  ConsumerState<WatchPartyMediaFollowScope> createState() =>
      _WatchPartyMediaFollowScopeState();
}

class _WatchPartyMediaFollowScopeState
    extends ConsumerState<WatchPartyMediaFollowScope> {
  final _planner = WatchPartyGuestMediaFollowPlanner();
  final _queue = WatchPartyMediaFollowQueue();
  ProviderSubscription<WatchPartyState>? _partySubscription;
  ProviderSubscription<WatchPartyPlaybackAffinity?>? _affinitySubscription;
  final _retryBudget = WatchPartyMediaFollowRetryBudget();
  Timer? _retryTimer;
  bool _navigationScheduled = false;

  @override
  void initState() {
    super.initState();
    _partySubscription = ref.listenManual(
      watchPartyControllerProvider,
      (_, _) => _evaluate(),
    );
    _affinitySubscription = ref.listenManual(
      watchPartyPlaybackAffinityProvider,
      (_, _) => _evaluate(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluate());
  }

  void _evaluate() {
    if (!mounted) return;
    final request = _planner.evaluate(
      ref.read(watchPartyControllerProvider),
      affinity: ref.read(watchPartyPlaybackAffinityProvider),
    );
    if (request == null) return;
    if (_retryBudget.observe(request)) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    _queue.add(request);
    if (_navigationScheduled) return;
    _navigationScheduled = true;
    scheduleMicrotask(_drainNavigation);
  }

  Future<void> _drainNavigation() async {
    PreparedNextEpisode? ownedPrepared;
    WatchPartyMediaFollowRequest? retryCandidate;
    try {
      if (!mounted) return;
      final initialLatest = _queue.takeLatest();
      if (initialLatest == null) return;
      WatchPartyMediaFollowRequest latest = initialLatest;
      retryCandidate = latest;
      while (mounted) {
        final current = widget.router.routeInformationProvider.value.uri;
        if (watchPartyRouteMatchesTarget(current, latest)) {
          _retryBudget.reset(latest);
          retryCandidate = null;
          return;
        }

        ownedPrepared = await _takePreparedTarget(
          mediaId: latest.anilistId,
          episode: latest.episode,
        );
        if (!mounted) return;
        if (ownedPrepared != null &&
            !preparedWatchPartyTargetMatches(ownedPrepared, latest)) {
          await _closePreparedWatchPartyTarget(ownedPrepared);
          ownedPrepared = null;
        }
        final supersedingBeforeDismiss = _queue.takeLatest();
        if (supersedingBeforeDismiss != null) {
          await _closePreparedWatchPartyTarget(ownedPrepared);
          ownedPrepared = null;
          latest = supersedingBeforeDismiss;
          retryCandidate = latest;
          continue;
        }

        final routeHandoff = ref.read(watchPartyPlayerRouteHandoffProvider);
        if (routeHandoff.hasActivePlayer) {
          final released = await routeHandoff.releaseActivePlayer();
          if (!released || !mounted) {
            if (mounted) _scheduleNavigationRetry(latest);
            retryCandidate = null;
            return;
          }
          final supersedingAfterRelease = _queue.takeLatest();
          if (supersedingAfterRelease != null) {
            await _closePreparedWatchPartyTarget(ownedPrepared);
            ownedPrepared = null;
            latest = supersedingAfterRelease;
            retryCandidate = latest;
            continue;
          }
        }
        final refreshed = widget.router.routeInformationProvider.value.uri;
        if (watchPartyRouteMatchesTarget(refreshed, latest)) {
          _retryBudget.reset(latest);
          retryCandidate = null;
          return;
        }

        final prepared = ownedPrepared;
        if (prepared != null) {
          final lease = prepared.launch.stream.playbackLease;
          if (latest.sourceKey case final sourceKey?) {
            ref
                .read(watchPartyControllerProvider.notifier)
                .prepareExactSourceHandoff(targetSourceKey: sourceKey);
          }
          final navigation = _replaceRoute(
            preparedNextEpisodePlayerLocation(
              prepared,
              watchPartyTargetSourceKey: latest.sourceKey,
            ),
            extra: prepared.launch,
          );
          // Ownership passes to the new player as soon as GoRouter accepts
          // the local launch. Only an asynchronous navigation failure retains
          // responsibility here.
          ownedPrepared = null;
          _trackRouteReplacement(
            navigation,
            latest,
            onRejected: () async => lease?.close(),
          );
        } else {
          _trackRouteReplacement(_replaceRoute(latest.location), latest);
        }
        retryCandidate = null;
        return;
      }
    } catch (_) {
      final failed = retryCandidate;
      if (mounted && failed != null) _scheduleNavigationRetry(failed);
    } finally {
      await _closePreparedWatchPartyTarget(ownedPrepared);
      _navigationScheduled = false;
      if (mounted && _queue.hasPending) {
        _navigationScheduled = true;
        scheduleMicrotask(_drainNavigation);
      }
    }
  }

  Future<PreparedNextEpisode?> _takePreparedTarget({
    required int mediaId,
    required int episode,
  }) {
    final reader = widget.preparedTargetReader;
    if (reader != null) {
      return reader(mediaId: mediaId, episode: episode);
    }
    return ref
        .read(nextEpisodePreparationControllerProvider)
        .takePreparedTarget(mediaId: mediaId, episode: episode);
  }

  Future<void> _replaceRoute(String location, {Object? extra}) async {
    final replacement = widget.routeReplacement;
    if (replacement != null) {
      await replacement(location, extra: extra);
      return;
    }
    await widget.router.pushReplacement<void>(location, extra: extra);
  }

  bool _routeMatches(WatchPartyMediaFollowRequest request) =>
      watchPartyRouteMatchesTarget(
        widget.router.routeInformationProvider.value.uri,
        request,
      );

  void _trackRouteReplacement(
    Future<void> navigation,
    WatchPartyMediaFollowRequest request, {
    Future<void> Function()? onRejected,
  }) {
    // GoRouter's replacement future normally completes when the destination
    // later pops, so route acceptance is observed on the next frame instead
    // of awaiting that future.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routeMatches(request)) _retryBudget.reset(request);
    });
    unawaited(
      navigation.then<void>(
        (_) {
          if (mounted && _routeMatches(request)) _retryBudget.reset(request);
        },
        onError: (Object _, StackTrace _) async {
          if (mounted && _routeMatches(request)) {
            _retryBudget.reset(request);
            return;
          }
          await onRejected?.call();
          if (mounted) _scheduleNavigationRetry(request);
        },
      ),
    );
  }

  void _scheduleNavigationRetry(WatchPartyMediaFollowRequest request) {
    if (!_planner.ownsTarget(request)) return;
    final retryDelay = _retryBudget.nextDelay(request);
    final exhausted = retryDelay == null;
    final delay = retryDelay ?? _retryBudget.recoveryDelay;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!mounted || !_planner.releaseFailedTarget(request)) return;
      if (exhausted) _retryBudget.reset(request);
      _evaluate();
    });
  }

  @override
  void dispose() {
    _partySubscription?.close();
    _affinitySubscription?.close();
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

bool watchPartyRouteMatchesTarget(
  Uri route,
  WatchPartyMediaFollowRequest target,
) {
  if ((route.path != '/resolve' && route.path != '/player') ||
      route.queryParameters['anilistId'] != '${target.anilistId}' ||
      route.queryParameters['episode'] != '${target.episode}') {
    return false;
  }
  final sourceKey = target.sourceKey;
  if (sourceKey != null) {
    return switch (route.path) {
      '/resolve' => route.queryParameters['watchPartySourceKey'] == sourceKey,
      '/player' =>
        route.queryParameters['watchPartyTargetSourceKey'] == sourceKey,
      _ => false,
    };
  }
  final fingerprint = target.sourceFingerprint;
  if (fingerprint == null) return true;
  return switch (route.path) {
    '/resolve' =>
      route.queryParameters['watchPartySourceFingerprint'] == fingerprint,
    '/player' =>
      route.queryParameters['watchPartyTargetFingerprint'] == fingerprint,
    _ => false,
  };
}

bool preparedWatchPartyTargetMatches(
  PreparedNextEpisode prepared,
  WatchPartyMediaFollowRequest target,
) {
  final descriptor = WatchPartySourceDescriptor.tryForRelease(
    prepared.launch.selectedRelease,
    requestedAudio: prepared.launch.requestedAudio,
  );
  if (target.sourceKey case final sourceKey?) {
    return descriptor?.sourceKey == sourceKey;
  }
  if (target.sourceFingerprint case final fingerprint?) {
    return descriptor?.fingerprint == fingerprint;
  }
  return true;
}

Future<void> _closePreparedWatchPartyTarget(
  PreparedNextEpisode? prepared,
) async {
  try {
    await prepared?.close();
  } catch (_) {
    // A transferred proxy/debrid lease is best-effort cleanup only.
  }
}
