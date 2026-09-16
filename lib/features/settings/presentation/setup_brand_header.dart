import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// The same branding and first-run badge across language and setup choices.
class SetupBrandHeader extends StatelessWidget {
  const SetupBrandHeader({required this.showStatus, super.key});

  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
          child: Image.asset(
            'assets/branding/tetotv_icon.png',
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'TetoTV',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
        ),
        if (showStatus)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: .78),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: palette.primaryText.withValues(alpha: .1),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune_rounded, size: 17, color: palette.accentBright),
                const SizedBox(width: 7),
                LocalizedText(
                  'FIRST-RUN SETUP',
                  style: TextStyle(
                    color: palette.primaryText,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
