import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/presentation/diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('TV panel compares working and failed playback timelines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final diagnostics = derivePlaybackSessionDiagnostics([
      ..._events('pbs-workingSession1234', working: true),
      ..._events('pbs-failedSession12345', working: false),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackSessionDiagnosticsPanel(diagnostics: diagnostics),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('PLAYBACK SESSION TIMELINES'), findsOneWidget);
    expect(find.text('WORKING VS FAILED PLAYBACK'), findsOneWidget);
    expect(find.text('WORKING SESSION'), findsOneWidget);
    expect(find.text('FAILED SESSION'), findsOneWidget);
    expect(find.textContaining('Codec H264'), findsOneWidget);
    expect(find.textContaining('Codec Hevc'), findsOneWidget);
    expect(find.textContaining('Fallback attempted'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<Map<String, Object?>> _events(String id, {required bool working}) {
  final start = working
      ? DateTime.utc(2026, 8, 23, 12)
      : DateTime.utc(2026, 8, 23, 13);
  final source = working ? 'web' : 'torrent';
  final codec = working ? 'h264' : 'hevc';
  final events = <Map<String, Object?>>[
    _event(id, start, 1, 'source_selected', {
      'status': 'selected_by_user',
      'source_kind': source,
    }),
    _event(
      id,
      start.add(const Duration(milliseconds: 20)),
      2,
      'decoder_selected',
      {
        'status': 'selected_automatically',
        'decoder': working ? 'hardware_adaptive' : 'hardware_direct',
        'codec': codec,
      },
    ),
    _event(
      id,
      start.add(const Duration(milliseconds: 40)),
      3,
      'stream_opened',
      {
        'status': working ? 'opened' : 'open_failed',
        'source_kind': source,
        if (!working) 'reason_code': 'codec_open_failed',
      },
    ),
  ];
  if (!working) {
    events.add(
      _event(
        id,
        start.add(const Duration(milliseconds: 60)),
        4,
        'fallback_attempted',
        {
          'status': 'attempted',
          'fallback_kind': 'decoder',
          'decoder': 'software_compatibility',
          'reason_code': 'codec_open_failed',
        },
      ),
    );
  }
  events.add(
    _event(
      id,
      start.add(const Duration(seconds: 2)),
      working ? 4 : 5,
      'final_outcome',
      {'status': working ? 'working' : 'failed'},
    ),
  );
  return events;
}

Map<String, Object?> _event(
  String id,
  DateTime timestamp,
  int sequence,
  String stage,
  Map<String, Object?> details,
) => {
  'timestamp': timestamp.toIso8601String(),
  'component': playbackSessionDiagnosticComponent,
  'context': {
    'session_id': id,
    'sequence': sequence,
    'stage': stage,
    ...details,
  },
};
