import 'package:anime_tv/features/player/presentation/player_failover_notification.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fallback reasons are user-facing, sanitized, and bounded', () {
    expect(
      sanitizePlayerFailoverReason('Bad state: No video frames were rendered.'),
      'No video frames were rendered.',
    );
    expect(
      sanitizePlayerFailoverReason(
        'Exception: GET https://private.example/video.m3u8?token=secret '
        'authorization=Bearer-secret ${'x' * 300}',
      ),
      isNot(contains('private.example')),
    );
    final sanitized = sanitizePlayerFailoverReason(
      'Exception: GET https://private.example/video.m3u8?token=secret '
      'authorization=Bearer-secret ${'x' * 300}',
    );
    expect(sanitized, isNot(contains('Bearer-secret')));
    expect(sanitized.length, lessThanOrEqualTo(113));
  });

  test('destination labels never expose URLs or unbounded provider data', () {
    expect(
      playerFailoverDestination(
        isWebStream: true,
        providerName: 'Provider A https://private.example/${'x' * 80}',
      ),
      isNot(contains('://')),
    );
    expect(
      playerFailoverDestination(isWebStream: false, quality: '1080p'),
      '1080p Debrid stream',
    );
  });

  test('notice gate deduplicates a burst but allows a later real switch', () {
    final gate = PlayerFailoverNoticeGate();
    final start = DateTime.utc(2026, 8, 20, 12);
    final first = gate.next(
      destination: 'Provider A Web stream',
      reason: 'Playback timed out',
      now: start,
    );
    final duplicate = gate.next(
      destination: 'Provider A Web stream',
      reason: 'Playback timed out',
      now: start.add(const Duration(seconds: 2)),
    );
    final later = gate.next(
      destination: 'Provider A Web stream',
      reason: 'Playback timed out',
      now: start.add(const Duration(seconds: 9)),
    );

    expect(
      first,
      'Stream switched to Provider A Web stream • The previous stream timed out.',
    );
    expect(duplicate, isNull);
    expect(later, first);
  });

  testWidgets('fallback notice is floating, bounded, and does not take focus', (
    tester,
  ) async {
    final gate = PlayerFailoverNoticeGate();
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              autofocus: true,
              focusNode: focusNode,
              onPressed: () => showPlayerFailoverNotice(
                context,
                gate: gate,
                destination: '1080p Debrid stream',
                reason: 'No first frame',
              ),
              child: const Text('Recover'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Recover'));
    await tester.pump();
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(snackBar.duration, playerFailoverNoticeDuration);
    expect(snackBar.width, lessThanOrEqualTo(620));
    expect(
      find.textContaining('Stream switched to 1080p Debrid stream'),
      findsOneWidget,
    );
    expect(focusNode.hasFocus, isTrue);
  });
}
