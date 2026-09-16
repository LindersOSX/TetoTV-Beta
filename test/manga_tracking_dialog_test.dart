import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/application/manga_tracking_controller.dart';
import 'package:anime_tv/features/manga/presentation/manga_tracking_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tracking extends Fake implements MangaTrackingController {
  final links = <MangaTrackingLink>[];
  final pending = <MangaTrackingPending>[];
  final searches = <TrackingProvider>[];
  int confirmations = 0;
  int unlinks = 0;
  int retries = 0;
  Object? searchError;
  Completer<List<MangaTrackingSearchResult>>? searchGate;
  @override
  Future<List<MangaTrackingLink>> currentLinks(
    MangaTrackingTitleKey title,
  ) async => List.of(links);
  @override
  Future<List<MangaTrackingPending>> pendingFor(
    MangaTrackingTitleKey title,
  ) async => List.of(pending);
  @override
  Future<List<MangaTrackingSearchResult>> searchCatalog(
    TrackingProvider provider,
    String query,
  ) async {
    searches.add(provider);
    if (searchError case final error?) throw error;
    return searchGate?.future ??
        [
          MangaTrackingSearchResult(
            provider: provider,
            mediaId: 42,
            title: 'Tracker Manga',
            format: 'MANGA',
            totalChapters: 100,
          ),
        ];
  }

  @override
  Future<MangaTrackingLink> linkManga(
    MangaTrackingTitleKey title,
    MangaTrackingSearchResult selection, {
    required bool confirmed,
  }) async {
    expect(confirmed, true);
    confirmations++;
    final link = MangaTrackingLink(
      titleKey: title,
      record: selection,
      profileId: 'slot',
      accountId: '77',
      bindingId: 'binding',
      linkedAt: DateTime.utc(2026),
    );
    links.add(link);
    return link;
  }

  @override
  Future<void> unlink(
    MangaTrackingTitleKey title,
    TrackingProvider provider,
  ) async {
    unlinks++;
    links.removeWhere((row) => row.provider == provider);
    pending.clear();
  }

  @override
  Future<void> retryPending({
    bool manual = false,
    MangaTrackingTitleKey? title,
    TrackingProvider? provider,
  }) async {
    expect(manual, true);
    expect(title?.publicationId, 'title');
    expect(provider, TrackingProvider.anilist);
    retries++;
    pending.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    }),
  );
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> show(
    WidgetTester tester,
    _Tracking controller,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: MangaTrackingDialog(
              controller: controller,
              titleKey: MangaTrackingTitleKey(
                ownerKey: 'owner',
                sourceId: 'seanime',
                publicationId: 'title',
              ),
              title: 'Local Manga',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final finder = find.text(label).first;
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(360, 700), const Size(1920, 1080)]) {
    testWidgets('explicit search, preview and confirmation work at $size', (
      tester,
    ) async {
      final controller = _Tracking();
      await show(tester, controller, size);
      expect(controller.searches, isEmpty);
      expect(find.text('SIMKL'), findsNothing);
      expect(find.text('Confirm and link manga'), findsNothing);
      await tap(tester, 'MAL');
      await tap(tester, 'Search catalog');
      expect(controller.searches, [TrackingProvider.myAnimeList]);
      expect(controller.confirmations, 0);
      await tap(tester, 'Tracker Manga');
      expect(find.text('Confirm and link manga'), findsOneWidget);
      expect(controller.confirmations, 0);
      await tap(tester, 'Confirm and link manga');
      expect(controller.confirmations, 1);
      expect(find.text('Linked manga'), findsOneWidget);
      expect(
        find.text('Manga linked. Future completed chapters can sync.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'remote select activates search and provider switch clears preview',
    (tester) async {
      final controller = _Tracking();
      await show(tester, controller, const Size(1280, 720));
      final search = find.text('Search catalog');
      await tester.ensureVisible(search);
      await tester.pumpAndSettle();
      Focus.of(tester.element(search)).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(controller.searches, [TrackingProvider.anilist]);
      await tap(tester, 'Tracker Manga');
      await tap(tester, 'MAL');
      expect(find.text('Confirm and link manga'), findsNothing);
      expect(controller.confirmations, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending error can be retried and unlink is local-only', (
    tester,
  ) async {
    final controller = _Tracking();
    final title = MangaTrackingTitleKey(
      ownerKey: 'owner',
      sourceId: 'seanime',
      publicationId: 'title',
    );
    await controller.linkManga(
      title,
      MangaTrackingSearchResult(
        provider: TrackingProvider.anilist,
        mediaId: 42,
        title: 'Tracker Manga',
      ),
      confirmed: true,
    );
    controller.pending.add(
      MangaTrackingPending(
        bindingId: 'binding',
        completedChapters: 8,
        attempts: 5,
        needsAttention: true,
        nextAttemptAt: DateTime.utc(2026),
        lastError: 'Reconnect the linked manga tracking account in Settings.',
      ),
    );
    await show(tester, controller, const Size(360, 700));
    expect(find.text('Chapter 8 waiting to sync.'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    await tap(tester, 'Retry pending updates');
    expect(controller.retries, 1);
    expect(find.text('Manga tracking is up to date.'), findsOneWidget);
    await tap(tester, 'Unlink manga');
    expect(controller.unlinks, 1);
    expect(
      find.text('Manga unlinked. Your tracker list entry was not removed.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'raw transport errors are hidden and sparse numbering warning is visible',
    (tester) async {
      final controller = _Tracking()
        ..searchError = Exception('Authorization: NEVER-DISPLAY');
      await show(tester, controller, const Size(360, 700));
      await tap(tester, 'Search catalog');
      expect(
        find.text('Manga tracking could not be updated. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('NEVER-DISPLAY'), findsNothing);
      expect(
        find.text(
          'For specials, gaps, or numbering that restarts by volume, review your chapter count on the tracker.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late search completion after dialog disposal has no state update',
    (tester) async {
      final controller = _Tracking()
        ..searchGate = Completer<List<MangaTrackingSearchResult>>();
      await show(tester, controller, const Size(1280, 720));
      final input = tester.widget<TvTextInput>(find.byType(TvTextInput));
      input.onSubmitted!('Manga');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      controller.searchGate!.complete([]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
