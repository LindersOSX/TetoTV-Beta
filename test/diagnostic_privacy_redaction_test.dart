import 'dart:convert';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'redacts media filenames, encoded URLs, private hosts, and auth headers',
    () {
      final redacted = redactDiagnosticValue(
        'filename="Private Show Episode 07.mkv" '
        'https%3A%2F%2Fcdn.private.example%2Fepisode.mkv '
        'server=basement-nas.home:32400 '
        'peer=plex.private.example:443 '
        'X-Plex-Token=plex-secret '
        'X-MediaBrowser-Token: jellyfin-secret '
        'headers={Authorization: Bearer nested-secret}',
        maximum: 2000,
      );

      for (final privateValue in const [
        'Private Show',
        'cdn.private.example',
        'basement-nas.home',
        'plex.private.example',
        'plex-secret',
        'jellyfin-secret',
        'nested-secret',
      ]) {
        expect(redacted, isNot(contains(privateValue)), reason: privateValue);
      }
      expect(redacted, contains('[FILENAME]'));
      expect(redacted, contains('[URL]'));
      expect(redacted, contains('[PRIVATE SERVER]'));
      expect(redacted, contains('[NETWORK HOST]'));
    },
  );

  test(
    'explicit report removes structured server and request capabilities',
    () {
      final text = buildRedactedDiagnosticsText(
        version: const AppVersionInfo(name: '2.0.18', code: 410001),
        profile: _profile,
        isTelevision: true,
        diagnostics: const {
          'session_id': 'pbs-safeCorrelation12',
          'httpHeaders': {'X-Plex-Token': 'private'},
          'requestHeaders': {'Authorization': 'Bearer private'},
          'queryParameters': {'api_key': 'private'},
          'serverId': 'private-server-id',
          'libraryId': 'private-library-id',
          'itemId': 'private-item-id',
          'mediaId': 'private-media-id',
          'baseUrl': 'http://192.168.1.20:8096',
        },
        generatedAt: DateTime.utc(2026, 8, 23),
      );
      final diagnostics =
          (jsonDecode(text) as Map<String, dynamic>)['diagnostics'] as Map;

      expect(diagnostics['session_id'], 'pbs-safeCorrelation12');
      for (final key in const [
        'httpHeaders',
        'requestHeaders',
        'queryParameters',
        'serverId',
        'libraryId',
        'itemId',
        'mediaId',
        'baseUrl',
      ]) {
        expect(diagnostics[key], '[REDACTED]', reason: key);
      }
      expect(text, isNot(contains('private-server-id')));
      expect(text, isNot(contains('192.168.1.20')));
    },
  );
}

const _profile = TvDeviceProfile(
  manufacturer: 'Example',
  model: 'TV',
  sdk: 36,
  abis: ['arm64-v8a'],
  displayModes: [],
  hdrTypes: [],
  codecs: [],
  audioOutputs: [],
);
