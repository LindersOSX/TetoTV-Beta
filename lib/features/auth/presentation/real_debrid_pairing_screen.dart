import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

class RealDebridPairingScreen extends ConsumerStatefulWidget {
  const RealDebridPairingScreen({super.key, this.client});

  /// Optional override used by widget tests. Production pairing always uses
  /// the official Real-Debrid OAuth client.
  final RealDebridOAuthClient? client;

  @override
  ConsumerState<RealDebridPairingScreen> createState() =>
      _RealDebridPairingScreenState();
}

class _RealDebridPairingScreenState
    extends ConsumerState<RealDebridPairingScreen> {
  late final RealDebridOAuthClient _client;
  RealDebridDeviceSession? _session;
  Timer? _pollTimer;
  String? _error;
  bool _authorized = false;
  bool _polling = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? RealDebridOAuthClient();
    _start();
  }

  Future<void> _start() async {
    if (!mounted) return;
    final generation = ++_generation;
    _pollTimer?.cancel();
    setState(() {
      _session = null;
      _error = null;
      _authorized = false;
    });
    try {
      final session = await _client.startDeviceAuthorization();
      if (!mounted || generation != _generation) return;
      setState(() => _session = session);
      _pollTimer = Timer.periodic(session.interval, (_) => _poll(generation));
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _friendlyError(error));
      }
    }
  }

  Future<void> _poll(int generation) async {
    if (!mounted || generation != _generation) return;
    final session = _session;
    if (_polling || session == null || _authorized) return;
    if (DateTime.now().isAfter(session.expiresAt)) {
      _pollTimer?.cancel();
      setState(() => _error = 'The authorization code expired.');
      return;
    }
    _polling = true;
    try {
      final credentials = await _client.pollCredentials(session);
      if (credentials == null) return;
      if (!mounted || generation != _generation) return;
      final tokens = await _client.exchangeDeviceCode(
        session: session,
        credentials: credentials,
      );
      if (!mounted || generation != _generation) return;
      final settingsController = ref.read(
        realDebridSettingsControllerProvider.notifier,
      );
      final valid = await settingsController.saveAndValidate(
        tokens.accessToken,
      );
      if (!mounted || generation != _generation) return;
      if (!valid) {
        final message = ref
            .read(realDebridSettingsControllerProvider)
            .errorMessage;
        throw StateError(message ?? 'Real-Debrid account validation failed.');
      }

      // Validation persists the access token. Add device-flow metadata only
      // after Premium access is confirmed so unusable credentials are never
      // treated as a connected streaming account.
      final storage = ref.read(secureStorageProvider);
      await storage.write(
        key: realDebridRefreshTokenStorageKey,
        value: tokens.refreshToken,
      );
      await storage.write(
        key: realDebridClientIdStorageKey,
        value: credentials.clientId,
      );
      await storage.write(
        key: realDebridClientSecretStorageKey,
        value: credentials.clientSecret,
      );
      await storage.write(
        key: realDebridTokenStorageKey,
        value: tokens.accessToken,
      );
      await storage.write(
        key: realDebridAccessExpiryStorageKey,
        value: tokens.expiresAt.toUtc().toIso8601String(),
      );
      if (!mounted || generation != _generation) return;
      _pollTimer?.cancel();
      setState(() => _authorized = true);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _pollTimer?.cancel();
      setState(() => _error = _friendlyError(error));
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
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            final compactHeader = viewport.maxWidth < 760;
            final horizontalPadding = viewport.maxWidth < 600 ? 16.0 : 42.0;
            final verticalPadding = viewport.maxHeight < 500 ? 12.0 : 28.0;
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      _BackButton(onPressed: context.pop),
                      SizedBox(width: compactHeader ? 12 : 18),
                      Flexible(
                        child: Text(
                          'Connect Real-Debrid',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      if (!compactHeader) ...[
                        const Spacer(),
                        Text(
                          'Your Real-Debrid password never touches this TV',
                          style: TextStyle(color: context.appPalette.mutedText),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: compactHeader ? 18 : 28),
                  Expanded(child: Center(child: _content(context))),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_authorized) {
      return _MessagePanel(
        icon: Icons.check_circle_rounded,
        color: const Color(0xFF67D49B),
        title: 'Real-Debrid connected',
        body: 'Premium status and streaming access are ready.',
        actionLabel: 'Done',
        onAction: context.pop,
      );
    }
    if (_error case final error?) {
      return _MessagePanel(
        icon: Icons.error_outline_rounded,
        color: const Color(0xFFFF929B),
        title: 'Could not connect',
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
      constraints: const BoxConstraints(maxWidth: 880),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final qrSize = compact ? 166.0 : 220.0;
          final qrData = session.verificationUrl.toString();
          final qr = CopyableQrInteraction(
            data: qrData,
            semanticsLabel: 'QR code for ${session.verificationUrl}',
            confirmationMessage: 'Real-Debrid pairing link copied.',
            child: Container(
              key: const ValueKey('real-debrid-qr-code'),
              width: qrSize,
              height: qrSize,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: qrData,
                semanticsLabel:
                    'Real-Debrid pairing link ${session.verificationUrl}',
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.Q,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
              ),
            ),
          );
          final code = _UserCode(code: session.userCode);

          if (compact) {
            // Put the human-readable code before the QR on narrow viewports.
            // A user can therefore complete pairing even when the lower part
            // of a short phone or split-screen window must be scrolled.
            return SingleChildScrollView(
              child: Column(
                children: [
                  const _WaitingPill(),
                  const SizedBox(height: 12),
                  Text(
                    'Enter this code',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  code,
                  const SizedBox(height: 12),
                  Text(
                    'Open ${session.verificationUrl} on your phone, or scan below.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  qr,
                  const SizedBox(height: 12),
                  Text(
                    'This screen updates automatically after approval.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            );
          }

          return Row(
            children: [
              qr,
              const SizedBox(width: 38),
              Expanded(
                child: Column(
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
                      'Open ${session.verificationUrl} and enter:',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 18),
                    code,
                    const SizedBox(height: 14),
                    Text(
                      'This screen updates automatically after approval.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _UserCode extends StatelessWidget {
  const _UserCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Real-Debrid confirmation code $code',
      readOnly: true,
      child: Container(
        key: const ValueKey('real-debrid-user-code'),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: context.appPalette.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.appPalette.accent.withValues(alpha: .7),
          ),
        ),
        child: Text(
          code,
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.appPalette.primaryText,
            fontSize: 32,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
          ),
        ),
      ),
    );
  }
}

String _friendlyError(Object error) {
  final text = error.toString().trim();
  return text
      .replaceFirst(RegExp(r'^(StateError|Bad state|FormatException):\s*'), '')
      .trim();
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

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
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
        _ActionButton(label: actionLabel, onPressed: onAction),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: true,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: context.appPalette.surface,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.arrow_back_rounded, size: 20),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: true,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: context.appPalette.accent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}
