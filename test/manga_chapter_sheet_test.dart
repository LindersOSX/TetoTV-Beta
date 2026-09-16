import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_chapter_sheet.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final _title = MangaExtensionTitle(
  providerId: 'provider',
  providerName: 'Source',
  id: 'title',
  title: 'Example manga',
  language: 'en',
);
MangaExtensionChapter _chapter(int number) => MangaExtensionChapter(
  id: 'c$number',
  title: 'Chapter $number',
  chapter: '$number',
  index: number,
);
MangaReadingProgress _progress(
  int number, {
  bool completed = false,
  bool bookmarked = false,
  int? pageCount,
  int updated = 1,
}) => MangaReadingProgress(
  ownerKey: 'owner.test',
  sourceId: 'source',
  entryId: 'entry',
  chapterId: mangaExtensionChapterId(_title.providerId, _title.id, 'c$number'),
  chapterNumber: number.toDouble(),
  pageIndex: pageCount == null ? 0 : 2,
  pageOffset: 0,
  pageCount: pageCount,
  completed: completed,
  bookmarked: bookmarked,
  updatedAt: DateTime.utc(2026, 9, 5, 0, updated),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('chapter panel fits narrow touch screens with scaled text', (
    tester,
  ) async {
    await _pump(tester, size: const Size(320, 568), textScale: 1.4);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byKey(const ValueKey('manga-chapter-scroll')),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('manga-chapter-read-c1')), findsOneWidget);
  });

  testWidgets(
    'sort and filters preserve full reading order for chapter callbacks',
    (tester) async {
      final controller = _FakeController()
        ..rows = [_progress(2, completed: true)];
      List<MangaExtensionChapter>? received;
      MangaExtensionChapter? selected;
      await _pump(
        tester,
        controller: controller,
        chapters: [_chapter(3), _chapter(1), _chapter(2)],
        onRead: (chapter, ordered) {
          selected = chapter;
          received = ordered;
        },
      );
      await _tap(tester, 'manga-chapter-sort');
      await _tap(tester, 'manga-chapter-unread-filter');
      expect(find.byKey(const ValueKey('manga-chapter-row-c2')), findsNothing);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('manga-chapter-row-c3')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('manga-chapter-row-c1')))
              .dy,
        ),
      );
      await _tap(tester, 'manga-chapter-read-c3');
      expect(selected?.id, 'c3');
      expect(received!.map((chapter) => chapter.id), ['c1', 'c2', 'c3']);
      expect(() => received!.clear(), throwsUnsupportedError);
    },
  );

  testWidgets(
    'Continue selects latest unfinished reading, not a newer bookmark',
    (tester) async {
      final controller = _FakeController()
        ..rows = [
          _progress(1, pageCount: 10, updated: 2),
          _progress(2, pageCount: 10, updated: 4),
          _progress(3, bookmarked: true, updated: 6),
        ];
      String? selected;
      await _pump(
        tester,
        controller: controller,
        onRead: (chapter, _) => selected = chapter.id,
      );
      await _tap(tester, 'manga-chapter-continue');
      expect(selected, 'c2');
    },
  );

  testWidgets(
    'Continue advances from a completed last-read chapter to next unread',
    (tester) async {
      final last = _progress(1, completed: true);
      final controller = _FakeController()
        ..rows = [last]
        ..last = last;
      String? selected;
      await _pump(
        tester,
        controller: controller,
        onRead: (chapter, _) => selected = chapter.id,
      );
      await _tap(tester, 'manga-chapter-continue');
      expect(selected, 'c2');
    },
  );

  testWidgets('read and bookmark controls persist and update filters', (
    tester,
  ) async {
    final controller = _FakeController();
    await _pump(tester, controller: controller);
    await _tap(tester, 'manga-chapter-status-c1');
    expect(controller.readWrites, [('c1', true)]);
    await _tap(tester, 'manga-chapter-bookmark-c1');
    expect(controller.bookmarkWrites, [('c1', true)]);
    await _tap(tester, 'manga-chapter-bookmarks-filter');
    expect(find.byKey(const ValueKey('manga-chapter-row-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-chapter-row-c2')), findsNothing);
    expect(find.text('Bookmarked'), findsOneWidget);
    await _tap(tester, 'manga-chapter-status-c1');
    expect(controller.readWrites.last, ('c1', false));
  });

  testWidgets('failed chapter loads show safe Retry and can recover', (
    tester,
  ) async {
    var loads = 0;
    await _pump(
      tester,
      load: () async {
        if (++loads == 1) {
          throw StateError('secret=https://private.invalid/token');
        }
        return [_chapter(1)];
      },
    );
    expect(find.textContaining('private.invalid'), findsNothing);
    await _tap(tester, 'manga-chapter-load-retry');
    expect(loads, 2);
    expect(find.byKey(const ValueKey('manga-chapter-row-c1')), findsOneWidget);
  });

  testWidgets(
    'unknown history disables progress filters and batch until retry',
    (tester) async {
      final controller = _FakeController()..historyFails = true;
      final batches = <List<MangaExtensionChapter>>[];
      await _pump(tester, controller: controller, onDownloadMany: batches.add);
      expect(_action(tester, 'manga-chapter-download-5').enabled, isFalse);
      expect(_action(tester, 'manga-chapter-unread-filter').enabled, isFalse);
      expect(
        find.byKey(const ValueKey('manga-chapter-continue')),
        findsNothing,
      );
      controller.historyFails = false;
      await _tap(tester, 'manga-chapter-history-retry');
      expect(_action(tester, 'manga-chapter-download-5').enabled, isTrue);
      await _tap(tester, 'manga-chapter-download-5');
      expect(batches.single.length, 3);
    },
  );

  testWidgets(
    'library request is serialized and failure is safely recoverable',
    (tester) async {
      final first = Completer<bool>();
      var writes = 0;
      await _pump(
        tester,
        onLibrary: () => ++writes == 1 ? first.future : Future.value(true),
      );
      await tester.tap(find.byKey(const ValueKey('manga-chapter-library')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('manga-chapter-library')));
      expect(writes, 1);
      first.completeError(StateError('private-token'));
      await tester.pumpAndSettle();
      expect(
        find.text('Your library could not be updated. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('private-token'), findsNothing);
      await _tap(tester, 'manga-chapter-library');
      expect(find.text('Remove from library'), findsOneWidget);
    },
  );

  testWidgets(
    'explicit next 5 or 10 downloads exclude read chapters and ignore display filters',
    (tester) async {
      final controller = _FakeController()
        ..rows = [_progress(2, completed: true), _progress(4, completed: true)];
      final batches = <List<MangaExtensionChapter>>[];
      await _pump(
        tester,
        controller: controller,
        chapters: List.generate(15, (i) => _chapter(i + 1)),
        onDownloadMany: batches.add,
      );
      await _tap(tester, 'manga-chapter-sort');
      await _tap(tester, 'manga-chapter-bookmarks-filter');
      await _tap(tester, 'manga-chapter-download-5');
      expect(batches[0].map((chapter) => chapter.id), [
        'c1',
        'c3',
        'c5',
        'c6',
        'c7',
      ]);
      await _tap(tester, 'manga-chapter-download-10');
      expect(batches[1].length, 10);
      expect(
        batches[1].any((chapter) => chapter.id == 'c2' || chapter.id == 'c4'),
        isFalse,
      );
    },
  );

  testWidgets(
    'TV arrows reach actions, select reads, and Back closes only chapter dialog',
    (tester) async {
      String? selected;
      await _pump(
        tester,
        dialog: true,
        onRead: (chapter, _) => selected = chapter.id,
      );
      final focus = tester
          .widget<FocusableActionDetector>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('manga-chapter-continue')),
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          )
          .focusNode!;
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 'c1');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(MangaChapterSheet), findsNothing);
      expect(find.text('Underlying manga library'), findsOneWidget);
    },
  );

  testWidgets('all-read chapters disable Continue and unread downloads', (
    tester,
  ) async {
    final controller = _FakeController()
      ..rows = [for (var n = 1; n <= 3; n++) _progress(n, completed: true)];
    await _pump(tester, controller: controller);
    expect(find.text('All chapters read'), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-chapter-continue')), findsNothing);
    expect(_action(tester, 'manga-chapter-download-5').enabled, isFalse);
    await _tap(tester, 'manga-chapter-unread-filter');
    expect(find.text('No chapters match these filters.'), findsOneWidget);
  });

  testWidgets(
    'profile changes prevent old-sheet callbacks from mutating the new profile',
    (tester) async {
      var reads = 0;
      var libraries = 0;
      await _pump(
        tester,
        onRead: (_, _) {
          reads++;
        },
        onLibrary: () async {
          libraries++;
          return true;
        },
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MangaChapterSheet)),
      );
      container.invalidate(mangaExtensionControllerProvider);
      container.read(mangaExtensionControllerProvider.notifier);
      await _tap(tester, 'manga-chapter-continue');
      await _tap(tester, 'manga-chapter-library');
      expect(reads, 0);
      expect(libraries, 0);
      expect(
        find.text('Profile changed. Close and reopen this manga.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'read and chapter status errors preserve existing state without raw details',
    (tester) async {
      final controller = _FakeController()..statusFails = true;
      await _pump(
        tester,
        controller: controller,
        onRead: (_, _) async => throw StateError('secret-source-url'),
      );
      await _tap(tester, 'manga-chapter-continue');
      expect(
        find.text(
          'This chapter could not be opened. Check the source and try again.',
        ),
        findsOneWidget,
      );
      await _tap(tester, 'manga-chapter-status-c1');
      expect(
        find.text('Chapter status could not be saved. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('secret-source-url'), findsNothing);
      expect(controller.rows, isEmpty);
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  _FakeController? controller,
  List<MangaExtensionChapter>? chapters,
  Future<List<MangaExtensionChapter>> Function()? load,
  FutureOr<void> Function(MangaExtensionChapter, List<MangaExtensionChapter>)?
  onRead,
  FutureOr<void> Function(List<MangaExtensionChapter>)? onDownloadMany,
  Future<bool> Function()? onLibrary,
  Size size = const Size(1280, 1000),
  double textScale = 1,
  bool dialog = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final sheet = MangaChapterSheet(
    title: _title,
    initiallyInLibrary: false,
    loadChapters:
        load ?? () async => chapters ?? [_chapter(1), _chapter(2), _chapter(3)],
    onRead: onRead ?? (_, _) {},
    onDownload: (_) {},
    onDownloadMany: onDownloadMany ?? (_) {},
    onLibrary: onLibrary ?? () async => true,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mangaExtensionControllerProvider.overrideWith(
          (_) => controller ?? _FakeController(),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: dialog
              ? Builder(
                  builder: (context) => Column(
                    children: [
                      const Text('Underlying manga library'),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => sheet,
                        ),
                        child: const Text('Open chapters'),
                      ),
                    ],
                  ),
                )
              : sheet,
        ),
      ),
    ),
  );
  if (dialog) {
    await tester.tap(find.text('Open chapters'));
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

TvFocusable _action(WidgetTester tester, String key) =>
    tester.widget<TvFocusable>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TvFocusable),
      ),
    );

class _FakeController extends MangaExtensionController {
  _FakeController()
    : super(
        addonStore: AddonStore(TetoTvDatabase.instance),
        mangaStore: MangaStore(),
        identityStore: ProtectedMangaExtensionIdentityStore(
          const FlutterSecureStorage(),
        ),
        ownerKey: () async => 'owner.test',
      );
  List<MangaReadingProgress> rows = [];
  MangaReadingProgress? last;
  bool historyFails = false;
  bool statusFails = false;
  final readWrites = <(String, bool)>[];
  final bookmarkWrites = <(String, bool)>[];

  @override
  Future<List<MangaReadingProgress>> chapterHistory(
    MangaExtensionTitle title,
  ) async {
    if (historyFails) throw StateError('secret-source-url');
    return rows;
  }

  @override
  Future<MangaReadingProgress?> lastRead(MangaExtensionTitle title) async =>
      last;
  @override
  Future<void> markRead(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    required bool completed,
  }) async {
    if (statusFails) throw StateError('secret-source-url');
    readWrites.add((chapter.id, completed));
    _update(chapter, completed: completed);
  }

  @override
  Future<void> bookmark(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    required bool bookmarked,
  }) async {
    if (statusFails) throw StateError('secret-source-url');
    bookmarkWrites.add((chapter.id, bookmarked));
    _update(chapter, bookmarked: bookmarked);
  }

  void _update(
    MangaExtensionChapter chapter, {
    bool? completed,
    bool? bookmarked,
  }) {
    final key = mangaExtensionChapterId(title.providerId, title.id, chapter.id);
    final old = rows.where((row) => row.chapterId == key).firstOrNull;
    rows = [
      ...rows.where((row) => row.chapterId != key),
      _progress(
        chapter.chapterNumber!.toInt(),
        completed: completed ?? old?.completed ?? false,
        bookmarked: bookmarked ?? old?.bookmarked ?? false,
      ),
    ];
  }

  MangaExtensionTitle get title => _title;
}
