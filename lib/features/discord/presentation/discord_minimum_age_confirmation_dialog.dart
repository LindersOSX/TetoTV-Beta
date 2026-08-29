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
      title: const Text('Discord age requirement'),
      content: const Text(
        'I confirm I meet Discord\'s minimum age of at least 13, or the older minimum required where I live.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('discord-age-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('discord-age-confirm'),
          autofocus: true,
          onPressed: () => Navigator.of(
            context,
          ).pop(const DiscordMinimumAgeConfirmation.current()),
          child: const Text('I meet the requirement'),
        ),
      ],
    ),
  );
}
