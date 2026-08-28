import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('episode notification bridge sends typed release alarms', () async {
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
      return 1;
    });
    final releaseAt = DateTime.utc(2026, 8, 25, 4, 30);

    final count = await AndroidTvBridge.instance
        .syncEpisodeReleaseNotifications([
          EpisodeReleaseNotification(
            mediaId: 42,
            episode: 3,
            title: 'A show',
            releaseAt: releaseAt,
            kind: EpisodeReleaseNotificationKind.simulcast,
          ),
        ]);

    expect(count, 1);
    expect(observed?.method, 'syncEpisodeReleaseNotifications');
    expect(observed?.arguments, {
      'notifications': [
        {
          'mediaId': 42,
          'episode': 3,
          'title': 'A show',
          'atMillis': releaseAt.millisecondsSinceEpoch,
          'kind': 'simulcast',
        },
      ],
    });
  });
}
