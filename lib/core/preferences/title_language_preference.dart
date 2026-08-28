enum TitleLanguagePreference { english, romaji }

extension TitleLanguagePreferenceLabel on TitleLanguagePreference {
  String get displayName => switch (this) {
    TitleLanguagePreference.english => 'English',
    TitleLanguagePreference.romaji => 'Romaji',
  };

  String get storageValue => name;
}

String preferredAnimeTitle({
  required TitleLanguagePreference preference,
  required String fallback,
  String? english,
  String? romaji,
}) {
  final preferred = switch (preference) {
    TitleLanguagePreference.english => english,
    TitleLanguagePreference.romaji => romaji,
  };
  final secondary = switch (preference) {
    TitleLanguagePreference.english => romaji,
    TitleLanguagePreference.romaji => english,
  };
  for (final value in [preferred, secondary, fallback]) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return 'Untitled';
}
