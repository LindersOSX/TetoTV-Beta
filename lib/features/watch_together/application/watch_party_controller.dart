import 'dart:async';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final watchPartyClientProvider = Provider<WatchPartyClient>(
  (_) => WatchPartyClient(baseUrl: AppConfig.watchTogetherBaseUrl),
);

final watchPartyControllerProvider =
    StateNotifierProvider<WatchPartyController, WatchPartyState>((ref) {
      return WatchPartyController(
        ref.watch(watchPartyClientProvider),
        diagnostics: (message, details) =>
            TetoTvDatabase.instance.recordDiagnosticEvent(
              category: 'watch-party',
              message: message,
              details: details,
            ),
      );
    });

typedef WatchPartyDiagnosticsSink =
    Future<void> Function(String message, Map<String, Object?> details);

enum WatchPartyConnection { disconnected, connecting, connected, reconnecting }

class WatchPartyNotice {
  const WatchPartyNotice({
    required this.sequence,
    required this.message,
    this.eventType,
    this.displayName,
    this.actionText,
    this.avatarUrl,
  });

  final int sequence;
  final String message;
  final WatchPartyEventType? eventType;
  final String? displayName;
  final String? actionText;
  final String? avatarUrl;

  bool get isParticipantEvent =>
      eventType != null && displayName != null && actionText != null;
}

const watchPartyNoticeLifetime = Duration(seconds: 5);

class WatchPartyState {
  const WatchPartyState({
    this.connection = WatchPartyConnection.disconnected,
    this.session,
    this.snapshot,
    this.attachedMedia,
    this.timelineMismatch = false,
    this.timelineCompatibility = WatchPartyTimelineCompatibility.unverified,
    this.guestSyncOffset = Duration.zero,
    this.membershipActionInFlight = false,
    this.notices = const <WatchPartyNotice>[],
    this.message,
  });

  final WatchPartyConnection connection;
  final WatchPartySession? session;
  final WatchPartySnapshot? snapshot;
  final WatchPartyMedia? attachedMedia;
  final bool timelineMismatch;
  final WatchPartyTimelineCompatibility timelineCompatibility;
  final Duration guestSyncOffset;
  final bool membershipActionInFlight;
  final List<WatchPartyNotice> notices;
  final String? message;

  /// Compatibility view for code which only needs the oldest active notice.
  WatchPartyNotice? get notice => notices.isEmpty ? null : notices.first;

  bool get isBusy => connection == WatchPartyConnection.connecting;
  bool get isActive => session != null;
  bool get isHost => session?.role == WatchPartyRole.host;

  /// Guests hand playback authority to the host only while a concrete player
  /// is attached. Browsing the lobby before choosing matching media remains
  /// fully interactive.
  bool get guestPlaybackControlsLocked =>
      session?.role == WatchPartyRole.guest && attachedMedia != null;

  WatchPartyState copyWith({
    WatchPartyConnection? connection,
    Object? session = _unset,
    Object? snapshot = _unset,
    Object? attachedMedia = _unset,
    bool? timelineMismatch,
    WatchPartyTimelineCompatibility? timelineCompatibility,
    Duration? guestSyncOffset,
    bool? membershipActionInFlight,
    Object? notices = _unset,
    Object? message = _unset,
  }) => WatchPartyState(
    connection: connection ?? this.connection,
    session: identical(session, _unset)
        ? this.session
        : session as WatchPartySession?,
    snapshot: identical(snapshot, _unset)
        ? this.snapshot
        : snapshot as WatchPartySnapshot?,
    attachedMedia: identical(attachedMedia, _unset)
        ? this.attachedMedia
        : attachedMedia as WatchPartyMedia?,
    timelineMismatch: timelineMismatch ?? this.timelineMismatch,
    timelineCompatibility: timelineCompatibility ?? this.timelineCompatibility,
    guestSyncOffset: guestSyncOffset ?? this.guestSyncOffset,
    membershipActionInFlight:
        membershipActionInFlight ?? this.membershipActionInFlight,
    notices: identical(notices, _unset)
        ? this.notices
        : notices as List<WatchPartyNotice>,
    message: identical(message, _unset) ? this.message : message as String?,
  );
}

const _unset = Object();

class WatchPartyController extends StateNotifier<WatchPartyState> {
  WatchPartyController(this._client, {this.diagnostics})
    : super(const WatchPartyState());

  final WatchPartyClient _client;
  final WatchPartyDiagnosticsSink? diagnostics;
  Timer? _pollTimer;
  StreamSubscription<WatchPartyPlaybackSample>? _playbackSubscription;
  WatchPartyPlaybackPort? _playbackPort;
  WatchPartyPlaybackPort? _pendingPlaybackPort;
  WatchPartyPlaybackSample? _lastSample;
  DateTime? _lastPublishedAt;
  int _generation = 0;
  bool _publishing = false;
  bool _publishAgain = false;
  bool _resyncPublishPending = false;
  Completer<bool>? _resyncPublishCompleter;
  bool _guestReady = false;
  WatchPartySession? _guestReadySession;
  Future<void> _guestReadyTail = Future<void>.value();
  bool _guestReconciliationInFlight = false;
  bool _guestReconcileAgain = false;
  WatchPartySnapshot? _pendingGuestSnapshot;
  int _lastGuestCommandRevision = -1;
  int _lastGuestResyncRevision = -1;
  DateTime? _lastGuestCommandAt;
  int _playbackAttachmentGeneration = 0;
  final Map<int, Timer> _noticeTimers = <int, Timer>{};
  final Map<String, String?> _participantAvatars = <String, String?>{};
  int _lastEventSequence = 0;
  int _localNoticeSequence = 1 << 30;
  bool _membershipActionInFlight = false;
  String? _pendingGuestSourceKey;
  int _pendingGuestSourceAfterAttachmentGeneration = -1;
  bool _pendingGuestAllowsDifferentSource = false;
  String? _acceptedGuestSourceKey;
  int _acceptedGuestSourceAttachmentGeneration = -1;
  bool _acceptedGuestAllowsDifferentSource = false;
  int _consecutivePollFailures = 0;
  bool _disposed = false;

  Future<bool> create() async {
    if (_disposed || state.isBusy) return false;
    final generation = ++_generation;
    final previousSession = _disconnectLocally();
    state = const WatchPartyState(connection: WatchPartyConnection.connecting);
    await _sendLeaveBestEffort(previousSession);
    if (_disposed || generation != _generation) return false;
    try {
      final created = await _client.create();
      if (generation != _generation) return false;
      final snapshot = await _client.snapshot(created.session);
      if (generation != _generation) return false;
      state = state.copyWith(
        connection: WatchPartyConnection.connected,
        session: created.session,
        snapshot: snapshot,
        message: 'Room created. Share the code, then start an episode.',
      );
      _seedMembershipEvents(snapshot);
      _recordDiagnostics('Watch Party room created', {
        'event': 'room_created',
        'role': 'host',
        'participant_count': snapshot.participantCount,
      });
      _schedulePoll(generation, immediate: false);
      if (_lastSample != null) unawaited(_publishHostSample(force: true));
      return true;
    } on WatchPartyClientException catch (error) {
      _recordDiagnostics('Watch Party room creation failed', {
        'event': 'room_create_failed',
        'error_code': error.code,
      });
      if (generation == _generation) {
        state = WatchPartyState(message: watchPartyFriendlyError(error));
      }
      return false;
    }
  }

  Future<bool> join(String code) async {
    if (_disposed || state.isBusy) return false;
    final normalizedCode = normalizeWatchPartyCode(code);
    if (normalizedCode == null) {
      state = state.copyWith(
        message: watchPartyFriendlyError(
          const WatchPartyClientException('invalid_room_code'),
        ),
      );
      return false;
    }
    final generation = ++_generation;
    final previousSession = _disconnectLocally();
    state = const WatchPartyState(connection: WatchPartyConnection.connecting);
    await _sendLeaveBestEffort(previousSession);
    if (_disposed || generation != _generation) return false;
    try {
      final joined = await _client.join(normalizedCode);
      if (generation != _generation) return false;
      state = state.copyWith(
        connection: WatchPartyConnection.connected,
        session: joined.session,
        snapshot: joined.snapshot,
        message: joined.snapshot.media == null
            ? 'Joined. Waiting for the host to choose an episode.'
            : 'Joined. Open the host episode when you are ready.',
      );
      _seedMembershipEvents(joined.snapshot);
      _recordDiagnostics('Watch Party room joined', {
        'event': 'room_joined',
        'role': 'guest',
        'participant_count': joined.snapshot.participantCount,
        'host_media_available': joined.snapshot.media != null,
      });
      _schedulePoll(generation, immediate: false);
      if (_playbackPort case final port?) {
        final sample = _lastSample;
        unawaited(
          _setGuestReady(
            sample?.ready == true &&
                _guestSampleMatchesRemoteMedia(
                  sample!.media,
                  joined.snapshot.media,
                  attachmentGeneration: _playbackAttachmentGeneration,
                  acceptedSourceKey: _acceptedGuestSourceKey,
                  acceptedSourceAttachmentGeneration:
                      _acceptedGuestSourceAttachmentGeneration,
                  acceptedAllowsDifferentSource:
                      _acceptedGuestAllowsDifferentSource,
                ),
            sessionOverride: joined.session,
            attachmentGeneration: _playbackAttachmentGeneration,
            attachmentPort: port,
          ),
        );
      }
      return true;
    } on WatchPartyClientException catch (error) {
      _recordDiagnostics('Watch Party room join failed', {
        'event': 'room_join_failed',
        'error_code': error.code,
      });
      if (generation == _generation) {
        state = WatchPartyState(message: watchPartyFriendlyError(error));
      }
      return false;
    }
  }

  Future<void> leave() async {
    if (_disposed) return;
    final departureGeneration = ++_generation;
    final previousSession = _disconnectLocally();
    state = const WatchPartyState(message: 'You left the Watch Party.');
    _recordDiagnostics('Watch Party room left', {'event': 'room_left'});
    await _sendLeaveBestEffort(previousSession);
    if (_disposed || departureGeneration != _generation) return;
  }

  Future<bool> transferHost(WatchPartyParticipant participant) =>
      _runMembershipAction(participant, transfer: true);

  Future<bool> kick(WatchPartyParticipant participant) =>
      _runMembershipAction(participant, transfer: false);

  Future<bool> _runMembershipAction(
    WatchPartyParticipant participant, {
    required bool transfer,
  }) async {
    final session = state.session;
    final snapshot = state.snapshot;
    final participantId = participant.participantId;
    if (_membershipActionInFlight ||
        session == null ||
        session.role != WatchPartyRole.host ||
        snapshot == null ||
        participant.role != WatchPartyRole.guest ||
        participantId == null) {
      return false;
    }
    _membershipActionInFlight = true;
    state = state.copyWith(membershipActionInFlight: true, message: null);
    try {
      final updated = transfer
          ? await _client.transferHost(
              session: session,
              participantId: participantId,
              baseRosterRevision: snapshot.rosterRevision,
            )
          : await _client.kick(
              session: session,
              participantId: participantId,
              baseRosterRevision: snapshot.rosterRevision,
            );
      if (_disposed || state.session != session) return false;
      await _acceptPolledSnapshot(session, updated);
      if (!_disposed && state.session?.token == session.token) {
        state = state.copyWith(
          message: transfer
              ? 'Host controls transferred to ${participant.displayName}.'
              : '${participant.displayName} was removed from the room.',
        );
      }
      return true;
    } on WatchPartyClientException catch (error) {
      if (!_disposed && state.session == session) {
        if (error.code == 'stale_roster' ||
            error.code == 'participant_not_found') {
          _schedulePoll(_generation, immediate: true);
        }
        state = state.copyWith(message: watchPartyFriendlyError(error));
      }
      return false;
    } finally {
      _membershipActionInFlight = false;
      if (!_disposed && state.session != null) {
        state = state.copyWith(membershipActionInFlight: false);
      }
    }
  }

  Future<void> attachPlayback({
    required WatchPartyPlaybackPort port,
    required WatchPartyMedia media,
  }) async {
    if (_disposed) return;
    final attachmentGeneration = ++_playbackAttachmentGeneration;
    _pendingPlaybackPort = port;
    final previousSubscription = _playbackSubscription;
    _playbackSubscription = null;
    _playbackPort = null;
    await previousSubscription?.cancel();
    if (_disposed || attachmentGeneration != _playbackAttachmentGeneration) {
      if (identical(_pendingPlaybackPort, port)) {
        _pendingPlaybackPort = null;
      }
      return;
    }
    _pendingPlaybackPort = null;
    _playbackPort = port;
    _lastSample = null;
    _resetGuestReconciliation();
    _acceptedGuestSourceKey = null;
    _acceptedGuestSourceAttachmentGeneration = -1;
    _acceptedGuestAllowsDifferentSource = false;
    _acceptPendingGuestSourceForAttachment(attachmentGeneration);
    state = state.copyWith(
      attachedMedia: media,
      timelineMismatch: false,
      timelineCompatibility: WatchPartyTimelineCompatibility.unverified,
      guestSyncOffset: Duration.zero,
    );
    _playbackSubscription = port.snapshots.listen((sample) {
      _lastSample = sample;
      if (state.attachedMedia != sample.media) {
        state = state.copyWith(attachedMedia: sample.media);
      }
      if (state.isHost) {
        unawaited(_publishHostSample(force: false));
      } else if (state.session case final session?
          when session.role == WatchPartyRole.guest) {
        unawaited(
          _handleGuestPlaybackSample(
            session: session,
            port: port,
            attachmentGeneration: attachmentGeneration,
            sample: sample,
          ),
        );
      }
    });
    if (state.session case final session?
        when session.role == WatchPartyRole.guest) {
      await _setGuestReady(
        false,
        sessionOverride: session,
        attachmentGeneration: attachmentGeneration,
        attachmentPort: port,
        force: true,
      );
    }
  }

  Future<void> _handleGuestPlaybackSample({
    required WatchPartySession session,
    required WatchPartyPlaybackPort port,
    required int attachmentGeneration,
    required WatchPartyPlaybackSample sample,
  }) async {
    final observedSnapshot = state.snapshot;
    final readyForObservedMedia =
        sample.ready &&
        _guestSampleMatchesRemoteMedia(
          sample.media,
          observedSnapshot?.media,
          attachmentGeneration: attachmentGeneration,
          acceptedSourceKey: _acceptedGuestSourceKey,
          acceptedSourceAttachmentGeneration:
              _acceptedGuestSourceAttachmentGeneration,
          acceptedAllowsDifferentSource: _acceptedGuestAllowsDifferentSource,
        );
    await _setGuestReady(
      readyForObservedMedia,
      sessionOverride: session,
      attachmentGeneration: attachmentGeneration,
      attachmentPort: port,
    );
    if (_disposed ||
        attachmentGeneration != _playbackAttachmentGeneration ||
        !identical(_playbackPort, port) ||
        state.session != session) {
      return;
    }
    final snapshot = state.snapshot;
    if (snapshot == null) return;
    if (readyForObservedMedia &&
        !_guestSampleMatchesRemoteMedia(
          sample.media,
          snapshot.media,
          attachmentGeneration: attachmentGeneration,
          acceptedSourceKey: _acceptedGuestSourceKey,
          acceptedSourceAttachmentGeneration:
              _acceptedGuestSourceAttachmentGeneration,
          acceptedAllowsDifferentSource: _acceptedGuestAllowsDifferentSource,
        )) {
      await _setGuestReady(
        false,
        sessionOverride: session,
        attachmentGeneration: attachmentGeneration,
        attachmentPort: port,
        force: true,
      );
      return;
    }
    await _applyGuestSnapshot(snapshot);
  }

  Future<void> detachPlayback(WatchPartyPlaybackPort port) async {
    if (_disposed) return;
    final activeAttachment = identical(_playbackPort, port);
    final pendingAttachment = identical(_pendingPlaybackPort, port);
    if (!activeAttachment && !pendingAttachment) return;
    final attachmentGeneration = ++_playbackAttachmentGeneration;
    if (pendingAttachment) _pendingPlaybackPort = null;
    final subscription = activeAttachment ? _playbackSubscription : null;
    _playbackSubscription = null;
    _playbackPort = null;
    _lastSample = null;
    _acceptedGuestSourceKey = null;
    _acceptedGuestSourceAttachmentGeneration = -1;
    _acceptedGuestAllowsDifferentSource = false;
    _resetGuestReconciliation();
    final session = state.session;
    final readyFuture = session?.role == WatchPartyRole.guest
        ? _setGuestReady(
            false,
            sessionOverride: session,
            force: true,
            allowAfterDispose: true,
          )
        : Future<void>.value();
    final cancellation = subscription?.cancel() ?? Future<void>.value();
    // Player routes detach from State.dispose. Notify listeners in a microtask
    // so Riverpod is never mutated while Flutter unmounts the tree, without
    // leaving a zero-duration Timer behind in widget tests.
    await Future<void>.value();
    if (!_disposed &&
        attachmentGeneration == _playbackAttachmentGeneration &&
        _playbackPort == null &&
        _pendingPlaybackPort == null) {
      state = state.copyWith(
        attachedMedia: null,
        timelineMismatch: false,
        timelineCompatibility: WatchPartyTimelineCompatibility.unverified,
        guestSyncOffset: Duration.zero,
      );
    }
    await cancellation;
    await readyFuture;
  }

  Future<void> setGuestReady(bool ready) => _setGuestReady(ready);

  void clearMessage() {
    if (state.message != null) state = state.copyWith(message: null);
  }

  Future<bool> resyncParty() async {
    if (_disposed ||
        state.session?.role != WatchPartyRole.host ||
        _lastSample?.ready != true) {
      return false;
    }
    final previousRevision = state.snapshot?.resyncRevision ?? 0;
    final completion = _resyncPublishCompleter ??= Completer<bool>();
    await _publishHostSample(force: true, forceResync: true);
    final succeeded = await completion.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => false,
    );
    if (identical(_resyncPublishCompleter, completion)) {
      if (!completion.isCompleted) completion.complete(false);
      _resyncPublishCompleter = null;
    }
    if (succeeded) {
      state = state.copyWith(message: 'Resync sent to everyone in the party.');
    }
    _recordDiagnostics('Watch Party host resync', {
      'event': 'host_resync',
      'status': succeeded ? 'sent' : 'not_sent',
      'resync_revision': state.snapshot?.resyncRevision ?? previousRevision,
    });
    return succeeded;
  }

  void adjustGuestSyncOffset(Duration delta) {
    if (_disposed || state.session?.role != WatchPartyRole.guest) return;
    final milliseconds = (state.guestSyncOffset + delta).inMilliseconds.clamp(
      -120000,
      120000,
    );
    final offset = Duration(milliseconds: milliseconds);
    state = state.copyWith(
      guestSyncOffset: offset,
      message: offset == Duration.zero
          ? 'Local sync adjustment reset.'
          : 'Local sync adjusted ${offset.isNegative ? 'earlier' : 'later'} '
                'by ${offset.abs().inSeconds} seconds.',
    );
    if (state.snapshot case final snapshot?) {
      unawaited(_applyGuestSnapshot(snapshot));
    }
  }

  void resetGuestSyncOffset() {
    if (state.guestSyncOffset == Duration.zero) return;
    adjustGuestSyncOffset(-state.guestSyncOffset);
  }

  void notifyDifferentSourceFallback({String? targetSourceKey}) {
    if (_disposed || state.session?.role != WatchPartyRole.guest) return;
    _prepareGuestSourceHandoff(targetSourceKey, allowsDifferentSource: true);
    _enqueueMembershipNotice(
      WatchPartyNotice(
        sequence: ++_localNoticeSequence,
        message:
            'The host’s exact stream is not available here. Using another local source.',
      ),
    );
  }

  /// Marks the next player attachment as the resolver-confirmed exact host
  /// source. This generation gate prevents the old same-episode player from
  /// becoming ready while still allowing harmless provider metadata
  /// differences around the same source fingerprint.
  void prepareExactSourceHandoff({required String targetSourceKey}) {
    if (_disposed || state.session?.role != WatchPartyRole.guest) return;
    _prepareGuestSourceHandoff(targetSourceKey, allowsDifferentSource: false);
  }

  void _prepareGuestSourceHandoff(
    String? targetSourceKey, {
    required bool allowsDifferentSource,
  }) {
    if (targetSourceKey == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(targetSourceKey)) {
      return;
    }
    // Acceptance applies only to the next player attachment. Merely showing
    // the fallback notice must never let the still-mounted old source report
    // itself ready after a same-episode host source change.
    _pendingGuestSourceKey = targetSourceKey;
    _pendingGuestSourceAfterAttachmentGeneration =
        _playbackAttachmentGeneration;
    _pendingGuestAllowsDifferentSource = allowsDifferentSource;
  }

  void _schedulePoll(int generation, {required bool immediate}) {
    _pollTimer?.cancel();
    final failureScale = 1 << _consecutivePollFailures.clamp(0, 3);
    _pollTimer = Timer(
      immediate ? Duration.zero : Duration(milliseconds: 1200 * failureScale),
      () {
        unawaited(_poll(generation));
      },
    );
  }

  Future<void> _poll(int generation) async {
    final session = state.session;
    if (session == null || generation != _generation) return;
    try {
      final snapshot = await _client.snapshot(session);
      if (generation != _generation) return;
      _consecutivePollFailures = 0;
      await _acceptPolledSnapshot(session, snapshot);
    } on WatchPartyClientException catch (error) {
      if (generation != _generation) return;
      if (error.code == 'party_not_found' ||
          error.code == 'invalid_party_token' ||
          error.code == 'party_token_required' ||
          error.code == 'removed_from_party') {
        final message = watchPartyFriendlyError(error);
        final terminalGeneration = ++_generation;
        _disconnectLocally();
        if (_disposed || terminalGeneration != _generation) return;
        state = WatchPartyState(message: message);
        if (error.code == 'removed_from_party') {
          _enqueueMembershipNotice(
            WatchPartyNotice(
              sequence: ++_localNoticeSequence,
              message: message,
              eventType: WatchPartyEventType.kicked,
              displayName: 'You',
              actionText: 'were kicked from the party',
            ),
          );
        }
        return;
      }
      _consecutivePollFailures = (_consecutivePollFailures + 1).clamp(0, 3);
      state = state.copyWith(
        connection: WatchPartyConnection.reconnecting,
        message: watchPartyFriendlyError(error),
      );
    } finally {
      if (generation == _generation && state.session != null) {
        _schedulePoll(generation, immediate: false);
      }
    }
  }

  Future<void> _acceptPolledSnapshot(
    WatchPartySession requestedSession,
    WatchPartySnapshot snapshot,
  ) async {
    if (_disposed || state.session != requestedSession) return;
    final wasReconnecting =
        state.connection == WatchPartyConnection.reconnecting;
    final currentSnapshot = state.snapshot;
    if (_watchPartySnapshotIsOlder(snapshot, currentSnapshot)) {
      if (wasReconnecting) {
        state = state.copyWith(
          connection: WatchPartyConnection.connected,
          message: 'Watch Party reconnected.',
        );
      }
      return;
    }
    final roleChanged = requestedSession.role != snapshot.role;
    final nextSession = roleChanged
        ? requestedSession.withRole(snapshot.role)
        : requestedSession;
    if (roleChanged) {
      _resetGuestReconciliation();
      _resetGuestSourceAcceptance();
      _guestReady = false;
      _guestReadySession = null;
      _lastPublishedAt = null;
    }
    state = state.copyWith(
      connection: WatchPartyConnection.connected,
      session: nextSession,
      snapshot: snapshot,
      timelineMismatch: roleChanged ? false : state.timelineMismatch,
      timelineCompatibility: roleChanged
          ? WatchPartyTimelineCompatibility.unverified
          : state.timelineCompatibility,
      guestSyncOffset: roleChanged ? Duration.zero : state.guestSyncOffset,
      message: wasReconnecting ? 'Watch Party reconnected.' : state.message,
    );
    _ingestMembershipEvents(snapshot);

    if (snapshot.role == WatchPartyRole.guest) {
      final port = _playbackPort;
      if (roleChanged && port != null) {
        final sample = _lastSample;
        await _setGuestReady(
          sample?.ready == true &&
              _guestSampleMatchesRemoteMedia(
                sample!.media,
                snapshot.media,
                attachmentGeneration: _playbackAttachmentGeneration,
                acceptedSourceKey: _acceptedGuestSourceKey,
                acceptedSourceAttachmentGeneration:
                    _acceptedGuestSourceAttachmentGeneration,
                acceptedAllowsDifferentSource:
                    _acceptedGuestAllowsDifferentSource,
              ),
          sessionOverride: nextSession,
          attachmentGeneration: _playbackAttachmentGeneration,
          attachmentPort: port,
          force: true,
        );
      }
      await _applyGuestSnapshot(snapshot);
    } else if (_lastSample != null &&
        (_resyncPublishPending ||
            roleChanged ||
            DateTime.now().toUtc().difference(
                  _lastPublishedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
                ) >=
                const Duration(milliseconds: 2200))) {
      await _publishHostSample(force: true);
    }
  }

  Future<void> _publishHostSample({
    required bool force,
    bool forceResync = false,
  }) async {
    final session = state.session;
    final sample = _lastSample;
    if (session == null ||
        session.role != WatchPartyRole.host ||
        sample == null ||
        !sample.ready) {
      return;
    }
    final last = _lastPublishedAt;
    final now = DateTime.now().toUtc();
    final currentSnapshot = state.snapshot;
    final previousResyncRevision = currentSnapshot?.resyncRevision ?? 0;
    final immediateChange =
        currentSnapshot == null ||
        currentSnapshot.media != sample.media ||
        currentSnapshot.playing != sample.playing ||
        (currentSnapshot.expectedPositionAt(now) - sample.position).abs() >
            const Duration(seconds: 3);
    if (!force &&
        !immediateChange &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 2200)) {
      return;
    }
    if (_publishing) {
      _publishAgain = true;
      _resyncPublishPending = _resyncPublishPending || forceResync;
      return;
    }
    _publishing = true;
    final requestResync = forceResync || _resyncPublishPending;
    _resyncPublishPending = false;
    try {
      final elapsed = sample.playing
          ? now.difference(sample.sampledAt)
          : Duration.zero;
      final position = sample.position + elapsed;
      final snapshot = await _client.updateState(
        session: session,
        baseRevision: state.snapshot?.revision ?? 0,
        media: sample.media,
        playing: sample.playing,
        position: position > sample.duration && sample.duration > Duration.zero
            ? sample.duration
            : position,
        forceResync: requestResync,
      );
      if (state.session == session &&
          !_watchPartySnapshotIsOlder(snapshot, state.snapshot)) {
        _lastPublishedAt = now;
        state = state.copyWith(
          connection: WatchPartyConnection.connected,
          snapshot: snapshot,
          timelineMismatch: false,
          timelineCompatibility: WatchPartyTimelineCompatibility.exact,
        );
        if (requestResync) {
          _completeResyncPublish(
            snapshot.resyncRevision > previousResyncRevision,
          );
        }
      }
    } on WatchPartyClientException catch (error) {
      if (error.code == 'stale_revision' || error.code == 'host_required') {
        _schedulePoll(_generation, immediate: true);
      }
      if (requestResync &&
          (error.code == 'stale_revision' ||
              error.code == 'timeout' ||
              error.code == 'network_unavailable' ||
              error.code == 'rate_limited')) {
        _resyncPublishPending = true;
        // Do not immediately replay the same stale revision or hammer a
        // temporarily unavailable broker. The poll refreshes the revision and
        // then `_acceptPolledSnapshot` retries the pending resync once.
        _publishAgain = false;
        if (error.code != 'stale_revision') {
          _schedulePoll(_generation, immediate: false);
        }
      } else if (requestResync) {
        _completeResyncPublish(false);
      }
      if (state.session == session) {
        final reconnecting =
            error.code == 'timeout' ||
            error.code == 'network_unavailable' ||
            error.code == 'rate_limited';
        state = state.copyWith(
          connection: reconnecting
              ? WatchPartyConnection.reconnecting
              : state.connection,
          message: watchPartyFriendlyError(error),
        );
      }
    } finally {
      _publishing = false;
      if (_publishAgain) {
        _publishAgain = false;
        final pendingResync = _resyncPublishPending;
        _resyncPublishPending = false;
        unawaited(_publishHostSample(force: true, forceResync: pendingResync));
      }
    }
  }

  Future<void> _applyGuestSnapshot(WatchPartySnapshot snapshot) async {
    final pending = _pendingGuestSnapshot;
    if (pending == null || snapshot.revision >= pending.revision) {
      _pendingGuestSnapshot = snapshot;
    }
    if (_guestReconciliationInFlight) {
      _guestReconcileAgain = true;
      return;
    }
    _guestReconciliationInFlight = true;
    try {
      do {
        _guestReconcileAgain = false;
        final latest = _pendingGuestSnapshot;
        _pendingGuestSnapshot = null;
        if (latest != null) await _reconcileGuestSnapshot(latest);
      } while (_guestReconcileAgain || _pendingGuestSnapshot != null);
    } finally {
      _guestReconciliationInFlight = false;
    }
  }

  Future<void> _reconcileGuestSnapshot(WatchPartySnapshot snapshot) async {
    final port = _playbackPort;
    final attachmentGeneration = _playbackAttachmentGeneration;
    final controllerGeneration = _generation;
    final sample = _lastSample;
    final remoteMedia = snapshot.media;
    if (port == null ||
        sample == null ||
        remoteMedia == null ||
        !_guestCommandContextIsCurrent(
          snapshot: snapshot,
          port: port,
          attachmentGeneration: attachmentGeneration,
          controllerGeneration: controllerGeneration,
        )) {
      return;
    }
    // A website host intentionally has no app catalog/source capability, so
    // it publishes `private`. Let that timeline control only the media the
    // guest explicitly opened and marked ready. The warning below makes the
    // unverifiable identity/coarse-sync tradeoff visible.
    final remotePrivateTimeline = remoteMedia.kind == 'private';
    final sameEpisode =
        remotePrivateTimeline ||
        (sample.media.kind == remoteMedia.kind &&
            sample.media.anilistId == remoteMedia.anilistId &&
            sample.media.episode == remoteMedia.episode);
    if (!sameEpisode) return;
    final remotePrivateTimelineUnverified =
        remotePrivateTimeline &&
        (sample.media.kind != 'private' ||
            sample.media.timelineFingerprint == null ||
            remoteMedia.timelineFingerprint == null);
    final exactFingerprint =
        !remotePrivateTimelineUnverified &&
        sample.media.timelineFingerprint != null &&
        sample.media.timelineFingerprint == remoteMedia.timelineFingerprint &&
        !_watchPartySourceFingerprintsConflict(
          sample.media.sourceDescriptor,
          remoteMedia.sourceDescriptor,
        );
    final hostPosition = snapshot.expectedPositionAt(DateTime.now().toUtc());
    final timelineMapping = mapWatchPartyTimeline(
      hostPosition: hostPosition,
      host: remoteMedia.timelineProfile,
      guest: sample.media.timelineProfile,
      exactFingerprint: exactFingerprint,
      guestOffset: state.guestSyncOffset,
    );
    final compatibility = remotePrivateTimelineUnverified
        ? WatchPartyTimelineCompatibility.unverified
        : timelineMapping.compatibility;
    final timelineMismatch =
        compatibility == WatchPartyTimelineCompatibility.differentCut ||
        compatibility == WatchPartyTimelineCompatibility.unverified;
    if (timelineMismatch != state.timelineMismatch ||
        compatibility != state.timelineCompatibility) {
      final driftMilliseconds = (sample.position - timelineMapping.position)
          .abs()
          .inMilliseconds
          .clamp(0, 24 * 60 * 60 * 1000);
      state = state.copyWith(
        timelineMismatch: timelineMismatch,
        timelineCompatibility: compatibility,
        message: switch (compatibility) {
          WatchPartyTimelineCompatibility.adjusted =>
            'Different source detected. Watch Party aligned its timeline.',
          WatchPartyTimelineCompatibility.differentCut =>
            'This source uses a different cut. Choose the host source or adjust sync.',
          WatchPartyTimelineCompatibility.unverified =>
            'Source timing could not be verified. Make sure you opened the same episode as the host.',
          _ => state.message,
        },
      );
      _recordDiagnostics('Watch Party timeline checked', {
        'event': 'timeline_checked',
        'compatibility': compatibility.name,
        'same_episode': sameEpisode,
        'exact_source': exactFingerprint,
        'timeline_mapping_used': timelineMapping.usedTimelineMapping,
        'drift_ms': driftMilliseconds,
        'host_resync_revision': snapshot.resyncRevision,
      });
    }
    if (!sample.ready ||
        !_guestSampleMatchesRemoteMedia(
          sample.media,
          remoteMedia,
          attachmentGeneration: attachmentGeneration,
          acceptedSourceKey: _acceptedGuestSourceKey,
          acceptedSourceAttachmentGeneration:
              _acceptedGuestSourceAttachmentGeneration,
          acceptedAllowsDifferentSource: _acceptedGuestAllowsDifferentSource,
        )) {
      return;
    }
    final target = timelineMapping.position;
    final forceResync = snapshot.resyncRevision > _lastGuestResyncRevision;
    final commandCooldownActive =
        !forceResync &&
        snapshot.revision == _lastGuestCommandRevision &&
        DateTime.now().toUtc().difference(
              _lastGuestCommandAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            ) <
            const Duration(milliseconds: 650);
    if (commandCooldownActive) return;
    var issuedCommand = false;
    try {
      final seekThreshold = forceResync
          ? const Duration(milliseconds: 150)
          : timelineMapping.usedTimelineMapping
          ? const Duration(milliseconds: 900)
          : timelineMismatch
          ? const Duration(seconds: 2)
          : const Duration(milliseconds: 1250);
      if ((sample.position - target).abs() > seekThreshold) {
        if (!_guestCommandContextIsCurrent(
          snapshot: snapshot,
          port: port,
          attachmentGeneration: attachmentGeneration,
          controllerGeneration: controllerGeneration,
        )) {
          return;
        }
        await port.seekTo(target);
        issuedCommand = true;
        _recordDiagnostics('Watch Party guest timeline corrected', {
          'event': 'guest_seek_applied',
          'compatibility': compatibility.name,
          'forced_by_host': forceResync,
          'timeline_mapping_used': timelineMapping.usedTimelineMapping,
          'drift_ms': (sample.position - target).abs().inMilliseconds.clamp(
            0,
            24 * 60 * 60 * 1000,
          ),
        });
      }
      if (!_guestCommandContextIsCurrent(
        snapshot: snapshot,
        port: port,
        attachmentGeneration: attachmentGeneration,
        controllerGeneration: controllerGeneration,
      )) {
        return;
      }
      if (snapshot.playing != sample.playing) {
        if (snapshot.playing) {
          await port.play();
        } else {
          await port.pause();
        }
        issuedCommand = true;
      }
    } catch (_) {
      if (_guestCommandContextIsCurrent(
        snapshot: snapshot,
        port: port,
        attachmentGeneration: attachmentGeneration,
        controllerGeneration: controllerGeneration,
      )) {
        _lastGuestCommandRevision = snapshot.revision;
        _lastGuestCommandAt = DateTime.now().toUtc();
        state = state.copyWith(
          message: 'Watch Party could not resync playback. Retrying shortly.',
        );
      }
      return;
    }
    if (issuedCommand &&
        _guestCommandContextIsCurrent(
          snapshot: snapshot,
          port: port,
          attachmentGeneration: attachmentGeneration,
          controllerGeneration: controllerGeneration,
        )) {
      _lastGuestCommandRevision = snapshot.revision;
      _lastGuestCommandAt = DateTime.now().toUtc();
    }
    if (_guestCommandContextIsCurrent(
      snapshot: snapshot,
      port: port,
      attachmentGeneration: attachmentGeneration,
      controllerGeneration: controllerGeneration,
    )) {
      _lastGuestResyncRevision = snapshot.resyncRevision;
    }
  }

  bool _guestCommandContextIsCurrent({
    required WatchPartySnapshot snapshot,
    required WatchPartyPlaybackPort port,
    required int attachmentGeneration,
    required int controllerGeneration,
  }) {
    final session = state.session;
    final currentSnapshot = state.snapshot;
    return !_disposed &&
        controllerGeneration == _generation &&
        attachmentGeneration == _playbackAttachmentGeneration &&
        identical(_playbackPort, port) &&
        session?.role == WatchPartyRole.guest &&
        session?.roomCode == snapshot.roomCode &&
        currentSnapshot?.role == WatchPartyRole.guest &&
        currentSnapshot?.revision == snapshot.revision;
  }

  void _resetGuestReconciliation() {
    _guestReconcileAgain = false;
    _pendingGuestSnapshot = null;
    _lastGuestCommandRevision = -1;
    _lastGuestResyncRevision = -1;
    _lastGuestCommandAt = null;
  }

  void _recordDiagnostics(String message, Map<String, Object?> details) {
    final sink = diagnostics;
    if (sink == null) return;
    try {
      unawaited(sink(message, details).catchError((_) {}));
    } catch (_) {
      // Diagnostics must never interrupt room control or playback.
    }
  }

  void _completeResyncPublish(bool succeeded) {
    final completion = _resyncPublishCompleter;
    if (completion != null && !completion.isCompleted) {
      completion.complete(succeeded);
    }
  }

  void _acceptPendingGuestSourceForAttachment(int attachmentGeneration) {
    final pendingSourceKey = _pendingGuestSourceKey;
    if (pendingSourceKey == null ||
        attachmentGeneration <= _pendingGuestSourceAfterAttachmentGeneration) {
      return;
    }
    final remoteSourceKey = state.snapshot?.media?.sourceDescriptor?.sourceKey;
    final allowsDifferentSource = _pendingGuestAllowsDifferentSource;
    _pendingGuestSourceKey = null;
    _pendingGuestSourceAfterAttachmentGeneration = -1;
    _pendingGuestAllowsDifferentSource = false;
    if (remoteSourceKey != pendingSourceKey) return;
    _acceptedGuestSourceKey = pendingSourceKey;
    _acceptedGuestSourceAttachmentGeneration = attachmentGeneration;
    _acceptedGuestAllowsDifferentSource = allowsDifferentSource;
  }

  void _resetGuestSourceAcceptance() {
    _pendingGuestSourceKey = null;
    _pendingGuestSourceAfterAttachmentGeneration = -1;
    _pendingGuestAllowsDifferentSource = false;
    _acceptedGuestSourceKey = null;
    _acceptedGuestSourceAttachmentGeneration = -1;
    _acceptedGuestAllowsDifferentSource = false;
  }

  void _seedMembershipEvents(WatchPartySnapshot snapshot) {
    _clearMembershipNotices();
    _rememberParticipantAvatars(snapshot.participants);
    for (final event in snapshot.events) {
      if (event.sequence > _lastEventSequence) {
        _lastEventSequence = event.sequence;
      }
    }
  }

  void _ingestMembershipEvents(WatchPartySnapshot snapshot) {
    _rememberParticipantAvatars(snapshot.participants);
    final notices = <WatchPartyNotice>[];
    for (final event in snapshot.events) {
      if (event.sequence <= _lastEventSequence) continue;
      _lastEventSequence = event.sequence;
      final message = switch (event.type) {
        WatchPartyEventType.joined =>
          '${event.displayName} joined the Watch Party.',
        WatchPartyEventType.left =>
          '${event.displayName} left the Watch Party.',
        WatchPartyEventType.kicked =>
          '${event.displayName} was removed from the Watch Party.',
        WatchPartyEventType.hostTransferred =>
          'Host controls transferred to ${event.displayName}.',
      };
      final actionText = switch (event.type) {
        WatchPartyEventType.joined => 'joined the party',
        WatchPartyEventType.left => 'left the party',
        WatchPartyEventType.kicked => 'was kicked from the party',
        WatchPartyEventType.hostTransferred => 'is now the host',
      };
      notices.add(
        WatchPartyNotice(
          sequence: event.sequence,
          message: message,
          eventType: event.type,
          displayName: event.displayName,
          actionText: actionText,
          avatarUrl: _participantAvatars[event.displayName],
        ),
      );
    }
    _enqueueMembershipNotices(notices);
  }

  void _rememberParticipantAvatars(
    Iterable<WatchPartyParticipant> participants,
  ) {
    final counts = <String, int>{};
    final safeAvatars = <String, String?>{};
    for (final participant in participants.take(maximumWatchPartyRosterSize)) {
      final identity = WatchPartyPublicIdentity.tryCreate(
        displayName: participant.displayName,
        avatarUrl: participant.avatarUrl,
      );
      if (identity == null) continue;
      counts.update(
        identity.displayName,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      safeAvatars[identity.displayName] = identity.avatarUrl;
    }
    for (final entry in counts.entries) {
      if (entry.value == 1) {
        // A currently present participant with no avatar must replace any
        // cached value for that name. Otherwise a later person reusing the
        // same display name could be shown with the previous person's PFP.
        _participantAvatars[entry.key] = safeAvatars[entry.key];
      } else {
        // Events contain only a public display name. Do not attach an avatar
        // when duplicate names make that association ambiguous.
        _participantAvatars.remove(entry.key);
      }
    }
    while (_participantAvatars.length > maximumWatchPartyRosterSize * 2) {
      _participantAvatars.remove(_participantAvatars.keys.first);
    }
  }

  void _enqueueMembershipNotice(WatchPartyNotice notice) =>
      _enqueueMembershipNotices(<WatchPartyNotice>[notice]);

  void _enqueueMembershipNotices(Iterable<WatchPartyNotice> incoming) {
    if (_disposed) return;
    final merged = <int, WatchPartyNotice>{
      for (final notice in state.notices) notice.sequence: notice,
    };
    final added = <WatchPartyNotice>[];
    for (final notice in incoming) {
      if (merged.containsKey(notice.sequence)) continue;
      merged[notice.sequence] = notice;
      added.add(notice);
    }
    if (added.isEmpty) return;

    state = state.copyWith(
      notices: List<WatchPartyNotice>.unmodifiable(merged.values),
    );
    for (final notice in added) {
      _noticeTimers.remove(notice.sequence)?.cancel();
      _noticeTimers[notice.sequence] = Timer(watchPartyNoticeLifetime, () {
        _removeMembershipNotice(notice.sequence);
      });
    }
  }

  void _removeMembershipNotice(int sequence) {
    _noticeTimers.remove(sequence)?.cancel();
    if (_disposed ||
        !state.notices.any((notice) => notice.sequence == sequence)) {
      return;
    }
    state = state.copyWith(
      notices: List<WatchPartyNotice>.unmodifiable(
        state.notices.where((notice) => notice.sequence != sequence),
      ),
    );
  }

  void _clearMembershipNotices() {
    for (final timer in _noticeTimers.values) {
      timer.cancel();
    }
    _noticeTimers.clear();
    _participantAvatars.clear();
    _lastEventSequence = 0;
    if (!_disposed && state.notices.isNotEmpty) {
      state = state.copyWith(notices: const <WatchPartyNotice>[]);
    }
  }

  Future<void> _setGuestReady(
    bool ready, {
    WatchPartySession? sessionOverride,
    int? attachmentGeneration,
    WatchPartyPlaybackPort? attachmentPort,
    bool force = false,
    bool allowAfterDispose = false,
  }) {
    if (_disposed && !allowAfterDispose) return Future<void>.value();
    final session = sessionOverride ?? state.session;
    if (session?.role != WatchPartyRole.guest) return Future<void>.value();
    final previous = _guestReadyTail;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A failed readiness request must not block later cleanup.
      }
      final attachmentGuarded = attachmentGeneration != null;
      if (ready &&
          (_disposed ||
              (attachmentGuarded &&
                  (attachmentGeneration != _playbackAttachmentGeneration ||
                      !identical(_playbackPort, attachmentPort))) ||
              (!_disposed && state.session != session))) {
        return;
      }
      if (_disposed && !allowAfterDispose) return;
      if (!force &&
          identical(_guestReadySession, session) &&
          _guestReady == ready) {
        return;
      }
      try {
        final snapshot = await _client.setReady(
          session: session!,
          ready: ready,
        );
        _guestReadySession = session;
        _guestReady = ready;
        if (_disposed) return;
        final attachmentStillCurrent =
            !attachmentGuarded ||
            (attachmentGeneration == _playbackAttachmentGeneration &&
                identical(_playbackPort, attachmentPort));
        final currentRevision = state.snapshot?.revision ?? -1;
        if (state.session == session &&
            attachmentStillCurrent &&
            snapshot.revision >= currentRevision &&
            !_watchPartySnapshotIsOlder(snapshot, state.snapshot)) {
          state = state.copyWith(snapshot: snapshot);
        }
      } on WatchPartyClientException catch (error) {
        if (!_disposed && state.session == session) {
          state = state.copyWith(message: watchPartyFriendlyError(error));
        }
      }
    }();
    _guestReadyTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  WatchPartySession? _disconnectLocally() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final session = state.session;
    _guestReady = false;
    _guestReadySession = null;
    _lastPublishedAt = null;
    _resetGuestReconciliation();
    _resetGuestSourceAcceptance();
    _clearMembershipNotices();
    _consecutivePollFailures = 0;
    return session;
  }

  Future<void> _sendLeaveBestEffort(WatchPartySession? session) async {
    if (session == null) return;
    try {
      await _client.leave(session);
    } catch (_) {
      // Local exit must not depend on room-service reachability.
    }
  }

  @override
  void dispose() {
    final session = state.session;
    final shouldClearGuestReady =
        session?.role == WatchPartyRole.guest &&
        (_playbackPort != null ||
            _pendingPlaybackPort != null ||
            (identical(_guestReadySession, session) && _guestReady));
    _disposed = true;
    ++_generation;
    ++_playbackAttachmentGeneration;
    _pollTimer?.cancel();
    for (final timer in _noticeTimers.values) {
      timer.cancel();
    }
    _noticeTimers.clear();
    _participantAvatars.clear();
    _completeResyncPublish(false);
    _resyncPublishCompleter = null;
    final subscription = _playbackSubscription;
    _playbackSubscription = null;
    _playbackPort = null;
    _pendingPlaybackPort = null;
    unawaited(subscription?.cancel());
    if (shouldClearGuestReady) {
      unawaited(
        _setGuestReady(
          false,
          sessionOverride: session,
          force: true,
          allowAfterDispose: true,
        ),
      );
    }
    super.dispose();
  }
}

/// The broker's participant count is the number of connected guests. Include
/// the host when presenting the total party audience to any active member.
int watchPartyViewerCount(WatchPartyState state) => state.session == null
    ? 0
    : ((state.snapshot?.participantCount ?? 0) + 1).clamp(
        1,
        maximumWatchPartyRosterSize,
      );

String watchPartyAudienceLabel(int count) {
  final safeCount = count < 0 ? 0 : count;
  return '$safeCount ${safeCount == 1 ? 'person' : 'people'} watching';
}

String watchPartyFriendlyError(WatchPartyClientException error) =>
    switch (error.code) {
      'invalid_room_code' =>
        'Enter the eight-digit room code using numbers 2-9 only.',
      'party_not_found' => 'That room ended or expired.',
      'party_full' => 'That room is full.',
      'party_capacity_reached' =>
        'Watch Party is temporarily at capacity. Try again shortly.',
      'invalid_party_token' || 'party_token_required' =>
        'This room session expired. Join again with the room code.',
      'removed_from_party' => 'The host removed you from this Watch Party.',
      'stale_roster' ||
      'participant_not_found' => 'The participant list changed. Try again.',
      'host_required' => 'Host controls moved to another participant.',
      'method_not_allowed' || 'not_found' =>
        'This room service does not support participant management yet.',
      'rate_limited' => 'Too many room requests. Wait a minute and try again.',
      'timeout' || 'network_unavailable' =>
        'Watch Party cannot reach the room service right now.',
      _ => 'Watch Party could not complete that request.',
    };

bool _watchPartySnapshotIsOlder(
  WatchPartySnapshot candidate,
  WatchPartySnapshot? current,
) =>
    current != null &&
    (candidate.revision < current.revision ||
        candidate.rosterRevision < current.rosterRevision);

bool _watchPartySourceFingerprintsConflict(
  WatchPartySourceDescriptor? local,
  WatchPartySourceDescriptor? remote,
) =>
    local != null &&
    remote != null &&
    (local.sourceClass != remote.sourceClass ||
        local.fingerprint != remote.fingerprint);

bool _guestSampleMatchesRemoteMedia(
  WatchPartyMedia local,
  WatchPartyMedia? remote, {
  required int attachmentGeneration,
  required String? acceptedSourceKey,
  required int acceptedSourceAttachmentGeneration,
  required bool acceptedAllowsDifferentSource,
}) {
  if (remote == null) return false;
  // A website host publishes an opaque private file identity that the app
  // cannot resolve. The guest's explicit local choice is therefore the only
  // readiness assertion available for that legacy/coarse-sync mode.
  if (remote.kind == 'private') return true;
  final sameEpisode =
      local.kind == remote.kind &&
      local.anilistId == remote.anilistId &&
      local.episode == remote.episode;
  if (!sameEpisode) return false;
  final remoteDescriptor = remote.sourceDescriptor;
  if (remoteDescriptor == null) return true;
  if (local.sourceDescriptor == remoteDescriptor) return true;
  final acceptedHandoff =
      acceptedSourceKey == remoteDescriptor.sourceKey &&
      acceptedSourceAttachmentGeneration == attachmentGeneration;
  if (!acceptedHandoff) return false;
  if (acceptedAllowsDifferentSource) return true;
  final localDescriptor = local.sourceDescriptor;
  return localDescriptor?.sourceClass == remoteDescriptor.sourceClass &&
      localDescriptor?.fingerprint == remoteDescriptor.fingerprint;
}
