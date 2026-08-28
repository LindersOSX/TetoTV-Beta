import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Discord activity uses show artwork with a TetoTV badge and fallback',
    () {
      final source = File(
        'android/app/src/main/cpp/discord_rich_presence.cpp',
      ).readAsStringSync();

      expect(
        source,
        contains('constexpr auto kAppIconAssetKey = "tetotv_app_icon";'),
      );
      expect(source, contains('assets.SetLargeImage(value.artwork_url);'));
      expect(source, contains('assets.SetLargeText(value.title);'));
      expect(
        source,
        contains('assets.SetSmallImage(std::string{kAppIconAssetKey});'),
      );
      expect(source, contains('assets.SetSmallText(std::string{"TetoTV"});'));
      expect(
        source,
        contains('assets.SetLargeImage(std::string{kAppIconAssetKey});'),
      );
      expect(source, contains('activity.SetAssets(std::move(assets));'));

      final setAssets = source.indexOf(
        'activity.SetAssets(std::move(assets));',
      );
      final publish = source.indexOf('g_client->UpdateRichPresence(');
      expect(setAssets, greaterThanOrEqualTo(0));
      expect(publish, greaterThan(setAssets));
    },
  );

  test('MPV passes show artwork to Discord', () {
    final bridge = File(
      'lib/core/platform/android_tv_bridge.dart',
    ).readAsStringSync();
    final mpv = File(
      'lib/features/player/presentation/tv_player_screen.dart',
    ).readAsStringSync();
    expect(bridge, contains("'artworkUrl': artworkUrl"));
    expect(mpv, contains('artworkUrl: widget.coverImageUrl'));
  });

  test('Discord asset documentation preserves the portal contract', () {
    final notes = File(
      'third_party/discord_social_sdk/README.md',
    ).readAsStringSync();

    expect(
      notes,
      contains('Rich Presence app-icon asset key: `tetotv_app_icon`'),
    );
    expect(notes, contains("current show's public"));
    expect(notes, contains("HTTPS artwork as the activity's large image"));
    expect(notes, contains('assets/branding/tetotv_icon.png'));
    expect(File('assets/branding/tetotv_icon.png').existsSync(), isTrue);
  });
}
