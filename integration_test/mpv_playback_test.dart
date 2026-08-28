import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets(
    'libmpv renders and advances on Android TV',
    (tester) async {
      final player = Player(
        configuration: const PlayerConfiguration(
          title: 'TetoTV MPV compatibility smoke test',
          bufferSize: 8 * 1024 * 1024,
        ),
      );
      final controller = VideoController(player);
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: Video(controller: controller)),
        ),
      );

      await player.open(
        Media('asset:///assets/videos/mpv_smoke.mp4'),
        play: true,
      );

      final params = await player.stream.videoParams
          .firstWhere((value) => (value.w ?? 0) > 0 && (value.h ?? 0) > 0)
          .timeout(const Duration(seconds: 30));
      final position = await player.stream.position
          .firstWhere((value) => value > const Duration(seconds: 1))
          .timeout(const Duration(seconds: 30));

      expect(params.w, greaterThan(0));
      expect(params.h, greaterThan(0));
      expect(position, greaterThan(const Duration(seconds: 1)));
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
