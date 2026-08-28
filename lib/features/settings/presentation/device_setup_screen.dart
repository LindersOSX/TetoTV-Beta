import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/device_setup_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class DeviceSetupScreen extends ConsumerStatefulWidget {
  const DeviceSetupScreen({super.key});

  @override
  ConsumerState<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends ConsumerState<DeviceSetupScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(deviceSetupProvider.notifier).scan());
    });
  }

  Future<void> _finish() async {
    await ref.read(deviceSetupProvider.notifier).markCompleted();
    if (mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceSetupProvider);
    return Scaffold(
      backgroundColor: context.appPalette.background,
      body: SafeArea(
        minimum: context.responsiveScreenPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _CalibrationButton(
                  icon: Icons.arrow_back_rounded,
                  label: 'Back',
                  autofocus: true,
                  onPressed: context.pop,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Device calibration',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(
                        'TetoTV scans Android’s decoders, display, audio output, and subtitle engine.',
                        style: TextStyle(color: context.appPalette.mutedText),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: state.loading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: context.appPalette.accentBright,
                      ),
                    )
                  : state.error != null
                  ? _CalibrationError(
                      message: state.error!,
                      onRetry: () =>
                          ref.read(deviceSetupProvider.notifier).scan(),
                    )
                  : state.report == null
                  ? const SizedBox.shrink()
                  : _CalibrationReportView(report: state.report!),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _CalibrationButton(
                  icon: Icons.refresh_rounded,
                  label: 'Scan again',
                  onPressed: () =>
                      ref.read(deviceSetupProvider.notifier).scan(),
                ),
                const SizedBox(width: 10),
                _CalibrationButton(
                  icon: Icons.check_rounded,
                  label: 'Save recommendation',
                  primary: true,
                  onPressed: state.report == null ? null : _finish,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CalibrationReportView extends StatelessWidget {
  const _CalibrationReportView({required this.report});

  final DeviceCalibrationReport report;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.appPalette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: .08)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.devices_other_rounded,
                color: context.appPalette.accentBright,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${report.profile.manufacturer} ${report.profile.model}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      'Android ${report.profile.sdk} • ${report.profile.abis.join(', ')}',
                      style: TextStyle(color: context.appPalette.mutedText),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 900
                ? 3
                : constraints.maxWidth >= 560
                ? 2
                : 1;
            final width =
                (constraints.maxWidth - ((columns - 1) * 10)) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final check in report.checks)
                  SizedBox(
                    width: width,
                    child: _CapabilityCard(check: check),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF19070B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: context.appPalette.accent.withValues(alpha: .7),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                color: context.appPalette.secondaryAccent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  report.recommendation,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.check});

  final CapabilityCheck check;

  @override
  Widget build(BuildContext context) => Container(
    height: 94,
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: context.appPalette.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: check.supported
            ? const Color(0xFF2F8D63).withValues(alpha: .7)
            : Colors.white.withValues(alpha: .08),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          check.supported
              ? Icons.check_circle_rounded
              : Icons.info_outline_rounded,
          color: check.supported
              ? const Color(0xFF5FE0A2)
              : context.appPalette.mutedText,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                check.label,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                check.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.appPalette.mutedText,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _CalibrationError extends StatelessWidget {
  const _CalibrationError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.error_outline_rounded,
          color: context.appPalette.accentBright,
        ),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        _CalibrationButton(
          icon: Icons.refresh_rounded,
          label: 'Try again',
          onPressed: onRetry,
        ),
      ],
    ),
  );
}

class _CalibrationButton extends StatelessWidget {
  const _CalibrationButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: onPressed == null,
    child: Opacity(
      opacity: onPressed == null ? .45 : 1,
      child: TvFocusable(
        autofocus: autofocus,
        onPressed: onPressed ?? () {},
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: primary
                ? context.appPalette.accent
                : context.appPalette.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: .1)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19),
              const SizedBox(width: 7),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
      ),
    ),
  );
}
