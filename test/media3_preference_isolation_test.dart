import 'dart:io';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'Media3 outcomes cannot train or reset MPV device health in SQLite',
    () async {
      final sqlite = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(sqlite.close);
      await sqlite.execute('''
      CREATE TABLE device_player_profiles (
        device_key TEXT PRIMARY KEY,
        preferred_engine TEXT NOT NULL DEFAULT 'mpv',
        media3_failures INTEGER NOT NULL DEFAULT 0,
        mpv_failures INTEGER NOT NULL DEFAULT 0,
        vlc_failures INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )
    ''');
      final database = TetoTvDatabase.forTesting(sqlite);
      await database.recordPlayerFailure('fixture-tv', 'mpv');
      await database.recordPlayerFailure('fixture-tv', 'mpv');
      final before = await sqlite.query('device_player_profiles');
      expect(before.single['mpv_failures'], 2);

      final result = await database.recordPlayerFailure('fixture-tv', 'media3');
      expect(result.mpvFailures, 2);
      await database.recordPlayerSuccess('fixture-tv', 'media3');
      expect(await sqlite.query('device_player_profiles'), before);
      await database.recordPlayerFailure('fresh-media3-tv', 'media3');
      await database.recordPlayerSuccess('fresh-media3-tv', 'media3');
      expect(await sqlite.query('device_player_profiles'), before);

      await database.recordPlayerFailure('fixture-tv', 'mpv');
      expect(
        (await database.devicePlaybackProfile('fixture-tv')).mpvFailures,
        3,
      );
      await database.recordPlayerSuccess('fixture-tv', 'mpv');
      expect(
        (await database.devicePlaybackProfile('fixture-tv')).mpvFailures,
        0,
      );
    },
  );

  final player = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();
  test('Media3 startup ignores the saved MPV per-series decoder mode', () {
    expect(
      player,
      matches(
        RegExp(
          r'_decoderMode\s*=\s*_usesMedia3\s*\?\s*PlaybackDecoderMode\.hardwareSafe\s*:\s*switch\s*\(_seriesPreferences\.decoder\)',
        ),
      ),
    );
    expect(
      player,
      matches(
        RegExp(
          r'if\s*\(!_usesMedia3\s*&&\s*_decoderMode\s*==\s*PlaybackDecoderMode\.hardwareSafe\s*&&\s*releaseRequiresSoftwareDecoder\(_currentRelease\)\)',
        ),
      ),
    );
  });

  test('general Media3 preference saves preserve the MPV decoder preference', () {
    final save = player.substring(
      player.indexOf('Future<void> _saveSeriesPreferences()'),
      player.indexOf('Future<void> _saveDecoderPreference()'),
    );
    expect(
      save,
      matches(
        RegExp(
          r'decoder:\s*_usesMedia3\s*\?\s*_seriesPreferences\.decoder\s*:\s*switch\s*\(_decoderMode\)',
        ),
      ),
    );
    expect(save, contains('subtitleSize: _subtitleSize'));
    expect(save, contains('audioLanguage: audioLanguage'));
    expect(save, contains('videoFit: switch (_videoFit)'));
  });

  test(
    'explicit Media3 decoder switches cannot persist an MPV decoder choice',
    () {
      final start = player.indexOf('Future<void> _saveDecoderPreference()');
      final save = player.substring(start, player.indexOf('\n  }', start));
      final guard = save.indexOf('if (_usesMedia3) return;');
      expect(guard, greaterThanOrEqualTo(0));
      expect(guard, lessThan(save.indexOf('_seriesPreferences.copyWith')));
    },
  );
}
