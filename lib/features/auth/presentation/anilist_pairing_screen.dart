import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/application/tracking_sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

class TrackingPairingScreen extends ConsumerStatefulWidget {
  const TrackingPairingScreen({required this.provider, super.key});

  final TrackingProvider provider;

  @override
  ConsumerState<TrackingPairingScreen> createState() =>
      _TrackingPairingScreenState();
}

class _TrackingPairingScreenState extends ConsumerState<TrackingPairingScreen> {
  late final TextEditingController _brokerController;
  String? _brokerError;
  bool _editingBroker = false;

  @override
  void initState() {
    super.initState();
    _brokerController = TextEditingController();
    Future.microtask(_loadConfigurationAndStart);
  }

  Future<void> _loadConfigurationAndStart() async {
    final storage = ref.read(secureStorageProvider);
    final saved = await storage.read(key: authBrokerUrlStorageKey);
    final effective = await effectiveAuthBrokerBaseUrl(storage);
    if (!mounted) return;
    _brokerController.text = saved ?? effective ?? '';
    await ref.read(pairingControllerProvider(widget.provider).notifier).start();
  }

  Future<void> _saveBrokerAndStart() async {
    final normalized = normalizeAuthBrokerBaseUrl(_brokerController.text);
    if (normalized == null) {
      setState(() {
        _brokerError =
            'Enter the public HTTPS URL where the TetoTV broker is deployed.';
      });
      return;
    }
    await ref
        .read(secureStorageProvider)
        .write(key: authBrokerUrlStorageKey, value: normalized);
    if (!mounted) return;
    setState(() {
      _brokerController.text = normalized;
      _brokerError = null;
      _editingBroker = false;
    });
    await ref.read(pairingControllerProvider(widget.provider).notifier).start();
  }

  @override
  void dispose() {
    _brokerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = pairingControllerProvider(widget.provider);
    ref.listen(provider, (previous, next) {
      final previousStatus = previous?.valueOrNull?.status;
      final nextStatus = next.valueOrNull?.status;
      if (nextStatus == PairingStatus.authorized &&
          previousStatus != PairingStatus.authorized) {
        ref.invalidate(trackingAccountsControllerProvider);
        ref.invalidate(trackingHomeProvider);
        ref.invalidate(trackingOutboxFlushProvider);
      }
    });
    final pairing = ref.watch(provider);

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
                _TrackingHeader(
                  compact: narrow,
                  provider: widget.provider,
                  onBack: context.pop,
                ),
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
                        child: Center(
                          child: pairing.when(
                            loading: () => const CircularProgressIndicator(),
                            error: (error, _) {
                              if (error is AuthBrokerNotConfigured ||
                                  _editingBroker) {
                                return _BrokerSetupPanel(
                                  controller: _brokerController,
                                  error: _brokerError,
                                  onSave: _saveBrokerAndStart,
                                );
                              }
                              return _ErrorPanel(
                                message: error.toString(),
                                onRetry: () => ref
                                    .read(
                                      pairingControllerProvider(
                                        widget.provider,
                                      ).notifier,
                                    )
                                    .start(),
                                onConfigure: () =>
                                    setState(() => _editingBroker = true),
                              );
                            },
                            data: (session) {
                              if (session == null) {
                                return const SizedBox.shrink();
                              }
                              return _PairingPanel(
                                provider: widget.provider,
                                session: session,
                                onRestart: () => ref
                                    .read(
                                      pairingControllerProvider(
                                        widget.provider,
                                      ).notifier,
                                    )
                                    .start(),
                              );
                            },
                          ),
                        ),
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
}

class _TrackingHeader extends StatelessWidget {
  const _TrackingHeader({
    required this.compact,
    required this.provider,
    required this.onBack,
  });

  final bool compact;
  final TrackingProvider provider;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final leading = Row(
      children: [
        _BackButton(onPressed: onBack),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            'Connect ${provider.displayName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
      ],
    );
    final note = Text(
      'No password is entered on this TV',
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

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({
    required this.provider,
    required this.session,
    required this.onRestart,
  });

  final TrackingProvider provider;
  final PairingSession session;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final verificationUri = Uri.tryParse(session.verificationUri);
    final malCallback = verificationUri
        ?.replace(
          path: '/oauth/myanimelist/callback',
          query: null,
          fragment: null,
        )
        .toString();
    if (session.status == PairingStatus.authorized) {
      return _StatusPanel(
        icon: Icons.check_circle_rounded,
        title: '${provider.displayName} connected',
        body: 'Your token is encrypted in the Android Keystore.',
        color: const Color(0xFF67D49B),
      );
    }
    if (session.status == PairingStatus.expired) {
      return _StatusPanel(
        icon: Icons.timer_off_rounded,
        title: 'Code expired',
        body: 'Generate a fresh code and try again.',
        actionLabel: 'New code',
        onAction: onRestart,
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          final qrSize = compact ? 190.0 : 220.0;
          final qr = CopyableQrInteraction(
            data: session.verificationUriComplete,
            semanticsLabel: 'QR code for anime tracker pairing',
            confirmationMessage: 'Tracker pairing link copied.',
            child: Container(
              width: qrSize,
              height: qrSize,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: session.verificationUriComplete,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.Q,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _WaitingPill(),
              const SizedBox(height: 18),
              Text(
                'Scan with your phone',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Open ${session.verificationUri} and confirm the code:',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 18),
              Text(
                session.userCode,
                style: TextStyle(
                  color: context.appPalette.primaryText,
                  fontSize: compact ? 28 : 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: compact ? 3 : 4,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'This screen updates automatically after approval.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (provider == TrackingProvider.myAnimeList) ...[
                const SizedBox(height: 10),
                Text(
                  'Registered callback: '
                  '${malCallback ?? 'your broker /oauth/myanimelist/callback'}',
                  style: TextStyle(
                    color: context.appPalette.mutedText,
                    fontSize: 11,
                  ),
                ),
              ],
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

class _WaitingPill extends StatelessWidget {
  const _WaitingPill();

  @override
  Widget build(BuildContext context) {
    return _Pill(
      icon: Icons.sync_rounded,
      text: 'WAITING FOR APPROVAL',
      color: context.appPalette.secondaryAccent,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Text(
            text,
            style: TextStyle(
              color: color,
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

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.body,
    this.color,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color? color;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final panelColor = color ?? context.appPalette.accentBright;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 72, color: panelColor),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: 10),
        Text(
          body,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              _ActionButton(label: actionLabel!, onPressed: onAction!),
              if (secondaryActionLabel != null && onSecondaryAction != null)
                _ActionButton(
                  label: secondaryActionLabel!,
                  onPressed: onSecondaryAction!,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.message,
    required this.onRetry,
    required this.onConfigure,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return _StatusPanel(
      icon: Icons.error_outline_rounded,
      title: 'Could not start pairing',
      body: message,
      color: const Color(0xFFFF8892),
      actionLabel: 'Retry',
      onAction: onRetry,
      secondaryActionLabel: 'Change broker URL',
      onSecondaryAction: onConfigure,
    );
  }
}

class _BrokerSetupPanel extends StatelessWidget {
  const _BrokerSetupPanel({
    required this.controller,
    required this.error,
    required this.onSave,
  });

  final TextEditingController controller;
  final String? error;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860),
      child: LayoutBuilder(
        builder: (context, constraints) => Container(
          width: constraints.maxWidth,
          padding: EdgeInsets.all(constraints.maxWidth < 600 ? 20 : 30),
          decoration: BoxDecoration(
            color: context.appPalette.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: .10)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Pill(
                icon: Icons.dns_rounded,
                text: 'ONE-TIME QR SETUP',
                color: context.appPalette.secondaryAccent,
              ),
              const SizedBox(height: 16),
              Text(
                'Connect the TetoTV sign-in broker',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Text(
                'AniList and MAL do not provide a native TV device-code '
                'login. Deploy the included broker with your registered OAuth '
                'clients, then enter its public address here. Provider secrets '
                'stay on the server and never enter the APK.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 18),
              TvTextInput(
                controller: controller,
                labelText: 'HTTPS broker URL',
                hintText: 'https://auth.your-domain.example',
                keyboardTitle: 'Enter TetoTV broker URL',
                autofillSuggestions: const ['https://'],
              ),
              if (error case final message?) ...[
                const SizedBox(height: 10),
                Text(message, style: const TextStyle(color: Color(0xFFFF929B))),
              ],
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: _ActionButton(
                  label: 'Save and connect',
                  onPressed: onSave,
                ),
              ),
            ],
          ),
        ),
      ),
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
