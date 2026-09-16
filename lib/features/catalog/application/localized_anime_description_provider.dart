import 'package:anime_tv/features/catalog/data/localized_anime_description_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localizedAnimeDescriptionClientProvider =
    Provider<LocalizedAnimeDescriptionClient>((ref) {
      final client = LocalizedAnimeDescriptionClient();
      ref.onDispose(client.dispose);
      return client;
    });

typedef LocalizedAnimeDescriptionRequest = ({int aniListId, String language});

final localizedAnimeDescriptionProvider = FutureProvider.autoDispose
    .family<String?, LocalizedAnimeDescriptionRequest>((ref, request) async {
      if (request.language == 'en' || request.aniListId <= 0) return null;
      final cancel = CancelToken();
      ref.onDispose(cancel.cancel);
      return ref
          .read(localizedAnimeDescriptionClientProvider)
          .lookup(request.aniListId, request.language, cancelToken: cancel);
    });
