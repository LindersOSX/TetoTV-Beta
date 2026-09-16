import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/catalogs/library_strings.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Set<String> slots(String text) => RegExp(
    r'\{([A-Za-z][A-Za-z0-9_]*)\}',
  ).allMatches(text).map((match) => match[1]!).toSet();

  test(
    'all library catalog messages have complete locale and placeholder coverage',
    () {
      final keys = libraryTranslations['es']!.keys.toSet();
      expect(keys.length, greaterThan(500));
      for (final code in ['es', 'pt', 'fr', 'hi', 'de']) {
        final messages = libraryTranslations[code]!;
        expect(messages.keys.toSet(), keys, reason: code);
        for (final entry in messages.entries) {
          expect(entry.value.trim(), isNotEmpty, reason: '$code: ${entry.key}');
          expect(
            slots(entry.value),
            slots(entry.key),
            reason: '$code: ${entry.key}',
          );
        }
      }
    },
  );

  test(
    'translated UI preserves provider names, codes, usernames and media titles',
    () {
      final ui = TetoLocalizations(AppLanguage.fromCode('es'));
      expect(
        ui.text('Connect {value1}', {'value1': 'TorBox'}),
        'Conectar TorBox',
      );
      expect(
        ui.text('TorBox one-time pairing code {value1}', {'value1': '483414'}),
        contains('483414'),
      );
      expect(
        ui.text('{value1} moved to {value2}.', {
          'value1': 'The Title {value2}',
          'value2': ui.text('Watching'),
        }),
        contains('The Title {value2}'),
      );
      expect(
        ui.text('{value1} • Episode {value2}', {
          'value1': 'Steins;Gate',
          'value2': 6,
        }),
        contains('Steins;Gate'),
      );
      expect(
        ui.text('A custom provider response'),
        'A custom provider response',
      );
    },
  );

  test(
    'reader and tracking enum labels localize without changing stored values',
    () {
      final labels = [
        ...MangaReadingMode.values.map((value) => value.displayName),
        ...MangaReadingDirection.values.map((value) => value.displayName),
        ...MangaSpreadMode.values.map((value) => value.displayName),
        ...MangaPageFit.values.map((value) => value.displayName),
        ...MangaReaderBackground.values.map((value) => value.displayName),
        ...MangaTapZoneLayout.values.map((value) => value.displayName),
        ...TrackingListStatus.values.map((value) => value.displayName),
        ...MyListSort.values.map((value) => value.displayName),
      ];
      final ui = TetoLocalizations(AppLanguage.fromCode('hi'));
      for (final label in labels) {
        expect(ui.text(label), isNot(label), reason: label);
      }
      expect(MangaReadingMode.paged.name, 'paged');
      expect(TrackingListStatus.planToWatch.name, 'planToWatch');
    },
  );

  test(
    'pairing recoverable errors and provider safety disclosures are translated',
    () {
      for (final code in ['es', 'pt', 'fr', 'hi', 'de']) {
        final ui = TetoLocalizations(AppLanguage.fromCode(code));
        for (final source in [
          'TorBox is temporarily unreachable. TetoTV will keep retrying this code.',
          'This page could not be decoded safely.',
          'The one-time Discord code expired. Create a new code.',
          'Manga repositories are always user-added, and installing an extension is a separate confirmation. TetoTV bundles, prefills, and recommends no source. Only use sources you trust and are authorized to access.',
        ]) {
          expect(ui.text(source), isNot(source), reason: '$code: $source');
        }
      }
    },
  );
}
