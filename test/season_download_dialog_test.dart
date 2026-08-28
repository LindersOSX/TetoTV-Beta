import 'package:anime_tv/features/downloads/presentation/season_download_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('season chooser exposes TV choices and focuses Best available', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showSeasonDownloadDialog(
              context,
              directTorrentAvailable: false,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('season-download-dialog')),
      findsOneWidget,
    );
    expect(find.text('Best available'), findsOneWidget);
    expect(find.text('2160p'), findsOneWidget);
    expect(find.text('Web streams'), findsOneWidget);
    expect(
      find.text('Enable direct torrent streaming in Settings'),
      findsOneWidget,
    );
    final bestAvailable = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byKey(const ValueKey('season-download-quality-best')),
        matching: find.byType(OutlinedButton),
      ),
    );
    final primary = tester.widget<FilledButton>(
      find.byKey(const ValueKey('season-download-start')),
    );
    expect(bestAvailable.autofocus, isTrue);
    expect(primary.autofocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct-torrent warning starts focus on Cancel', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => confirmDirectSeasonDownload(context),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final cancel = tester.widget<TextButton>(
      find.byKey(const ValueKey('season-download-direct-cancel')),
    );
    expect(cancel.autofocus, isTrue);
    expect(find.textContaining('public IP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
