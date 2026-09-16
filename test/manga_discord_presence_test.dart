import 'dart:async';

import 'package:anime_tv/features/manga/application/manga_discord_presence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'publishes identity immediately and coalesces page-only changes',
    () async {
      final platform = _FakeMangaDiscordPlatform();
      final coordinator = MangaDiscordPresenceCoordinator(
        platform,
        minimumPageInterval: const Duration(milliseconds: 30),
      );

      await coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: true,
        title: 'A test manga',
        chapterLabel: 'Chapter 4',
        pageIndex: 0,
        pageCount: 20,
      );
      await coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: true,
        title: 'A test manga',
        chapterLabel: 'Chapter 4',
        pageIndex: 4,
        pageCount: 20,
      );
      await coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: true,
        title: 'A test manga',
        chapterLabel: 'Chapter 4',
        pageIndex: 8,
        pageCount: 20,
      );

      expect(platform.updates, hasLength(1));
      expect(platform.updates.single.page, 1);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(platform.updates, hasLength(2));
      expect(platform.updates.last.page, 9);
      coordinator.dispose();
    },
  );

  test('privacy mode redacts every publication identity field', () async {
    final platform = _FakeMangaDiscordPlatform();
    final coordinator = MangaDiscordPresenceCoordinator(platform);

    await coordinator.update(
      enabled: true,
      connected: true,
      shareTitle: false,
      title: 'Private title',
      chapterLabel: 'Private title — Chapter 2',
      artworkUrl: 'https://covers.example.com/private-title.jpg',
      pageIndex: 3,
      pageCount: 9,
    );

    expect(platform.updates.single.title, 'Reading manga');
    expect(platform.updates.single.chapterLabel, 'Private chapter');
    expect(platform.updates.single.artworkUrl, isNull);
    expect(
      <String>[
        platform.updates.single.title,
        platform.updates.single.chapterLabel,
      ].join(' '),
      isNot(contains('Private title')),
    );
    await coordinator.stop();
    expect(platform.clearCount, 1);
    coordinator.dispose();
  });

  test('disabled or disconnected state never publishes', () async {
    final platform = _FakeMangaDiscordPlatform();
    final coordinator = MangaDiscordPresenceCoordinator(platform);

    await coordinator.update(
      enabled: false,
      connected: true,
      shareTitle: true,
      title: 'Title',
      chapterLabel: 'Chapter 1',
      artworkUrl: 'https://covers.example.com/title.jpg',
      pageIndex: 0,
      pageCount: 1,
    );
    await coordinator.update(
      enabled: true,
      connected: false,
      shareTitle: true,
      title: 'Title',
      chapterLabel: 'Chapter 1',
      artworkUrl: 'https://covers.example.com/title.jpg',
      pageIndex: 0,
      pageCount: 1,
    );

    expect(platform.updates, isEmpty);
    expect(platform.clearCount, 0);
    coordinator.dispose();
  });

  test(
    'bounds long Unicode labels before crossing the native bridge',
    () async {
      final platform = _FakeMangaDiscordPlatform();
      final coordinator = MangaDiscordPresenceCoordinator(platform);

      await coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: true,
        title: List<String>.filled(80, '😀').join(),
        chapterLabel: List<String>.filled(100, '章').join(),
        pageIndex: 0,
        pageCount: 1,
      );

      expect(platform.updates.single.title.length, lessThanOrEqualTo(120));
      expect(platform.updates.single.title.runes.length, 60);
      expect(platform.updates.single.chapterLabel.length, 80);
      coordinator.dispose();
    },
  );

  test('stop waits for an in-flight first update before clearing', () async {
    final platform = _DelayedMangaDiscordPlatform();
    final coordinator = MangaDiscordPresenceCoordinator(platform);

    final update = coordinator.update(
      enabled: true,
      connected: true,
      shareTitle: true,
      title: 'A test manga',
      chapterLabel: 'Chapter 1',
      pageIndex: 0,
      pageCount: 10,
    );
    await Future<void>.delayed(Duration.zero);
    expect(platform.events, <String>['update-start']);

    final stop = coordinator.stop();
    await Future<void>.delayed(Duration.zero);
    expect(platform.events, <String>['update-start']);

    platform.finishUpdate();
    await Future.wait(<Future<void>>[update, stop]);
    expect(platform.events, <String>['update-start', 'update-finish', 'clear']);
    coordinator.dispose();
  });

  test(
    'cover-only identity changes publish immediately despite page coalescing',
    () async {
      final platform = _FakeMangaDiscordPlatform();
      final coordinator = MangaDiscordPresenceCoordinator(
        platform,
        minimumPageInterval: const Duration(minutes: 5),
      );
      addTearDown(coordinator.dispose);
      Future<void> update(String? cover, int page) => coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: true,
        title: 'A test manga',
        chapterLabel: 'Chapter 2',
        artworkUrl: cover,
        pageIndex: page,
        pageCount: 20,
      );
      await update('https://covers.example.com/first.jpg', 0);
      await update('https://covers.example.com/first.jpg', 3);
      expect(platform.updates, hasLength(1));
      await update('https://covers.example.com/second.jpg', 3);
      expect(platform.updates, hasLength(2));
      expect(
        platform.updates.last.artworkUrl,
        'https://covers.example.com/second.jpg',
      );
      expect(platform.updates.last.page, 4);
      await update(null, 3);
      expect(platform.updates, hasLength(3));
      expect(platform.updates.last.artworkUrl, isNull);
    },
  );

  test(
    'privacy toggle immediately removes cover and discards queued title-bearing presence',
    () async {
      final platform = _FakeMangaDiscordPlatform();
      final coordinator = MangaDiscordPresenceCoordinator(
        platform,
        minimumPageInterval: const Duration(milliseconds: 40),
      );
      addTearDown(coordinator.dispose);
      Future<void> update(bool shareTitle, int page) => coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: shareTitle,
        title: 'Private manga',
        chapterLabel: 'Private manga Chapter 3',
        artworkUrl: 'https://covers.example.com/private-manga.jpg',
        pageIndex: page,
        pageCount: 20,
      );
      await update(true, 0);
      await update(true, 5);
      expect(platform.updates, hasLength(1));
      await update(false, 5);
      expect(platform.updates, hasLength(2));
      final private = platform.updates.last;
      expect(private.title, 'Reading manga');
      expect(private.chapterLabel, 'Private chapter');
      expect(private.artworkUrl, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        platform.updates,
        hasLength(2),
        reason:
            'A queued public page update must not restore artwork after privacy is enabled.',
      );
    },
  );

  test(
    'cover change queued behind an in-flight update bypasses the page timer',
    () async {
      final platform = _DelayedMangaDiscordPlatform();
      final coordinator = MangaDiscordPresenceCoordinator(
        platform,
        minimumPageInterval: const Duration(minutes: 5),
      );
      addTearDown(coordinator.dispose);
      Future<void> update(String cover) => coordinator.update(
        enabled: true,
        connected: true,
        shareTitle: true,
        title: 'Manga',
        chapterLabel: 'Chapter 1',
        artworkUrl: cover,
        pageIndex: 0,
        pageCount: 10,
      );
      final first = update('https://covers.example.com/first.jpg');
      await Future<void>.delayed(Duration.zero);
      await update('https://covers.example.com/second.jpg');
      expect(platform.artworkUrls, ['https://covers.example.com/first.jpg']);
      platform.finishUpdate();
      await first;
      expect(platform.artworkUrls, [
        'https://covers.example.com/first.jpg',
        'https://covers.example.com/second.jpg',
      ]);
    },
  );

  test(
    'coordinator never forwards signed artwork or local resources',
    () async {
      for (final artwork in [
        'https://covers.example.com/title.jpg?token=private',
        'file:///private/manga/cover.jpg',
        'content://downloads/manga/cover',
        'https://127.0.0.1/cover.jpg',
        'https://covers.example.test/title.jpg',
      ]) {
        final platform = _FakeMangaDiscordPlatform();
        final coordinator = MangaDiscordPresenceCoordinator(platform);
        await coordinator.update(
          enabled: true,
          connected: true,
          shareTitle: true,
          title: 'Manga',
          chapterLabel: 'Chapter 1',
          artworkUrl: artwork,
          pageIndex: 0,
          pageCount: 1,
        );
        expect(platform.updates.single.artworkUrl, isNull, reason: artwork);
        coordinator.dispose();
      }
    },
  );
}

class _PresenceUpdate {
  const _PresenceUpdate({
    required this.title,
    required this.chapterLabel,
    required this.page,
    required this.pageCount,
    this.artworkUrl,
  });

  final String title;
  final String chapterLabel;
  final int page;
  final int pageCount;
  final String? artworkUrl;
}

class _FakeMangaDiscordPlatform implements MangaDiscordPresencePlatform {
  final updates = <_PresenceUpdate>[];
  int clearCount = 0;

  @override
  Future<void> clear() async {
    clearCount += 1;
  }

  @override
  Future<void> updateReading({
    required String title,
    required String chapterLabel,
    required int page,
    required int pageCount,
    String? artworkUrl,
  }) async {
    updates.add(
      _PresenceUpdate(
        title: title,
        chapterLabel: chapterLabel,
        page: page,
        pageCount: pageCount,
        artworkUrl: artworkUrl,
      ),
    );
  }
}

class _DelayedMangaDiscordPlatform implements MangaDiscordPresencePlatform {
  final events = <String>[];
  final artworkUrls = <String?>[];
  final _updateCompleter = Completer<void>();

  void finishUpdate() {
    events.add('update-finish');
    _updateCompleter.complete();
  }

  @override
  Future<void> clear() async {
    events.add('clear');
  }

  @override
  Future<void> updateReading({
    required String title,
    required String chapterLabel,
    required int page,
    required int pageCount,
    String? artworkUrl,
  }) {
    events.add('update-start');
    artworkUrls.add(artworkUrl);
    return _updateCompleter.future;
  }
}
