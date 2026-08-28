import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StreamReady stream(
    String source, {
    Map<String, String> headers = const {},
    bool directTorrent = false,
    bool downloaded = false,
    String? mediaContentType,
  }) => StreamReady(
    uri: Uri.parse(source),
    displayName: 'Episode',
    headers: headers,
    isDirectTorrent: directTorrent,
    isDownloaded: downloaded,
    mediaContentType: mediaContentType,
  );

  test('allows only header-free public or granted media URIs', () {
    expect(
      externalPlayerTargetForStream(
        stream('https://media.example/episode.mkv'),
      )?.uri,
      Uri.parse('https://media.example/episode.mkv'),
    );
    expect(
      externalPlayerTargetForStream(
        stream('content://documents/video/episode'),
      )?.uri,
      Uri.parse('content://documents/video/episode'),
    );
    expect(
      externalPlayerTargetForStream(
        stream(
          'https://media.example/private.mkv',
          headers: const {'Authorization': 'private'},
        ),
      ),
      isNull,
    );
    expect(
      externalPlayerTargetForStream(
        stream('https://media.example/direct', directTorrent: true),
      ),
      isNull,
    );
  });

  test('allows only completed app-private offline download paths', () {
    final target = externalPlayerTargetForStream(
      stream(
        'file:///data/user/0/dev.animetv.anime_tv/files/'
        'offline_downloads/show/episode.mkv',
        downloaded: true,
      ),
    );
    expect(
      target?.localPath,
      '/data/user/0/dev.animetv.anime_tv/files/'
      'offline_downloads/show/episode.mkv',
    );
    expect(target?.uri, isNull);
    expect(
      externalPlayerTargetForStream(
        stream(
          'file:///data/user/0/dev.animetv.anime_tv/files/'
          'offline_downloads/show/episode.mkv',
        ),
      ),
      isNull,
    );
    expect(
      externalPlayerTargetForStream(
        stream('file:///sdcard/Movies/episode.mkv', downloaded: true),
      ),
      isNull,
    );
  });

  test('keeps multi-file offline HLS bundles inside TetoTV', () {
    const base =
        'file:///data/user/0/dev.animetv.anime_tv/files/'
        'offline_downloads/show/';
    expect(
      externalPlayerTargetForStream(
        stream('${base}episode.m3u8', downloaded: true),
      ),
      isNull,
    );
    expect(
      externalPlayerTargetForStream(
        stream(
          '${base}episode.data',
          downloaded: true,
          mediaContentType: 'application/vnd.apple.mpegurl',
        ),
      ),
      isNull,
    );
  });

  test('keeps private media servers inside TetoTV', () {
    expect(externalPlayerLibraryProviderAllowed(null), isTrue);
    expect(externalPlayerLibraryProviderAllowed('device-local'), isTrue);
    expect(externalPlayerLibraryProviderAllowed('offline-download'), isTrue);
    expect(externalPlayerLibraryProviderAllowed('jellyfin'), isFalse);
    expect(externalPlayerLibraryProviderAllowed('plex'), isFalse);
    expect(externalPlayerLibraryProviderAllowed('private-library'), isFalse);
  });

  test('configured default app is used only for safe standalone streams', () {
    const configured = SettingsPreferences(
      preferredPlayer: PreferredPlayer.external,
      externalPlayerEnabled: true,
      selectedExternalPlayerPackage: 'org.example.player',
      selectedExternalPlayerLabel: 'Example Player',
    );
    final publicStream = stream('https://media.example/episode.mkv');

    expect(
      configuredExternalPlayerEligible(
        preferences: configured,
        watchPartyActive: false,
        stream: publicStream,
      ),
      isTrue,
    );
    expect(
      configuredExternalPlayerEligible(
        preferences: configured,
        watchPartyActive: true,
        stream: publicStream,
      ),
      isFalse,
    );
    expect(
      configuredExternalPlayerEligible(
        preferences: configured,
        watchPartyActive: false,
        stream: publicStream,
        libraryProviderId: 'jellyfin',
      ),
      isFalse,
    );
    expect(
      configuredExternalPlayerEligible(
        preferences: configured.copyWith(externalPlayerEnabled: false),
        watchPartyActive: false,
        stream: publicStream,
      ),
      isFalse,
    );
  });
}
