import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'external player bridge sends only typed media location fields',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      MethodCall? observed;
      messenger.setMockMethodCallHandler(channel, (call) async {
        observed = call;
        return true;
      });

      final opened = await AndroidTvBridge.instance.openExternalPlayer(
        uri: Uri.parse('https://media.example/episode.mkv'),
        mediaContentType: 'video/x-matroska',
        packageName: 'org.example.player',
      );

      expect(opened, isTrue);
      expect(observed?.method, 'openExternalPlayer');
      expect(observed?.arguments, {
        'uri': 'https://media.example/episode.mkv',
        'mimeType': 'video/x-matroska',
        'packageName': 'org.example.player',
      });
    },
  );

  test('external player bridge lists installed video apps', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('dev.tetotv/android_tv');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listExternalPlayers');
      return [
        {'packageName': 'org.videolan.vlc', 'label': 'VLC'},
        {'packageName': '', 'label': 'Invalid'},
      ];
    });

    final players = await AndroidTvBridge.instance
        .installedExternalVideoPlayers();

    expect(players, hasLength(1));
    expect(players.single.packageName, 'org.videolan.vlc');
    expect(players.single.label, 'VLC');
  });

  test('external player bridge accepts a private offline path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('dev.tetotv/android_tv');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    MethodCall? observed;
    messenger.setMockMethodCallHandler(channel, (call) async {
      observed = call;
      return true;
    });

    await AndroidTvBridge.instance.openExternalPlayer(
      localPath: '/private/offline_downloads/episode.mkv',
    );

    expect(observed?.arguments, {
      'localPath': '/private/offline_downloads/episode.mkv',
    });
  });

  test('external player bridge rejects an empty handoff', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(AndroidTvBridge.instance.openExternalPlayer(), throwsArgumentError);
  });
}
