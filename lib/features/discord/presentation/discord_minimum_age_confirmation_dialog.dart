import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/features/discord/domain/discord_minimum_age_confirmation.dart';
import 'package:flutter/material.dart';

/// Requests the only eligibility fact TetoTV retains for Discord linking.
/// No birth date, age, or location is collected.
Future<DiscordMinimumAgeConfirmation?> showDiscordMinimumAgeConfirmationDialog(
  BuildContext context,
) {
  return showDialog<DiscordMinimumAgeConfirmation>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(context.tr("Discord age requirement")),
      content: Text(
        context.tr(
          "I confirm I meet Discord's minimum age of at least 13, or the older minimum required where I live.",
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('discord-age-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr("Cancel")),
        ),
        FilledButton(
          key: const ValueKey('discord-age-confirm'),
          autofocus: true,
          onPressed: () => Navigator.of(
            context,
          ).pop(const DiscordMinimumAgeConfirmation.current()),
          child: Text(context.tr("I meet the requirement")),
        ),
      ],
    ),
  );
}
