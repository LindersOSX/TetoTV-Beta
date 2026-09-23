import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/presentation/language_selection_screen.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  const captureLocalization = bool.fromEnvironment('CAPTURE_LOCALIZATION');
  if (captureLocalization) {
    setUpAll(() async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await (FontLoader(
        'Roboto',
      )..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))).load();
      await (FontLoader('TetoDevanagari')
            ..addFont(rootBundle.load('assets/fonts/NotoSansDevanagari.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tearDownAll(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });
  }

  Future<void> captureSettings(
    WidgetTester tester,
    GlobalKey boundaryKey,
    String name,
  ) async {
    // Asset decoding can finish after pumpAndSettle on the first capture.
    // Wait for the shared setup logo before recording the actual UI frame.
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/branding/tetotv_icon.png'),
        boundaryKey.currentContext!,
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = await Directory(
          'build/localization-visuals',
        ).create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  for (final language in AppLanguage.values) {
    for (final device in const [
      ('TV', Size(1280, 720)),
      ('phone', Size(390, 844)),
    ]) {
      testWidgets('${language.code} language screen fits ${device.$1}', (
        tester,
      ) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.physicalSize = device.$2;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.dark,
              locale: language.locale,
              supportedLocales: TetoLocalizations.supportedLocales,
              localizationsDelegates: const [
                TetoLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: RepaintBoundary(
                key: boundaryKey,
                child: const LanguageSelectionScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(TetoLocalizations(language).text('Choose your language')),
          findsOneWidget,
        );
        for (final option in AppLanguage.values) {
          expect(find.text(option.nativeName), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        if (captureLocalization &&
            (((language == AppLanguage.english ||
                        language == AppLanguage.spanish) &&
                    device.$1 == 'TV') ||
                (language == AppLanguage.hindi && device.$1 == 'phone'))) {
          await captureSettings(
            tester,
            boundaryKey,
            'setup-language-${language.code}-${device.$1}',
          );
        }
      });

      testWidgets('${language.code} settings areas fit ${device.$1}', (
        tester,
      ) async {
        FlutterSecureStorage.setMockInitialValues({
          interfaceLanguageStorageKey: language.code,
          interfaceLanguageChosenStorageKey: 'true',
        });
        tester.view.physicalSize = device.$2;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isTelevisionProvider.overrideWithValue(device.$1 == 'TV'),
            ],
            child: MaterialApp(
              theme: AppTheme.dark,
              locale: language.locale,
              supportedLocales: TetoLocalizations.supportedLocales,
              localizationsDelegates: const [
                TetoLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: RepaintBoundary(
                key: boundaryKey,
                child: const AccountsScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(TetoLocalizations(language).text('App language')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (captureLocalization &&
            language == AppLanguage.spanish &&
            device.$1 == 'TV') {
          await captureSettings(
            tester,
            boundaryKey,
            'settings-es-TV-appearance',
          );
        }
        for (final area in ['playback', 'services', 'accounts', 'system']) {
          final tab = find.byKey(ValueKey('settings-area-$area'));
          await tester.ensureVisible(tab);
          await tester.tap(tab);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${language.code} $area ${device.$1}',
          );
          if (captureLocalization &&
              language == AppLanguage.hindi &&
              device.$1 == 'phone' &&
              area == 'playback') {
            await captureSettings(
              tester,
              boundaryKey,
              'settings-hi-phone-playback',
            );
          }
        }
      });
    }
  }

  testWidgets('TV language choices follow their visible two-column order', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LanguageSelectionScreen())),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.language.en');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.language.es');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.language.fr');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.language.pt');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.language.en');
    for (final language in AppLanguage.values) {
      final rect = tester.getRect(
        find.byKey(ValueKey('choose-language-${language.code}')),
      );
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(540));
    }
    expect(tester.takeException(), isNull);
  });

  test('fresh install needs language choice before setup', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = SettingsPreferencesController(storage);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.loaded, isTrue);
    expect(controller.state.languageChoiceCompleted, isFalse);
    expect(controller.state.interfaceLanguage, AppLanguage.english);
  });

  test(
    'upgrade preserves existing media preferences without prompting',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'player_preferred_audio': 'sub',
        'player_preferred_audio_language': 'jpn',
        'player_preferred_caption_language': 'fra',
        'player_preferred_captions': 'disabled',
        initialSetupCompletedStorageKey: 'true',
      });
      final controller = SettingsPreferencesController(storage);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.state.languageChoiceCompleted, isTrue);
      expect(controller.state.interfaceLanguage, AppLanguage.english);
      expect(controller.state.preferredAudio, PlaybackAudioPreference.sub);
      expect(controller.state.preferredAudioLanguage, 'jpn');
      expect(controller.state.preferredCaptionLanguage, 'fra');
      expect(
        controller.state.preferredCaptionMode,
        PreferredCaptionMode.disabled,
      );
      expect(await storage.read(key: interfaceLanguageStorageKey), isNull);
    },
  );

  test('interrupted initial setup still asks for a language', () async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupStartedStorageKey: 'true',
      'player_preferred_audio': 'dub',
    });
    final controller = SettingsPreferencesController(storage);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.languageChoiceCompleted, isFalse);
  });

  for (final language in AppLanguage.values) {
    test(
      '${language.code} seeds independent audio and CC and persists',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final controller = SettingsPreferencesController(storage);
        addTearDown(controller.dispose);
        await controller.setInterfaceLanguage(language);
        expect(controller.state.interfaceLanguage, language);
        expect(controller.state.languageChoiceCompleted, isTrue);
        expect(controller.state.preferredAudio, PlaybackAudioPreference.dub);
        expect(controller.state.preferredAudioLanguage, language.mediaLanguage);
        expect(
          controller.state.preferredCaptionLanguage,
          language.mediaLanguage,
        );
        expect(
          controller.state.preferredCaptionMode,
          PreferredCaptionMode.enabled,
        );
        final restored = SettingsPreferencesController(storage);
        addTearDown(restored.dispose);
        await restored.load();
        expect(restored.state.interfaceLanguage, language);
        expect(restored.state.languageChoiceCompleted, isTrue);
        expect(restored.state.preferredAudioLanguage, language.mediaLanguage);
        expect(restored.state.preferredCaptionLanguage, language.mediaLanguage);
        await restored.setPreferredAudioLanguage('ita');
        await restored.setPreferredCaptionLanguage('jpn');
        expect(restored.state.interfaceLanguage, language);
        expect(restored.state.preferredAudioLanguage, 'ita');
        expect(restored.state.preferredCaptionLanguage, 'jpn');
      },
    );
  }

  for (final language in AppLanguage.values) {
    for (final titleStyle in ShowTitleStyle.values) {
      test(
        '${language.code} UI preserves ${titleStyle.name} title style',
        () async {
          FlutterSecureStorage.setMockInitialValues({});
          final controller = SettingsPreferencesController(storage);
          addTearDown(controller.dispose);
          await controller.setShowTitleStyle(titleStyle);
          await controller.setInterfaceLanguage(language);
          expect(controller.state.interfaceLanguage, language);
          expect(controller.state.showTitleStyle, titleStyle);
          expect(
            await storage.read(key: 'appearance_show_title_style'),
            titleStyle.name,
          );
          final restored = SettingsPreferencesController(storage);
          addTearDown(restored.dispose);
          await restored.load();
          expect(restored.state.interfaceLanguage, language);
          expect(restored.state.showTitleStyle, titleStyle);
        },
      );
    }
  }

  test(
    'UI language leaves the independent Title Language preference alone',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final titleController = TitleLanguagePreferenceController(storage);
      final settingsController = SettingsPreferencesController(storage);
      addTearDown(titleController.dispose);
      addTearDown(settingsController.dispose);
      await titleController.setPreference(TitleLanguagePreference.romaji);
      await settingsController.setInterfaceLanguage(AppLanguage.spanish);
      expect(titleController.state, TitleLanguagePreference.romaji);
      expect(
        await storage.read(key: titleLanguagePreferenceStorageKey),
        TitleLanguagePreference.romaji.storageValue,
      );
    },
  );

  test('explicit UI-only change preserves audio and captions', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = SettingsPreferencesController(storage);
    addTearDown(controller.dispose);
    await controller.setShowTitleStyle(ShowTitleStyle.text);
    await controller.setPreferredAudioLanguage('jpn');
    await controller.setPreferredCaptionLanguage('spa');
    await controller.setInterfaceLanguage(
      AppLanguage.german,
      updateMediaPreferences: false,
    );
    expect(controller.state.interfaceLanguage, AppLanguage.german);
    expect(controller.state.preferredAudioLanguage, 'jpn');
    expect(controller.state.preferredCaptionLanguage, 'spa');
    expect(controller.state.showTitleStyle, ShowTitleStyle.text);
  });

  for (final updateMedia in [true, false]) {
    test(
      'Spanish to English preserves title style with media updates=$updateMedia',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final controller = SettingsPreferencesController(storage);
        addTearDown(controller.dispose);
        await controller.setShowTitleStyle(ShowTitleStyle.text);
        await controller.setInterfaceLanguage(AppLanguage.spanish);
        await controller.setPreferredAudioLanguage('jpn');
        await controller.setPreferredCaptionLanguage('ita');
        await controller.setPreferredCaptionMode(PreferredCaptionMode.disabled);
        expect(controller.state.showTitleStyle, ShowTitleStyle.text);
        await controller.setInterfaceLanguage(
          AppLanguage.english,
          updateMediaPreferences: updateMedia,
        );
        expect(controller.state.interfaceLanguage, AppLanguage.english);
        expect(controller.state.showTitleStyle, ShowTitleStyle.text);
        expect(
          controller.state.preferredAudioLanguage,
          updateMedia ? 'eng' : 'jpn',
        );
        expect(
          controller.state.preferredCaptionLanguage,
          updateMedia ? 'eng' : 'ita',
        );
        expect(
          controller.state.preferredCaptionMode,
          updateMedia
              ? PreferredCaptionMode.enabled
              : PreferredCaptionMode.disabled,
        );
        final restored = SettingsPreferencesController(storage);
        addTearDown(restored.dispose);
        await restored.load();
        expect(restored.state.interfaceLanguage, AppLanguage.english);
        expect(restored.state.showTitleStyle, ShowTitleStyle.text);
        expect(
          restored.state.preferredAudioLanguage,
          updateMedia ? 'eng' : 'jpn',
        );
        expect(
          restored.state.preferredCaptionLanguage,
          updateMedia ? 'eng' : 'ita',
        );

        // Title presentation stays independently editable afterward.
        await restored.setShowTitleStyle(ShowTitleStyle.englishLogo);
        await restored.load();
        expect(restored.state.interfaceLanguage, AppLanguage.english);
        expect(restored.state.showTitleStyle, ShowTitleStyle.englishLogo);
      },
    );
  }

  test(
    'Home reload waits for all pending language preference writes',
    () async {
      final writeGate = Completer<void>();
      final values = <String, String>{
        initialSetupStartedStorageKey: 'true',
        // A setup already in progress has persisted the fresh-install crash
        // default. Keep this fixture focused on the language write barrier;
        // the crash migration tests separately exercise the missing-key path.
        'privacy_anonymous_crash_reporting': 'true',
        playerMedia3SurfaceMigration277Key: 'true',
      };
      var reads = 0;
      final controller = SettingsPreferencesController(
        storage,
        readValue: (key) async {
          reads++;
          return values[key];
        },
        writeValue: (key, value) async {
          await writeGate.future;
          values[key] = value;
        },
      );
      addTearDown(controller.dispose);
      await controller.load();
      final initialReads = reads;
      final selecting = controller.setInterfaceLanguage(AppLanguage.hindi);
      final reload = controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(reads, initialReads, reason: 'no half-written snapshot');
      expect(controller.state.interfaceLanguage, AppLanguage.hindi);
      writeGate.complete();
      await Future.wait([selecting, reload]);
      expect(controller.state.interfaceLanguage, AppLanguage.hindi);
      expect(controller.state.languageChoiceCompleted, isTrue);
      expect(controller.state.preferredAudioLanguage, 'hin');
      expect(controller.state.preferredCaptionLanguage, 'hin');
      expect(controller.state.showTitleStyle, ShowTitleStyle.englishLogo);
      expect(
        controller.state.preferredCaptionMode,
        PreferredCaptionMode.enabled,
      );
    },
  );

  for (final hasSavedLanguage in [false, true]) {
    test(
      'returning user bypasses language gate when only completion read fails ($hasSavedLanguage)',
      () async {
        final values = <String, String>{
          initialSetupCompletedStorageKey: 'true',
          if (hasSavedLanguage) interfaceLanguageStorageKey: 'fr',
          'player_preferred_audio_language': 'ita',
          'player_preferred_caption_language': 'jpn',
          'player_preferred_captions': 'disabled',
        };
        final controller = SettingsPreferencesController(
          storage,
          readValue: (key) async {
            if (key == interfaceLanguageChosenStorageKey) {
              throw StateError('temporary read failure');
            }
            return values[key];
          },
          writeValue: (_, _) async {},
        );
        addTearDown(controller.dispose);
        await controller.load();
        expect(controller.state.languageChoiceCompleted, isTrue);
        expect(
          controller.state.interfaceLanguage,
          hasSavedLanguage ? AppLanguage.french : AppLanguage.english,
        );
        expect(controller.state.preferredAudioLanguage, 'ita');
        expect(controller.state.preferredCaptionLanguage, 'jpn');
        expect(
          controller.state.preferredCaptionMode,
          PreferredCaptionMode.disabled,
        );
      },
    );
  }

  test(
    'a delayed startup read cannot overwrite a new language choice',
    () async {
      final gate = Completer<void>();
      final controller = SettingsPreferencesController(
        storage,
        readValue: (key) async {
          await gate.future;
          return null;
        },
        writeValue: (_, _) async {},
      );
      addTearDown(controller.dispose);
      final loading = controller.load();
      await controller.setInterfaceLanguage(AppLanguage.hindi);
      gate.complete();
      await loading;
      expect(controller.state.interfaceLanguage, AppLanguage.hindi);
      expect(controller.state.languageChoiceCompleted, isTrue);
      expect(controller.state.preferredAudioLanguage, 'hin');
      expect(controller.state.preferredCaptionLanguage, 'hin');
      expect(controller.state.showTitleStyle, ShowTitleStyle.englishLogo);
    },
  );

  testWidgets('fresh install displays six native names and gates content', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: const [TetoLocalizations.delegate],
          supportedLocales: TetoLocalizations.supportedLocales,
          home: const LanguageSelectionGate(child: Text('home content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('home content'), findsNothing);
    for (final language in AppLanguage.values) {
      expect(find.text(language.nativeName), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('choose-language-es')));
    await tester.pumpAndSettle();
    expect(find.text('home content'), findsOneWidget);
    expect(await storage.read(key: interfaceLanguageStorageKey), 'es');
    expect(await storage.read(key: initialSetupStartedStorageKey), 'true');
    final progress = SetupProgressController(storage);
    addTearDown(progress.dispose);
    await progress.load();
    expect(
      progress.state.completed,
      isFalse,
      reason: 'language preferences must not skip first-time account setup',
    );
  });
}
