import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/presentation/language_selection_screen.dart';
import 'package:anime_tv/features/settings/presentation/setup_method_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _storage = FlutterSecureStorage();
const _methodHeading = 'How would you like to set up TetoTV?';

class _TestApp extends ConsumerWidget {
  const _TestApp(this.router);
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    theme: AppTheme.dark,
    locale: ref.watch(settingsPreferencesProvider).interfaceLanguage.locale,
    supportedLocales: TetoLocalizations.supportedLocales,
    localizationsDelegates: const [
      TetoLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    routerConfig: router,
    builder: (context, child) => TvShortcuts(
      child: LanguageSelectionGate(child: child ?? const SizedBox.shrink()),
    ),
  );
}

GoRouter _router() => GoRouter(
  initialLocation: SetupMethodScreen.routePath,
  routes: [
    GoRoute(
      path: SetupMethodScreen.routePath,
      builder: (_, _) => const SetupMethodScreen(),
    ),
    GoRoute(
      path: '/setup',
      builder: (_, _) => const Scaffold(body: Text('on-device setup sentinel')),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final action in [
    'Android Back',
    'Escape',
    'Go Back',
    'Browser Back',
    'touch Back',
  ]) {
    testWidgets(
      '$action revisits language without resetting saved preferences',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          interfaceLanguageStorageKey: 'es',
          interfaceLanguageChosenStorageKey: 'true',
          initialSetupStartedStorageKey: 'true',
          'player_preferred_audio_language': 'jpn',
          'player_preferred_caption_language': 'ita',
          'player_preferred_captions': 'disabled',
          'fixture_unrelated_preference': 'preserve',
        });
        tester.view.physicalSize = action == 'touch Back'
            ? const Size(390, 844)
            : const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final router = _router();
        addTearDown(router.dispose);
        await tester.pumpWidget(ProviderScope(child: _TestApp(router)));
        await tester.pumpAndSettle();
        expect(find.byType(SetupMethodScreen), findsOneWidget);
        expect(
          find.text(
            const TetoLocalizations(AppLanguage.spanish).text(_methodHeading),
          ),
          findsOneWidget,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SetupMethodScreen)),
        );
        final beforeBack = await _storage.readAll();

        switch (action) {
          case 'Android Back':
            await tester.binding.handlePopRoute();
          case 'Escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'Go Back':
            await tester.sendKeyEvent(
              LogicalKeyboardKey.goBack,
              physicalKey: PhysicalKeyboardKey.escape,
            );
          case 'Browser Back':
            await tester.sendKeyEvent(
              LogicalKeyboardKey.browserBack,
              platform: 'windows',
            );
          case 'touch Back':
            final back = find.byKey(const ValueKey('setup-method-back'));
            await tester.ensureVisible(back);
            await tester.tap(back);
        }
        await tester.pumpAndSettle();

        expect(find.byType(LanguageSelectionScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('setup-method-screen')), findsNothing);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'setup.language.es',
        );
        expect(
          router.routeInformationProvider.value.uri.path,
          SetupMethodScreen.routePath,
        );
        expect(await _storage.readAll(), beforeBack);
        final preserved = container.read(settingsPreferencesProvider);
        expect(preserved.interfaceLanguage, AppLanguage.spanish);
        expect(preserved.languageChoiceCompleted, isTrue);
        expect(preserved.preferredAudioLanguage, 'jpn');
        expect(preserved.preferredCaptionLanguage, 'ita');
        expect(preserved.preferredCaptionMode, PreferredCaptionMode.disabled);
        for (final language in AppLanguage.values) {
          expect(find.text(language.nativeName), findsOneWidget);
        }

        // Only an explicit new choice applies the existing audio/CC defaults.
        final french = find.byKey(const ValueKey('choose-language-fr'));
        await tester.ensureVisible(french);
        await tester.tap(french);
        await tester.pumpAndSettle();
        expect(find.byType(LanguageSelectionScreen), findsNothing);
        expect(
          find.byKey(const ValueKey('setup-method-screen')),
          findsOneWidget,
        );
        expect(
          find.text(
            const TetoLocalizations(AppLanguage.french).text(_methodHeading),
          ),
          findsOneWidget,
        );
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'setup-method.tv',
        );
        final changed = container.read(settingsPreferencesProvider);
        expect(changed.interfaceLanguage, AppLanguage.french);
        expect(changed.preferredAudioLanguage, 'fra');
        expect(changed.preferredCaptionLanguage, 'fra');
        expect(changed.preferredCaptionMode, PreferredCaptionMode.enabled);
        expect(
          await _storage.read(key: 'fixture_unrelated_preference'),
          'preserve',
        );
        expect(
          await _storage.read(key: initialSetupCompletedStorageKey),
          isNot('true'),
        );

        final television = find.byKey(const ValueKey('setup-method-tv'));
        await tester.ensureVisible(television);
        await tester.tap(television);
        await tester.pumpAndSettle();
        expect(find.text('on-device setup sentinel'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('first-run gate choice can be revisited from the method step', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(child: _TestApp(router)));
    await tester.pumpAndSettle();
    expect(find.byType(SetupMethodScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('choose-language-hi')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-method-screen')), findsOneWidget);
    final beforeBack = await _storage.readAll();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LanguageSelectionScreen), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup.language.hi');
    expect(await _storage.readAll(), beforeBack);
    expect(tester.takeException(), isNull);
  });
}
