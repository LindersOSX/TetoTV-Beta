import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These binding contracts complement the monitor's executable fake-clock and
// native-property tests. The host suite cannot render the Android MPV backend.
void main() {
  final source = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final player = source.substring(
    source.indexOf('class _MpvTvPlayerScreenState'),
  );

  String section(String start, String end) {
    final begin = player.indexOf(start);
    expect(begin, greaterThanOrEqualTo(0), reason: start);
    final finish = player.indexOf(end, begin + start.length);
    expect(finish, greaterThan(begin), reason: end);
    return player.substring(begin, finish);
  }

  void inOrder(String value, List<String> tokens) {
    var offset = 0;
    for (final token in tokens) {
      final next = value.indexOf(token, offset);
      expect(next, greaterThanOrEqualTo(offset), reason: token);
      offset = next + token.length;
    }
  }

  test(
    'monitor shares the existing random session and accepts only context',
    () {
      final binding = section(
        '_playbackPerformance = PlaybackPerformanceMonitor(',
        '_watchPartyHandle =',
      );
      expect(binding, contains('sessionId: _playbackDiagnostics.sessionId'));
      expect(
        binding,
        contains('persist: _database.savePlaybackPerformanceSnapshot'),
      );
      for (final field in [
        'position:',
        'duration:',
        'playing:',
        'buffering:',
        'seeking:',
        'hudVisible:',
        'inForeground:',
        'playbackSpeed:',
        'androidDisplayFps:',
      ]) {
        expect(binding, contains(field));
      }
      for (final privateInput in [
        '_source',
        '_currentRelease',
        '_httpHeaders',
        'widget.',
        'ref.read',
      ]) {
        expect(binding, isNot(contains(privateInput)));
      }
    },
  );

  test(
    'each native open has a separate attempt and reports failure honestly',
    () {
      final open = section(
        'Future<int?> _openCurrentMedia',
        'Future<bool> _openMedia',
      );
      inOrder(open, [
        'required int diagnosticAttempt',
        '_playbackPerformance.beginAttempt(',
        'attempt: diagnosticAttempt',
        'sourceKind: _diagnosticSourceKind.wireValue',
        'requestedDecoder: _diagnosticDecoder.wireValue',
        'await _player.open(',
        '} catch (_) {',
        '_playbackPerformance.failed()',
        'rethrow',
        '_mediaOpenInProgress = false',
        'if (!playerMediaOpenCanCommit(',
        '_playbackPerformance.endAttempt()',
        '_playbackPerformance.opened()',
      ]);
      expect(
        RegExp(
          r'diagnosticAttempt: diagnosticOpenAttempt',
        ).allMatches(player).length,
        3,
        reason: 'initial/source open, decoder reopen, and explicit retry',
      );
      expect(
        RegExp(
          r'\+\+_diagnosticStreamOpenAttempt;\s*'
          r'_playbackPerformance.endAttempt\(\);',
        ).allMatches(player).length,
        3,
        reason: 'stop measuring the previous engine before reconfiguration',
      );
    },
  );

  test('native probes cannot await initialization across player teardown', () {
    final reader = section(
      'Future<String?> _readPlaybackPerformanceProperty',
      'Future<void> _seekWithPerformanceDiagnostics',
    );
    inOrder(reader, [
      'if (!_canApplyTrackSelection || _mediaOpenInProgress) return null',
      'if (platform is! NativePlayer) return null',
      'platform.getProperty(property, waitForInitialization: false)',
    ]);
    expect(reader, isNot(contains('setProperty')));
    expect(reader, isNot(contains('await ')));
  });

  test(
    'seek instrumentation does not swallow failures or count resume as user input',
    () {
      final seek = section(
        'Future<void> _seekWithPerformanceDiagnostics',
        'void _onTracksChanged',
      );
      inOrder(seek, [
        '_performanceSeekDepth++',
        '_playbackPerformance.noteSeek(userInitiated: userInitiated)',
        'await _player.seek(position)',
        '} finally {',
        '_performanceSeekDepth--',
        '_playbackPerformance.stateChanged()',
      ]);
      expect(seek, isNot(contains('catch')));
      expect(RegExp(r'_player\.seek\(').allMatches(player).length, 1);
      expect(player, isNot(contains('seek: _player.seek')));
      final restore = section(
        'Future<bool> _restoreResumePosition',
        'Duration _effectiveHandoffPosition',
      );
      expect(
        restore,
        contains(
          '_seekWithPerformanceDiagnostics(resume, userInitiated: false)',
        ),
      );
    },
  );

  test(
    'state transitions and lifecycle are observed without native polling callbacks',
    () {
      final lifecycle = section(
        'void didChangeAppLifecycleState',
        'Future<String?> _readPlaybackPerformanceProperty',
      );
      inOrder(lifecycle, [
        '_performanceInForeground = state == AppLifecycleState.resumed',
        '_playbackPerformance.stateChanged()',
        'if (!_performanceInForeground) unawaited(_playbackPerformance.flush())',
      ]);
      expect(lifecycle, isNot(contains('getProperty')));
      expect(
        player,
        contains('_bufferingSubscription = _player.stream.buffering.listen'),
      );
      final playing = section(
        '_playingSubscription =',
        '_mediaActionSubscription =',
      );
      expect(playing, contains('_playbackPerformance.stateChanged()'));
      final params = section(
        '_videoParamsSubscription =',
        '_lastPlayerPlaying =',
      );
      expect(
        params,
        contains('_playbackPerformance.markVideoParametersAvailable()'),
      );
      expect(params, contains("reasonCode: 'video_parameters_available'"));
    },
  );

  test('handoff and route disposal stop probing before native release', () {
    final handoff = section(
      'Future<bool> _prepareForEngineHandoff',
      'void _showAutomaticFailoverNotice',
    );
    inOrder(handoff, [
      '_playbackPerformance.endAttempt()',
      '_engineHandoffInProgress = true',
      'await _bufferingSubscription?.cancel()',
      'await _player.dispose()',
    ]);
    final dispose = section(
      'void dispose()',
      'Widget build(BuildContext context)',
    );
    inOrder(dispose, [
      'WidgetsBinding.instance.removeObserver(this)',
      '_playbackPerformance.dispose()',
      '_bufferingSubscription?.cancel()',
      '_engineHandoffInProgress = true',
      'await _player.dispose()',
    ]);
  });

  test('terminal runtime failures preserve the useful final snapshot', () {
    final outcome = section(
      'void _recordDiagnosticOutcome',
      'void _recordDiagnosticWorkingOutcome',
    );
    inOrder(outcome, [
      'outcome == PlaybackDiagnosticOutcome.failed',
      '_playbackPerformance.failed()',
      'outcome == PlaybackDiagnosticOutcome.completed',
      '_playbackPerformance.endAttempt()',
    ]);
  });
}
