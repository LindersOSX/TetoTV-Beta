import 'dart:convert';

import 'package:anime_tv/core/diagnostics/ui_diagnostic_context.dart';
import 'package:anime_tv/core/diagnostics/ui_diagnostic_scope.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _canary = 'PRIVATE_USER_SECRET_92817';

Map<String, Object?> _current(UiDiagnosticContext recorder) =>
    recorder.snapshot()['current']! as Map<String, Object?>;
List<Map<String, Object?>> _events(UiDiagnosticContext recorder) =>
    recorder.snapshot()['events']! as List<Map<String, Object?>>;

class _Routes extends RouteInformationProvider with ChangeNotifier {
  _Routes(String path) : _value = RouteInformation(uri: Uri.parse(path));
  RouteInformation _value;
  @override
  RouteInformation get value => _value;
  bool get isObserved => hasListeners;
  void move(String path) {
    _value = RouteInformation(uri: Uri.parse(path));
    notifyListeners();
  }
}

Widget _app(UiDiagnosticContext recorder, _Routes routes, Widget child) =>
    MaterialApp(
      builder: (context, routedChild) => UiDiagnosticScope(
        recorder: recorder,
        routeInformation: routes,
        child: routedChild!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  test(
    'routes retain only static categories and never IDs, queries or fragments',
    () {
      const cases = {
        '/search?q=$_canary#$_canary': 'search',
        '/anime/$_canary?title=$_canary': 'anime',
        '/anime/$_canary/credits': 'credits',
        '/anime/$_canary/franchise': 'franchise',
        '/manga/read?chapter=$_canary': 'manga_reader',
        '/pair/$_canary': 'pairing',
        '/settings/accounts?token=$_canary': 'settings',
        '/setup/start': 'setup',
        '/$_canary': 'other',
        'https://$_canary.example/player': 'other',
      };
      final recorder = UiDiagnosticContext();
      for (final entry in cases.entries) {
        final category = UiDiagnosticContext.screenForUri(Uri.parse(entry.key));
        expect(category, entry.value);
        recorder.configure(screen: category);
      }
      expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
    },
  );

  test(
    'manga source controls keep static action but discard dynamic identities',
    () {
      const safe = [
        'manga.section.library',
        'manga.section.browse',
        'manga.section.downloads',
        'manga.section.sources',
        'manga.sources.repository.add',
        'manga.sources.extension.install',
        'manga.sources.catalog.credentials',
      ];
      for (final label in safe) {
        expect(UiDiagnosticContext.controlForLabel(label), label);
      }
      expect(
        UiDiagnosticContext.controlForLabel(
          'manga.sources.repository:$_canary:toggle',
        ),
        'manga.sources.other',
      );
      expect(
        UiDiagnosticContext.controlForLabel(
          'player.watch-party.participant.$_canary',
        ),
        'player.watch_party',
      );
      expect(
        UiDiagnosticContext.controlForLabel('settings.selection.$_canary.14'),
        'settings.selection',
      );
      expect(
        UiDiagnosticContext.controlForLabel('accounts.section.$_canary'),
        'settings.section',
      );
      expect(UiDiagnosticContext.controlForLabel(_canary), 'other');
    },
  );

  test('all public string inputs are allowlisted before retention', () {
    final recorder = UiDiagnosticContext();
    recorder.configure(
      screen: _canary,
      languageCode: _canary,
      playerEngine: _canary,
    );
    recorder.recordFocus(control: _canary, ordinal: 1);
    recorder.recordNavigation(_canary);
    recorder.recordLifecycle(_canary);
    expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
    expect(recorder.crashSummary(), isNot(contains(_canary)));
    expect(_events(recorder).where((e) => e['event'] == 'navigation'), isEmpty);
    expect(_current(recorder)['screen'], 'other');
  });

  test(
    '64-event five-minute ring coalesces repeats and reports discarded context',
    () {
      var now = DateTime(2026, 9, 5);
      final recorder = UiDiagnosticContext(now: () => now);
      for (var index = 0; index < 100; index++) {
        recorder.recordNavigation(index.isEven ? 'up' : 'down');
      }
      recorder.recordNavigation('down');
      expect(_events(recorder), hasLength(64));
      expect(_events(recorder).last['count'], 2);
      var bounds = recorder.snapshot()['bounds']! as Map;
      expect(bounds['discarded'], 36);
      expect(bounds['coalesced'], 1);
      expect(bounds['truncated'], true);
      now = now.add(const Duration(minutes: 6));
      expect(_events(recorder), isEmpty);
      bounds = recorder.snapshot()['bounds']! as Map;
      expect(bounds['discarded'], 100);
    },
  );

  test(
    'snapshot is frozen and caller mutation cannot alter current or events',
    () {
      final recorder = UiDiagnosticContext();
      recorder.configure(screen: 'manga');
      recorder.recordFocus(
        control: 'manga.section.sources',
        ordinal: 2,
        rect: [1, 2, 3, 4],
      );
      final first = recorder.snapshot();
      final serialized = jsonEncode(first);
      recorder.recordFocus(
        control: 'manga.sources.repository.add',
        ordinal: 3,
        rect: [5, 6, 7, 8],
      );
      expect(jsonEncode(first), serialized);
      final oldCurrent = first['current']! as Map;
      final oldFocus = oldCurrent['focus']! as Map;
      (oldFocus['rect']! as List)[0] = 1234;
      final oldEvents = first['events']! as List;
      (oldEvents.last as Map)['control'] = _canary;
      expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
      expect(jsonEncode(recorder.snapshot()), isNot(contains('1234')));
    },
  );

  test(
    'text entry records only entered/exited and no navigation, counts or geometry',
    () {
      final recorder = UiDiagnosticContext();
      recorder.recordTextEntry(true);
      final before = jsonEncode(recorder.snapshot());
      for (var i = 0; i < 100; i++) {
        recorder.recordNavigation('left', repeat: true);
        recorder.recordFocus(
          control: 'button',
          ordinal: i,
          rect: [i.toDouble(), 2, 3, 4],
        );
        recorder.recordScroll(offset: i.toDouble(), maximum: 100, viewport: 50);
        recorder.recordTextEntry(true);
        recorder.recordFrame(buildMs: i.toDouble(), rasterMs: 4);
      }
      // Age can advance, but nothing else is added or counted.
      final after = recorder.snapshot();
      expect(_events(recorder), hasLength(1));
      expect(_events(recorder).single['count'], 1);
      expect(after['bounds'], jsonDecode(before)['bounds']);
      expect(_current(recorder).keys, isNot(contains('focus')));
      expect(_current(recorder).keys, isNot(contains('scroll')));
      expect((after['frames']! as Map)['samples'], 0);
      recorder.recordTextEntry(false);
      recorder.recordNavigation('down');
      expect(_events(recorder).map((e) => e['event']), [
        'text_entry',
        'text_entry',
        'navigation',
      ]);
    },
  );

  test(
    'geometry and frame samples reject nonfinite numbers and cap counts',
    () {
      var now = DateTime(2026, 9, 5);
      final recorder = UiDiagnosticContext(now: () => now);
      recorder.recordViewport(
        width: double.nan,
        height: double.infinity,
        physicalWidth: 1e9,
        physicalHeight: 1e9,
        pixelRatio: -5,
        textScale: 1e9,
      );
      recorder.recordFocus(
        control: 'button',
        ordinal: 1 << 40,
        rect: [0, 0, double.nan, 4],
      );
      recorder.recordScroll(offset: double.nan, maximum: 100, viewport: 50);
      recorder.recordFrame(buildMs: double.nan, rasterMs: 1);
      for (var index = 0; index < 140; index++) {
        recorder.recordFrame(buildMs: index.toDouble(), rasterMs: index * 2);
      }
      final frame = recorder.snapshot()['frames']! as Map;
      expect(frame['samples'], 120);
      expect(frame['build_max_ms'], 139);
      expect(frame['raster_max_ms'], 278);
      expect((_current(recorder)['focus']! as Map)['ordinal'], 1000000);
      expect((_current(recorder)['focus']! as Map).containsKey('rect'), false);
      expect(jsonEncode(recorder.snapshot()), isNot(contains('NaN')));
      now = now.add(const Duration(minutes: 6));
      expect((recorder.snapshot()['frames']! as Map)['samples'], 0);
    },
  );

  test('crash summary always obeys character, line and per-line budgets', () {
    final recorder = UiDiagnosticContext();
    recorder.configure(
      screen: 'manga',
      languageCode: 'hi',
      playerEngine: 'media3',
      media3SurfaceView: true,
    );
    recorder.recordViewport(
      width: 1280,
      height: 720,
      physicalWidth: 3840,
      physicalHeight: 2160,
      pixelRatio: 3,
      textScale: 1.5,
    );
    for (var i = 0; i < 100; i++) {
      recorder.recordFocus(
        control: 'manga.sources.catalog.credentials',
        ordinal: i,
        rect: [100, 200, 300, 400],
        scrollOffset: 8000,
        scrollMaximum: 99999,
      );
      recorder.recordNavigation('down');
    }
    for (final budget in [-1, 0, 1, 90, 600, 1100, 9000]) {
      final summary = recorder.crashSummary(maximum: budget);
      expect(summary.length, lessThanOrEqualTo(budget.clamp(0, 1100)));
      expect(summary.split('\n').length, lessThanOrEqualTo(15));
      expect(summary.split('\n').every((line) => line.length <= 240), true);
    }
    expect(recorder.crashSummary(), contains('ui_snapshot_v1 screen=manga'));
    expect(recorder.crashSummary(), contains('discarded='));
  });

  testWidgets(
    'scope captures safe focus ordinal and rect without changing navigation',
    (tester) async {
      final recorder = UiDiagnosticContext();
      final routes = _Routes('/manga?token=$_canary');
      final first = FocusNode(debugLabel: 'manga.section.sources');
      final second = FocusNode(
        debugLabel: 'manga.sources.repository:$_canary:toggle',
      );
      addTearDown(routes.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        _app(
          recorder,
          routes,
          Row(
            children: [
              TvFocusable(
                focusNode: first,
                autofocus: true,
                onPressed: () {},
                child: const SizedBox(width: 100, height: 50),
              ),
              TvFocusable(
                focusNode: second,
                onPressed: () {},
                child: const SizedBox(width: 100, height: 50),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_current(recorder)['player_engine'], 'media3');
      expect(_current(recorder)['surface_view'], isTrue);
      expect(first.hasFocus, true);
      expect(
        _current(recorder)['focus'],
        isNotNull,
        reason: jsonEncode(recorder.snapshot()),
      );
      final firstFocus = _current(recorder)['focus']! as Map;
      expect(firstFocus['control'], 'manga.section.sources');
      expect(firstFocus['rect'], hasLength(4));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(second.hasFocus, true);
      final secondFocus = _current(recorder)['focus']! as Map;
      expect(secondFocus['control'], 'manga.sources.other');
      expect(secondFocus['ordinal'], isNot(firstFocus['ordinal']));
      first.requestFocus();
      await tester.pumpAndSettle();
      expect(
        (_current(recorder)['focus']! as Map)['ordinal'],
        firstFocus['ordinal'],
      );
      expect(_events(recorder).any((e) => e['key'] == 'right'), true);
      expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
      routes.move('/anime/$_canary?title=$_canary');
      expect(_current(recorder)['screen'], 'anime');
      expect(_current(recorder).containsKey('focus'), false);
      await tester.pumpWidget(const SizedBox.shrink());
      final detached = jsonEncode(recorder.snapshot());
      routes.move('/search?q=$_canary');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_current(recorder)['screen'], 'anime');
      expect(_events(recorder).where((e) => e['key'] == 'down'), isEmpty);
      expect(detached, isNot(contains(_canary)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('printable keyboard characters never become navigation events', (
    tester,
  ) async {
    final recorder = UiDiagnosticContext();
    final routes = _Routes('/manga');
    addTearDown(routes.dispose);
    await tester.pumpWidget(
      _app(recorder, routes, const Focus(autofocus: true, child: SizedBox())),
    );
    await tester.pumpAndSettle();
    final before = _events(recorder).length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
    await tester.pump();
    expect(_events(recorder), hasLength(before));
    expect(_events(recorder).where((e) => e['event'] == 'navigation'), isEmpty);
  });

  testWidgets(
    'scroll metrics and lifecycle are bounded without retaining item data',
    (tester) async {
      final recorder = UiDiagnosticContext();
      final routes = _Routes('/manga');
      final focus = FocusNode(
        debugLabel: 'manga.sources.catalog:$_canary:open',
      );
      final scroll = ScrollController();
      addTearDown(routes.dispose);
      addTearDown(focus.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        _app(
          recorder,
          routes,
          ListView(
            controller: scroll,
            children: [
              TvFocusable(
                autofocus: true,
                focusNode: focus,
                onPressed: () {},
                child: const SizedBox(height: 100, child: Text(_canary)),
              ),
              const SizedBox(height: 2500),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(40);
      await tester.pumpAndSettle();
      final current = _current(recorder);
      expect((current['scroll']! as Map)['offset'], 40);
      expect((current['scroll']! as Map)['axis'], 'vertical');
      expect((current['focus']! as Map)['scroll'], 40);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(_current(recorder)['lifecycle'], 'inactive');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_current(recorder)['lifecycle'], 'resumed');
      expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope updates language/player configuration and replaces route listeners',
    (tester) async {
      final recorder = UiDiagnosticContext();
      final oldRoutes = _Routes('/manga');
      final newRoutes = _Routes('/settings/accounts?private=$_canary');
      addTearDown(oldRoutes.dispose);
      addTearDown(newRoutes.dispose);
      Widget configured(_Routes routes, {bool selecting = false}) =>
          MaterialApp(
            builder: (context, child) => UiDiagnosticScope(
              routeInformation: routes,
              recorder: recorder,
              languageSelection: selecting,
              languageCode: 'de',
              playerEngine: 'media3',
              media3SurfaceView: true,
              child: child!,
            ),
            home: const Scaffold(body: SizedBox()),
          );
      await tester.pumpWidget(configured(oldRoutes));
      await tester.pumpAndSettle();
      expect(oldRoutes.isObserved, true);
      await tester.pumpWidget(configured(newRoutes, selecting: true));
      await tester.pumpAndSettle();
      expect(oldRoutes.isObserved, false);
      expect(newRoutes.isObserved, true);
      expect(_current(recorder)['screen'], 'language_selection');
      expect(_current(recorder)['language'], 'de');
      expect(_current(recorder)['player_engine'], 'media3');
      expect(_current(recorder)['surface_view'], true);
      oldRoutes.move('/search?q=$_canary');
      expect(_current(recorder)['screen'], 'language_selection');
      await tester.pumpWidget(configured(newRoutes));
      await tester.pumpAndSettle();
      expect(_current(recorder)['screen'], 'settings');
      await tester.pumpWidget(const SizedBox());
      expect(newRoutes.isObserved, false);
      expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
    },
  );

  testWidgets(
    'native editable password entry suppresses key, focus and geometry details',
    (tester) async {
      final recorder = UiDiagnosticContext();
      final routes = _Routes('/settings/accounts');
      final editing = FocusNode(debugLabel: _canary);
      final outside = FocusNode(debugLabel: 'manga.section.sources');
      final text = TextEditingController(text: _canary);
      addTearDown(routes.dispose);
      addTearDown(editing.dispose);
      addTearDown(outside.dispose);
      addTearDown(text.dispose);
      await tester.pumpWidget(
        _app(
          recorder,
          routes,
          Column(
            children: [
              TextField(
                focusNode: editing,
                controller: text,
                obscureText: true,
              ),
              TvFocusable(
                focusNode: outside,
                onPressed: () {},
                child: const SizedBox(width: 100, height: 50),
              ),
            ],
          ),
        ),
      );
      editing.requestFocus();
      await tester.pumpAndSettle();
      expect(_current(recorder)['text_entry'], true);
      final before = _events(recorder).length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.pump();
      expect(_events(recorder), hasLength(before));
      expect(_current(recorder).containsKey('focus'), false);
      outside.requestFocus();
      await tester.pumpAndSettle();
      expect(
        _current(recorder)['text_entry'],
        false,
        reason: jsonEncode(recorder.snapshot()),
      );
      expect(
        (_current(recorder)['focus']! as Map)['control'],
        'manga.section.sources',
      );
      expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
      expect(tester.takeException(), isNull);
    },
  );

  for (final numeric in [false, true]) {
    testWidgets(
      'custom ${numeric ? 'PIN' : 'text'} keyboard suppresses focus positions and navigation counts',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final recorder = UiDiagnosticContext();
        final routes = _Routes('/setup');
        addTearDown(routes.dispose);
        await tester.pumpWidget(
          _app(
            recorder,
            routes,
            TvKeyboardDialog(
              title: _canary,
              initialValue: numeric ? '92817' : _canary,
              obscureText: true,
              numericOnly: numeric,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(_current(recorder)['text_entry'], true);
        final before = _events(recorder).length;
        for (final key in [
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
        }
        expect(_events(recorder), hasLength(before));
        expect(
          _events(
            recorder,
          ).where((e) => e['event'] == 'focus' || e['event'] == 'navigation'),
          isEmpty,
        );
        expect(_current(recorder).containsKey('focus'), false);
        expect(jsonEncode(recorder.snapshot()), isNot(contains(_canary)));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
