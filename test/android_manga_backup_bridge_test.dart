import 'dart:convert';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.tetotv/android_tv');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  final encrypted = jsonEncode({
    'format': 'tetotv-manga-backup',
    'cipher': 'AES-256-GCM',
    'ciphertext': 'opaque-ciphertext',
  });

  test(
    'SAF export sends encrypted envelope and safe suggested name only',
    () async {
      MethodCall? observed;
      messenger.setMockMethodCallHandler(channel, (call) async {
        observed = call;
        return true;
      });
      expect(
        await AndroidTvBridge.instance.exportMangaBackup(
          encryptedJson: encrypted,
          suggestedName: 'TetoTV-Manga-Backup.json',
        ),
        isTrue,
      );
      expect(observed!.method, 'exportMangaBackup');
      expect(observed!.arguments, {
        'encryptedJson': encrypted,
        'suggestedName': 'TetoTV-Manga-Backup.json',
      });
    },
  );
  test(
    'import and picker cancellation return bounded strings or null',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'importMangaBackup');
        return encrypted;
      });
      expect(await AndroidTvBridge.instance.importMangaBackup(), encrypted);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await AndroidTvBridge.instance.importMangaBackup(), isNull);
      expect(
        await AndroidTvBridge.instance.exportMangaBackup(
          encryptedJson: encrypted,
          suggestedName: 'TetoTV-Manga-Backup.json',
        ),
        isFalse,
      );
    },
  );
  test(
    'outbound plaintext, traversal names and inbound oversized content are rejected',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return 'x' * (12 * 1024 * 1024 + 1);
      });
      await expectLater(
        AndroidTvBridge.instance.exportMangaBackup(
          encryptedJson: '{"title":"private"}',
          suggestedName: 'backup.json',
        ),
        throwsFormatException,
      );
      await expectLater(
        AndroidTvBridge.instance.exportMangaBackup(
          encryptedJson: encrypted,
          suggestedName: '../private.json',
        ),
        throwsFormatException,
      );
      expect(calls, 0);
      await expectLater(
        AndroidTvBridge.instance.importMangaBackup(),
        throwsFormatException,
      );
    },
  );
  test(
    'non-Android platforms fail explicitly without file operations',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(
        AndroidTvBridge.instance.importMangaBackup(),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
