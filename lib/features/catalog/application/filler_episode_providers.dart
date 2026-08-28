import 'package:anime_tv/features/catalog/data/jikan_filler_episode_repository.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final fillerEpisodeRepositoryProvider = Provider<FillerEpisodeRepository>(
  (_) => JikanFillerEpisodeRepository(),
);
