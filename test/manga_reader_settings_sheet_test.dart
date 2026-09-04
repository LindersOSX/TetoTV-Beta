import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/application/manga_series_preferences_controller.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _seriesKey = MangaReaderSeriesKey(
  sourceId: 'settings-source',
  publicationId: 'settings-series',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_SETTINGS_PREVIEWS')) return;
    final text = FontLoader('SettingsPreview')
      ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), icons.load()]);
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('narrow sheet scrolls through every group with a pinned close', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _showSettings(tester);
    await _capturePreview(tester, 'narrow-layout');

    expect(tester.takeException(), isNull);
    expect(find.text('Reading layout'), findsOneWidget);
    final close = find.byKey(const ValueKey('manga-settings-close'));
    final closePosition = tester.getTopLeft(close);
    final reset = find.byKey(const ValueKey('manga-settings-reset'));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Page appearance'), findsOneWidget);
    expect(find.text('Controls & progress'), findsOneWidget);
    expect(find.text('Performance & privacy'), findsOneWidget);
    expect(tester.getTopLeft(close), closePosition);
    expect(reset.hitTestable(), findsOneWidget);
    await _capturePreview(tester, 'narrow-privacy');
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(MangaReaderSettingsSheet), findsNothing);
  });

  testWidgets('short wide TV sheet remains bounded and scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _showSettings(tester);
    await _capturePreview(tester, 'short-tv-layout');

    final sheetSize = tester.getSize(find.byType(MangaReaderSettingsSheet));
    expect(sheetSize.height, lessThanOrEqualTo(324));
    expect(sheetSize.width, lessThanOrEqualTo(720));
    await tester.ensureVisible(
      find.byKey(const ValueKey('manga-settings-reset')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('manga-settings-close')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets(
    'large text on a narrow phone keeps settings and confirmation usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _showSettings(tester);

      expect(tester.takeException(), isNull);
      final reset = find.byKey(const ValueKey('manga-settings-reset'));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Keep settings').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Keep settings'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('manga-settings-close')).hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'layout changes use the selected scope and restore global defaults',
    (tester) async {
      final container = await _showSettings(tester);
      final global = container.read(mangaReaderPreferencesProvider.notifier);
      await global.setPageFit(MangaPageFit.height);
      await tester.pumpAndSettle();

      await _choose<MangaReadingMode>(tester, 'mode', 'Vertical');
      expect(
        container.read(mangaReaderPreferencesProvider).mode,
        MangaReadingMode.vertical,
      );
      expect(
        container
            .read(mangaSeriesReaderPreferencesProvider(_seriesKey))
            .enabled,
        isFalse,
      );

      await _toggle(tester, 'remember-layout');
      expect(
        container
            .read(mangaSeriesReaderPreferencesProvider(_seriesKey))
            .enabled,
        isTrue,
      );
      expect(
        container
            .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
            .pageFit,
        MangaPageFit.height,
      );
      await _choose<MangaReadingMode>(tester, 'mode', 'Webtoon');
      expect(
        container
            .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
            .mode,
        MangaReadingMode.webtoon,
      );
      expect(
        container.read(mangaReaderPreferencesProvider).mode,
        MangaReadingMode.vertical,
      );

      await _choose<MangaReaderBackground>(tester, 'background', 'Sepia');
      expect(
        container.read(mangaReaderPreferencesProvider).background,
        MangaReaderBackground.sepia,
      );
      await _toggle(tester, 'remember-layout');
      expect(
        container
            .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
            .mode,
        MangaReadingMode.vertical,
      );
      expect(
        container
            .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
            .background,
        MangaReaderBackground.sepia,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Webtoon direction changes honor global and per-manga scope', (
    tester,
  ) async {
    final container = await _showSettings(tester);
    await _choose<MangaReadingMode>(tester, 'mode', 'Webtoon');
    await _choose<MangaReadingDirection>(tester, 'direction', 'Left to right');
    expect(
      container.read(mangaReaderPreferencesProvider).direction,
      MangaReadingDirection.leftToRight,
    );
    expect(
      find.text(
        'Sets forward/back tap and remote controls; scrolling stays vertical.',
      ),
      findsOneWidget,
    );

    await _toggle(tester, 'remember-layout');
    await _choose<MangaReadingDirection>(tester, 'direction', 'Right to left');
    expect(
      container
          .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
          .direction,
      MangaReadingDirection.rightToLeft,
    );
    expect(
      container.read(mangaReaderPreferencesProvider).direction,
      MangaReadingDirection.leftToRight,
    );
    await _toggle(tester, 'remember-layout');
    expect(
      container
          .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
          .direction,
      MangaReadingDirection.leftToRight,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mode-specific controls are disabled without losing their values',
    (tester) async {
      final container = await _showSettings(tester);
      await _choose<MangaReadingMode>(tester, 'mode', 'Webtoon');

      expect(
        _choice<MangaReadingDirection>(tester, 'direction').onChanged,
        isNotNull,
      );
      expect(_choice<MangaSpreadMode>(tester, 'spread').onChanged, isNull);
      expect(_choice<MangaPageFit>(tester, 'fit').onChanged, isNull);
      expect(_slider(tester, 'page-gap').onChanged, isNull);
      expect(_slider(tester, 'webtoon-gap').onChanged, isNotNull);
      expect(_switch(tester, 'cover-alone').onChanged, isNull);
      expect(_switch(tester, 'swap-spread').onChanged, isNull);
      expect(_switch(tester, 'book-animation').onChanged, isNotNull);

      await _choose<MangaReadingMode>(tester, 'mode', 'Paged');
      expect(
        _choice<MangaReadingDirection>(tester, 'direction').onChanged,
        isNotNull,
      );
      expect(_slider(tester, 'page-gap').onChanged, isNotNull);
      expect(_slider(tester, 'webtoon-gap').onChanged, isNull);
      expect(
        container.read(mangaReaderPreferencesProvider).coverStartsAlone,
        isTrue,
      );
      expect(container.read(mangaReaderPreferencesProvider).pageGap, 12);
    },
  );

  testWidgets(
    'appearance sliders and control switches update saved preferences',
    (tester) async {
      final container = await _showSettings(tester);
      final margins = find.byKey(const ValueKey('manga-settings-side-padding'));
      await tester.ensureVisible(margins);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(margins);
      await tester.tapAt(
        Offset(bounds.left + bounds.width * .75, bounds.center.dy),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(mangaReaderPreferencesProvider).sidePadding,
        greaterThan(0),
      );

      await _toggle(tester, 'grayscale');
      await _toggle(tester, 'invert-colors');
      await _toggle(tester, 'tap-zones');
      expect(container.read(mangaReaderPreferencesProvider).grayscale, isTrue);
      expect(
        container.read(mangaReaderPreferencesProvider).invertColors,
        isTrue,
      );
      expect(
        _choice<MangaTapZoneLayout>(tester, 'tap-zone-layout').onChanged,
        isNull,
      );
      expect(_switch(tester, 'invert-tap-zones').onChanged, isNull);

      await _toggle(tester, 'tap-zones');
      await _choose<MangaTapZoneLayout>(
        tester,
        'tap-zone-layout',
        MangaTapZoneLayout.edges.displayName,
      );
      await _toggle(tester, 'invert-tap-zones');
      expect(
        container.read(mangaReaderPreferencesProvider).tapZoneLayout,
        MangaTapZoneLayout.edges,
      );
      expect(
        container.read(mangaReaderPreferencesProvider).invertTapZones,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reset is confirmed and clears global settings and this series only',
    (tester) async {
      final container = await _showSettings(tester);
      final global = container.read(mangaReaderPreferencesProvider.notifier);
      final series = container.read(
        mangaSeriesReaderPreferencesProvider(_seriesKey).notifier,
      );
      const otherKey = MangaReaderSeriesKey(
        sourceId: 'settings-source',
        publicationId: 'other-series',
      );
      final otherSubscription = container.listen(
        mangaSeriesReaderPreferencesProvider(otherKey),
        (_, _) {},
      );
      addTearDown(otherSubscription.close);
      final otherSeries = container.read(
        mangaSeriesReaderPreferencesProvider(otherKey).notifier,
      );
      await global.setBackground(MangaReaderBackground.sepia);
      await series.setEnabled(true);
      await series.setMode(MangaReadingMode.webtoon);
      await otherSeries.setEnabled(true);
      await otherSeries.setMode(MangaReadingMode.vertical);
      await tester.pumpAndSettle();

      final reset = find.byKey(const ValueKey('manga-settings-reset'));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(find.text('Reset reader settings?'), findsOneWidget);
      expect(
        container.read(mangaReaderPreferencesProvider).background,
        MangaReaderBackground.sepia,
      );
      await tester.tap(find.text('Keep settings'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(mangaSeriesReaderPreferencesProvider(_seriesKey))
            .enabled,
        isTrue,
      );

      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('manga-settings-confirm-reset')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(mangaReaderPreferencesProvider).background,
        MangaReaderBackground.black,
      );
      expect(
        container
            .read(mangaSeriesReaderPreferencesProvider(_seriesKey))
            .enabled,
        isFalse,
      );
      expect(
        container
            .read(mangaEffectiveReaderPreferencesProvider(_seriesKey))
            .mode,
        MangaReadingMode.paged,
      );
      expect(
        container.read(mangaSeriesReaderPreferencesProvider(otherKey)).enabled,
        isTrue,
      );
      expect(
        container.read(mangaEffectiveReaderPreferencesProvider(otherKey)).mode,
        MangaReadingMode.vertical,
      );
    },
  );

  testWidgets('keyboard users can reach and activate the series scope switch', (
    tester,
  ) async {
    final container = await _showSettings(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(
      container.read(mangaSeriesReaderPreferencesProvider(_seriesKey)).enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _showSettings(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: const bool.fromEnvironment('CAPTURE_SETTINGS_PREVIEWS')
            ? AppTheme.dark.copyWith(
                textTheme: AppTheme.dark.textTheme.apply(
                  fontFamily: 'SettingsPreview',
                ),
              )
            : AppTheme.dark,
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('settings-preview'),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  constraints: const BoxConstraints(maxWidth: 720),
                  builder: (_) => const MangaReaderSettingsSheet(
                    seriesKey: _seriesKey,
                    seriesTitle:
                        'A very long manga title that should truncate safely on a narrow phone',
                  ),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open settings'));
  await tester.pumpAndSettle();
  return container;
}

DropdownButton<T> _choice<T>(WidgetTester tester, String id) => tester
    .widget<DropdownButton<T>>(find.byKey(ValueKey('manga-settings-$id')));

Slider _slider(WidgetTester tester, String id) =>
    tester.widget<Slider>(find.byKey(ValueKey('manga-settings-$id')));

SwitchListTile _switch(WidgetTester tester, String id) =>
    tester.widget<SwitchListTile>(find.byKey(ValueKey('manga-settings-$id')));

Future<void> _choose<T>(WidgetTester tester, String id, String value) async {
  final choice = find.byKey(ValueKey('manga-settings-$id'));
  await tester.ensureVisible(choice);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Future<void> _toggle(WidgetTester tester, String id) async {
  final control = find.byKey(ValueKey('manga-settings-$id'));
  await tester.ensureVisible(control);
  await tester.pumpAndSettle();
  await tester.tap(control);
  await tester.pumpAndSettle();
}

/// Optional local visual QA artifacts; normal test runs do not write images.
Future<void> _capturePreview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_SETTINGS_PREVIEWS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('settings-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      final directory = Directory('build/reader-settings-previews');
      await directory.create(recursive: true);
      await File('${directory.path}/$name.png').writeAsBytes(
        bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}
