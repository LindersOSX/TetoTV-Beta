import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/discord/application/discord_device_pairing_controller.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:anime_tv/features/discord/domain/discord_minimum_age_confirmation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

class DiscordDevicePairingScreen extends ConsumerStatefulWidget {
  const DiscordDevicePairingScreen({super.key});

  @override
  ConsumerState<DiscordDevicePairingScreen> createState() =>
      _DiscordDevicePairingScreenState();
}

class _DiscordDevicePairingScreenState
    extends ConsumerState<DiscordDevicePairingScreen>
    with WidgetsBindingObserver {
  late final DiscordDevicePairingController _controller;
  final _backFocus = FocusNode(debugLabel: 'discord-pairing.back');
  final _statusActionFocus = FocusNode(
    debugLabel: 'discord-pairing.status-action',
  );
  DiscordMinimumAgeConfirmation? _minimumAgeConfirmation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ref.read(discordDevicePairingControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _statusActionFocus.canRequestFocus) {
        _statusActionFocus.requestFocus();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.pollNow());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // PopScope and _close handle normal navigation. Avoid publishing provider
    // state while Riverpod is unmounting this consumer during ancestor/test
    // teardown; the controller's own dispose still cancels the native session.
    unawaited(Future<void>.microtask(_controller.stop));
    _backFocus.dispose();
    _statusActionFocus.dispose();
    super.dispose();
  }

  void _close() {
    _controller.stop();
    context.pop();
  }

  void _confirmAndStart() {
    const confirmation = DiscordMinimumAgeConfirmation.current();
    setState(() => _minimumAgeConfirmation = confirmation);
    unawaited(_controller.start(confirmation));
  }

  void _restart() {
    final confirmation = _minimumAgeConfirmation;
    if (confirmation != null) unawaited(_controller.start(confirmation));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discordDevicePairingControllerProvider);
    ref.listen(discordDevicePairingControllerProvider, (previous, next) {
      if (previous?.stage == next.stage) return;
      final target = switch (next.stage) {
        DiscordDevicePairingStage.completed ||
        DiscordDevicePairingStage.expired ||
        DiscordDevicePairingStage.failed ||
        DiscordDevicePairingStage.stopped => _statusActionFocus,
        _ => _backFocus,
      };
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && target.canRequestFocus) target.requestFocus();
      });
    });
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _controller.stop();
      },
      child: Scaffold(
        backgroundColor: context.appPalette.background,
        body: SafeArea(
          minimum: context.responsiveScreenPadding,
          child: Column(
            children: [
              Row(
                children: [
                  _PairingAction(
                    key: const ValueKey('discord-pairing-back'),
                    autofocus: true,
                    focusNode: _backFocus,
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onPressed: _close,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Connect Discord',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  if (!context.isCompactWidth)
                    Text(
                      'Approve securely on your phone or computer',
                      style: TextStyle(color: context.appPalette.mutedText),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              Expanded(
                child: Center(
                  child: _minimumAgeConfirmation == null
                      ? _MinimumAgeConfirmationCard(
                          onConfirm: _confirmAndStart,
                          actionFocusNode: _statusActionFocus,
                        )
                      : _DiscordPairingContent(
                          state: state,
                          onRestart: _restart,
                          onDone: _close,
                          actionFocusNode: _statusActionFocus,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MinimumAgeConfirmationCard extends StatelessWidget {
  const _MinimumAgeConfirmationCard({
    required this.onConfirm,
    required this.actionFocusNode,
  });

  final VoidCallback onConfirm;
  final FocusNode actionFocusNode;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 720),
      padding: EdgeInsets.all(context.isCompactWidth ? 20 : 32),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: context.isCompactWidth ? 48 : 64,
            color: context.appPalette.accentBright,
          ),
          const SizedBox(height: 18),
          Text(
            'Discord age requirement',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            'I confirm I meet Discord\'s minimum age of at least 13, or the older minimum required where I live.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appPalette.mutedText),
          ),
          const SizedBox(height: 24),
          _PairingAction(
            key: const ValueKey('discord-age-confirm'),
            focusNode: actionFocusNode,
            icon: Icons.check_rounded,
            label: 'I meet the requirement',
            onPressed: onConfirm,
          ),
        ],
      ),
    );
  }
}

class _DiscordPairingContent extends StatelessWidget {
  const _DiscordPairingContent({
    required this.state,
    required this.onRestart,
    required this.onDone,
    required this.actionFocusNode,
  });

  final DiscordDevicePairingState state;
  final VoidCallback onRestart;
  final VoidCallback onDone;
  final FocusNode actionFocusNode;

  @override
  Widget build(BuildContext context) {
    return switch (state.stage) {
      DiscordDevicePairingStage.waiting => _WaitingForDiscord(
        session: state.session!,
      ),
      DiscordDevicePairingStage.linking => const _PairingStatus(
        busy: true,
        title: 'Discord approved',
        body: 'Saving the secure link on this device\u2026',
      ),
      DiscordDevicePairingStage.completed => _PairingStatus(
        icon: Icons.check_circle_rounded,
        color: const Color(0xFF67D49B),
        title: 'Discord linked',
        body:
            'Discord is linked and Rich Presence is enabled. If it is still connecting, use Retry in Settings.',
        actionIcon: Icons.check_rounded,
        actionLabel: 'Done',
        onAction: onDone,
        actionFocusNode: actionFocusNode,
      ),
      DiscordDevicePairingStage.expired => _PairingStatus(
        icon: Icons.timer_off_rounded,
        title: 'Code expired',
        body: state.message ?? 'Create a new one-time code and try again.',
        actionLabel: 'New code',
        onAction: onRestart,
        actionFocusNode: actionFocusNode,
      ),
      DiscordDevicePairingStage.failed => _PairingStatus(
        icon: Icons.error_outline_rounded,
        color: const Color(0xFFFF929B),
        title: 'Could not connect Discord',
        body:
            state.message ??
            'Check the internet connection, then create a new code.',
        actionLabel: 'Try again',
        onAction: onRestart,
        actionFocusNode: actionFocusNode,
      ),
      DiscordDevicePairingStage.stopped => _PairingStatus(
        icon: Icons.link_off_rounded,
        title: 'Pairing stopped',
        body: 'Return to Settings when you are ready to connect Discord.',
        actionLabel: 'Try again',
        onAction: onRestart,
        actionFocusNode: actionFocusNode,
      ),
      DiscordDevicePairingStage.idle ||
      DiscordDevicePairingStage.starting => const _PairingStatus(
        busy: true,
        title: 'Creating a one-time code',
        body: 'Connecting securely to Discord\u2026',
      ),
    };
  }
}

class _WaitingForDiscord extends StatelessWidget {
  const _WaitingForDiscord({required this.session});

  final DiscordDevicePairingSession session;

  @override
  Widget build(BuildContext context) {
    final expiresInMinutes =
        session.expiresAt.difference(DateTime.now()).inMinutes.clamp(0, 14) + 1;
    return Container(
      constraints: const BoxConstraints(maxWidth: 900),
      padding: EdgeInsets.all(context.isCompactWidth ? 18 : 28),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 650;
          final qrSize = compact ? 166.0 : 220.0;
          final qrData = session.verificationUriComplete.toString();
          final qr = CopyableQrInteraction(
            data: qrData,
            semanticsLabel: 'QR code to authorize TetoTV with Discord',
            confirmationMessage: 'Discord authorization link copied.',
            child: Container(
              key: const ValueKey('discord-pairing-qr'),
              width: qrSize,
              height: qrSize,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: qrData,
                semanticsLabel: 'Discord device authorization link',
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.Q,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
              ),
            ),
          );
          final instructions = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              const _WaitingPill(),
              const SizedBox(height: 16),
              Text(
                'Scan with your phone',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 10),
              Text(
                'Or open ${session.verificationUri} and enter:',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 14),
              Semantics(
                label: 'Discord confirmation code ${session.userCode}',
                readOnly: true,
                child: Text(
                  session.userCode,
                  key: const ValueKey('discord-pairing-code'),
                  maxLines: 1,
                  style: TextStyle(
                    color: context.appPalette.accentBright,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 5,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'TetoTV updates automatically after you approve the request. '
                'Your Discord password is never entered on this device.',
                textAlign: TextAlign.start,
                style: TextStyle(color: context.appPalette.mutedText),
              ),
              const SizedBox(height: 7),
              Text(
                'This one-time code expires in about $expiresInMinutes '
                '${expiresInMinutes == 1 ? 'minute' : 'minutes'}.',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: TextStyle(
                  color: context.appPalette.mutedText,
                  fontSize: 11,
                ),
              ),
            ],
          );
          if (compact) {
            return SingleChildScrollView(
              child: Column(
                children: [instructions, const SizedBox(height: 18), qr],
              ),
            );
          }
          return Row(
            children: [
              qr,
              const SizedBox(width: 36),
              Expanded(child: instructions),
            ],
          );
        },
      ),
    );
  }
}

class _WaitingPill extends StatelessWidget {
  const _WaitingPill();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: context.appPalette.secondaryAccent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.sync_rounded,
          size: 15,
          color: context.appPalette.secondaryAccent,
        ),
        const SizedBox(width: 7),
        Text(
          'WAITING FOR APPROVAL',
          style: TextStyle(
            color: context.appPalette.secondaryAccent,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
      ],
    ),
  );
}

class _PairingStatus extends StatelessWidget {
  const _PairingStatus({
    required this.title,
    required this.body,
    this.icon,
    this.color,
    this.busy = false,
    this.actionIcon = Icons.refresh_rounded,
    this.actionLabel,
    this.onAction,
    this.actionFocusNode,
  });

  final IconData? icon;
  final Color? color;
  final bool busy;
  final String title;
  final String body;
  final IconData actionIcon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final FocusNode? actionFocusNode;

  @override
  Widget build(BuildContext context) {
    final statusColor = color ?? context.appPalette.accentBright;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              CircularProgressIndicator(color: context.appPalette.accentBright)
            else
              Icon(icon, size: 72, color: statusColor),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(height: 10),
            Text(body, textAlign: TextAlign.center),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              _PairingAction(
                focusNode: actionFocusNode,
                icon: actionIcon,
                label: actionLabel!,
                onPressed: onAction!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairingAction extends StatelessWidget {
  const _PairingAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => TvFocusable(
    autofocus: autofocus,
    focusNode: focusNode,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      color: context.appPalette.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    ),
  );
}
