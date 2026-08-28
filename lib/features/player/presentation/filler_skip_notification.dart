import 'package:anime_tv/features/player/application/filler_episode_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final fillerUnavailableNotifiedSeriesProvider = StateProvider<Set<int>>(
  (_) => const <int>{},
);

bool consumeFillerUnavailableNotice(
  StateController<Set<int>> controller,
  int anilistMediaId,
) {
  final notified = controller.state;
  if (notified.contains(anilistMediaId)) return false;
  controller.state = {...notified, anilistMediaId};
  return true;
}

void showFillerDataUnavailableNotice(
  BuildContext context, {
  required int episode,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        'Filler data is unavailable. Playing Episode $episode normally.',
      ),
    ),
  );
}

Future<void> showFillerSkipNotification(
  BuildContext context,
  FillerEpisodeNavigationDecision decision,
) {
  if (!decision.skippedAny) return Future.value();
  final skipped = fillerEpisodeListLabel(decision.skippedEpisodes);
  final nextEpisode = decision.episode;
  final message = nextEpisode != null
      ? 'Skipped filler $skipped. Playing Episode $nextEpisode.'
      : '$skipped ${decision.skippedEpisodes.length == 1 ? 'is' : 'are'} marked as filler. There are no later non-filler episodes available.';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(duration: const Duration(seconds: 5), content: Text(message)),
  );
  // The notice is intentionally fire-and-forget: autoplay navigation must
  // never wait for remote-control interaction or a display timeout.
  return Future.value();
}
