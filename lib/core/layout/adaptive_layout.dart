import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The native Android device category. Tests default to television so the
/// established 10-foot focus and sizing behavior remains deterministic.
final startupDeviceCategoryProvider = StateProvider<AndroidDeviceCategory>(
  (_) => AndroidDeviceCategory.unknown,
);

/// Used only while Android has not returned a definitive native category.
final startupTelevisionFallbackProvider = Provider<bool>((_) => true);

/// Existing tests and callers can continue overriding this boolean provider.
/// Production derives it from the reactive native category so a result which
/// arrives after the first frame can repair a temporary viewport fallback.
final isTelevisionProvider = Provider<bool>((ref) {
  final category = ref.watch(startupDeviceCategoryProvider);
  return switch (category) {
    AndroidDeviceCategory.television => true,
    AndroidDeviceCategory.mobile => false,
    AndroidDeviceCategory.unknown => ref.watch(
      startupTelevisionFallbackProvider,
    ),
  };
});

enum AdaptiveWindowClass { compact, medium, expanded, large, extraLarge }

extension AdaptiveLayoutContext on BuildContext {
  AdaptiveWindowClass get adaptiveWindowClass {
    final width = MediaQuery.sizeOf(this).width;
    if (width < 600) return AdaptiveWindowClass.compact;
    if (width < 840) return AdaptiveWindowClass.medium;
    if (width < 1200) return AdaptiveWindowClass.expanded;
    if (width < 1600) return AdaptiveWindowClass.large;
    return AdaptiveWindowClass.extraLarge;
  }

  bool get isCompactWidth => adaptiveWindowClass == AdaptiveWindowClass.compact;

  bool get isMediumWidth {
    return adaptiveWindowClass == AdaptiveWindowClass.medium;
  }

  EdgeInsets get responsiveScreenPadding {
    final size = MediaQuery.sizeOf(this);
    final isShortLandscape = size.height < 480 && size.width > size.height;
    if (size.width < 360) {
      return const EdgeInsets.fromLTRB(12, 8, 12, 12);
    }
    if (isShortLandscape) {
      return const EdgeInsets.fromLTRB(18, 10, 18, 12);
    }
    return switch (adaptiveWindowClass) {
      AdaptiveWindowClass.compact => const EdgeInsets.fromLTRB(16, 12, 16, 18),
      AdaptiveWindowClass.medium => const EdgeInsets.fromLTRB(24, 18, 24, 24),
      AdaptiveWindowClass.expanded => const EdgeInsets.fromLTRB(28, 20, 28, 26),
      AdaptiveWindowClass.large || AdaptiveWindowClass.extraLarge =>
        const EdgeInsets.fromLTRB(34, 24, 34, 28),
    };
  }
}
