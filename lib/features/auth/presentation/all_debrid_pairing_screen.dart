import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/auth/data/all_debrid_pin_auth_client.dart';
import 'package:anime_tv/features/settings/application/all_debrid_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

class AllDebridPairingScreen extends ConsumerStatefulWidget {
  const AllDebridPairingScreen({super.key, this.client});

  @visibleForTesting
  final AllDebridPinAuthClient? client;

  @override
  ConsumerState<AllDebridPairingScreen> createState() =>
      _AllDebridPairingScreenState();
}

class _AllDebridPairingScreenState
    extends ConsumerState<AllDebridPairingScreen> {
  late final AllDebridPinAuthClient _client;
  AllDebridPinSession? _session;
  Timer? _pollTimer;
  bool _polling = false;
  bool _authorized = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? AllDebridPinAuthClient();
    _start();
  }

  Future<void> _start() async {
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
      _pollTimer = Timer.periodic(
        session.pollInterval,
        (_) => _poll(generation),
      );
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
      setState(() => _error = 'The AllDebrid PIN expired.');
      return;
    }
    _polling = true;
    try {
      final token = await _client.poll(session);
      if (token == null || !mounted || generation != _generation) return;
      final saved = await ref
          .read(allDebridSettingsControllerProvider.notifier)
          .saveAndValidate(token);
      if (!mounted || generation != _generation) return;
      if (!saved) {
        throw StateError(
          ref.read(allDebridSettingsControllerProvider).errorMessage ??
              'AllDebrid could not validate this account.',
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
    final isTelevision = ref.watch(isTelevisionProvider);
    return Scaffold(
      body: SafeArea(
        minimum: EdgeInsets.symmetric(
          horizontal: isTelevision ? 28 : 16,
          vertical: isTelevision ? 22 : 14,
        ),
        child: Column(
          children: [
            if (isTelevision)
              Row(
                children: [
                  _ActionButton(
                    autofocus: true,
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onPressed: context.pop,
                  ),
                  const SizedBox(width: 18),
                  Text(
                    'Connect AllDebrid',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ],
              )
            else
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: context.pop,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Connect AllDebrid',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            Expanded(child: Center(child: _content(context))),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_authorized) {
      return _PairingMessage(
        icon: Icons.check_circle_rounded,
        color: const Color(0xFF67D49B),
        title: 'AllDebrid connected',
        body: 'Your API key is encrypted in the Android Keystore.',
        actionLabel: 'Done',
        onAction: context.pop,
      );
    }
    if (_error case final error?) {
      return _PairingMessage(
        icon: Icons.error_outline_rounded,
        color: const Color(0xFFFF929B),
        title: 'Could not connect AllDebrid',
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
    return Container(
      constraints: const BoxConstraints(maxWidth: 900),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 650;
          final qr = CopyableQrInteraction(
            data: session.verificationUrl.toString(),
            semanticsLabel: 'QR code for AllDebrid pairing',
            confirmationMessage: 'AllDebrid pairing link copied.',
            child: Container(
              width: compact ? 170 : 220,
              height: compact ? 170 : 220,
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
                textAlign: compact ? TextAlign.center : null,
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 10),
              const Text('Or open alldebrid.com/pin and enter:'),
              const SizedBox(height: 14),
              Text(
                session.pin,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'TetoTV saves the key only after AllDebrid confirms an active premium account.',
                style: TextStyle(color: context.appPalette.mutedText),
              ),
            ],
          );
          if (compact) {
            return SingleChildScrollView(
              child: Column(
                children: [qr, const SizedBox(height: 22), instructions],
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
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 72, color: color),
      const SizedBox(height: 18),
      Text(title, style: Theme.of(context).textTheme.displaySmall),
      const SizedBox(height: 10),
      Text(body, textAlign: TextAlign.center),
      const SizedBox(height: 24),
      _ActionButton(
        autofocus: true,
        icon: Icons.check_rounded,
        label: actionLabel,
        onPressed: onAction,
      ),
    ],
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
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
  Widget build(BuildContext context) => TvFocusable(
    autofocus: autofocus,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      color: context.appPalette.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(label)],
      ),
    ),
  );
}
