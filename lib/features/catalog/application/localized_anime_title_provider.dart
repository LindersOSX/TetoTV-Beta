import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/localized_anime_title_client.dart';

final localizedAnimeTitleClientProvider = Provider<LocalizedAnimeTitleClient>((
  ref,
) {
  final client = LocalizedAnimeTitleClient();
  ref.onDispose(client.dispose);
  return client;
});

typedef LocalizedAnimeTitleRequest = ({int aniListId, String language});

final localizedAnimeTitleProvider = FutureProvider.autoDispose
    .family<String?, LocalizedAnimeTitleRequest>((ref, request) async {
      if (request.language == 'en' || request.aniListId <= 0) return null;
      // Do not start work for cards that only flash past during TV navigation.
      final cancel = CancelToken();
      ref.onDispose(cancel.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (cancel.isCancelled) return null;
      return ref
          .read(localizedAnimeTitleClientProvider)
          .lookup(request.aniListId, request.language, cancelToken: cancel);
    });
