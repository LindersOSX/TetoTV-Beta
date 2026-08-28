import 'dart:math' as math;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/player/presentation/watch_party_player_status.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Compact, non-interactive Watch Party activity cards.
///
/// Notice lifetimes live in [WatchPartyController], so unrelated UI rebuilds
/// cannot restart the five-second countdown. Each active event receives its
/// own row and therefore never paints over another.
class WatchPartyMembershipNoticeOverlay extends ConsumerWidget {
  const WatchPartyMembershipNoticeOverlay({super.key});

  static const _horizontalSafeInset = 22.0;
  static const _verticalSafeInset = 18.0;
  static const _maximumCardWidth = 340.0;
  static const _estimatedCardExtent = 62.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices = ref.watch(
      watchPartyControllerProvider.select((state) => state.notices),
    );
    if (notices.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          _horizontalSafeInset,
          _verticalSafeInset,
          _horizontalSafeInset,
          _verticalSafeInset,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(_maximumCardWidth, constraints.maxWidth);
            final capacity = math.max(
              1,
              constraints.maxHeight ~/ _estimatedCardExtent,
            );
            // Ordinary activity shows every event. In an extreme broker burst,
            // retain all lifetimes in controller state but keep only the newest
            // rows inside the physical TV safe area.
            final visible = notices.length <= capacity
                ? notices
                : notices.sublist(notices.length - capacity);
            return Align(
              alignment: Alignment.topRight,
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.35,
                child: SizedBox(
                  key: const ValueKey('watch-party-membership-notice-list'),
                  width: width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < visible.length; index++) ...[
                        if (index > 0) const SizedBox(height: 8),
                        _WatchPartyNoticeCard(notice: visible[index]),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WatchPartyNoticeCard extends StatelessWidget {
  const _WatchPartyNoticeCard({required this.notice});

  final WatchPartyNotice notice;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Semantics(
      key: ValueKey('watch-party-membership-notice-${notice.sequence}'),
      container: true,
      liveRegion: true,
      excludeSemantics: true,
      label: watchPartyPlayerCopy(notice.message),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xF20B0B10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: palette.accentBright.withValues(alpha: .82),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x8A000000),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 12, 8),
          child: Row(
            children: [
              _NoticeAvatar(notice: notice),
              const SizedBox(width: 10),
              Expanded(child: _NoticeCopy(notice: notice)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeAvatar extends StatelessWidget {
  const _NoticeAvatar({required this.notice});

  final WatchPartyNotice notice;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final displayName = notice.displayName;
    final avatarUrl = notice.avatarUrl;
    return SizedBox.square(
      key: ValueKey('watch-party-membership-avatar-${notice.sequence}'),
      dimension: 36,
      child: ClipOval(
        child: avatarUrl != null
            ? NetworkArtwork(
                url: avatarUrl,
                icon: Icons.person_rounded,
                cacheWidth: 96,
              )
            : ColoredBox(
                color: palette.accent.withValues(alpha: .3),
                child: Center(
                  child: displayName == null
                      ? Icon(
                          Icons.group_rounded,
                          size: 20,
                          color: palette.accentBright,
                        )
                      : Text(
                          _initial(displayName),
                          style: TextStyle(
                            color: palette.accentBright,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ),
      ),
    );
  }
}

class _NoticeCopy extends StatelessWidget {
  const _NoticeCopy({required this.notice});

  final WatchPartyNotice notice;

  @override
  Widget build(BuildContext context) {
    final displayName = notice.displayName;
    final actionText = notice.actionText;
    if (!notice.isParticipantEvent ||
        displayName == null ||
        actionText == null) {
      return Text(
        watchPartyPlayerCopy(notice.message),
        key: ValueKey('watch-party-membership-message-${notice.sequence}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          decoration: TextDecoration.none,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          height: 1.18,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          displayName,
          key: ValueKey('watch-party-membership-name-${notice.sequence}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            decoration: TextDecoration.none,
            fontSize: 14,
            fontWeight: FontWeight.w900,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          actionText,
          key: ValueKey('watch-party-membership-action-${notice.sequence}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            decoration: TextDecoration.none,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.05,
          ),
        ),
      ],
    );
  }
}

String _initial(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '?';
  return String.fromCharCode(normalized.runes.first).toUpperCase();
}
