import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/settings/application/premiumize_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Premiumize supports OAuth device authorization only for registered OAuth
/// clients. TetoTV therefore uses Premiumize's official API-key flow here and
/// validates the key with `account/info` before it is saved.
class PremiumizePairingScreen extends ConsumerStatefulWidget {
  const PremiumizePairingScreen({super.key});

  @override
  ConsumerState<PremiumizePairingScreen> createState() =>
      _PremiumizePairingScreenState();
}

class _PremiumizePairingScreenState
    extends ConsumerState<PremiumizePairingScreen> {
  final _tokenController = TextEditingController();
  final _tokenFocus = FocusNode(debugLabel: 'premiumize.api-key');
  bool _connected = false;

  @override
  void dispose() {
    _tokenController.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final saved = await ref
        .read(premiumizeSettingsControllerProvider.notifier)
        .saveAndValidate(_tokenController.text);
    if (!mounted || !saved) return;
    _tokenController.clear();
    setState(() => _connected = true);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(premiumizeSettingsControllerProvider);
    return Scaffold(
      body: SafeArea(
        minimum: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        child: Column(
          children: [
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
                  'Connect Premiumize',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Center(
                child: _connected
                    ? _connectedMessage(context)
                    : SingleChildScrollView(child: _form(context, state)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectedMessage(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(
        Icons.check_circle_rounded,
        size: 72,
        color: Color(0xFF67D49B),
      ),
      const SizedBox(height: 18),
      Text(
        'Premiumize connected',
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 10),
      const Text('Your API key is encrypted in the Android Keystore.'),
      const SizedBox(height: 24),
      _ActionButton(
        autofocus: true,
        icon: Icons.check_rounded,
        label: 'Done',
        onPressed: context.pop,
      ),
    ],
  );

  Widget _form(BuildContext context, PremiumizeSettingsState state) =>
      Container(
        constraints: const BoxConstraints(maxWidth: 720),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: context.appPalette.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Use your Premiumize API key',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              'Open premiumize.me/account on your phone, copy the API key, '
              'then enter or paste it below. The key is sent only as a secure '
              'Bearer header for validation.',
              style: TextStyle(color: context.appPalette.mutedText),
            ),
            const SizedBox(height: 22),
            TvTextInput(
              controller: _tokenController,
              focusNode: _tokenFocus,
              labelText: 'Premiumize API key',
              hintText: state.hasSavedToken
                  ? 'Enter a replacement key'
                  : 'Enter API key',
              keyboardTitle: 'Enter Premiumize API key',
              obscureText: true,
              onSubmitted: (_) => _connect(),
            ),
            if (state.errorMessage case final message?) ...[
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Color(0xFFFF929B))),
            ],
            const SizedBox(height: 18),
            _ActionButton(
              icon: Icons.lock_rounded,
              label: state.isLoading ? 'Validating…' : 'Connect securely',
              onPressed: state.isLoading ? () {} : _connect,
            ),
          ],
        ),
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
