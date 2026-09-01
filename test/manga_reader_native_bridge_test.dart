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

  test('manga Discord payload has no user-source artwork capability', () async {
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
  });
}
