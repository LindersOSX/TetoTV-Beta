import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/episode_airing_availability.dart';
import 'package:flutter/widgets.dart';

/// Keep the domain's conservative availability checks. Only presentation is
/// localized; missing or stale provider dates never become a guessed schedule.
String? localizedNextEpisodeCountdown(
  BuildContext context,
  AnimeSummary anime, {
  DateTime? now,
}) {
  final reference = now ?? DateTime.now();
  final fallback = nextEpisodeAiringCountdownLabel(
    anime: anime,
    now: reference,
  );
  if (fallback == null) return null;
  final localizations = TetoLocalizations.of(context);
  final minutes = anime.nextAiringAt!.difference(reference).inMinutes;
  if (minutes < 60) return context.tr('next episode in less than an hour');
  if (minutes < Duration.minutesPerDay) {
    return localizations.plural(
      (minutes / 60).ceil(),
      one: 'next episode in {count} hour',
      other: 'next episode in {count} hours',
    );
  }
  return localizations.plural(
    (minutes / Duration.minutesPerDay).ceil(),
    one: 'next episode in {count} day',
    other: 'next episode in {count} days',
  );
}
