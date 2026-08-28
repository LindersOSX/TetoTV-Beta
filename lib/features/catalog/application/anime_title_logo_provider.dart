import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final animeTitleLogoClientProvider = Provider<AnimeTitleLogoClient>(
  (_) => AnimeTitleLogoClient(),
);

typedef AnimeTitleLogoRequest = ({
  int aniListId,
  TitleLanguagePreference titleLanguage,
});

final animeTitleLogoProvider = FutureProvider.autoDispose
    .family<AnimeTitleLogo?, AnimeTitleLogoRequest>((ref, request) {
      final language = switch (request.titleLanguage) {
        TitleLanguagePreference.english => 'en',
        // Artwork services classify original-language logos as Japanese.
        // The surrounding text fallback remains the user's Romaji title.
        TitleLanguagePreference.romaji => 'ja',
      };
      return ref
          .watch(animeTitleLogoClientProvider)
          .lookup(request.aniListId, preferredLanguage: language);
    });
