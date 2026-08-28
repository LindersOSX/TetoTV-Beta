import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/auth/data/torbox_device_auth_client.dart';
import 'package:anime_tv/features/settings/application/torbox_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

class TorBoxPairingScreen extends ConsumerStatefulWidget {
  const TorBoxPairingScreen({super.key, this.client});

  @visibleForTesting
  final TorBoxDeviceAuthClient? client;

  @override
  ConsumerState<TorBoxPairingScreen> createState() =>
      _TorBoxPairingScreenState();
}

class _TorBoxPairingScreenState extends ConsumerState<TorBoxPairingScreen> {
  late final TorBoxDeviceAuthClient _client;
  TorBoxDeviceSession? _session;
  Timer? _pollTimer;
  bool _polling = false;
  bool _authorized = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? TorBoxDeviceAuthClient();
    _start();
  }

  Future<void> _start() async {
    if (!mounted) return;
    final generation = ++_generation;
    _pollTimer?.cancel();
    setState(() {
      _session = null;
      _authorized = false;
      _error = null;
    });
    try {
      final session = await _client.start();
      if (!mounted || generation != _generation) return;
      setState(() => _session = session);
      _pollTimer = Timer.periodic(session.interval, (_) => _poll(generation));
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _poll(int generation) async {
    final session = _session;
    if (_polling ||
        session == null ||
        _authorized ||
        !mounted ||
        generation != _generation) {
      return;
    }
    if (DateTime.now().isAfter(session.expiresAt)) {
      _pollTimer?.cancel();
      setState(() => _error = 'The TorBox authorization code expired.');
      return;
    }
    _polling = true;
    try {
      final token = await _client.poll(session);
      if (token == null || !mounted || generation != _generation) return;
      final saved = await ref
          .read(torBoxSettingsControllerProvider.notifier)
          .saveAndValidate(token);
      if (!mounted || generation != _generation) return;
      if (!saved) {
        throw StateError(
          ref.read(torBoxSettingsControllerProvider).errorMessage ??
              'TorBox could not validate this account.',
        );
      }
      _pollTimer?.cancel();
      setState(() => _authorized = true);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _pollTimer?.cancel();
      setState(() => _error = error.toString());
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 720;
          final short = constraints.maxHeight < 600;
          return SafeArea(
            minimum: EdgeInsets.symmetric(
              horizontal: narrow ? 20 : 42,
              vertical: short ? 14 : 28,
            ),
            child: Column(
              children: [
                _PairingHeader(compact: narrow, onBack: context.pop),
                SizedBox(height: short ? 16 : 28),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, viewport) => SingleChildScrollView(
                      padding: EdgeInsets.only(bottom: short ? 8 : 20),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: (viewport.maxHeight - (short ? 8 : 20))
                              .clamp(0, double.infinity)
                              .toDouble(),
                        ),
                        child: Center(child: _content(context)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_authorized) {
      return _PairingMessage(
        icon: Icons.check_circle_rounded,
        color: const Color(0xFF67D49B),
        title: 'TorBox connected',
        body: 'Your API token is encrypted in the Android Keystore.',
        actionLabel: 'Done',
        onAction: context.pop,
      );
    }
    if (_error case final error?) {
      return _PairingMessage(
        icon: Icons.error_outline_rounded,
        color: const Color(0xFFFF929B),
        title: 'Could not connect TorBox',
        body: error,
        actionLabel: 'Try again',
        onAction: _start,
      );
    }
    final session = _session;
    if (session == null) {
      return CircularProgressIndicator(
        color: context.appPalette.secondaryAccent,
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          final qrSize = compact ? 190.0 : 220.0;
          final qr = CopyableQrInteraction(
            data: session.verificationUrl.toString(),
            semanticsLabel: 'QR code for TorBox pairing',
            confirmationMessage: 'TorBox pairing link copied.',
            child: Container(
              width: qrSize,
              height: qrSize,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: session.verificationUrl.toString(),
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.Q,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
              ),
            ),
          );
          final details = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _WaitingPill(),
              const SizedBox(height: 18),
              Text(
                'Scan with your phone',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Or open ${session.friendlyVerificationUrl} and enter:',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 18),
              Text(
                session.userCode,
                style: TextStyle(
                  color: context.appPalette.primaryText,
                  fontSize: compact ? 30 : 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: compact ? 3 : 5,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'TorBox updates this screen automatically after approval. '
                'Device authorization requires a paid TorBox plan.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
          return Container(
            width: constraints.maxWidth,
            padding: EdgeInsets.all(compact ? 20 : 34),
            decoration: BoxDecoration(
              color: context.appPalette.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: .08)),
            ),
            child: compact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Align(alignment: Alignment.center, child: qr),
                      const SizedBox(height: 24),
                      details,
                    ],
                  )
                : Row(
                    children: [
                      qr,
                      const SizedBox(width: 38),
                      Expanded(child: details),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _PairingHeader extends StatelessWidget {
  const _PairingHeader({required this.compact, required this.onBack});

  final bool compact;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final leading = Row(
      children: [
        _PairingAction(
          autofocus: true,
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onPressed: onBack,
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            'Connect TorBox',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
      ],
    );
    final note = Text(
      'Your TorBox password never touches this TV',
      style: TextStyle(color: context.appPalette.mutedText),
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [leading, const SizedBox(height: 8), note],
      );
    }
    return Row(
      children: [
        Expanded(child: leading),
        const SizedBox(width: 20),
        note,
      ],
    );
  }
}

class _WaitingPill extends StatelessWidget {
  const _WaitingPill();

  @override
  Widget build(BuildContext context) {
    return Container(
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
}

class _PairingMessage extends StatelessWidget {
  const _PairingMessage({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 72, color: color),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 10),
        Text(body, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 24),
        _PairingAction(
          autofocus: true,
          icon: Icons.refresh_rounded,
          label: actionLabel,
          onPressed: onAction,
        ),
      ],
    );
  }
}

class _PairingAction extends StatelessWidget {
  const _PairingAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
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
            Text(label),
          ],
        ),
      ),
    );
  }
}
