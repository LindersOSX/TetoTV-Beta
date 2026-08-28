import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/settings/application/phone_setup_pairing_controller.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

const phoneSetupRoutePath = '/setup/phone';

class PhoneSetupScreen extends ConsumerStatefulWidget {
  const PhoneSetupScreen({super.key});

  static const routePath = phoneSetupRoutePath;

  @override
  ConsumerState<PhoneSetupScreen> createState() => _PhoneSetupScreenState();
}

class _PhoneSetupScreenState extends ConsumerState<PhoneSetupScreen> {
  final _regenerateFocusNode = FocusNode(debugLabel: 'phone-setup.regenerate');
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      ref.read(phoneSetupPairingControllerProvider.notifier).startOrResume,
    );
  }

  Future<void> _goBack() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    if (!mounted) return;
    context.go('/setup/start?focus=phone');
  }

  Future<void> _useDeviceSetup() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await ref.read(phoneSetupPairingControllerProvider.notifier).cancel();
    if (mounted) {
      context.pushReplacement('/setup?from=method-choice');
    }
  }

  @override
  void dispose() {
    _regenerateFocusNode.dispose();
    super.dispose();
  }

  Future<void> _openSetupPage(Uri uri) async {
    try {
      final opened = await AndroidTvBridge.instance.openExternalWebPage(uri);
      if (opened || !mounted) return;
    } catch (_) {
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No browser could open the secure setup page.'),
        duration: Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final state = ref.watch(phoneSetupPairingControllerProvider);
    ref.listen(phoneSetupPairingControllerProvider, (previous, next) {
      if (next.stage == PhoneSetupViewStage.completed &&
          previous?.stage != PhoneSetupViewStage.completed) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });
    return Scaffold(
      key: const ValueKey('phone-setup-screen'),
      backgroundColor: palette.background,
      body: SafeArea(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(.72, -.92),
              radius: 1.3,
              colors: [
                palette.accent.withValues(alpha: .16),
                palette.background,
                palette.background,
              ],
              stops: const [0, .46, 1],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 820;
              return SingleChildScrollView(
                padding: context.responsiveScreenPadding,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1160),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Header(onBack: _goBack),
                        const SizedBox(height: 22),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 9,
                                child: _ConnectionCard(
                                  state: state,
                                  onOpenSetupPage: _openSetupPage,
                                ),
                              ),
                              const SizedBox(width: 22),
                              Expanded(
                                flex: 10,
                                child: _StatusCard(
                                  state: state,
                                  onUseDeviceSetup: _useDeviceSetup,
                                  regenerateFocusNode: _regenerateFocusNode,
                                ),
                              ),
                            ],
                          )
                        else ...[
                          _ConnectionCard(
                            state: state,
                            onOpenSetupPage: _openSetupPage,
                          ),
                          const SizedBox(height: 18),
                          _StatusCard(
                            state: state,
                            onUseDeviceSetup: _useDeviceSetup,
                            regenerateFocusNode: _regenerateFocusNode,
                          ),
                        ],
                        const SizedBox(height: 18),
                        const _SecurityNotice(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton.filledTonal(
          key: const ValueKey('phone-setup-back'),
          autofocus: true,
          tooltip: 'Back',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set up with phone',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'One secure setup for accounts, Discord, sources, debrid, and preferences',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: palette.mutedText),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.state, required this.onOpenSetupPage});

  final PhoneSetupViewState state;
  final Future<void> Function(Uri uri) onOpenSetupPage;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final session = state.session;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: _cardDecoration(palette),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'CONNECT YOUR PHONE',
            style: TextStyle(
              color: palette.accentBright,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: .8,
            ),
          ),
          const SizedBox(height: 14),
          if (session == null)
            SizedBox(
              height: 258,
              child: Center(
                child: state.stage == PhoneSetupViewStage.failed
                    ? Icon(
                        Icons.phonelink_erase_rounded,
                        size: 72,
                        color: palette.mutedText,
                      )
                    : CircularProgressIndicator(color: palette.accentBright),
              ),
            )
          else ...[
            Center(
              child: Container(
                width: 236,
                height: 236,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: QrImageView(
                  data: session.verificationUriComplete.toString(),
                  backgroundColor: Colors.white,
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
            ),
            const SizedBox(height: 18),
            SelectableText(
              session.userCode,
              key: const ValueKey('phone-setup-user-code'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              session.verificationUri.toString(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.mutedText),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () =>
                  unawaited(onOpenSetupPage(session.verificationUriComplete)),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open secure setup page'),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: palette.selectableSurface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  const Text(
                    'MATCH THIS ON BOTH SCREENS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .7,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    session.confirmationCode,
                    style: TextStyle(
                      color: palette.accentBright,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends ConsumerWidget {
  const _StatusCard({
    required this.state,
    required this.onUseDeviceSetup,
    required this.regenerateFocusNode,
  });

  final PhoneSetupViewState state;
  final Future<void> Function() onUseDeviceSetup;
  final FocusNode regenerateFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.appPalette;
    final controller = ref.read(phoneSetupPairingControllerProvider.notifier);
    final discord = ref.watch(discordPresenceControllerProvider);
    final shouldConnectDiscord = state.linkDiscordRequested && !discord.linked;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: _cardDecoration(palette),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _stageIcon(state.stage),
                color: palette.accentBright,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _stageTitle(state.stage),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              if (state.isBusy)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: palette.accentBright,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            state.message ?? 'Preparing secure phone setup…',
            style: TextStyle(color: palette.mutedText, height: 1.4),
          ),
          const SizedBox(height: 20),
          if (state.stage == PhoneSetupViewStage.review && state.bundle != null)
            _BundlePreview(bundle: state.bundle!)
          else if (state.stage == PhoneSetupViewStage.completed)
            _CompletionSummary(state: state, discordLinked: discord.linked)
          else
            const _SetupSteps(),
          const SizedBox(height: 22),
          if (state.stage == PhoneSetupViewStage.review) ...[
            OutlinedButton.icon(
              onPressed: state.isBusy ? null : controller.rejectReviewedSetup,
              icon: const Icon(Icons.edit_rounded),
              label: const Text('Edit on phone'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('phone-setup-apply'),
              onPressed: state.isBusy ? null : controller.applyReviewedSetup,
              icon: const Icon(Icons.verified_user_rounded),
              label: const Text('Apply setup'),
            ),
          ] else if (state.stage == PhoneSetupViewStage.completed) ...[
            if (shouldConnectDiscord) ...[
              FilledButton.icon(
                key: const ValueKey('phone-setup-connect-discord'),
                autofocus: true,
                onPressed: () => context.push('/pair/discord'),
                icon: const Icon(Icons.forum_rounded),
                label: const Text('Connect Discord'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('phone-setup-finish'),
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.home_rounded),
                label: const Text('Start TetoTV'),
              ),
            ] else
              FilledButton.icon(
                key: const ValueKey('phone-setup-finish'),
                autofocus: true,
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.home_rounded),
                label: const Text('Start TetoTV'),
              ),
          ] else if (state.canRetry) ...[
            FilledButton.icon(
              key: const ValueKey('phone-setup-regenerate'),
              focusNode: regenerateFocusNode,
              onPressed: state.isBusy ? null : controller.regenerate,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Regenerate code'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onUseDeviceSetup,
              icon: const Icon(Icons.tv_rounded),
              label: const Text('Set up on this device instead'),
            ),
          ] else ...[
            OutlinedButton.icon(
              onPressed: state.isBusy ? null : controller.pollNow,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Check now'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('phone-setup-regenerate'),
              focusNode: regenerateFocusNode,
              onPressed: state.isBusy ? null : controller.regenerate,
              icon: const Icon(Icons.autorenew_rounded),
              label: const Text('Regenerate code'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: state.isBusy ? null : onUseDeviceSetup,
              icon: const Icon(Icons.tv_rounded),
              label: const Text('Use on-device setup instead'),
            ),
          ],
        ],
      ),
    );
  }
}

class _BundlePreview extends StatelessWidget {
  const _BundlePreview({required this.bundle});

  final PhoneSetupBundle bundle;

  @override
  Widget build(BuildContext context) {
    final trackingProvider =
        bundle.preferences.trackingProvider ??
        bundle.credentials.tracking?.provider;
    final debridProvider =
        bundle.preferences.debridProvider ??
        bundle.credentials.debrid?.provider;
    final entries = <(IconData, String, String)>[
      (
        Icons.tune_rounded,
        'Preferences',
        '${bundle.preferences.choiceCount} selected',
      ),
      (
        Icons.extension_rounded,
        'Marketplace repositories',
        '${bundle.repositoryUrls.length}',
      ),
      (
        Icons.cloud_download_rounded,
        'Torrent manifests',
        '${bundle.manifestUrls.length}',
      ),
      if (trackingProvider case final provider?)
        (Icons.checklist_rounded, 'Anime tracking', _trackingName(provider)),
      if (debridProvider case final provider?)
        (Icons.shield_rounded, 'Debrid service', _debridName(provider)),
      if (bundle.credentials.discord != null)
        (Icons.forum_rounded, 'Discord', 'Authorized securely')
      else if (bundle.preferences.linkDiscord case final requested?)
        (
          Icons.forum_rounded,
          'Discord',
          requested ? 'Connect after setup' : 'Skip',
        ),
    ];
    return Column(
      children: [
        for (final entry in entries) ...[
          _PreviewRow(icon: entry.$1, label: entry.$2, value: entry.$3),
          const SizedBox(height: 9),
        ],
        const SizedBox(height: 4),
        Text(
          'Account credentials are end-to-end encrypted and intentionally hidden from this preview. Linked services use their official authorization pages; passwords are never included.',
          style: TextStyle(
            color: context.appPalette.mutedText,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.selectableSurface,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(icon, size: 21, color: palette.accentBright),
          const SizedBox(width: 11),
          Expanded(child: Text(label)),
          const SizedBox(width: 10),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _CompletionSummary extends StatelessWidget {
  const _CompletionSummary({required this.state, required this.discordLinked});

  final PhoneSetupViewState state;
  final bool discordLinked;

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _DoneLine(label: 'Encrypted setup verified'),
        const _DoneLine(label: 'Preferences saved'),
        if (result?.trackerConnected == true)
          const _DoneLine(label: 'Anime tracking connected'),
        if (result?.debridConnected == true)
          const _DoneLine(label: 'Debrid service connected'),
        if (result?.discordConnected == true)
          const _DoneLine(label: 'Discord connected'),
        if (state.linkDiscordRequested && discordLinked)
          const _DoneLine(label: 'Discord connected'),
        if ((result?.repositoriesAdded ?? 0) + (result?.manifestsAdded ?? 0) >
            0)
          _DoneLine(
            label:
                '${(result?.repositoriesAdded ?? 0) + (result?.manifestsAdded ?? 0)} sources added',
          ),
      ],
    );
  }
}

class _DoneLine extends StatelessWidget {
  const _DoneLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Icon(
          Icons.check_circle_rounded,
          color: const Color(0xFF62D99C),
          size: 21,
        ),
        const SizedBox(width: 10),
        Text(label),
      ],
    ),
  );
}

class _SetupSteps extends StatelessWidget {
  const _SetupSteps();

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      _Step(number: '1', text: 'Scan the QR code or open the secure page'),
      _Step(number: '2', text: 'Choose accounts, sources, and preferences'),
      _Step(number: '3', text: 'Return here and approve the private preview'),
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.selectableSurface,
              shape: BoxShape.circle,
              border: Border.all(color: palette.accent.withValues(alpha: .5)),
            ),
            child: Text(
              number,
              style: TextStyle(
                color: palette.accentBright,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _SecurityNotice extends StatelessWidget {
  const _SecurityNotice();

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.selectableSurface.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.primaryText.withValues(alpha: .08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_rounded, color: palette.accentBright),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Protected with end-to-end encryption. You sign in only on each service\'s official page; TetoTV never asks for passwords. The setup companion holds the resulting credentials only temporarily, then your browser encrypts them for this device. Credentials never appear in the QR code, URL, browser draft storage, logs, or diagnostics. After your phone connects, the page can be minimized and reopened without losing the setup draft.',
              style: TextStyle(color: palette.mutedText, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

BoxDecoration _cardDecoration(AppThemePalette palette) => BoxDecoration(
  color: palette.surface.withValues(alpha: .96),
  borderRadius: BorderRadius.circular(22),
  border: Border.all(color: palette.primaryText.withValues(alpha: .1)),
  boxShadow: [
    BoxShadow(
      color: palette.accent.withValues(alpha: .06),
      blurRadius: 24,
      spreadRadius: 1,
    ),
  ],
);

IconData _stageIcon(PhoneSetupViewStage stage) => switch (stage) {
  PhoneSetupViewStage.idle ||
  PhoneSetupViewStage.starting => Icons.phonelink_lock_rounded,
  PhoneSetupViewStage.waiting => Icons.qr_code_rounded,
  PhoneSetupViewStage.bound => Icons.phone_android_rounded,
  PhoneSetupViewStage.review => Icons.fact_check_rounded,
  PhoneSetupViewStage.applying => Icons.security_rounded,
  PhoneSetupViewStage.completed => Icons.verified_rounded,
  PhoneSetupViewStage.expired => Icons.timer_off_rounded,
  PhoneSetupViewStage.failed => Icons.error_outline_rounded,
};

String _stageTitle(PhoneSetupViewStage stage) => switch (stage) {
  PhoneSetupViewStage.idle ||
  PhoneSetupViewStage.starting => 'Creating a secure session',
  PhoneSetupViewStage.waiting => 'Waiting for your phone',
  PhoneSetupViewStage.bound => 'Phone connected',
  PhoneSetupViewStage.review => 'Review before applying',
  PhoneSetupViewStage.applying => 'Applying securely',
  PhoneSetupViewStage.completed => 'Setup complete',
  PhoneSetupViewStage.expired => 'Code expired',
  PhoneSetupViewStage.failed => 'Setup unavailable',
};

String _trackingName(String value) => switch (value) {
  'anilist' => 'AniList',
  'myanimelist' => 'MyAnimeList',
  _ => 'Selected account',
};

String _debridName(String value) => switch (value) {
  'realdebrid' => 'Real-Debrid',
  'torbox' => 'TorBox',
  'alldebrid' => 'AllDebrid',
  'premiumize' => 'Premiumize',
  _ => 'Selected service',
};
