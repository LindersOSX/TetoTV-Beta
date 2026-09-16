import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/presentation/manga_library_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'owner.library.test';
final _date = DateTime.utc(2026, 9, 5);

MangaLibraryEntry _entry(
  String id, {
  String? title,
  String category = '',
  MangaLibraryStatus status = MangaLibraryStatus.planToRead,
  int updates = 0,
  int added = 0,
}) => MangaLibraryEntry(
  ownerKey: _owner,
  sourceId: 'source.test',
  entryId: id,
  title: title ?? id,
  metadata: const {'kind': 'seanime-manga-extension'},
  updatedAt: _date.add(Duration(minutes: added)),
  category: category,
  status: status,
  newChapterCount: updates,
);

final _entries = [
  _entry(
    'alpha',
    title: 'Alpha manga',
    category: 'Favorites',
    status: MangaLibraryStatus.reading,
    updates: 2,
    added: 1,
  ),
  _entry(
    'beta',
    title: 'Beta manga',
    category: 'Favorites',
    status: MangaLibraryStatus.completed,
    added: 3,
  ),
  _entry(
    'gamma',
    title: 'Gamma manga',
    category: 'Weekend',
    updates: 5,
    added: 2,
  ),
];

MangaReadingProgress _progress(String id, {int minute = 0}) =>
    MangaReadingProgress(
      ownerKey: _owner,
      sourceId: 'source.test',
      entryId: id,
      chapterId: 'chapter.5',
      chapterNumber: 5,
      pageIndex: 6,
      pageOffset: .4,
      pageCount: 12,
      completed: false,
      updatedAt: _date.add(Duration(minutes: minute)),
    );

MangaDownloadJob _download(String id, MangaDownloadJobStatus status) =>
    MangaDownloadJob(
      id: 'download.$id',
      sourceId: 'source.test',
      entryId: id,
      chapterId: 'chapter.5',
      seriesTitle: id,
      chapterLabel: 'Chapter 5',
      status: status,
      relativeDirectory: 'manga/download.$id',
      completedPages: 12,
      receivedBytes: 100,
      pageCount: 12,
      queuePosition: 0,
      retryCount: 0,
      createdAt: _date,
      updatedAt: _date,
    );

void main() {
  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'false',
    }),
  );

  for (final configuration in [
    (size: const Size(320, 568), scale: 1.3, tv: false),
    (size: const Size(390, 844), scale: 1.5, tv: false),
    (size: const Size(1280, 720), scale: 1.4, tv: true),
  ]) {
    testWidgets(
      'library fits ${configuration.size.width.toInt()}px with enlarged text and a long category',
      (tester) async {
        final longCategory = List.filled(8, 'Favorites ').join().trim();
        await _pump(
          tester,
          size: configuration.size,
          scale: configuration.scale,
          television: configuration.tv,
          entries: [
            _entry(
              'alpha',
              title:
                  'A long manga title that must remain readable without displacing the chapter actions',
              category: longCategory,
              updates: 27,
            ),
          ],
          store: _HistoryStore()..rows = [_progress('alpha')],
        );
        expect(tester.takeException(), isNull);
        await _choose(tester, 'Category', longCategory);
        expect(tester.takeException(), isNull);
        await _reveal(tester, _action('Chapters'));
        expect(
          tester
              .getRect(_action('Chapters'))
              .overlaps(Offset.zero & configuration.size),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'phone search uses the device keyboard and filters case-insensitively',
    (tester) async {
      await _pump(tester, size: const Size(390, 844), television: false);
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(field, '  bETA  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_row('beta'), findsOneWidget);
      expect(_row('alpha'), findsNothing);
      expect(_row('gamma'), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'category and status selections combine without changing source entries',
    (tester) async {
      await _pump(tester);
      await _choose(tester, 'Category', 'Favorites');
      await _choose(tester, 'Status', 'Completed');
      expect(_row('beta'), findsOneWidget);
      expect(_row('alpha'), findsNothing);
      expect(_row('gamma'), findsNothing);
      await _choose(tester, 'Status', 'All statuses');
      expect(_row('alpha'), findsOneWidget);
      expect(_entries.map((entry) => entry.entryId), [
        'alpha',
        'beta',
        'gamma',
      ]);
    },
  );

  testWidgets(
    'download and update filters combine and only completed downloads qualify',
    (tester) async {
      await _pump(
        tester,
        downloads: [
          _download('alpha', MangaDownloadJobStatus.completed),
          _download('beta', MangaDownloadJobStatus.completed),
          _download('gamma', MangaDownloadJobStatus.downloading),
        ],
      );
      await _tap(tester, find.widgetWithText(FilterChip, 'Downloaded'));
      expect(_row('alpha'), findsOneWidget);
      expect(_row('beta'), findsOneWidget);
      expect(_row('gamma'), findsNothing);
      await _tap(tester, find.widgetWithText(FilterChip, 'New chapters'));
      expect(_row('alpha'), findsOneWidget);
      expect(_row('beta'), findsNothing);
      await _tap(tester, find.widgetWithText(FilterChip, 'Downloaded'));
      expect(_row('gamma'), findsOneWidget);
    },
  );

  testWidgets(
    'library sort menu uses title, profile history, added date, and update count',
    (tester) async {
      final store = _HistoryStore()
        ..rows = [
          _progress('gamma', minute: 10),
          _progress('alpha', minute: 5),
        ];
      await _pump(tester, store: store);
      expect(_visibleRowIds(tester).first, 'alpha');
      await _choose(tester, 'Sort', 'Recently read');
      expect(_visibleRowIds(tester).first, 'gamma');
      await _choose(tester, 'Sort', 'Recently added');
      expect(_visibleRowIds(tester).first, 'beta');
      await _choose(tester, 'Sort', 'New chapters');
      expect(_visibleRowIds(tester).first, 'gamma');
      await _choose(tester, 'Sort', 'Title');
      expect(_visibleRowIds(tester).first, 'alpha');
      expect(store.requestedOwners, everyElement(_owner));
    },
  );

  testWidgets(
    'history loading and errors never offer an active Start reading fallback',
    (tester) async {
      final pending = Completer<List<MangaReadingProgress>>();
      final store = _HistoryStore()..next = () => pending.future;
      await _pump(tester, store: store, settle: false);
      await tester.pump();
      await tester.pump();
      expect(_actionWidget(tester, 'Start reading').onPressed, isNull);
      pending.completeError(StateError('private-account-id'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Reading history could not be loaded. Retry before continuing.',
        ),
        findsOneWidget,
      );
      expect(_actionWidget(tester, 'Start reading').onPressed, isNull);
      expect(find.textContaining('private-account-id'), findsNothing);
      store.next = null;
      store.rows = [_progress('alpha')];
      await _tap(tester, _action('Retry history'));
      expect(_actionWidget(tester, 'Continue reading').onPressed, isNotNull);
      expect(find.text('Last read: chapter 5.0, page 7'), findsOneWidget);
    },
  );

  testWidgets(
    'chapter-update check is single-flight and retryable after a safe failure',
    (tester) async {
      var checks = 0;
      final pending = Completer<String>();
      await _pump(
        tester,
        onCheck: () =>
            ++checks == 1 ? pending.future : Future.value('Checked 3 titles'),
      );
      await _tap(tester, _action('Check chapter updates'), settle: false);
      expect(_actionWidget(tester, 'Checking…').onPressed, isNull);
      await tester.tap(_action('Checking…'));
      await tester.pump();
      expect(checks, 1);
      pending.completeError(StateError('https://private.invalid/access-token'));
      await tester.pumpAndSettle();
      expect(
        find.text('Chapter updates could not be checked. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('private.invalid'), findsNothing);
      await _tap(tester, _action('Check chapter updates'));
      expect(checks, 2);
      expect(find.text('Checked 3 titles'), findsOneWidget);
    },
  );

  testWidgets(
    'backup is single-flight, catches safe errors, and refreshes history after retry',
    (tester) async {
      var backups = 0;
      final pending = Completer<void>();
      final store = _HistoryStore();
      await _pump(
        tester,
        store: store,
        onBackup: () async {
          if (++backups == 1) return pending.future;
          store.rows = [_progress('alpha')];
        },
      );
      await _tap(tester, _action('Backup & restore'), settle: false);
      final backup = find.byWidgetPredicate(
        (widget) =>
            widget is MangaLibraryAction &&
            widget.icon == Icons.enhanced_encryption_outlined,
      );
      expect(tester.widget<MangaLibraryAction>(backup).onPressed, isNull);
      await tester.tap(backup);
      await tester.pump();
      expect(backups, 1);
      pending.completeError(StateError('private-backup-password'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('private-backup-password'), findsNothing);
      expect(find.textContaining('Try again.'), findsOneWidget);
      await _tap(tester, _action('Backup & restore'));
      expect(backups, 2);
      expect(_action('Continue reading'), findsOneWidget);
      expect(store.requestedOwners.length, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'pending check or backup completion after disposal causes no late UI work',
    (tester) async {
      final check = Completer<String>();
      final backup = Completer<void>();
      await _pump(
        tester,
        onCheck: () => check.future,
        onBackup: () => backup.future,
      );
      await _tap(tester, _action('Check chapter updates'), settle: false);
      await _tap(tester, _action('Backup & restore'), settle: false);
      await tester.pumpWidget(const SizedBox.shrink());
      check.complete('Late result');
      backup.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('library row callbacks retain the selected entry identity', (
    tester,
  ) async {
    final events = <String>[];
    await _pump(
      tester,
      entries: [_entries.first],
      store: _HistoryStore()..rows = [_progress('alpha')],
      onContinue: (entry) => events.add('continue:${entry.entryId}'),
      onOpen: (entry) => events.add('chapters:${entry.entryId}'),
      onRemove: (entry) => events.add('remove:${entry.entryId}'),
      onMigrate: (entry) => events.add('migrate:${entry.entryId}'),
    );
    for (final label in [
      'Continue reading',
      'Chapters',
      'Change source',
      'Remove',
    ]) {
      await _tap(tester, _action(label));
    }
    expect(events, [
      'continue:alpha',
      'chapters:alpha',
      'migrate:alpha',
      'remove:alpha',
    ]);
  });

  testWidgets(
    'TV remote reaches library actions and keeps focus visible while scrolling',
    (tester) async {
      var continued = false;
      final searchFocus = FocusNode(debugLabel: 'library test search');
      await _pump(
        tester,
        television: true,
        size: const Size(1280, 720),
        scale: 1.3,
        firstFocus: searchFocus,
        entries: List.generate(
          12,
          (i) => _entry('entry${i.toString().padLeft(2, '0')}'),
        ),
        onContinue: (_) => continued = true,
      );
      searchFocus.requestFocus();
      await tester.pumpAndSettle();
      var reachedRow = false;
      final traversal = <String>[];
      for (var i = 0; i < 25; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        final primary = FocusManager.instance.primaryFocus;
        final action = primary?.context
            ?.findAncestorWidgetOfExactType<MangaLibraryAction>();
        traversal.add('${primary?.debugLabel}: ${action?.label}');
        if (const [
          'Start reading',
          'Chapters',
          'Organize',
          'Remove',
        ].contains(action?.label)) {
          reachedRow = true;
          break;
        }
      }
      expect(
        reachedRow,
        isTrue,
        reason:
            'D-pad Down must leave Search and reach the library rows. $traversal',
      );
      // The header can enter whichever row control is vertically aligned.
      // Horizontal movement must then reach the primary reading action.
      for (var i = 0; i < 5; i++) {
        final action = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<MangaLibraryAction>();
        if (action?.label == 'Start reading') break;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(continued, isTrue);
      final positionBefore = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      final primaryContext = FocusManager.instance.primaryFocus!.context!;
      final rect = tester.getRect(find.byWidget(primaryContext.widget));
      expect(rect.overlaps(const Rect.fromLTWH(0, 0, 1280, 720)), isTrue);
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        greaterThan(positionBefore),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote filter strip reaches every control without opening dropdowns on Down',
    (tester) async {
      final focus = FocusNode(debugLabel: 'filter test search');
      var exited = false;
      await _pump(tester, firstFocus: focus, onExitUp: () => exited = true);
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'manga.library.sort',
      );
      for (final next in [
        'category',
        'status',
        'updates',
        'downloaded',
        'check',
        'backup',
        'sort',
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'manga.library.$next',
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'manga.library.first.entry',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'manga.library.sort',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButton<MangaLibrarySort>>(_choice('Sort')).value,
        MangaLibrarySort.recentlyRead,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(exited, isTrue);
    },
  );

  testWidgets('remote can reach history Retry and filtered-empty Browse', (
    tester,
  ) async {
    final store = _HistoryStore()
      ..next = () async => throw StateError('private');
    final focus = FocusNode(debugLabel: 'retry test search');
    await _pump(tester, firstFocus: focus, store: store, entries: []);
    focus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'manga.library.retry',
    );
    store.next = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Retry history'), findsNothing);
    focus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'manga.library.browse',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'manga.library.sort',
    );
  });

  testWidgets(
    'TV search opens the visible remote keyboard and Back returns to the library',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'input_use_built_in_keyboard': 'true',
      });
      final focus = FocusNode(debugLabel: 'library keyboard search');
      await _pump(
        tester,
        firstFocus: focus,
        television: true,
        size: const Size(1280, 720),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(TvKeyboardDialog), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('tv-keyboard-panel')))
            .overlaps(const Rect.fromLTWH(0, 0, 1280, 720)),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TvKeyboardDialog), findsNothing);
      expect(find.byType(MangaLibraryView), findsOneWidget);
      expect(focus.hasFocus, isTrue);
    },
  );

  testWidgets(
    'empty and filtered-empty libraries retain a working Browse action',
    (tester) async {
      var browsed = 0;
      await _pump(tester, entries: [], onBrowse: () => browsed++);
      expect(find.text('Your manga library is empty'), findsOneWidget);
      await _tap(tester, _action('Browse manga'));
      expect(browsed, 1);
    },
  );
}

Finder _row(String id) => find.byKey(ValueKey('manga-library-source.test-$id'));
Finder _action(String label) => find.byWidgetPredicate(
  (widget) => widget is MangaLibraryAction && widget.label == label,
);
MangaLibraryAction _actionWidget(WidgetTester tester, String label) =>
    tester.widget<MangaLibraryAction>(_action(label).first);

List<String> _visibleRowIds(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((widget) => widget.key)
    .whereType<ValueKey<String>>()
    .where((key) => key.value.startsWith('manga-library-source.test-'))
    .map((key) => key.value.substring('manga-library-source.test-'.length))
    .toList();

Finder _choice(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  ),
  matching: find.byWidgetPredicate((widget) => widget is DropdownButton),
);

Future<void> _choose(WidgetTester tester, String label, String value) async {
  final dropdown = _choice(label);
  await _tap(tester, dropdown);
  final option = find.text(value).last;
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      220,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('manga-library-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(
  WidgetTester tester,
  Finder target, {
  bool settle = true,
}) async {
  await _reveal(tester, target);
  await tester.tap(target);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(1280, 720),
  double scale = 1,
  bool television = true,
  List<MangaLibraryEntry>? entries,
  List<MangaDownloadJob> downloads = const [],
  _HistoryStore? store,
  FocusNode? firstFocus,
  bool settle = true,
  VoidCallback? onBrowse,
  VoidCallback? onExitUp,
  ValueChanged<MangaLibraryEntry>? onOpen,
  ValueChanged<MangaLibraryEntry>? onContinue,
  ValueChanged<MangaLibraryEntry>? onRemove,
  ValueChanged<MangaLibraryEntry>? onMigrate,
  Future<String> Function()? onCheck,
  Future<void> Function()? onBackup,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final focus = firstFocus ?? FocusNode(debugLabel: 'library first');
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mangaOwnerKeyProvider.overrideWith((_) async => _owner),
        mangaStoreProvider.overrideWithValue(store ?? _HistoryStore()),
        isTelevisionProvider.overrideWithValue(television),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: TvShortcuts(child: child!),
        ),
        home: Scaffold(
          body: MangaLibraryView(
            state: MangaHubState(
              library: entries ?? _entries,
              downloads: downloads,
            ),
            firstFocusNode: focus,
            onBrowse: onBrowse ?? () {},
            onExitUp: onExitUp,
            onOpen: onOpen ?? (_) {},
            onContinue: onContinue ?? (_) {},
            onRemove: onRemove ?? (_) {},
            onMigrate: onMigrate,
            onBackup: onBackup ?? () async {},
            onCheckUpdates: onCheck ?? () async => 'Checked',
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

class _HistoryStore extends MangaStore {
  _HistoryStore()
    : super(
        databaseProvider: () async =>
            throw StateError('Widget tests must not use the real database.'),
      );
  List<MangaReadingProgress> rows = [];
  Future<List<MangaReadingProgress>> Function()? next;
  final requestedOwners = <String>[];

  @override
  Future<List<MangaReadingProgress>> latestProgressForOwner(
    String ownerKey,
  ) async {
    requestedOwners.add(ownerKey);
    return next == null ? rows : next!();
  }
}
