import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/presentation/setup_brand_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Keeps the router's content unmounted until the first-run language decision.
/// Returning users bypass this screen without changing audio or CC preferences.
class LanguageSelectionGate extends ConsumerWidget {
  const LanguageSelectionGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(settingsPreferencesProvider);
    if (!preferences.loaded) {
      return const ColoredBox(
        color: Color(0xFF07090D),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!preferences.languageChoiceCompleted) {
      return const LanguageSelectionScreen();
    }
    return child;
  }
}

class LanguageSelectionScreen extends ConsumerStatefulWidget {
  const LanguageSelectionScreen({this.onLanguageSelected, super.key});

  /// Setup may revisit this step without resetting the persisted language gate.
  final VoidCallback? onLanguageSelected;

  @override
  ConsumerState<LanguageSelectionScreen> createState() =>
      _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState
    extends ConsumerState<LanguageSelectionScreen> {
  bool _saving = false;
  final _languageFocusNodes = [
    for (final language in AppLanguage.values)
      FocusNode(debugLabel: 'setup.language.${language.code}'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final language = ref.read(settingsPreferencesProvider).interfaceLanguage;
      _languageFocusNodes[language.index].requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _languageFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleDirection(int index, int columns, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final target = switch (key) {
      LogicalKeyboardKey.arrowUp => index - columns,
      LogicalKeyboardKey.arrowDown => index + columns,
      LogicalKeyboardKey.arrowLeft => index % columns > 0 ? index - 1 : index,
      LogicalKeyboardKey.arrowRight =>
        index % columns < columns - 1 ? index + 1 : index,
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    if (!_saving && target >= 0 && target < _languageFocusNodes.length) {
      _languageFocusNodes[target].requestFocus();
    }
    return KeyEventResult.handled;
  }

  Future<void> _choose(AppLanguage language) async {
    if (_saving) return;
    setState(() => _saving = true);
    // Mark setup started before language/media preferences are written. The
    // legacy setup migration otherwise sees those keys as an existing install.
    await ref.read(setupProgressProvider.notifier).start();
    if (!mounted) return;
    await ref
        .read(settingsPreferencesProvider.notifier)
        .setInterfaceLanguage(language);
    if (mounted) {
      setState(() => _saving = false);
      widget.onLanguageSelected?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      key: const ValueKey('first-launch-language-screen'),
      backgroundColor: palette.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final padding = context.responsiveScreenPadding;
            final wide =
                constraints.maxWidth >= 700 &&
                constraints.maxWidth > constraints.maxHeight;
            final compact = wide && constraints.maxHeight < 620;
            final columns = wide ? 2 : 1;
            final gap = compact ? 10.0 : 14.0;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(.62, -.86),
                  radius: 1.35,
                  colors: [
                    palette.accent.withValues(alpha: .16),
                    palette.background,
                    palette.background,
                  ],
                  stops: const [0, .46, 1],
                ),
              ),
              child: SingleChildScrollView(
                padding: padding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - padding.vertical).clamp(
                      0.0,
                      double.infinity,
                    ),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SetupBrandHeader(showStatus: wide),
                          SizedBox(height: compact ? 14 : 28),
                          LocalizedText(
                            'Choose your language',
                            textAlign: wide ? TextAlign.left : TextAlign.center,
                            style: Theme.of(context).textTheme.displaySmall
                                ?.copyWith(
                                  fontSize: compact
                                      ? 32
                                      : wide
                                      ? 38
                                      : 30,
                                  height: 1.08,
                                ),
                          ),
                          const SizedBox(height: 10),
                          LocalizedText(
                            'This sets the app language and preferred audio and captions. You can change them separately later.',
                            textAlign: wide ? TextAlign.left : TextAlign.center,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  fontSize: compact ? 14 : 15,
                                  color: palette.mutedText,
                                  height: 1.4,
                                ),
                          ),
                          SizedBox(height: compact ? 18 : 24),
                          for (
                            var row = 0;
                            row < (AppLanguage.values.length / columns).ceil();
                            row++
                          ) ...[
                            if (row > 0) SizedBox(height: gap),
                            Row(
                              children: [
                                for (
                                  var column = 0;
                                  column < columns;
                                  column++
                                ) ...[
                                  if (column > 0) SizedBox(width: gap),
                                  Expanded(
                                    child: _LanguageChoiceCard(
                                      language: AppLanguage
                                          .values[row * columns + column],
                                      focusNode:
                                          _languageFocusNodes[row * columns +
                                              column],
                                      compact: compact,
                                      enabled: !_saving,
                                      onPressed: () => _choose(
                                        AppLanguage.values[row * columns +
                                            column],
                                      ),
                                      onKeyEvent: (_, event) =>
                                          _handleDirection(
                                            row * columns + column,
                                            columns,
                                            event,
                                          ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LanguageChoiceCard extends StatelessWidget {
  const _LanguageChoiceCard({
    required this.language,
    required this.focusNode,
    required this.compact,
    required this.enabled,
    required this.onPressed,
    required this.onKeyEvent,
  });

  final AppLanguage language;
  final FocusNode focusNode;
  final bool compact;
  final bool enabled;
  final VoidCallback onPressed;
  final FocusOnKeyEventCallback onKeyEvent;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final radius = BorderRadius.circular(18);
    return TvFocusable(
      key: ValueKey('choose-language-${language.code}'),
      focusNode: focusNode,
      enabled: enabled,
      focusScale: 1.012,
      borderRadius: radius,
      onPressed: onPressed,
      onKeyEvent: onKeyEvent,
      onFocusChanged: (focused) {
        if (focused && focusNode.context != null) {
          Scrollable.ensureVisible(
            focusNode.context!,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        }
      },
      child: Container(
        constraints: BoxConstraints(minHeight: compact ? 64 : 76),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 20,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: .96),
          borderRadius: radius,
          border: Border.all(color: palette.primaryText.withValues(alpha: .1)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.selectableSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: palette.accent.withValues(alpha: .42),
                ),
              ),
              child: Text(
                language.code.toUpperCase(),
                style: TextStyle(
                  color: palette.accentBright,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .5,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                language.nativeName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: compact ? 21 : 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_rounded,
              color: palette.accentBright,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}
