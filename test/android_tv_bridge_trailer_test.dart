import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('in-app trailer bridge sends only a provider ID and title', () async {
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

    final opened = await AndroidTvBridge.instance.playInAppTrailer(
      provider: 'youtube',
      videoId: 'abcDEF_12-3',
      title: 'Trailer Show',
    );

    expect(opened, isTrue);
    expect(observed?.method, 'playInAppTrailer');
    expect(observed?.arguments, {
      'provider': 'youtube',
      'videoId': 'abcDEF_12-3',
      'title': 'Trailer Show',
    });
  });
}
