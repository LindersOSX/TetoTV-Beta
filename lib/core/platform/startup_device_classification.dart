import 'dart:async';
import 'dart:ui' show Size;

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/foundation.dart';

typedef StartupDeviceCategoryLoader =
    Future<AndroidDeviceCategory> Function({required bool refresh});

class StartupDeviceClassification {
  const StartupDeviceClassification({
    required this.initialCategory,
    this.lateCategory,
  });

  /// The native category available before the first frame. Unknown means the
  /// UI should use its viewport fallback temporarily.
  final AndroidDeviceCategory initialCategory;

  /// A bounded background correction after an inconclusive first attempt.
  /// This never completes with an error.
  final Future<AndroidDeviceCategory>? lateCategory;
}

/// Starts device classification without holding the first frame indefinitely.
///
/// Android's method channel can become ready slightly later than Flutter on
/// some Chromecast and Fire TV firmware. A short timeout must therefore be a
/// soft failure: render with a viewport fallback, retry natively in the
/// background, and apply any late definitive result reactively.
Future<StartupDeviceClassification> startDeviceClassification({
  required StartupDeviceCategoryLoader loadDeviceCategory,
  Duration initialAttemptTimeout = const Duration(seconds: 2),
  Duration lateCorrectionTimeout = const Duration(seconds: 4),
}) async {
  final initialRequest = _loadDeviceCategory(
    loadDeviceCategory,
    refresh: false,
  );
  final initial = await initialRequest.timeout(
    initialAttemptTimeout,
    onTimeout: () => AndroidDeviceCategory.unknown,
  );
  if (_isDefinitive(initial)) {
    return StartupDeviceClassification(initialCategory: initial);
  }

  final retryRequest = _loadDeviceCategory(loadDeviceCategory, refresh: true);
  return StartupDeviceClassification(
    initialCategory: AndroidDeviceCategory.unknown,
    lateCategory: _firstDefinitiveCategory([
      initialRequest,
      retryRequest,
    ], timeout: lateCorrectionTimeout),
  );
}

Future<AndroidDeviceCategory> _loadDeviceCategory(
  StartupDeviceCategoryLoader loader, {
  required bool refresh,
}) async {
  try {
    return await loader(refresh: refresh);
  } catch (_) {
    return AndroidDeviceCategory.unknown;
  }
}

bool _isDefinitive(AndroidDeviceCategory category) =>
    category != AndroidDeviceCategory.unknown;

Future<AndroidDeviceCategory> _firstDefinitiveCategory(
  List<Future<AndroidDeviceCategory>> requests, {
  required Duration timeout,
}) {
  final result = Completer<AndroidDeviceCategory>();
  var remaining = requests.length;
  for (final request in requests) {
    request.then((category) {
      if (result.isCompleted) return;
      if (_isDefinitive(category)) {
        result.complete(category);
        return;
      }
      remaining -= 1;
      if (remaining == 0) result.complete(AndroidDeviceCategory.unknown);
    });
  }
  return result.future.timeout(
    timeout,
    onTimeout: () => AndroidDeviceCategory.unknown,
  );
}

/// Best-effort fallback used while native classification is inconclusive.
///
/// A ten-foot Android surface is normally landscape, near 16:9, and at least
/// 480 logical pixels tall. This keeps a slow TV bridge in TV mode without
/// making ordinary portrait or wide phone viewports look like televisions.
bool inferStartupTelevisionFromViewport({
  required TargetPlatform platform,
  required Size physicalSize,
  required double devicePixelRatio,
}) {
  if (platform != TargetPlatform.android) return false;
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) return true;
  if (!physicalSize.width.isFinite ||
      !physicalSize.height.isFinite ||
      physicalSize.width <= 0 ||
      physicalSize.height <= 0) {
    // The view can still be unmeasured while an Android TV engine starts.
    // Preserve the TV-first, D-pad-operable surface until the bounded native
    // correction completes instead of prematurely choosing phone.
    return true;
  }

  final logicalWidth = physicalSize.width / devicePixelRatio;
  final logicalHeight = physicalSize.height / devicePixelRatio;
  if (logicalWidth <= logicalHeight) return false;
  final aspectRatio = logicalWidth / logicalHeight;
  if (aspectRatio < 1.65 || aspectRatio > 1.9) return false;

  // 720p is still a normal Android/Fire TV output. Some firmwares expose it
  // at DPR 2 (640x360 logical), below phone-oriented shortest-side cutoffs.
  final physicalWidth = physicalSize.width.round();
  final physicalHeight = physicalSize.height.round();
  if (physicalWidth == 1280 && physicalHeight == 720) return true;

  // Typical 16:9 tablets use a denser logical canvas than televisions. Native
  // classification remains authoritative; this only avoids guessing TV for a
  // high-DPR tablet during the brief soft-timeout window.
  return logicalWidth >= 900 && logicalHeight >= 480;
}
