import 'package:anime_tv/core/localization/catalogs/manga_reader_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'manga reader catalog covers all five languages with matching placeholders',
    () {
      expect(
        mangaReaderTranslations.keys,
        unorderedEquals(['es', 'pt', 'fr', 'hi', 'de']),
      );
      final reference = mangaReaderTranslations['es']!;
      final placeholder = RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}');
      Set<String> parameters(String value) =>
          placeholder.allMatches(value).map((match) => match.group(0)!).toSet();
      expect(reference.length, greaterThanOrEqualTo(70));
      for (final language in mangaReaderTranslations.entries) {
        expect(language.value.keys, unorderedEquals(reference.keys));
        for (final translation in language.value.entries) {
          expect(
            translation.value.trim(),
            isNotEmpty,
            reason: '${language.key}: ${translation.key}',
          );
          expect(
            parameters(translation.value),
            parameters(translation.key),
            reason: '${language.key}: ${translation.key}',
          );
        }
      }
    },
  );

  test(
    'reader catalog includes safe fetch errors and nonliteral chapter labels',
    () {
      const required = [
        'The manga source rejected its access credential.',
        'The manga source refused this page request.',
        'The manga source is temporarily limiting requests. Try again shortly.',
        'This manga page is no longer available from the source.',
        'This chapter could not be opened. Your current page is unchanged. Check the source and try again.',
        'Reading status could not be loaded. Retry before using progress filters or batch downloads.',
        'Profile changed. Close and reopen this manga.',
        'Already read',
        'Unread',
        'Mark read',
        'Mark unread',
        'Bookmark',
        'Remove bookmark',
        'Download next 5 unread',
        'Download next 10 unread',
        'Ascending',
        'Descending',
        'Manga page {page}',
        'Page {page} of {total}',
      ];
      for (final language in mangaReaderTranslations.values) {
        for (final key in required) {
          expect(language, contains(key), reason: key);
        }
      }
    },
  );
}
