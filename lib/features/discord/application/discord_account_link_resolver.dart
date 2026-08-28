import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DiscordAccountLinkFlow { deviceQr, mobileOAuth }

typedef AndroidDeviceCategoryLoader = Future<AndroidDeviceCategory> Function();

final discordAccountLinkResolverProvider = Provider<DiscordAccountLinkResolver>(
  (_) => DiscordAccountLinkResolver(
    () => AndroidTvBridge.instance.getDeviceCategory(refresh: true),
  ),
);

/// Resolves the Discord authentication UI at the moment Connect is pressed.
///
/// Startup classification can be stale when a Fire TV's method channel takes
/// longer than app startup. Only an explicit native "mobile" result is allowed
/// to enter Discord's browser OAuth; a timeout, missing bridge, or any other
/// unknown result safely stays inside TetoTV's QR device flow.
class DiscordAccountLinkResolver {
  const DiscordAccountLinkResolver(
    this._loadDeviceCategory, {
    this.nativeTimeout = const Duration(seconds: 2),
  });

  final AndroidDeviceCategoryLoader _loadDeviceCategory;
  final Duration nativeTimeout;

  Future<DiscordAccountLinkFlow> resolve({
    required bool startupTelevision,
  }) async {
    if (startupTelevision) return DiscordAccountLinkFlow.deviceQr;
    late final Future<AndroidDeviceCategory> categoryRequest;
    try {
      categoryRequest = _loadDeviceCategory();
    } catch (_) {
      return DiscordAccountLinkFlow.deviceQr;
    }
    final category = await categoryRequest
        .then((value) => value, onError: (_) => AndroidDeviceCategory.unknown)
        .timeout(nativeTimeout, onTimeout: () => AndroidDeviceCategory.unknown);
    return category == AndroidDeviceCategory.mobile
        ? DiscordAccountLinkFlow.mobileOAuth
        : DiscordAccountLinkFlow.deviceQr;
  }
}
