import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Discord bridge exposes privacy-bounded reading presence', () {
    final kotlin = File(
      'android/app/src/main/kotlin/dev/animetv/anime_tv/'
      'DiscordRichPresenceBridge.kt',
    ).readAsStringSync();
    final native = File(
      'android/app/src/main/cpp/discord_rich_presence.cpp',
    ).readAsStringSync();
    final dart = File(
      'lib/core/platform/android_tv_bridge.dart',
    ).readAsStringSync();

    expect(kotlin, contains('"discordUpdateReadingPresence" -> {'));
    expect(kotlin, contains('nativeUpdateReadingPresence('));
    expect(native, contains('value.activity_kind == "reading"'));
    expect(native, contains('" - Page " + std::to_string(value.page)'));
    expect(
      native,
      contains('value.activity_kind != "reading" && value.playing'),
    );
    expect(dart, contains("'discordUpdateReadingPresence'"));
    expect(dart, isNot(contains("'sourceUrl':")));
    expect(dart, isNot(contains("'requestHeaders':")));

    final dartReading = dart.substring(
      dart.indexOf('Future<void> updateDiscordReadingPresence'),
      dart.indexOf('Future<void> clearDiscordPresence'),
    );
    final kotlinReading = kotlin.substring(
      kotlin.indexOf('"discordUpdateReadingPresence" -> {'),
      kotlin.indexOf('"discordClearPresence" -> {'),
    );
    final nativeReading = native.substring(
      native.indexOf('nativeUpdateReadingPresence('),
      native.indexOf('nativeClearPresence('),
    );
    expect(dartReading, contains('safeMangaPresenceArtworkUrl(artworkUrl)'));
    expect(kotlinReading, contains('sanitizeDiscordMangaArtworkUrl'));
    expect(nativeReading, contains('jstring artwork_url'));
    expect(nativeReading, contains('from_jstring(env, artwork_url)'));
    expect(native, contains('assets.SetLargeImage(value.artwork_url)'));
    expect(
      native,
      contains('assets.SetLargeImage(std::string{kAppIconAssetKey})'),
    );
    for (final code in [dartReading, kotlinReading, nativeReading]) {
      for (final forbidden in [
        'requestHeaders',
        'sourceUrl',
        'pageUrl',
        'localPath',
      ]) {
        expect(code, isNot(contains(forbidden)));
      }
    }
  });
}
