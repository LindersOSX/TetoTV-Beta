import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpSettings(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    bool isTelevision = true,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(isTelevision)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const TvShortcuts(child: AccountsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectArea(WidgetTester tester, String area) async {
    final tab = find.byKey(ValueKey('settings-area-$area'));
    expect(tab, findsOneWidget);
    await tester.tap(tab, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  Finder settingsCard(String key) =>
      find.byKey(ValueKey(key), skipOffstage: false);

  Rect cardRect(WidgetTester tester, String key) =>
      tester.getRect(settingsCard(key));

  double verticalGap(WidgetTester tester, String upper, String lower) =>
      cardRect(tester, lower).top - cardRect(tester, upper).bottom;

  testWidgets('all five Settings tabs expose the restyled card contract', (
    tester,
  ) async {
    await pumpSettings(tester);

    const cardsByArea = <String, List<String>>{
      'appearance': [
        'appearance-theme-display-card',
        'appearance-home-screen-card',
        'appearance-display-options-card',
        'appearance-input-feedback-card',
        'appearance-home-shelves-card',
        'appearance-navigation-card',
      ],
      'playback': [
        'settings-card-playback-captions',
        'settings-card-playback-player',
      ],
      'services': [
        'settings-card-services-debrid',
        'settings-card-services-sources',
        'settings-card-services-autopick',
        'settings-card-services-features',
        'settings-card-services-privacy',
      ],
      'accounts': [
        'settings-card-accounts-tracking',
        'settings-card-accounts-profiles',
        'settings-card-accounts-behavior',
        'settings-card-accounts-discord',
      ],
      'system': [
        'settings-card-system-support',
        'settings-card-system-updates',
        'settings-card-system-community',
        'settings-card-system-storage',
        'settings-card-system-legal',
        'settings-card-system-privacy-diagnostics',
      ],
    };

    for (final entry in cardsByArea.entries) {
      await selectArea(tester, entry.key);

      for (final key in entry.value) {
        final card = find.byKey(ValueKey(key), skipOffstage: false);
        expect(
          card,
          findsOneWidget,
          reason: '${entry.key} must keep the restyled $key card.',
        );
      }

      expect(
        find.byKey(const ValueKey('settings-toggle-all-sections')),
        findsOneWidget,
      );
      expect(find.text('Collapse all'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('non-Appearance tabs use the shared Settings section card', (
    tester,
  ) async {
    await pumpSettings(tester);

    const cardsByArea = <String, List<String>>{
      'playback': [
        'settings-card-playback-captions',
        'settings-card-playback-player',
      ],
      'services': [
        'settings-card-services-debrid',
        'settings-card-services-sources',
        'settings-card-services-autopick',
        'settings-card-services-features',
        'settings-card-services-privacy',
      ],
      'accounts': [
        'settings-card-accounts-tracking',
        'settings-card-accounts-profiles',
        'settings-card-accounts-behavior',
        'settings-card-accounts-discord',
      ],
      'system': [
        'settings-card-system-support',
        'settings-card-system-updates',
        'settings-card-system-community',
        'settings-card-system-storage',
        'settings-card-system-legal',
        'settings-card-system-privacy-diagnostics',
      ],
    };

    for (final entry in cardsByArea.entries) {
      await selectArea(tester, entry.key);

      for (final key in entry.value) {
        final card = find.byKey(ValueKey(key), skipOffstage: false);
        expect(card, findsOneWidget);
        await tester.ensureVisible(card);
        await tester.pump();
        expect(
          tester.widget(card).runtimeType.toString(),
          '_SettingsSectionCard',
          reason: '$key must use the shared restyled section-card primitive.',
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byWidgetPredicate(
              (widget) => widget.runtimeType.toString() == '_SettingsCardFrame',
            ),
            skipOffstage: false,
          ),
          findsOneWidget,
          reason: '$key must use the shared card frame.',
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget.runtimeType.toString() == '_AppearanceCardTitle',
            ),
            skipOffstage: false,
          ),
          findsOneWidget,
          reason: '$key must use the shared Settings heading treatment.',
        );
      }
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('TV Settings use compact controls across every area', (
    tester,
  ) async {
    await pumpSettings(tester);

    AnimatedContainer compactSurface(String key) => tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byKey(ValueKey(key), skipOffstage: false),
            matching: find.byType(AnimatedContainer, skipOffstage: false),
            skipOffstage: false,
          ),
        )
        .firstWhere((widget) => widget.constraints?.minHeight != null);

    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-area-appearance')))
          .height,
      lessThanOrEqualTo(40),
    );

    final titleLanguage = compactSurface('settings-appearance-title-language');
    expect(titleLanguage.constraints?.minHeight, 48);
    expect(
      titleLanguage.padding,
      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(
                const ValueKey('settings-appearance-title-language'),
              ),
              matching: find.text('Title language'),
            ),
          )
          .style
          ?.fontSize,
      16,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('appearance-theme-display-card')))
          .height,
      lessThanOrEqualTo(220),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('appearance-navigation-card')))
          .height,
      lessThanOrEqualTo(220),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('appearance-home-screen-card')))
          .height,
      lessThanOrEqualTo(420),
    );

    const representativeRows = <String, String>{
      'playback': 'settings-default-player',
      'services': 'settings-direct-torrent-toggle',
      'accounts': 'settings-tracking-update-threshold',
      'system': 'settings-anonymous-crash-reports',
    };
    for (final entry in representativeRows.entries) {
      await selectArea(tester, entry.key);
      final surface = compactSurface(entry.value);
      expect(
        surface.constraints?.minHeight,
        48,
        reason: '${entry.key} must use the compact shared TV row.',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('TV Settings use one full-width card list in every area', (
    tester,
  ) async {
    await pumpSettings(tester);

    const cardsByArea = <String, List<String>>{
      'appearance': [
        'appearance-theme-display-card',
        'appearance-home-screen-card',
        'appearance-display-options-card',
        'appearance-input-feedback-card',
        'appearance-home-shelves-card',
        'appearance-navigation-card',
      ],
      'playback': [
        'settings-card-playback-captions',
        'settings-card-playback-player',
      ],
      'services': [
        'settings-card-services-debrid',
        'settings-card-services-sources',
        'settings-card-services-autopick',
        'settings-card-services-features',
        'settings-card-services-privacy',
      ],
      'accounts': [
        'settings-card-accounts-tracking',
        'settings-card-accounts-profiles',
        'settings-card-accounts-behavior',
        'settings-card-accounts-discord',
      ],
      'system': [
        'settings-card-system-support',
        'settings-card-system-updates',
        'settings-card-system-community',
        'settings-card-system-storage',
        'settings-card-system-legal',
        'settings-card-system-privacy-diagnostics',
      ],
    };

    for (final entry in cardsByArea.entries) {
      await selectArea(tester, entry.key);
      final list = tester.getRect(
        find.byKey(const ValueKey('settings-content-list')),
      );
      final first = cardRect(tester, entry.value.first);
      expect(first.left, closeTo(list.left, 1));
      expect(first.right, closeTo(list.right, 1));

      for (var index = 0; index < entry.value.length; index++) {
        final current = cardRect(tester, entry.value[index]);
        expect(
          current.left,
          closeTo(first.left, 1),
          reason: '${entry.key} cards must share one left edge.',
        );
        expect(
          current.width,
          closeTo(first.width, 1),
          reason: '${entry.key} cards must use the full list width.',
        );
        if (index == 0) continue;
        expect(
          verticalGap(tester, entry.value[index - 1], entry.value[index]),
          closeTo(8, 1),
          reason: '${entry.key} cards must use the shared TV list gap.',
        );
      }
    }

    final tabRects = [
      for (final area in const [
        'appearance',
        'playback',
        'services',
        'accounts',
        'system',
      ])
        tester.getRect(find.byKey(ValueKey('settings-area-$area'))),
    ];
    for (var index = 1; index < tabRects.length; index++) {
      expect(tabRects[index].width, closeTo(tabRects.first.width, 1));
      expect(tabRects[index].left - tabRects[index - 1].right, closeTo(8, 1));
    }
  });

  testWidgets('TV Appearance cards hug their final controls', (tester) async {
    await pumpSettings(tester);

    const finalRows = <String, String>{
      'appearance-theme-display-card': 'settings-appearance-show-title-style',
      'appearance-navigation-card': 'settings-appearance-reset',
      'appearance-home-screen-card': 'settings-appearance-continue-watching',
    };
    for (final entry in finalRows.entries) {
      final card = cardRect(tester, entry.key);
      final finalRow = tester.getRect(
        find.byKey(ValueKey(entry.value), skipOffstage: false),
      );
      expect(
        card.bottom - finalRow.bottom,
        inInclusiveRange(6, 16),
        reason: '${entry.key} must not reserve unused TV height.',
      );
    }
  });

  testWidgets('mobile Settings retain their existing control sizing', (
    tester,
  ) async {
    await pumpSettings(tester, size: const Size(360, 800), isTelevision: false);

    final row = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byKey(
              const ValueKey('settings-appearance-title-language'),
            ),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .firstWhere((widget) => widget.constraints?.minHeight != null);
    expect(row.constraints?.minHeight, 64);
    expect(
      row.padding,
      const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(
                const ValueKey('settings-appearance-title-language'),
              ),
              matching: find.text('Title language'),
            ),
          )
          .style
          ?.fontSize,
      14,
    );

    final theme = cardRect(tester, 'appearance-theme-display-card');
    final navigation = cardRect(tester, 'appearance-navigation-card');
    final home = cardRect(tester, 'appearance-home-screen-card');
    expect((navigation.left - theme.left).abs(), lessThanOrEqualTo(.5));
    expect((navigation.width - theme.width).abs(), lessThanOrEqualTo(.5));
    expect(navigation.top - theme.bottom, closeTo(18, .5));
    expect(home.top - navigation.bottom, closeTo(18, .5));

    await selectArea(tester, 'playback');
    expect(
      verticalGap(
        tester,
        'settings-card-playback-captions',
        'settings-card-playback-player',
      ),
      closeTo(18, .5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide non-TV layouts retain their responsive columns', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      size: const Size(1280, 720),
      isTelevision: false,
    );

    final theme = cardRect(tester, 'appearance-theme-display-card');
    final home = cardRect(tester, 'appearance-home-screen-card');
    expect((theme.top - home.top).abs(), lessThanOrEqualTo(1));
    expect(home.left, greaterThan(theme.right));
    expect(theme.width, lessThan(home.right - theme.left));
    expect(tester.takeException(), isNull);
  });
}
