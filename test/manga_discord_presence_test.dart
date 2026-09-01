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
      pageIndex: 3,
      pageCount: 9,
    );

    expect(platform.updates.single.title, 'Reading manga');
    expect(platform.updates.single.chapterLabel, 'Private chapter');
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
      pageIndex: 0,
      pageCount: 1,
    );
    await coordinator.update(
      enabled: true,
      connected: false,
      shareTitle: true,
      title: 'Title',
      chapterLabel: 'Chapter 1',
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
}

class _PresenceUpdate {
  const _PresenceUpdate({
    required this.title,
    required this.chapterLabel,
    required this.page,
    required this.pageCount,
  });

  final String title;
  final String chapterLabel;
  final int page;
  final int pageCount;
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
  }) async {
    updates.add(
      _PresenceUpdate(
        title: title,
        chapterLabel: chapterLabel,
        page: page,
        pageCount: pageCount,
      ),
    );
  }
}

class _DelayedMangaDiscordPlatform implements MangaDiscordPresencePlatform {
  final events = <String>[];
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
  }) {
    events.add('update-start');
    return _updateCompleter.future;
  }
}
