import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:anime_tv/features/marketplace/application/source_pairing_controller.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

Future<void> showSourcePairingDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const SourcePairingDialog(),
);

class SourcePairingDialog extends ConsumerStatefulWidget {
  const SourcePairingDialog({super.key});

  @override
  ConsumerState<SourcePairingDialog> createState() =>
      _SourcePairingDialogState();
}

class _SourcePairingDialogState extends ConsumerState<SourcePairingDialog>
    with WidgetsBindingObserver {
  late final SourcePairingController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ref.read(sourcePairingControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller.start());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Mobile users may briefly switch to a browser to paste URLs. Android
      // suspends periodic timers in the background, so poll immediately when
      // they return instead of cancelling their one-time session.
      unawaited(_controller.pollNow());
      return;
    }
    if (state == AppLifecycleState.detached) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Avoid mutating Riverpod state while Flutter is finalizing this route.
    // PopScope handles ordinary closes; this remains a best-effort safety net
    // for ancestor/lifecycle teardown.
    unawaited(Future<void>.microtask(_controller.stop));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sourcePairingControllerProvider);
    final saving = state.stage == SourcePairingStage.validating;
    return PopScope(
      canPop: !saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _controller.stop();
      },
      child: Dialog(
        backgroundColor: context.appPalette.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.phone_android_rounded,
                      color: context.appPalette.accentBright,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Add sources with phone',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Flexible(child: _SourcePairingBody(state: state)),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: switch (state.stage) {
                    SourcePairingStage.failed when state.canRetryImport =>
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: _controller.retryImport,
                        icon: const Icon(Icons.save_rounded),
                        label: const Text('RETRY SAVE'),
                      ),
                    _ when state.canRetryAcknowledgement => FilledButton.icon(
                      autofocus: true,
                      onPressed: _controller.retryAcknowledgement,
                      icon: const Icon(Icons.sync_rounded),
                      label: const Text('RETRY PHONE CONFIRMATION'),
                    ),
                    SourcePairingStage.failed ||
                    SourcePairingStage.expired => FilledButton.icon(
                      autofocus: true,
                      onPressed: _controller.start,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('NEW CODE'),
                    ),
                    SourcePairingStage.completed => FilledButton(
                      autofocus: true,
                      onPressed: () => Navigator.pop(context),
                      child: const Text('DONE'),
                    ),
                    SourcePairingStage.validating => const TextButton(
                      onPressed: null,
                      child: Text('SAVING…'),
                    ),
                    _ => TextButton(
                      autofocus: true,
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CANCEL'),
                    ),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourcePairingBody extends StatelessWidget {
  const _SourcePairingBody({required this.state});

  final SourcePairingState state;

  @override
  Widget build(BuildContext context) => switch (state.stage) {
    SourcePairingStage.starting => _CenteredStatus(
      busy: true,
      title: 'Creating a private one-time code…',
      body:
          state.message ??
          'Keep this screen open while TetoTV creates the secure phone link.',
    ),
    SourcePairingStage.waiting => _WaitingForSources(session: state.session!),
    SourcePairingStage.validating => _CenteredStatus(
      busy: true,
      title: 'Sources received',
      body: state.message ?? 'Validating public HTTPS destinations on this TV…',
    ),
    SourcePairingStage.completed => _CompletionStatus(
      state: state,
      successful: true,
    ),
    SourcePairingStage.failed => _CompletionStatus(
      state: state,
      successful: false,
    ),
    SourcePairingStage.expired => _CenteredStatus(
      title: 'Code expired',
      body: state.message ?? 'Create a new one-time code and try again.',
    ),
    SourcePairingStage.stopped => const _CenteredStatus(
      title: 'Pairing stopped',
      body: 'Close this window and start again when you are ready.',
    ),
    SourcePairingStage.idle => const SizedBox.shrink(),
  };
}

class _WaitingForSources extends StatelessWidget {
  const _WaitingForSources({required this.session});

  final SourcePairingSession session;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 650;
        final qrSize = compact ? 150.0 : 220.0;
        final qrData = session.verificationUriComplete.toString();
        final qr = CopyableQrInteraction(
          data: qrData,
          semanticsLabel: 'QR code for source pairing',
          confirmationMessage: 'Source pairing link copied.',
          child: Container(
            width: qrSize,
            height: qrSize,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: qrData,
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
            Text(
              'Scan the QR code',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              'Or open ${session.verificationUri} and enter:',
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 14),
            SelectableText(
              session.userCode,
              style: TextStyle(
                color: context.appPalette.accentBright,
                fontSize: 30,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Paste Marketplace repository and Torrent source manifest URLs on your phone. This device validates every destination before saving it.',
              textAlign: TextAlign.start,
              style: TextStyle(color: context.appPalette.mutedText),
            ),
          ],
        );
        return SingleChildScrollView(
          child: compact
              ? Column(children: [qr, const SizedBox(height: 18), instructions])
              : Row(
                  children: [
                    qr,
                    const SizedBox(width: 30),
                    Expanded(child: instructions),
                  ],
                ),
        );
      },
    );
  }
}

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({
    required this.title,
    required this.body,
    this.busy = false,
  });

  final String title;
  final String body;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          CircularProgressIndicator(color: context.appPalette.accentBright)
        else
          const Icon(Icons.timer_off_rounded, size: 58),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(body, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _CompletionStatus extends StatelessWidget {
  const _CompletionStatus({required this.state, required this.successful});

  final SourcePairingState state;
  final bool successful;

  @override
  Widget build(BuildContext context) {
    final errors = state.summary?.errors ?? const <String>[];
    return SingleChildScrollView(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              successful ? Icons.check_circle_rounded : Icons.error_rounded,
              size: 62,
              color: successful
                  ? const Color(0xFF67D49B)
                  : context.appPalette.accent,
            ),
            const SizedBox(height: 16),
            Text(
              successful ? 'Sources added' : 'Sources were not added',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(state.message ?? 'Try again with a new one-time code.'),
            for (final error in errors.take(3)) ...[
              const SizedBox(height: 7),
              Text(
                error,
                style: TextStyle(color: context.appPalette.mutedText),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
