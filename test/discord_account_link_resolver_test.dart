import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/application/discord_account_link_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'startup TV classification never asks native or opens mobile OAuth',
    () async {
      var calls = 0;
      final resolver = DiscordAccountLinkResolver(() async {
        calls++;
        return AndroidDeviceCategory.mobile;
      });

      expect(
        await resolver.resolve(startupTelevision: true),
        DiscordAccountLinkFlow.deviceQr,
      );
      expect(calls, 0);
    },
  );

  test(
    'late native Fire TV result repairs a stale startup phone flag',
    () async {
      final resolver = DiscordAccountLinkResolver(
        () async => AndroidDeviceCategory.television,
      );

      expect(
        await resolver.resolve(startupTelevision: false),
        DiscordAccountLinkFlow.deviceQr,
      );
    },
  );

  test('only an explicit native mobile result enables mobile OAuth', () async {
    final resolver = DiscordAccountLinkResolver(
      () async => AndroidDeviceCategory.mobile,
    );

    expect(
      await resolver.resolve(startupTelevision: false),
      DiscordAccountLinkFlow.mobileOAuth,
    );
  });

  test('native errors and timeouts fail closed to QR linking', () async {
    final failure = DiscordAccountLinkResolver(
      () async => throw StateError('bridge unavailable'),
    );
    final never = Completer<AndroidDeviceCategory>();
    final timeout = DiscordAccountLinkResolver(
      () => never.future,
      nativeTimeout: const Duration(milliseconds: 1),
    );

    expect(
      await failure.resolve(startupTelevision: false),
      DiscordAccountLinkFlow.deviceQr,
    );
    expect(
      await timeout.resolve(startupTelevision: false),
      DiscordAccountLinkFlow.deviceQr,
    );
  });
}
