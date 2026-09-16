import 'package:anime_tv/core/discord/manga_presence_artwork.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'manga keep-awake state is forwarded to Android and can be cleared',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await AndroidTvBridge.instance.setMangaKeepScreenAwake(true);
      await AndroidTvBridge.instance.setMangaKeepScreenAwake(false);

      expect(calls.map((call) => call.method), <String>[
        'setMangaKeepScreenAwake',
        'setMangaKeepScreenAwake',
      ]);
      expect(calls.first.arguments, <String, Object?>{'enabled': true});
      expect(calls.last.arguments, <String, Object?>{'enabled': false});
    },
  );

  test(
    'manga Discord payload omits artwork when no safe cover was supplied',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await AndroidTvBridge.instance.updateDiscordReadingPresence(
        title: 'A manga',
        chapterLabel: 'Chapter 2',
        page: 4,
        pageCount: 20,
      );

      expect(captured?.method, 'discordUpdateReadingPresence');
      final arguments = captured?.arguments as Map<Object?, Object?>;
      expect(arguments, isNot(contains('artworkUrl')));
      expect(arguments.keys, <Object?>[
        'title',
        'chapterLabel',
        'page',
        'pageCount',
      ]);
    },
  );

  test(
    'manga Discord payload forwards only the sanitized optional cover and reading fields',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      for (final cover in [
        'https://covers.example.com/manga.jpg',
        'https://covers.example.com/manga.jpg?authorization=private',
        'https://username:password@covers.example.com/manga.jpg',
        'file:///data/private/cover.jpg',
        'content://private-manga/cover',
        'https://192.168.1.20/cover.jpg',
      ]) {
        await AndroidTvBridge.instance.updateDiscordReadingPresence(
          title: 'Manga',
          chapterLabel: 'Chapter 2',
          page: 4,
          pageCount: 20,
          artworkUrl: cover,
        );
      }
      expect(
        calls.every((call) => call.method == 'discordUpdateReadingPresence'),
        isTrue,
      );
      final first = calls.first.arguments as Map<Object?, Object?>;
      expect(first, {
        'title': 'Manga',
        'chapterLabel': 'Chapter 2',
        'page': 4,
        'pageCount': 20,
        'artworkUrl': 'https://covers.example.com/manga.jpg',
      });
      for (final call in calls.skip(1)) {
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(
          arguments.keys,
          unorderedEquals(['title', 'chapterLabel', 'page', 'pageCount']),
        );
        expect(arguments, isNot(contains('sourceUrl')));
        expect(arguments, isNot(contains('pageUrl')));
        expect(arguments, isNot(contains('requestHeaders')));
      }
    },
  );

  test(
    'manga artwork policy accepts ordinary public HTTPS covers within the bound',
    () {
      for (final cover in [
        'https://covers.example.com/title.jpg',
        'https://images.cdn.example.com/series/cover.webp',
        'https://covers.example.com:443/title.png',
      ]) {
        expect(safeMangaPresenceArtworkUrl(cover), isNotNull, reason: cover);
      }
      const prefix = 'https://covers.example.com/';
      final boundary = prefix + List.filled(300 - prefix.length, 'a').join();
      expect(safeMangaPresenceArtworkUrl(boundary), isNotNull);
      expect(safeMangaPresenceArtworkUrl('${boundary}a'), isNull);
    },
  );

  test(
    'manga artwork policy rejects capabilities and non-public/local destinations',
    () {
      for (final cover in <String?>[
        null,
        '',
        'not a URL',
        'http://covers.example.com/title.jpg',
        'https://covers.example.com/title.jpg?token=secret',
        'https://covers.example.com/title.jpg?',
        'https://covers.example.com/title.jpg#secret',
        'https://user:secret@covers.example.com/title.jpg',
        'https://covers.example.com:8443/title.jpg',
        'https://localhost/title.jpg',
        'https://covers.local/title.jpg',
        'https://covers.internal/title.jpg',
        'https://covers.test/title.jpg',
        'https://covers.example/title.jpg',
        'https://covers.invalid/title.jpg',
        'https://127.0.0.1/title.jpg',
        'https://10.0.0.5/title.jpg',
        'https://192.168.0.1/title.jpg',
        'https://[::1]/title.jpg',
        'https://8.8.8.8/title.jpg',
        'https://2130706433/title.jpg',
        'https://0x7f000001/title.jpg',
        'https://covers.example.com/cover\n.jpg',
        'https://covers.example.com/cover\t.jpg',
        r'https://covers.example.com\@private.local/title.jpg',
        'file:///storage/manga/cover.jpg',
        'content://manga/cover',
        'data:image/png;base64,secret',
      ]) {
        expect(safeMangaPresenceArtworkUrl(cover), isNull, reason: '$cover');
      }
    },
  );
}
