import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/legal/bundled_licenses.dart';
import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/aniyomi/application/aniyomi_controller.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_repository_client.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:anime_tv/features/aniyomi/presentation/aniyomi_screen.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('APK license registry exposes the pinned Ani runtime notices', () async {
    registerBundledThirdPartyLicenses();
    final byPackage = <String, String>{};
    await for (final entry in LicenseRegistry.licenses) {
      final text = entry.paragraphs
          .map((paragraph) => paragraph.text)
          .join('\n');
      for (final package in entry.packages) {
        byPackage[package] = text;
      }
    }
    const expectedNotices = {
      'TetoTV experimental Aniyomi runtime provenance':
          '39e9a749590b89b432f04b83725aaa12591371b2',
      'Aniyomi source API v0.18.1.2 (39e9a749)': 'Apache License',
      'Injekt core and API 1.16.1': 'Jayson Minard',
      'Mihon Injekt registry patch 91edab2317': 'MIT License',
      'RxJava 1.3.8': 'Copyright 2012 Netflix, Inc.',
      'Jsoup 1.19.1': 'Jonathan Hedley',
      'OkHttp 5.4.0': 'Apache License',
      'Okio 3.17.0': 'Apache License',
      'Cash App QuickJS Android 0.9.2 wrapper': 'Apache License',
      'Cash App QuickJS Android 0.9.2 embedded QuickJS engine':
          'Fabrice Bellard',
      'Kotlin coroutines 1.10.1': 'JetBrains',
      'Kotlin serialization 1.9.0': 'JetBrains',
      'AndroidX Preference and Preference KTX 1.2.1': 'Apache License',
      'Android apksig 9.0.1': 'Apache License',
    };
    for (final entry in expectedNotices.entries) {
      expect(byPackage[entry.key], contains(entry.value), reason: entry.key);
    }
    expect(byPackage['RxJava 1.3.8'], contains('Apache License'));
    expect(byPackage['RxJava 1.3.8'], isNot(contains('LESSER GENERAL')));
    final sources = await rootBundle.loadString(
      'assets/legal/aniyomi/LICENSE_SOURCES.json',
    );
    expect(sources, contains('7e3879abfb32eeebb38c970195a7f1e354eb1f82'));
    expect(sources, contains('injekt-api/1.16.1/injekt-api-1.16.1.pom'));
  });

  testWidgets(
    'gate is closed while loading or disabled and opens only when loaded and enabled',
    (tester) async {
      final harness = _Harness(
        update: const AppUpdateState(loaded: false, developerMode: true),
      );
      await harness.pump(tester);
      expect(find.byType(AniyomiScreen), findsNothing);
      expect(harness.controllerBuilds, 0);
      harness.update.replace(
        const AppUpdateState(loaded: true, developerMode: false),
      );
      await tester.pump();
      expect(find.byType(AniyomiScreen), findsNothing);
      expect(harness.controllerBuilds, 0);
      harness.update.replace(
        const AppUpdateState(loaded: true, developerMode: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Aniyomi • Experimental'), findsOneWidget);
      expect(harness.controllerBuilds, 1);
      harness.update.replace(
        const AppUpdateState(loaded: true, developerMode: false),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AniyomiScreen), findsNothing);
      expect(
        find.text('Aniyomi experiments require Developer Mode.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'TV remote opens repository input and submits only explicit confirmation',
    (tester) async {
      final harness = _Harness();
      await harness.pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _transition(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(harness.controller.added, isEmpty);
      final input = tester.widget<TvTextInput>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TvTextInput),
        ),
      );
      input.controller.text = '  https://catalog.example.test/index.json  ';
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Add repository'));
      await tester.pumpAndSettle();
      expect(harness.controller.added, [
        (AniyomiMediaKind.anime, 'https://catalog.example.test/index.json'),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Manga opt-out hides Manga creation execution and browse actions',
    (tester) async {
      final harness = _Harness(
        mangaEnabled: false,
        state: AniyomiState(
          available: true,
          repositories: [
            AniyomiRepositoryEntry(
              Uri.parse('https://anime.catalog.example.test/index.json'),
              AniyomiMediaKind.anime,
            ),
            AniyomiRepositoryEntry(
              Uri.parse('https://manga.catalog.example.test/index.json'),
              AniyomiMediaKind.manga,
            ),
          ],
          catalog: [
            _extension(0),
            _extension(1, kind: AniyomiMediaKind.manga),
          ],
          approved: const [
            {
              'extensionId': 'anime-installed',
              'packageName': 'org.example.anime',
              'kind': 'anime',
            },
            {
              'extensionId': 'manga-installed',
              'packageName': 'org.example.manga',
              'kind': 'manga',
            },
          ],
          sources: const [_mangaSource],
        ),
      );
      await harness.pump(tester);

      expect(find.text('Add anime repository'), findsOneWidget);
      expect(find.text('Add manga repository'), findsNothing);
      await _show(tester, find.text('Fixture extension 0 • en • 1.0'));
      expect(find.text('Fixture extension 0 • en • 1.0'), findsOneWidget);
      expect(find.text('Fixture extension 1 • en • 1.0'), findsNothing);
      expect(find.text('Fixture manga source • en'), findsNothing);
      expect(find.text('Browse'), findsNothing);
      await _show(tester, find.text('org.example.manga'));
      expect(find.text('org.example.manga'), findsOneWidget);
      expect(find.text('Manga is disabled in Settings.'), findsOneWidget);
      await _show(
        tester,
        find.text('manga • manga.catalog.example.test • Remove'),
      );
      expect(
        find.text('manga • manga.catalog.example.test • Remove'),
        findsOneWidget,
      );
      await _show(tester, find.text('Retry source discovery'));
      expect(
        find.text('Retry source discovery'),
        findsOneWidget,
        reason: 'Only the installed anime extension remains executable.',
      );
      expect(harness.gateway.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an open Aniyomi Manga browser closes on Manga opt-out', (
    tester,
  ) async {
    final harness = _Harness(
      state: const AniyomiState(available: true, sources: [_mangaSource]),
    );
    await harness.pump(tester);
    await _tapVisible(tester, find.text('Fixture manga source • en'));
    await tester.pumpAndSettle();
    expect(find.text('Search manga'), findsOneWidget);

    harness.settings.replace(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Search manga'), findsNothing);
    expect(find.text('Manga is disabled in Settings.'), findsOneWidget);
    expect(harness.gateway.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed discovery is visibly installed and has an explicit narrow-layout retry',
    (tester) async {
      final harness = _Harness(
        state: const AniyomiState(
          available: true,
          approved: [
            {
              'extensionId': 'fixture',
              'packageName': 'first.party.fixture',
              'kind': 'anime',
            },
          ],
          readiness: {
            'fixture': AniyomiReadiness(
              AniyomiReadinessStage.failed,
              failure: AniyomiFailure(
                'unsupported_extension_abi',
                stage: 'source_construct',
                cause: 'method_missing',
              ),
            ),
          },
        ),
      );
      await harness.pump(tester, size: const Size(360, 640));
      await _show(tester, find.text('Installed • source discovery failed'));
      expect(find.text('Installed • source discovery failed'), findsOneWidget);
      expect(find.textContaining('source_construct'), findsOneWidget);
      await _tapVisible(tester, find.text('Retry source discovery'));
      await tester.pumpAndSettle();
      expect(harness.controller.retried, ['fixture']);
      expect(find.text('Ready • 1 source'), findsOneWidget);
      expect(find.text('Retry source discovery'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'verified first-party fixture requires trust dialog before approval',
    (tester) async {
      final harness = _Harness(
        state: AniyomiState(available: true, catalog: [_extension(0)]),
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Fixture extension 0 • en • 1.0'));
      await _transition(tester);
      expect(harness.controller.inspected, ['test.fixture.extension0']);
      expect(harness.controller.approved, isEmpty);
      expect(find.text('Trust this experimental extension?'), findsOneWidget);
      expect(find.text('Verified signer (SHA-256)'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        _fingerprint,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Trust and install'));
      await tester.pumpAndSettle();
      expect(harness.controller.approved, ['fixture-inspection']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('canceling trust never approves executable code', (tester) async {
    final harness = _Harness(
      state: AniyomiState(available: true, catalog: [_extension(0)]),
    );
    await harness.pump(tester);
    await _tapVisible(tester, find.text('Fixture extension 0 • en • 1.0'));
    await _transition(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(harness.controller.approved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disabling Developer Mode invalidates a pending trust confirmation',
    (tester) async {
      final harness = _Harness(
        state: AniyomiState(available: true, catalog: [_extension(0)]),
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Fixture extension 0 • en • 1.0'));
      await _transition(tester);
      expect(find.text('Trust this experimental extension?'), findsOneWidget);
      harness.update.replace(
        const AppUpdateState(loaded: true, developerMode: false),
      );
      await tester.pump();
      expect(find.byType(AniyomiScreen), findsNothing);
      // A dialog route can outlive its caller, but it must never authorize work.
      if (find
          .widgetWithText(FilledButton, 'Trust and install')
          .evaluate()
          .isNotEmpty) {
        await tester.tap(
          find.widgetWithText(FilledButton, 'Trust and install'),
        );
      }
      await tester.pumpAndSettle();
      expect(harness.controller.approved, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inspection finishing after gate closes cannot open trust or approve',
    (tester) async {
      final inspection = Completer<Map<String, dynamic>>();
      final harness = _Harness(
        state: AniyomiState(available: true, catalog: [_extension(0)]),
        inspection: inspection.future,
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Fixture extension 0 • en • 1.0'));
      await tester.pump();
      harness.update.replace(
        const AppUpdateState(loaded: true, developerMode: false),
      );
      await tester.pump();
      inspection.complete(_descriptor);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(harness.controller.approved, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Manga opt-out invalidates a pending Manga extension inspection',
    (tester) async {
      final inspection = Completer<Map<String, dynamic>>();
      final harness = _Harness(
        state: AniyomiState(
          available: true,
          catalog: [_extension(0, kind: AniyomiMediaKind.manga)],
        ),
        inspection: inspection.future,
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Fixture extension 0 • en • 1.0'));
      await tester.pump();
      harness.settings.replace(
        const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
      );
      await tester.pump();
      inspection.complete(_descriptor);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(harness.controller.approved, isEmpty);
      expect(find.text('Fixture extension 0 • en • 1.0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final viewport in [const Size(1280, 720), const Size(360, 640)]) {
    testWidgets(
      'German UI and trust dialog fit ${viewport.width.toInt()}x${viewport.height.toInt()}',
      (tester) async {
        final harness = _Harness(
          state: AniyomiState(available: true, catalog: [_extension(0)]),
        );
        await harness.pump(
          tester,
          size: viewport,
          language: AppLanguage.german,
        );
        expect(tester.takeException(), isNull);
        await _tapVisible(tester, find.text('Fixture extension 0 • en • 1.0'));
        await _transition(tester);
        expect(
          find.text('Dieser experimentellen Erweiterung vertrauen?'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'catalog pages at 100 entries and search resets to first matching page',
    (tester) async {
      final harness = _Harness(
        state: AniyomiState(
          available: true,
          catalog: List.generate(101, _extension),
        ),
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Next'));
      await tester.pumpAndSettle();
      await _show(tester, find.text('Fixture extension 100 • en • 1.0'));
      expect(find.text('Fixture extension 100 • en • 1.0'), findsOneWidget);
      expect(find.text('Fixture extension 99 • en • 1.0'), findsNothing);
      await _show(tester, find.byType(TvTextInput));
      tester.widget<TvTextInput>(find.byType(TvTextInput)).controller.text =
          'Fixture extension 0';
      await tester.pumpAndSettle();
      await _show(tester, find.text('Fixture extension 0 • en • 1.0'));
      expect(find.text('Fixture extension 0 • en • 1.0'), findsOneWidget);
      expect(find.text('Previous'), findsNothing);
      expect(harness.controller.inspected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV language picker supports remote selection and search together',
    (tester) async {
      final harness = _Harness(
        state: AniyomiState(
          available: true,
          catalog: [
            _extension(0),
            _extension(1, language: 'es'),
            _extension(2, language: 'all', sourceLanguages: ['en', 'es']),
          ],
          approved: const [
            {
              'extensionId': 'installed',
              'packageName': 'test.installed.extension',
              'kind': 'anime',
            },
          ],
        ),
      );
      await harness.pump(tester);
      final originalPreferences = harness.settings.state;
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-language-filter')),
      );
      await tester.pumpAndSettle();
      expect(find.text('All languages'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Español'), findsOneWidget);
      expect(find.text('Multilingual'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.text('Language: English'), findsOneWidget);
      await _show(tester, find.text('Fixture extension 0 • en • 1.0'));
      expect(find.text('Fixture extension 1 • es • 1.0'), findsNothing);
      expect(find.text('Fixture extension 2 • all • 1.0'), findsOneWidget);

      tester.widget<TvTextInput>(find.byType(TvTextInput)).controller.text =
          'Fixture extension 2';
      await tester.pumpAndSettle();
      expect(find.text('Fixture extension 0 • en • 1.0'), findsNothing);
      expect(find.text('Fixture extension 2 • all • 1.0'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-clear-filters')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Language: All languages'), findsOneWidget);
      await _show(tester, find.text('Fixture extension 1 • es • 1.0'));
      expect(find.text('Fixture extension 1 • es • 1.0'), findsOneWidget);
      expect(harness.controller.inspected, isEmpty);
      expect(harness.controller.approved, isEmpty);
      expect(harness.gateway.requests, isEmpty);
      expect(
        harness.controller.state.approved.single['extensionId'],
        'installed',
      );
      expect(identical(harness.settings.state, originalPreferences), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing language resets page and gives recoverable empty results',
    (tester) async {
      final harness = _Harness(
        state: AniyomiState(
          available: true,
          catalog: [
            ...List.generate(101, _extension),
            _extension(102, language: 'pt-BR'),
          ],
        ),
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Next'));
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-language-filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('aniyomi-language-option-pt')),
      );
      await tester.pumpAndSettle();
      await _show(tester, find.text('Fixture extension 102 • pt-BR • 1.0'));
      expect(find.text('Previous'), findsNothing);
      expect(find.text('Next'), findsNothing);
      tester.widget<TvTextInput>(find.byType(TvTextInput)).controller.text =
          'missing';
      await tester.pumpAndSettle();
      expect(find.text('No extensions match this filter'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-clear-filters')),
      );
      await tester.pumpAndSettle();
      await _show(tester, find.text('Fixture extension 0 • en • 1.0'));
      expect(find.text('Fixture extension 0 • en • 1.0'), findsOneWidget);
      expect(find.text('Previous'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone language picker uses autonyms and hides disabled manga', (
    tester,
  ) async {
    final harness = _Harness(
      isTelevision: false,
      mangaEnabled: false,
      state: AniyomiState(
        available: true,
        catalog: [
          _extension(0),
          _extension(1, language: 'es'),
          _extension(2, language: 'pt-BR'),
          _extension(3, language: 'ja', kind: AniyomiMediaKind.manga),
        ],
      ),
    );
    await harness.pump(
      tester,
      size: const Size(360, 640),
      language: AppLanguage.spanish,
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('aniyomi-language-filter')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Filtrar idioma de las extensiones'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Español'), findsOneWidget);
    expect(find.text('Português'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('aniyomi-language-option-ja')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('aniyomi-language-option-es')));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Fixture extension 1 • es • 1.0'));
    expect(find.text('Idioma: Español'), findsOneWidget);
    expect(find.text('Fixture extension 0 • en • 1.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removed catalog language stays clearable and cancel keeps selection',
    (tester) async {
      final harness = _Harness(
        state: AniyomiState(
          available: true,
          catalog: [
            _extension(0),
            _extension(1, language: 'es'),
          ],
        ),
      );
      await harness.pump(tester);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-language-filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('aniyomi-language-option-es')),
      );
      await tester.pumpAndSettle();
      harness.controller.replaceCatalog([_extension(0)]);
      await tester.pumpAndSettle();
      expect(find.text('No extensions match this filter'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-language-filter')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Español'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.text('Language: Español'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('aniyomi-clear-filters')),
      );
      await tester.pumpAndSettle();
      await _show(tester, find.text('Fixture extension 0 • en • 1.0'));
      expect(find.text('Fixture extension 0 • en • 1.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manga search pages request source pages and chapter pages stay local',
    (tester) async {
      final harness = _Harness(
        state: const AniyomiState(available: true, sources: [_mangaSource]),
      );
      await harness.pump(tester);
      await _tapVisible(tester, find.text('Fixture manga source • en'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.text('Manga result page 1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('aniyomi-manga-search-cover')),
        findsOneWidget,
      );
      await _tapVisible(tester, find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Manga result page 2'), findsOneWidget);
      expect(harness.gateway.requests.map((r) => r['page']).toList(), [1, 2]);
      await _tapVisible(tester, find.text('Manga result page 2'));
      await tester.pumpAndSettle();
      await _show(tester, find.text('Chapter 1'));
      expect(find.text('Chapter 1'), findsOneWidget);
      await _tapVisible(tester, find.text('Next'));
      await tester.pumpAndSettle();
      await _show(tester, find.text('Chapter 101'));
      expect(find.text('Chapter 101'), findsOneWidget);
      expect(harness.gateway.requests.map((r) => r['operation']).toList(), [
        'search',
        'search',
        'details',
        'chapters',
      ]);
      expect(
        harness.gateway.requests.last['url'],
        '/title/canonical',
        reason: 'Chapter loading must use the canonical details locator.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _transition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      450,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pump();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
}

const _fingerprint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _descriptor = <String, dynamic>{
  'inspectionId': 'fixture-inspection',
  'certificateSha256': _fingerprint,
};
const _mangaSource = AniyomiRuntimeSource(
  extensionId: 'fixture',
  id: '42',
  name: 'Fixture manga source',
  kind: AniyomiMediaKind.manga,
  language: 'en',
);

AniyomiRepositoryExtension _extension(
  int index, {
  AniyomiMediaKind kind = AniyomiMediaKind.anime,
  String language = 'en',
  List<String> sourceLanguages = const [],
}) => AniyomiRepositoryExtension(
  kind: kind,
  packageName: 'test.fixture.extension$index',
  name: 'Fixture extension $index',
  versionName: '1.0',
  versionCode: 1,
  extensionLib: '14',
  apkUri: Uri.parse('https://catalog.example.test/fixture$index.apk'),
  iconUri: Uri.parse('https://catalog.example.test/icon.png'),
  language: language,
  isNsfw: false,
  isTorrent: false,
  sources: [
    for (var i = 0; i < sourceLanguages.length; i++)
      AniyomiRepositorySource(
        kind: kind,
        id: '$i',
        name: 'Fixture source $i',
        language: sourceLanguages[i],
      ),
  ],
);

class _Harness {
  _Harness({
    AppUpdateState update = const AppUpdateState(
      loaded: true,
      developerMode: true,
    ),
    bool mangaEnabled = true,
    bool isTelevision = true,
    AniyomiState state = const AniyomiState(available: true),
    Future<Map<String, dynamic>>? inspection,
  }) : update = _MutableAppUpdateController(update),
       settings = _MutableSettingsController(
         SettingsPreferences(loaded: true, mangaReaderEnabled: mangaEnabled),
       ) {
    controller = _FixtureController(
      gateway,
      state,
      inspection,
      () => settings.state.loaded && settings.state.mangaReaderEnabled,
    );
    container = ProviderContainer(
      overrides: [
        appUpdateControllerProvider.overrideWith((_) => this.update),
        settingsPreferencesProvider.overrideWith((_) => settings),
        isTelevisionProvider.overrideWithValue(isTelevision),
        aniyomiGatewayProvider.overrideWith((ref) {
          ref.listen(aniyomiEnabledProvider, (_, next) {
            unawaited(gateway.configure(next));
          }, fireImmediately: true);
          return gateway;
        }),
        aniyomiControllerProvider.overrideWith((ref) {
          controllerBuilds++;
          ref.watch(aniyomiGatewayProvider);
          return controller;
        }),
      ],
    );
  }
  final _MutableAppUpdateController update;
  final _MutableSettingsController settings;
  final _FixtureGateway gateway = _FixtureGateway();
  late final _FixtureController controller;
  late final ProviderContainer container;
  int controllerBuilds = 0;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    AppLanguage language = AppLanguage.english,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      container.dispose();
      if (controllerBuilds == 0) controller.dispose();
      gateway.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          locale: language.locale,
          supportedLocales: TetoLocalizations.supportedLocales,
          localizationsDelegates: const [
            TetoLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: const TvShortcuts(
            child: AniyomiExperimentalGate(child: AniyomiScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

class _FixtureGateway extends AniyomiGateway {
  _FixtureGateway() : super(supportedPlatform: false);
  bool _active = false;
  int _lease = 0;
  final requests = <Map<String, dynamic>>[];
  @override
  bool get enabled => _active;
  @override
  int get generation => _lease;
  @override
  Future<void> configure(bool enabled, {bool revokeApprovals = true}) async {
    _active = enabled;
    _lease++;
  }

  @override
  void check(int generation) {
    if (!_active || generation != _lease) {
      throw const AniyomiFailure('developer_access_revoked');
    }
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> arguments) async {
    check(_lease);
    requests.add(Map.of(arguments));
    return switch (arguments['operation']) {
      'search' => {
        'items': [
          {'url': '/title', 'title': 'Manga result page ${arguments['page']}'},
        ],
        'hasNextPage': arguments['page'] == 1,
      },
      'details' => {
        'item': {
          'url': '/title/canonical',
          'title': 'Canonical manga title',
          'thumbnailUrl': 'https://images.example.test/cover.jpg',
        },
      },
      'chapters' => {
        'chapters': List.generate(
          101,
          (index) => {
            'url': '/chapter/${101 - index}',
            'name': 'Chapter ${101 - index}',
            'number': 101 - index,
          },
        ),
      },
      _ => throw StateError('Unexpected fixture operation'),
    };
  }
}

class _FixtureController extends AniyomiController {
  _FixtureController(
    AniyomiGateway gateway,
    AniyomiState initial,
    Future<Map<String, dynamic>>? inspection,
    bool Function() mangaEnabled,
  ) : this._(
        gateway,
        initial,
        inspection,
        mangaEnabled,
        AniyomiRepositoryClient(),
      );

  _FixtureController._(
    AniyomiGateway gateway,
    AniyomiState initial,
    this.inspection,
    this.mangaEnabled,
    this.client,
  ) : super(
        gateway: gateway,
        client: client,
        storage: const FlutterSecureStorage(),
        mangaEnabled: mangaEnabled,
      ) {
    state = initial;
  }
  final AniyomiRepositoryClient client;
  final Future<Map<String, dynamic>>? inspection;
  final bool Function() mangaEnabled;
  final inspected = <String>[];
  final approved = <String>[];
  final added = <(AniyomiMediaKind, String)>[];
  final retried = <String>[];
  void replaceCatalog(List<AniyomiRepositoryExtension> catalog) {
    state = state.copyWith(catalog: catalog);
  }

  @override
  Future<void> retryDiscovery(
    String extensionId, {
    required AniyomiMediaKind kind,
  }) async {
    gateway.check(gateway.generation);
    if (kind == AniyomiMediaKind.manga && !mangaEnabled()) {
      throw const AniyomiFailure('manga_disabled');
    }
    retried.add(extensionId);
    state = state.copyWith(
      readiness: {
        ...state.readiness,
        extensionId: const AniyomiReadiness(
          AniyomiReadinessStage.ready,
          sourceCount: 1,
        ),
      },
    );
  }

  @override
  Future<Map<String, dynamic>> inspect(
    AniyomiRepositoryExtension extension,
  ) async {
    if (extension.kind == AniyomiMediaKind.manga && !mangaEnabled()) {
      throw const AniyomiFailure('manga_disabled');
    }
    inspected.add(extension.packageName);
    final result = inspection == null ? _descriptor : await inspection!;
    if (extension.kind == AniyomiMediaKind.manga && !mangaEnabled()) {
      throw const AniyomiFailure('manga_disabled');
    }
    return result;
  }

  @override
  Future<void> approve(String inspectionId) async {
    gateway.check(gateway.generation);
    approved.add(inspectionId);
  }

  @override
  Future<void> addRepository(String value, AniyomiMediaKind kind) async {
    added.add((kind, value));
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }
}

class _MutableAppUpdateController extends AppUpdateController {
  _MutableAppUpdateController(AppUpdateState initial)
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => initial.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = initial;
  }
  void replace(AppUpdateState next) => state = next;
}

class _MutableSettingsController extends SettingsPreferencesController {
  _MutableSettingsController(SettingsPreferences initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  void replace(SettingsPreferences next) => state = next;

  @override
  Future<void> load() async {}
}

class _UnusedReleaseSource extends AppReleaseSource {
  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) =>
      throw StateError('No release lookup in fixture');
  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => throw StateError('No downloads in fixture');
}
