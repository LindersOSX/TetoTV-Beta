import 'dart:io';

import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../tool/audit_ui_localization.dart' as audit;

Widget _app(AppLanguage language, Widget child) => MaterialApp(
  locale: language.locale,
  theme: AppTheme.dark,
  supportedLocales: TetoLocalizations.supportedLocales,
  localizationsDelegates: const [
    TetoLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  home: Scaffold(body: child),
);

void main() {
  test('app-owned literal UI messages are wired and have translations', () {
    final result = audit.auditUiLocalizations();
    expect(
      result.missing,
      isEmpty,
      reason: 'Add missing messages in every language.',
    );
    expect(
      result.raw,
      isEmpty,
      reason:
          'Use LocalizedText/context.tr for app-authored text, not provider metadata.',
    );
  });
  test(
    'all catalogs have five complete languages and preserve placeholders',
    () {
      final placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');
      Set<String> names(String value) =>
          placeholder.allMatches(value).map((m) => m[1]!).toSet();
      for (final catalog in TetoLocalizations.catalogs) {
        expect(catalog.keys, unorderedEquals(['es', 'pt', 'fr', 'hi', 'de']));
        for (final locale in catalog.entries) {
          expect(locale.value.keys, unorderedEquals(catalog['es']!.keys));
          for (final message in locale.value.entries) {
            expect(
              message.value.trim(),
              isNotEmpty,
              reason: '${locale.key}: ${message.key}',
            );
            expect(
              names(message.value),
              names(message.key),
              reason: '${locale.key}: ${message.key}',
            );
          }
        }
      }
    },
  );

  test(
    'unknown locale falls back to English and regional locales normalize',
    () {
      expect(AppLanguage.fromCode('pt-BR'), AppLanguage.portuguese);
      expect(AppLanguage.fromCode('de_DE'), AppLanguage.german);
      expect(AppLanguage.fromCode('xx'), AppLanguage.english);
      const english = TetoLocalizations(AppLanguage.english);
      expect(
        english.text('Missing message {count}', {'count': 5}),
        'Missing message 5',
      );
    },
  );

  test('uppercase UI headings translate without altering IDs or arguments', () {
    const es = TetoLocalizations(AppLanguage.spanish);
    expect(es.text('SETTINGS'), es.text('Settings').toUpperCase());
    expect(
      es.text('Results for “{value1}”', {'value1': 'Home {value1} 日本語'}),
      contains('Home {value1} 日本語'),
    );
    expect(es.text('watch-party-session'), 'watch-party-session');
  });

  test(
    'Hindi font is bundled and licensed without replacing Latin typeface',
    () {
      expect(
        File('assets/fonts/NotoSansDevanagari.ttf').lengthSync(),
        greaterThan(100000),
      );
      expect(
        File('assets/fonts/NotoSansDevanagari-OFL.txt').readAsStringSync(),
        contains('Copyright 2022 The Noto Project Authors'),
      );
      expect(
        AppTheme.dark.textTheme.bodyMedium!.fontFamilyFallback,
        contains('TetoDevanagari'),
      );
    },
  );

  test('dates and plural rules use the selected locale', () async {
    await initializeDateFormatting();
    const fr = TetoLocalizations(AppLanguage.french);
    expect(fr.date(DateTime(2026, 9, 8)), contains('septembre'));
    expect(
      fr.date(DateTime.utc(2026, 8, 20, 2, 5), localTime: false),
      '20 août 2026',
      reason: 'GitHub calendar dates keep their original day when localized.',
    );
    expect(
      fr.plural(
        1,
        one: 'next episode in {count} day',
        other: 'next episode in {count} days',
      ),
      'prochain épisode dans 1 jour',
    );
    expect(
      fr.plural(
        5,
        one: 'next episode in {count} day',
        other: 'next episode in {count} days',
      ),
      'prochain épisode dans 5 jours',
    );
  });

  testWidgets(
    'const UI text changes live while provider metadata stays untouched',
    (tester) async {
      const body = Column(
        children: [
          LocalizedText('Home'),
          Text('Home', key: ValueKey('provider-title')),
        ],
      );
      await tester.pumpWidget(_app(AppLanguage.english, body));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsNWidgets(2));
      await tester.pumpWidget(_app(AppLanguage.spanish, body));
      await tester.pumpAndSettle();
      expect(find.text('Inicio'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
    },
  );

  for (final language in AppLanguage.values) {
    for (final numeric in [false, true]) {
      testWidgets(
        '${language.code} ${numeric ? "numeric" : "full"} TV keyboard fits and preserves input',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            _app(
              language,
              TvKeyboardDialog(
                title: numeric ? 'Episode number' : 'Search anime',
                initialValue: numeric ? '12' : 'Home 日本語',
                numericOnly: numeric,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(
              TetoLocalizations(
                language,
              ).text(numeric ? 'Episode number' : 'Search anime'),
            ),
            findsOneWidget,
          );
          expect(find.text(numeric ? '12' : 'Home 日本語'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
