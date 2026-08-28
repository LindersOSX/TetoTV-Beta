import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native lease uses one opaque ID and releases idempotently', () async {
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
      return call.method == 'acquireOfflineDownloadKeepAlive';
    });

    final lease = await AndroidOfflineDownloadKeepAlive().acquire();
    await lease.release();
    await lease.release();

    expect(calls.map((call) => call.method), [
      'acquireOfflineDownloadKeepAlive',
      'releaseOfflineDownloadKeepAlive',
    ]);
    final acquiredId =
        (calls.first.arguments as Map<Object?, Object?>)['leaseId'];
    final releasedId =
        (calls.last.arguments as Map<Object?, Object?>)['leaseId'];
    expect(acquiredId, matches(RegExp(r'^offline-\d+$')));
    expect(releasedId, acquiredId);
    expect(calls.first.arguments.toString(), isNot(contains('http')));
  });

  test('bridge rejects an empty lease identifier before platform I/O', () {
    expect(
      AndroidTvBridge.instance.acquireOfflineDownloadKeepAlive('   '),
      throwsArgumentError,
    );
  });
}
