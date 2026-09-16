import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'dart:async';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_media_follower.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class WatchTogetherScreen extends ConsumerStatefulWidget {
  const WatchTogetherScreen({
    this.initialRoomCode,
    this.autofocusNavigation = false,
    super.key,
  });

  final String? initialRoomCode;
  final bool autofocusNavigation;

  @override
  ConsumerState<WatchTogetherScreen> createState() =>
      _WatchTogetherScreenState();
}

class _WatchTogetherScreenState extends ConsumerState<WatchTogetherScreen> {
  final _createFocus = FocusNode(debugLabel: 'watch-together.create');
  final _roomCodeFocus = FocusNode(debugLabel: 'watch-together.room-code');
  final _joinFocus = FocusNode(debugLabel: 'watch-together.join');
  final _copyFocus = FocusNode(debugLabel: 'watch-together.copy');
  final _watchFocus = FocusNode(debugLabel: 'watch-together.watch');
  final _leaveFocus = FocusNode(debugLabel: 'watch-together.leave');
  final _classicNavigationFocus = FocusNode(
    debugLabel: 'watch-together.navigation',
  );
  late final TextEditingController _roomCodeController;

  @override
  void initState() {
    super.initState();
    _roomCodeController = TextEditingController(text: widget.initialRoomCode);
  }

  @override
  void dispose() {
    _createFocus.dispose();
    _roomCodeFocus.dispose();
    _joinFocus.dispose();
    _copyFocus.dispose();
    _watchFocus.dispose();
    _leaveFocus.dispose();
    _classicNavigationFocus.dispose();
    _roomCodeController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    await ref
        .read(watchPartyControllerProvider.notifier)
        .join(_roomCodeController.text);
  }

  void _openHostEpisode(WatchPartyMedia media) {
    if (!media.isCatalogEpisode) return;
    context.push(watchPartyCatalogFollowLocation(media));
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(settingsPreferencesProvider);
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final party = ref.watch(watchPartyControllerProvider);
    final publicIdentity = ref.watch(watchPartyPublicIdentityProvider);
    ref.read(watchPartyClientProvider).setPublicIdentity(publicIdentity);
    return Stack(
      fit: StackFit.expand,
      children: [
        TetoTopLevelShell(
          preferences: preferences,
          activeDestination: TopNavigationDestination.watchTogether,
          firstContentFocusNode: party.isActive ? _copyFocus : _createFocus,
          autofocusRail: widget.autofocusNavigation,
          fallbackContentFocusNode: party.isActive
              ? _leaveFocus
              : _roomCodeFocus,
          builder: (context, layout) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!layout.usesPersistentNavigation)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Focus(
                    canRequestFocus: false,
                    onKeyEvent: (_, event) {
                      if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
                        return KeyEventResult.ignored;
                      }
                      if (event is KeyDownEvent || event is KeyRepeatEvent) {
                        final target = party.isActive
                            ? _copyFocus
                            : _createFocus;
                        if (target.context != null) target.requestFocus();
                      }
                      return KeyEventResult.handled;
                    },
                    child: MainNavigationBar(
                      active: MainNavigationDestination.watchTogether,
                      preferences: preferences,
                      activeFocusNode: _classicNavigationFocus,
                      onActivePressed: () {
                        final target = party.isActive
                            ? _copyFocus
                            : _createFocus;
                        if (target.context != null) target.requestFocus();
                      },
                    ),
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: layout.usesSideNavigation
                      ? EdgeInsets.zero
                      : const EdgeInsets.fromLTRB(20, 10, 20, 28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr("Watch Party"),
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.tr(
                            "Everyone uses their own TetoTV source or local video. Playback timing, public show identity, and a privacy-preserving source hint are synchronized; stream URLs and credentials stay on each device.",
                          ),
                          style: TextStyle(color: context.appPalette.mutedText),
                        ),
                        const SizedBox(height: 20),
                        if (!party.isActive)
                          _LobbyCard(
                            state: party,
                            roomCodeController: _roomCodeController,
                            createFocus: _createFocus,
                            roomCodeFocus: _roomCodeFocus,
                            joinFocus: _joinFocus,
                            onCreate: () => unawaited(
                              ref
                                  .read(watchPartyControllerProvider.notifier)
                                  .create(),
                            ),
                            onJoin: () => unawaited(_join()),
                            onLeftEdge: layout.usesPersistentNavigation
                                ? layout.focusRail
                                : _classicNavigationFocus.requestFocus,
                          )
                        else
                          _ActivePartyCard(
                            state: party,
                            titlePreference: titlePreference,
                            copyFocus: _copyFocus,
                            watchFocus: _watchFocus,
                            leaveFocus: _leaveFocus,
                            onLeftEdge: layout.usesPersistentNavigation
                                ? layout.focusRail
                                : _classicNavigationFocus.requestFocus,
                            onWatch: party.snapshot?.media == null
                                ? null
                                : () =>
                                      _openHostEpisode(party.snapshot!.media!),
                            onLeave: () => unawaited(
                              ref
                                  .read(watchPartyControllerProvider.notifier)
                                  .leave(),
                            ),
                          ),
                        if (party.message case final message?) ...[
                          const SizedBox(height: 14),
                          Text(
                            context.tr(message),
                            key: const ValueKey('watch-together-message'),
                            style: TextStyle(
                              color: context.appPalette.accentBright,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LobbyCard extends StatelessWidget {
  const _LobbyCard({
    required this.state,
    required this.roomCodeController,
    required this.createFocus,
    required this.roomCodeFocus,
    required this.joinFocus,
    required this.onCreate,
    required this.onJoin,
    required this.onLeftEdge,
  });

  final WatchPartyState state;
  final TextEditingController roomCodeController;
  final FocusNode createFocus;
  final FocusNode roomCodeFocus;
  final FocusNode joinFocus;
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  final VoidCallback onLeftEdge;

  @override
  Widget build(BuildContext context) => _PartyPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr("Start a room or enter a code"),
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _PartyButton(
              key: const ValueKey('watch-together-create'),
              focusNode: createFocus,
              autofocus: true,
              icon: Icons.groups_rounded,
              label: state.isBusy
                  ? context.tr("Starting…")
                  : context.tr("Create room"),
              onPressed: state.isBusy ? null : onCreate,
              onLeft: onLeftEdge,
            ),
            SizedBox(
              width: 230,
              child: TvTextInput(
                key: const ValueKey('watch-together-code-input'),
                controller: roomCodeController,
                focusNode: roomCodeFocus,
                autofocus: false,
                labelText: context.tr("Room code"),
                keyboardTitle: context.tr("Enter Watch Party room code"),
                hintText: '23456789',
                keyboardType: TextInputType.number,
                numericOnly: true,
                maxLength: 8,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[2-9]')),
                ],
                onExitLeft: createFocus.requestFocus,
                onExitUp: createFocus.requestFocus,
                onExitRight: joinFocus.requestFocus,
                onExitDown: joinFocus.requestFocus,
                onSubmitted: (_) => onJoin(),
              ),
            ),
            _PartyButton(
              key: const ValueKey('watch-together-join'),
              focusNode: joinFocus,
              icon: Icons.login_rounded,
              label: state.isBusy
                  ? context.tr("Joining…")
                  : context.tr("Join room"),
              onPressed: state.isBusy ? null : onJoin,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          context.tr(
            "Rooms expire automatically. TetoTV never sends stream URLs, server tokens, headers, magnets, or video data to the room service.",
          ),
          style: TextStyle(color: context.appPalette.mutedText, fontSize: 12),
        ),
      ],
    ),
  );
}

class _ActivePartyCard extends StatelessWidget {
  const _ActivePartyCard({
    required this.state,
    required this.titlePreference,
    required this.copyFocus,
    required this.watchFocus,
    required this.leaveFocus,
    required this.onLeftEdge,
    required this.onWatch,
    required this.onLeave,
  });

  final WatchPartyState state;
  final TitleLanguagePreference titlePreference;
  final FocusNode copyFocus;
  final FocusNode watchFocus;
  final FocusNode leaveFocus;
  final VoidCallback onLeftEdge;
  final VoidCallback? onWatch;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final session = state.session!;
    final snapshot = state.snapshot;
    final media = snapshot?.media;
    return _PartyPanel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            width: constraints.maxWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.isHost ? context.tr("HOSTING") : context.tr("JOINED"),
                  style: TextStyle(
                    color: context.appPalette.accentBright,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
                SelectableText(
                  session.roomCode,
                  key: const ValueKey('watch-together-room-code'),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    watchPartyViewerCount(state) == 1
                        ? '{count} person watching • {ready} guests ready'
                        : '{count} people watching • {ready} guests ready',
                    {
                      'count': watchPartyViewerCount(state),
                      'ready': snapshot?.readyCount ?? 0,
                    },
                  ),
                  style: TextStyle(color: context.appPalette.mutedText),
                ),
                if (snapshot != null && snapshot.participants.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _ParticipantRoster(participants: snapshot.participants),
                ],
                if (media != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    media.isCatalogEpisode
                        ? context.tr("{value1} • Episode {value2}", {
                            'value1': media.displayTitle(titlePreference),
                            'value2': media.episode ?? 0,
                          })
                        : media.displayTitle(titlePreference),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _PartyButton(
                      key: const ValueKey('watch-together-copy'),
                      focusNode: copyFocus,
                      autofocus: true,
                      icon: Icons.copy_rounded,
                      label: context.tr("Copy code"),
                      onLeft: onLeftEdge,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: session.roomCode),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(context.tr("Room code copied.")),
                            ),
                          );
                        }
                      },
                    ),
                    if (!state.isHost && media?.isCatalogEpisode == true)
                      _PartyButton(
                        key: const ValueKey('watch-together-watch'),
                        focusNode: watchFocus,
                        icon: Icons.play_arrow_rounded,
                        label: context.tr("Open this episode"),
                        onPressed: onWatch,
                      ),
                    _PartyButton(
                      key: const ValueKey('watch-together-leave'),
                      focusNode: leaveFocus,
                      icon: Icons.logout_rounded,
                      label: state.isHost
                          ? context.tr("End party")
                          : context.tr("Leave party"),
                      onPressed: onLeave,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ParticipantRoster extends StatelessWidget {
  const _ParticipantRoster({required this.participants});

  final List<WatchPartyParticipant> participants;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: context.tr("People in this room"),
    child: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var index = 0; index < participants.length; index++)
          _ParticipantChip(
            key: ValueKey('watch-together-participant-$index'),
            participant: participants[index],
          ),
      ],
    ),
  );
}

class _ParticipantChip extends StatelessWidget {
  const _ParticipantChip({required this.participant, super.key});

  final WatchPartyParticipant participant;

  @override
  Widget build(BuildContext context) {
    final role = context.tr(
      participant.role == WatchPartyRole.host ? 'Host' : 'Guest',
    );
    final readiness = context.tr(participant.ready ? 'Ready' : 'Not ready');
    return Semantics(
      label: '${participant.displayName}, $role, $readiness',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.appPalette.selectableSurface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: context.appPalette.primaryText.withValues(alpha: .12),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 36,
                child: ClipOval(
                  child: participant.avatarUrl == null
                      ? ColoredBox(
                          color: context.appPalette.accent.withValues(
                            alpha: .22,
                          ),
                          child: Center(
                            child: Text(
                              _participantInitials(participant.displayName),
                              style: TextStyle(
                                color: context.appPalette.accentBright,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        )
                      : NetworkArtwork(
                          url: participant.avatarUrl,
                          icon: Icons.person_rounded,
                          cacheWidth: 96,
                        ),
                ),
              ),
              const SizedBox(width: 9),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      participant.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '$role • $readiness',
                    style: TextStyle(
                      color: context.appPalette.mutedText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _participantInitials(String value) {
  final words = value.trim().split(RegExp(r'\s+')).take(2);
  final initials = words
      .where((word) => word.isNotEmpty)
      .map((word) => String.fromCharCode(word.runes.first))
      .join()
      .toUpperCase();
  return initials.isEmpty ? '?' : initials;
}

class _PartyPanel extends StatelessWidget {
  const _PartyPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.appPalette.surface.withValues(alpha: .82),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: context.appPalette.accent.withValues(alpha: .35),
      ),
    ),
    child: Padding(padding: const EdgeInsets.all(22), child: child),
  );
}

class _PartyButton extends StatelessWidget {
  const _PartyButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.onLeft,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onLeft;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    autofocus: autofocus,
    onPressed: onPressed ?? () {},
    onKeyEvent: onLeft == null
        ? null
        : (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              onLeft!();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
    borderRadius: BorderRadius.circular(12),
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: onPressed == null ? .45 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: context.appPalette.selectableSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    ),
  );
}
