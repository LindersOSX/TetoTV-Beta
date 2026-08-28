import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/player/presentation/watch_party_player_status.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> showWatchPartyPlayerDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xDD000000),
      builder: (_) => const WatchPartyPlayerDialog(),
    );

String watchPartyViewerCountLabel(int count) {
  final safeCount = count < 0 ? 0 : count;
  return '$safeCount ${safeCount == 1 ? 'person' : 'people'} watching';
}

String watchPartyReadyGuestCountLabel(int count) {
  final safeCount = count < 0 ? 0 : count;
  return '$safeCount ${safeCount == 1 ? 'guest' : 'guests'} ready';
}

/// Playback-safe Watch Party entry point for MPV playback.
///
/// Closing this dialog deliberately leaves the room and player attachment
/// intact. Ending a room remains an explicit action on the full Watch Party
/// screen, so dismissing a HUD never surprises every connected viewer.
class WatchPartyPlayerDialog extends ConsumerStatefulWidget {
  const WatchPartyPlayerDialog({super.key});

  @override
  ConsumerState<WatchPartyPlayerDialog> createState() =>
      _WatchPartyPlayerDialogState();
}

class _WatchPartyPlayerDialogState
    extends ConsumerState<WatchPartyPlayerDialog> {
  final _copyFocus = FocusNode(debugLabel: 'player.watch-party.copy');
  final _retryFocus = FocusNode(debugLabel: 'player.watch-party.retry');
  final _resyncFocus = FocusNode(debugLabel: 'player.watch-party.resync');
  final _earlierFocus = FocusNode(debugLabel: 'player.watch-party.earlier');
  final _laterFocus = FocusNode(debugLabel: 'player.watch-party.later');
  final _closeFocus = FocusNode(debugLabel: 'player.watch-party.close');
  final _leaveFocus = FocusNode(debugLabel: 'player.watch-party.leave');
  final _participantFocusNodes = <String, FocusNode>{};
  bool _creating = false;
  bool _leaving = false;
  bool _createAttempted = false;
  bool _resyncing = false;
  bool _managingParticipant = false;
  bool _participantFocusCleanupScheduled = false;
  bool _recoverParticipantFocus = false;
  String? _localMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !ref.read(watchPartyControllerProvider).isActive) {
        unawaited(_createRoom());
      }
    });
  }

  @override
  void dispose() {
    _copyFocus.dispose();
    _retryFocus.dispose();
    _resyncFocus.dispose();
    _earlierFocus.dispose();
    _laterFocus.dispose();
    _closeFocus.dispose();
    _leaveFocus.dispose();
    for (final node in _participantFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Set<String> _actionableParticipantIds(
    Iterable<WatchPartyParticipant> participants, {
    required bool canManageParticipants,
  }) {
    if (!canManageParticipants) return const <String>{};
    return participants
        .where(
          (participant) =>
              participant.role == WatchPartyRole.guest &&
              participant.participantId != null,
        )
        .map((participant) => participant.participantId!)
        .toSet();
  }

  void _syncParticipantFocusNodes(
    List<WatchPartyParticipant> participants, {
    required bool canManageParticipants,
  }) {
    final desiredIds = _actionableParticipantIds(
      participants,
      canManageParticipants: canManageParticipants,
    );
    for (final id in desiredIds) {
      _participantFocusNodes.putIfAbsent(
        id,
        () => FocusNode(debugLabel: 'player.watch-party.participant.$id'),
      );
    }
    final staleNodes = _participantFocusNodes.entries
        .where((entry) => !desiredIds.contains(entry.key))
        .toList(growable: false);
    if (staleNodes.any((entry) => entry.value.hasFocus)) {
      _recoverParticipantFocus = true;
    }
    if (staleNodes.isNotEmpty) _scheduleParticipantFocusCleanup();
  }

  void _scheduleParticipantFocusCleanup({bool recoverFocus = false}) {
    _recoverParticipantFocus = _recoverParticipantFocus || recoverFocus;
    if (_participantFocusCleanupScheduled) return;
    _participantFocusCleanupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _participantFocusCleanupScheduled = false;
      if (!mounted) return;
      final state = ref.read(watchPartyControllerProvider);
      final desiredIds = _actionableParticipantIds(
        state.snapshot?.participants ?? const <WatchPartyParticipant>[],
        canManageParticipants:
            state.isHost &&
            !state.membershipActionInFlight &&
            !_managingParticipant,
      );
      if (_recoverParticipantFocus && _copyFocus.context != null) {
        _copyFocus.requestFocus();
      }
      _recoverParticipantFocus = false;
      final staleIds = _participantFocusNodes.keys
          .where((id) => !desiredIds.contains(id))
          .toList(growable: false);
      for (final id in staleIds) {
        _participantFocusNodes.remove(id)?.dispose();
      }
    });
  }

  Future<void> _createRoom() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _createAttempted = true;
      _localMessage = null;
    });
    ref
        .read(watchPartyClientProvider)
        .setPublicIdentity(ref.read(watchPartyPublicIdentityProvider));
    await ref.read(watchPartyControllerProvider.notifier).create();
    if (!mounted) return;
    setState(() => _creating = false);
  }

  Future<void> _leaveRoom(WatchPartyRole role) async {
    if (_leaving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xCC000000),
      builder: (_) => _ConfirmLeaveRoomDialog(role: role),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _leaving = true);
    await ref.read(watchPartyControllerProvider.notifier).leave();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) setState(() => _localMessage = 'Room code copied.');
  }

  Future<void> _resyncParty() async {
    if (_resyncing) return;
    setState(() {
      _resyncing = true;
      _localMessage = null;
    });
    final succeeded = await ref
        .read(watchPartyControllerProvider.notifier)
        .resyncParty();
    if (!mounted) return;
    setState(() {
      _resyncing = false;
      _localMessage = succeeded
          ? 'Everyone was moved to the host’s current scene.'
          : 'Resync is available after playback is ready.';
    });
  }

  void _adjustGuestSync(Duration delta) {
    ref
        .read(watchPartyControllerProvider.notifier)
        .adjustGuestSyncOffset(delta);
  }

  Future<void> _manageParticipant(WatchPartyParticipant participant) async {
    if (_managingParticipant || participant.participantId == null) return;
    final action = await showDialog<_ParticipantManagementAction>(
      context: context,
      barrierColor: const Color(0xCC000000),
      builder: (_) => _ManageParticipantDialog(participant: participant),
    );
    if (!mounted || action == null) return;
    setState(() {
      _managingParticipant = true;
      _localMessage = null;
    });
    final controller = ref.read(watchPartyControllerProvider.notifier);
    final succeeded = switch (action) {
      _ParticipantManagementAction.transferHost =>
        await controller.transferHost(participant),
      _ParticipantManagementAction.kick => await controller.kick(participant),
    };
    if (!mounted) return;
    setState(() {
      _managingParticipant = false;
      if (succeeded) {
        _localMessage = action == _ParticipantManagementAction.transferHost
            ? 'Host controls transferred to ${participant.displayName}.'
            : '${participant.displayName} was removed from the room.';
      }
    });
    if (succeeded) {
      _scheduleParticipantFocusCleanup(recoverFocus: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final state = ref.watch(watchPartyControllerProvider);
    final session = state.session;
    final snapshot = state.snapshot;
    final media = MediaQuery.of(context);
    final compact = media.size.width < 720 || media.size.height < 480;
    final hasRoom = session != null;
    final participants =
        snapshot?.participants ?? const <WatchPartyParticipant>[];
    final canManageParticipants =
        state.isHost &&
        !state.membershipActionInFlight &&
        !_managingParticipant;
    _syncParticipantFocusNodes(
      participants,
      canManageParticipants: canManageParticipants,
    );
    final failureMessage = !hasRoom && _createAttempted && !_creating
        ? watchPartyPlayerCopy(
            state.message ?? 'Watch Party could not create a room.',
          )
        : null;

    return Dialog(
      key: const ValueKey('player-watch-party-dialog'),
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(compact ? 14 : 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: DecoratedBox(
          key: const ValueKey('player-watch-party-panel'),
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: .98),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: palette.accent.withValues(alpha: .72)),
            boxShadow: [
              BoxShadow(
                color: palette.background.withValues(alpha: .78),
                blurRadius: 34,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(compact ? 18 : 24),
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.groups_rounded, color: palette.accentBright),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          hasRoom ? 'Watch Party room' : 'Start Watch Party',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Playback keeps running. Closing this panel does not end the room.',
                    style: TextStyle(color: palette.mutedText),
                  ),
                  SizedBox(height: compact ? 14 : 20),
                  if (hasRoom)
                    Flexible(
                      child: SingleChildScrollView(
                        child: _ActivePlayerParty(
                          roomCode: session.roomCode,
                          watchUrl: session.watchUrl,
                          participantCount: watchPartyViewerCount(state),
                          readyCount: snapshot?.readyCount ?? 0,
                          participants: participants,
                          participantFocusNodes: _participantFocusNodes,
                          timelineDetail: watchPartyTimelineDetail(state),
                          guestSyncOffset: state.guestSyncOffset,
                          canManageParticipants: canManageParticipants,
                          onManageParticipant: (participant) =>
                              unawaited(_manageParticipant(participant)),
                        ),
                      ),
                    )
                  else if (_creating || state.isBusy)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 26,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          SizedBox(width: 14),
                          Text('Creating a private room…'),
                        ],
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        failureMessage ?? 'Preparing Watch Party…',
                        key: const ValueKey('player-watch-party-error'),
                        style: TextStyle(color: palette.accentBright),
                      ),
                    ),
                  if (state.message case final message?
                      when hasRoom && message.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      watchPartyPlayerCopy(message),
                      style: TextStyle(color: palette.mutedText),
                    ),
                  ],
                  if (_localMessage case final message?) ...[
                    const SizedBox(height: 10),
                    Text(
                      message,
                      key: const ValueKey('player-watch-party-message'),
                      style: TextStyle(color: palette.accentBright),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (hasRoom && state.isHost)
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: _DialogAction(
                            key: const ValueKey('player-watch-party-resync'),
                            focusNode: _resyncFocus,
                            autofocus: false,
                            icon: Icons.sync_rounded,
                            label: _resyncing ? 'Resyncing…' : 'Resync party',
                            onPressed: _resyncing
                                ? () {}
                                : () => unawaited(_resyncParty()),
                          ),
                        ),
                      if (hasRoom && !state.isHost) ...[
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: _DialogAction(
                            key: const ValueKey(
                              'player-watch-party-sync-earlier',
                            ),
                            focusNode: _earlierFocus,
                            autofocus: false,
                            icon: Icons.fast_rewind_rounded,
                            label: '5s earlier',
                            onPressed: () =>
                                _adjustGuestSync(const Duration(seconds: -5)),
                          ),
                        ),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(2),
                          child: _DialogAction(
                            key: const ValueKey(
                              'player-watch-party-sync-later',
                            ),
                            focusNode: _laterFocus,
                            icon: Icons.fast_forward_rounded,
                            label: '5s later',
                            onPressed: () =>
                                _adjustGuestSync(const Duration(seconds: 5)),
                          ),
                        ),
                        if (state.guestSyncOffset != Duration.zero)
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(3),
                            child: _DialogAction(
                              key: const ValueKey(
                                'player-watch-party-sync-reset',
                              ),
                              icon: Icons.restore_rounded,
                              label: 'Reset sync',
                              onPressed: () => ref
                                  .read(watchPartyControllerProvider.notifier)
                                  .resetGuestSyncOffset(),
                            ),
                          ),
                      ],
                      if (hasRoom)
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(4),
                          child: _DialogAction(
                            key: const ValueKey('player-watch-party-copy'),
                            focusNode: _copyFocus,
                            autofocus: true,
                            icon: Icons.copy_rounded,
                            label: 'Copy code',
                            onPressed: () =>
                                unawaited(_copyCode(session.roomCode)),
                          ),
                        )
                      else if (!_creating && !state.isBusy)
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: _DialogAction(
                            key: const ValueKey('player-watch-party-retry'),
                            focusNode: _retryFocus,
                            autofocus: true,
                            icon: Icons.refresh_rounded,
                            label: 'Try again',
                            onPressed: () => unawaited(_createRoom()),
                          ),
                        ),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(5),
                        child: _DialogAction(
                          key: const ValueKey('player-watch-party-close'),
                          focusNode: _closeFocus,
                          autofocus: !hasRoom && (_creating || state.isBusy),
                          icon: Icons.close_rounded,
                          label: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                      if (hasRoom)
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(6),
                          child: _DialogAction(
                            key: const ValueKey('player-watch-party-leave'),
                            focusNode: _leaveFocus,
                            icon: session.role == WatchPartyRole.host
                                ? Icons.stop_circle_outlined
                                : Icons.logout_rounded,
                            label: _leaving
                                ? 'Leaving…'
                                : session.role == WatchPartyRole.host
                                ? 'End room'
                                : 'Leave room',
                            onPressed: _leaving
                                ? () {}
                                : () => unawaited(_leaveRoom(session.role)),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivePlayerParty extends StatelessWidget {
  const _ActivePlayerParty({
    required this.roomCode,
    required this.watchUrl,
    required this.participantCount,
    required this.readyCount,
    required this.participants,
    required this.participantFocusNodes,
    required this.timelineDetail,
    required this.guestSyncOffset,
    required this.canManageParticipants,
    required this.onManageParticipant,
  });

  final String roomCode;
  final Uri watchUrl;
  final int participantCount;
  final int readyCount;
  final List<WatchPartyParticipant> participants;
  final Map<String, FocusNode> participantFocusNodes;
  final String timelineDetail;
  final Duration guestSyncOffset;
  final bool canManageParticipants;
  final ValueChanged<WatchPartyParticipant> onManageParticipant;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const ValueKey('player-watch-party-room-code-action'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: palette.selectableSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: palette.accentBright.withValues(alpha: .42),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                roomCode,
                key: const ValueKey('player-watch-party-room-code'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: palette.accentBright,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.people_outline_rounded, color: palette.accentBright),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${watchPartyViewerCountLabel(participantCount)} • '
          '${watchPartyReadyGuestCountLabel(readyCount)}',
          style: TextStyle(color: palette.mutedText),
        ),
        const SizedBox(height: 6),
        Text(
          guestSyncOffset == Duration.zero
              ? timelineDetail
              : '$timelineDetail • local adjustment '
                    '${guestSyncOffset.isNegative ? '-' : '+'}'
                    '${guestSyncOffset.abs().inSeconds}s',
          key: const ValueKey('player-watch-party-timeline-status'),
          style: TextStyle(
            color: palette.accentBright,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        _CompactParticipantPreview(
          participants: participants,
          participantFocusNodes: participantFocusNodes,
          canManageParticipants: canManageParticipants,
          onManageParticipant: onManageParticipant,
        ),
        const SizedBox(height: 10),
        Text(
          'Share this room code to invite someone from TetoTV or the Watch Party website.',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          watchUrl.toString(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.mutedText, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Text(
          'Room timing, public show identity, and a privacy-preserving source hint are synchronized. Stream URLs, tokens, headers, and video data stay on each viewer’s device.',
          style: TextStyle(color: palette.mutedText, fontSize: 12),
        ),
      ],
    );
    return details;
  }
}

class _CompactParticipantPreview extends StatelessWidget {
  const _CompactParticipantPreview({
    required this.participants,
    required this.participantFocusNodes,
    required this.canManageParticipants,
    required this.onManageParticipant,
  });

  final List<WatchPartyParticipant> participants;
  final Map<String, FocusNode> participantFocusNodes;
  final bool canManageParticipants;
  final ValueChanged<WatchPartyParticipant> onManageParticipant;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    if (participants.isEmpty) {
      return Text(
        'Participant profiles will appear here as people join.',
        key: const ValueKey('player-watch-party-participants-empty'),
        style: TextStyle(color: palette.mutedText, fontSize: 12),
      );
    }
    return Container(
      key: const ValueKey('player-watch-party-participants'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final participant in participants)
            _ParticipantChip(
              key: ValueKey(
                'player-watch-party-participant-${_participantStableKey(participant)}',
              ),
              participant: participant,
              focusNode: participant.participantId == null
                  ? null
                  : participantFocusNodes[participant.participantId],
              onPressed:
                  canManageParticipants &&
                      participant.role == WatchPartyRole.guest &&
                      participant.participantId != null
                  ? () => onManageParticipant(participant)
                  : null,
            ),
        ],
      ),
    );
  }
}

String _participantStableKey(WatchPartyParticipant participant) =>
    participant.participantId ??
    '${participant.role.name}:${participant.displayName}:${participant.avatarUrl ?? ''}';

class _ParticipantChip extends StatelessWidget {
  const _ParticipantChip({
    required this.participant,
    this.focusNode,
    this.onPressed,
    super.key,
  });

  final WatchPartyParticipant participant;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final avatarUrl = participant.avatarUrl;
    final chip = Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: const EdgeInsets.fromLTRB(5, 5, 9, 5),
      decoration: BoxDecoration(
        color: palette.selectableSurface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: palette.accent.withValues(alpha: .35),
            foregroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl),
            child: avatarUrl == null
                ? Text(
                    participant.displayName.characters.first.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              participant.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 5),
          Icon(
            participant.role == WatchPartyRole.host
                ? Icons.star_rounded
                : participant.ready
                ? Icons.check_circle_rounded
                : Icons.hourglass_empty_rounded,
            size: 15,
            color: participant.role == WatchPartyRole.host || participant.ready
                ? palette.accentBright
                : palette.mutedText,
          ),
          if (onPressed != null) ...[
            const SizedBox(width: 5),
            Icon(
              Icons.admin_panel_settings_outlined,
              size: 15,
              color: palette.accentBright,
            ),
          ],
        ],
      ),
    );
    if (onPressed == null) return chip;
    return Semantics(
      button: true,
      label: 'Manage ${participant.displayName}',
      child: TvFocusable(
        focusNode: focusNode,
        onPressed: onPressed!,
        focusScale: 1.025,
        borderRadius: BorderRadius.circular(999),
        child: chip,
      ),
    );
  }
}

enum _ParticipantManagementAction { transferHost, kick }

class _ManageParticipantDialog extends StatelessWidget {
  const _ManageParticipantDialog({required this.participant});

  final WatchPartyParticipant participant;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Manage ${participant.displayName}'),
    content: const Text(
      'Transfer makes this person the only playback host. Remove disconnects them from this room.',
    ),
    actions: [
      _DialogAction(
        key: const ValueKey('player-watch-party-manage-cancel'),
        icon: Icons.close_rounded,
        label: 'Cancel',
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(),
      ),
      _DialogAction(
        key: const ValueKey('player-watch-party-transfer-host'),
        icon: Icons.manage_accounts_rounded,
        label: 'Make host',
        onPressed: () => Navigator.of(
          context,
        ).pop(_ParticipantManagementAction.transferHost),
      ),
      _DialogAction(
        key: const ValueKey('player-watch-party-kick'),
        icon: Icons.person_remove_rounded,
        label: 'Remove',
        onPressed: () =>
            Navigator.of(context).pop(_ParticipantManagementAction.kick),
      ),
    ],
  );
}

class _ConfirmLeaveRoomDialog extends StatelessWidget {
  const _ConfirmLeaveRoomDialog({required this.role});

  final WatchPartyRole role;

  @override
  Widget build(BuildContext context) {
    final host = role == WatchPartyRole.host;
    return AlertDialog(
      title: Text(host ? 'End Watch Party room?' : 'Leave this room?'),
      content: Text(
        host
            ? 'This ends the room for every participant. Playback on your device keeps running.'
            : 'You will stop following the host. Playback on your device keeps running.',
      ),
      actions: [
        _DialogAction(
          icon: Icons.close_rounded,
          label: 'Cancel',
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        _DialogAction(
          icon: host ? Icons.stop_circle_outlined : Icons.logout_rounded,
          label: host ? 'End room' : 'Leave room',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

class _DialogAction extends StatelessWidget {
  const _DialogAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    autofocus: autofocus,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        color: context.appPalette.selectableSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    ),
  );
}
