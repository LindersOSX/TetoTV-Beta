import 'dart:io';

import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();

  String method(String start, String end) {
    final startIndex = source.indexOf(start);
    expect(startIndex, greaterThanOrEqualTo(0), reason: start);
    final endIndex = source.indexOf(end, startIndex + start.length);
    expect(endIndex, greaterThan(startIndex), reason: end);
    return source.substring(startIndex, endIndex);
  }

  test('Media3 is an explicit Android-only choice; MPV stays the default', () {
    for (final platform in TargetPlatform.values) {
      for (final preference in PreferredPlayer.values) {
        expect(
          useBuiltInMedia3(
            preference: preference,
            platform: platform,
            isWeb: false,
          ),
          platform == TargetPlatform.android &&
              preference == PreferredPlayer.media3,
        );
        expect(
          useBuiltInMedia3(
            preference: preference,
            platform: platform,
            isWeb: true,
          ),
          isFalse,
        );
      }
    }
  });

  test(
    'Media3 injects the common player contract without initializing MPV',
    () {
      expect(source, contains('platformPlayer: _media3Player'));
      expect(
        RegExp(
          r'if \(!_usesMedia3\) \{\s*_controller = VideoController\(',
        ).hasMatch(source),
        isTrue,
      );
      expect(source, contains('Media3VideoSurface('));
      expect(source, contains('VideoController? _controller'));
      expect(source, contains('TetoPlayerChrome('));
      expect(source, isNot(contains('NativeMedia3PlayerScreen(')));
    },
  );

  test('engine identity reaches watch party, metrics, health and HUD', () {
    expect(source, contains("_usesMedia3 ? 'media3' : 'mpv'"));
    expect(source, contains("_usesMedia3 ? 'Media3 (Built in)' : 'MPV'"));
    expect(RegExp(r'engine: _engineKey').allMatches(source).length, 2);
    expect(source, contains('engineKey: _engineKey'));
    expect(source, contains('recordPlayerSuccess(device.key, _engineKey)'));
    expect(source, contains('recordPlayerFailure(device.key, _engineKey)'));
    final metrics = method(
      'Future<String?> _readPlaybackPerformanceProperty',
      'Future<void> _seekWithPerformanceDiagnostics',
    );
    expect(metrics, contains('return media3.readProperty(property)'));
  });

  test('alternate surface is captured only for Media3 at session creation', () {
    expect(source, contains('late final bool _media3SurfaceViewEnabled;'));
    expect(
      RegExp(
        r'_media3SurfaceViewEnabled\s*=\s*_usesMedia3 &&\s*ref.read\(settingsPreferencesProvider\).media3SurfaceViewEnabled',
      ).hasMatch(source),
      isTrue,
    );
    expect(source, contains('useSurfaceView: _media3SurfaceViewEnabled'));
    final surface = File(
      'lib/features/player/presentation/media3_video_surface.dart',
    ).readAsStringSync();
    expect(surface, contains('this.useSurfaceView = false'));
    expect(surface, contains('if (!widget.useSurfaceView)'));
    expect(surface, contains('return AndroidView('));
    expect(surface, contains('return PlatformViewLink('));
    expect(surface, contains('PlatformViewsService.initExpensiveAndroidView('));
    expect(surface, contains("widget.useSurfaceView ? 'surface' : 'texture'"));
  });

  test('Media3 seeks never capture or render a scene thumbnail', () {
    final capture = method(
      'Future<void> _captureTrickplay(',
      'Future<void> _openAudioTrackPicker()',
    );
    expect(capture, contains('if (_usesMedia3) return;'));
    expect(
      capture.indexOf('if (_usesMedia3) return;'),
      lessThan(capture.indexOf('await Future<void>.delayed')),
    );
    expect(capture, contains("_player.screenshot(format: 'image/jpeg')"));
    expect(
      source,
      contains('if (_seekPreview case final preview? when !_usesMedia3)'),
    );
    expect(
      RegExp(
        r'onSeekPreview:\s*!_usesMedia3 &&\s*supportsProvisionalSeekPreview\(\s*_currentStream,?\s*\)',
      ).hasMatch(source),
      isTrue,
    );
    // Final seek commits still use the normal queue and diagnostics.
    expect(source, contains('onSeek: _seekTo'));
    expect(source, contains('await _seekWithPerformanceDiagnostics(target)'));
  });

  test(
    'MPV performance recovery and surface internals do not run on Media3',
    () {
      final watchdog = method(
        'void _startPerformanceWatchdog()',
        'Future<String?> _optionalNativeProperty',
      );
      expect(watchdog, contains('if (_usesMedia3) return'));
      final detach = method(
        'Future<void> _detachAndroidVideoOutputBeforeRelease()',
        'Future<bool> _prepareForEngineHandoff',
      );
      expect(detach, contains('if (controller == null) return'));
      expect(detach, contains('controller.platform.future'));
    },
  );

  test(
    'Media3 uses the same caption preferences and registers all sidecars',
    () {
      final options = method(
        'Future<void> _applyMedia3Options()',
        'Future<void> _applySubtitle(',
      );
      for (final key in [
        'subtitleSize',
        'subtitlePosition',
        'subtitleColor',
        'subtitleBackground',
        'audioLanguage',
      ]) {
        expect(options, contains("'$key':"));
      }
      expect(source, contains('platform.addSubtitleTrack('));
      expect(source, contains('select: false'));
      expect(source, contains('_selectPreferredTracks(_player.state.tracks)'));
    },
  );

  test('unsupported sync offsets are explained, not silently applied', () {
    final options = method(
      'Future<void> _applyMedia3Options()',
      'Future<void> _applySubtitle(',
    );
    expect(options, contains("'subtitleDelayMs': 0"));
    expect(options, contains("'audioDelayMs': 0"));
    expect(
      source,
      contains('Audio and caption timing offsets are available in '),
    );
    expect(
      source,
      contains("'MPV. Switch the built-in player in Playback settings '"),
    );
  });
}
