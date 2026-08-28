import 'dart:async';
import 'dart:ui' show Size;

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/platform/startup_device_classification.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('startDeviceClassification', () {
    test('accepts a definitive native television result immediately', () async {
      final refreshValues = <bool>[];

      final result = await startDeviceClassification(
        loadDeviceCategory: ({required refresh}) async {
          refreshValues.add(refresh);
          return AndroidDeviceCategory.television;
        },
      );

      expect(result.initialCategory, AndroidDeviceCategory.television);
      expect(result.lateCategory, isNull);
      expect(refreshValues, [false]);
    });

    test('accepts a definitive native mobile result immediately', () async {
      final result = await startDeviceClassification(
        loadDeviceCategory: ({required refresh}) async =>
            AndroidDeviceCategory.mobile,
      );

      expect(result.initialCategory, AndroidDeviceCategory.mobile);
      expect(result.lateCategory, isNull);
    });

    test('returns after the soft deadline and corrects from retry', () async {
      final neverCompletes = Completer<AndroidDeviceCategory>();
      final refreshValues = <bool>[];

      final result = await startDeviceClassification(
        loadDeviceCategory: ({required refresh}) {
          refreshValues.add(refresh);
          return refresh
              ? Future.value(AndroidDeviceCategory.television)
              : neverCompletes.future;
        },
        initialAttemptTimeout: const Duration(milliseconds: 1),
        lateCorrectionTimeout: const Duration(milliseconds: 20),
      );

      expect(result.initialCategory, AndroidDeviceCategory.unknown);
      expect(await result.lateCategory, AndroidDeviceCategory.television);
      expect(refreshValues, [false, true]);
    });

    test('late first response can repair the viewport fallback', () async {
      final initial = Completer<AndroidDeviceCategory>();
      final retry = Completer<AndroidDeviceCategory>();

      final result = await startDeviceClassification(
        loadDeviceCategory: ({required refresh}) {
          return refresh ? retry.future : initial.future;
        },
        initialAttemptTimeout: const Duration(milliseconds: 1),
        lateCorrectionTimeout: const Duration(milliseconds: 50),
      );
      initial.complete(AndroidDeviceCategory.mobile);

      expect(result.initialCategory, AndroidDeviceCategory.unknown);
      expect(await result.lateCategory, AndroidDeviceCategory.mobile);
    });

    test(
      'late result remains unknown after unknown and failed attempts',
      () async {
        final refreshValues = <bool>[];

        final result = await startDeviceClassification(
          loadDeviceCategory: ({required refresh}) async {
            refreshValues.add(refresh);
            if (refresh) throw StateError('bridge unavailable');
            return AndroidDeviceCategory.unknown;
          },
        );

        expect(result.initialCategory, AndroidDeviceCategory.unknown);
        expect(await result.lateCategory, AndroidDeviceCategory.unknown);
        expect(refreshValues, [false, true]);
      },
    );
  });

  group('reactive device category providers', () {
    test('late native TV and mobile values replace the fallback', () {
      final container = ProviderContainer(
        overrides: [
          startupDeviceCategoryProvider.overrideWith(
            (_) => AndroidDeviceCategory.unknown,
          ),
          startupTelevisionFallbackProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(isTelevisionProvider), isFalse);
      container.read(startupDeviceCategoryProvider.notifier).state =
          AndroidDeviceCategory.television;
      expect(container.read(isTelevisionProvider), isTrue);
      container.read(startupDeviceCategoryProvider.notifier).state =
          AndroidDeviceCategory.mobile;
      expect(container.read(isTelevisionProvider), isFalse);
    });

    test('existing boolean test override remains supported', () {
      final container = ProviderContainer(
        overrides: [isTelevisionProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      expect(container.read(isTelevisionProvider), isFalse);
    });
  });

  group('inferStartupTelevisionFromViewport', () {
    test('recognizes 1080p and 4K Android television canvases', () {
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: const Size(1920, 1080),
          devicePixelRatio: 2,
        ),
        isTrue,
      );
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: const Size(3840, 2160),
          devicePixelRatio: 2,
        ),
        isTrue,
      );
    });

    test('recognizes a 720p television even with high DPR', () {
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: const Size(1280, 720),
          devicePixelRatio: 2,
        ),
        isTrue,
      );
    });

    test('does not mistake a high-DPR 16:9 tablet for a television', () {
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: const Size(2560, 1440),
          devicePixelRatio: 3,
        ),
        isFalse,
      );
    });

    test('does not mistake portrait or landscape phones for televisions', () {
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: const Size(1080, 2400),
          devicePixelRatio: 3,
        ),
        isFalse,
      );
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: const Size(2400, 1080),
          devicePixelRatio: 3,
        ),
        isFalse,
      );
    });

    test('unmeasured Android view preserves the TV-safe fallback', () {
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.android,
          physicalSize: Size.zero,
          devicePixelRatio: 0,
        ),
        isTrue,
      );
      expect(
        inferStartupTelevisionFromViewport(
          platform: TargetPlatform.iOS,
          physicalSize: Size.zero,
          devicePixelRatio: 0,
        ),
        isFalse,
      );
    });
  });
}
