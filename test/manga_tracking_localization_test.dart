import 'dart:io';

import 'package:anime_tv/core/localization/catalogs/manga_tracking_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'tracking catalog covers five languages with exact placeholder parity',
    () {
      expect(
        mangaTrackingTranslations.keys,
        unorderedEquals(['es', 'pt', 'fr', 'hi', 'de']),
      );
      final reference = mangaTrackingTranslations['es']!;
      expect(reference.length, greaterThanOrEqualTo(50));
      final placeholder = RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}');
      Set<String> parameters(String value) =>
          placeholder.allMatches(value).map((match) => match.group(0)!).toSet();
      for (final language in mangaTrackingTranslations.entries) {
        expect(language.value.keys, unorderedEquals(reference.keys));
        for (final message in language.value.entries) {
          expect(
            message.value.trim(),
            isNotEmpty,
            reason: '${language.key}: ${message.key}',
          );
          expect(
            message.value,
            isNot(message.key),
            reason: '${language.key}: ${message.key}',
          );
          expect(
            parameters(message.value),
            parameters(message.key),
            reason: '${language.key}: ${message.key}',
          );
        }
      }
    },
  );

  test(
    'all friendly tracking client/controller/storage errors are translated',
    () {
      final exception = RegExp(
        r"MangaTrackingException\(\s*'([^']+)'",
        multiLine: true,
      );
      final keys = <String>{};
      for (final path in [
        'lib/features/manga/application/manga_tracking_controller.dart',
        'lib/features/manga/data/manga_tracking_client.dart',
        'lib/features/manga/data/manga_tracking_state_store.dart',
      ]) {
        keys.addAll(
          exception
              .allMatches(File(path).readAsStringSync())
              .map((match) => match.group(1)!),
        );
      }
      expect(keys.length, greaterThanOrEqualTo(16));
      for (final language in mangaTrackingTranslations.values) {
        for (final key in keys) {
          expect(language, contains(key), reason: key);
        }
      }
    },
  );

  test(
    'tracking dynamic labels and all seven download recovery messages are translated',
    () {
      const required = [
        'Needs attention',
        'Retry scheduled',
        'Manga tracking could not be updated. Try again.',
        'Manga linked. Future completed chapters can sync.',
        'Manga unlinked. Your tracker list entry was not removed.',
        'Manga tracking is up to date.',
        'Progress remains queued. Check the account or wait for the next retry.',
        'The manga download queue is full. Wait for downloads to finish.',
        'Reconnect to the manga source before resuming this download.',
        'This manga source is unavailable. Reconnect to it and try again.',
        'Reconnect to the manga source to retry this download.',
        'Manga pages could not be saved. Free device storage and resume the download.',
        'The manga download is paused. Resume it when you are ready.',
        'Manga download storage is full. Delete downloaded chapters and try again.',
      ];
      for (final language in mangaTrackingTranslations.values) {
        for (final key in required) {
          expect(language, contains(key), reason: key);
        }
      }
    },
  );
}
