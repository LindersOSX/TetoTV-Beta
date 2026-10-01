import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:anime_tv/features/streaming/data/debrid_account_history.dart';
import 'package:anime_tv/features/streaming/presentation/cached_download_file_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(1920, 1080),
    const Size(360, 640),
    const Size(720, 360),
  ]) {
    testWidgets(
      'cached file picker fits $size with larger text and scrolls to a file',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final files = [
          for (var i = 1; i <= 12; i++)
            DebridAccountVideoFile(
              id: '$i',
              name:
                  'A longer unrecognized show title - $i (1080p) [Dual Audio].mkv',
              size: 1500000000,
              open: () async =>
                  throw StateError('Picker must not resolve files'),
            ),
        ];
        DebridAccountVideoFile? chosen;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    chosen = await showTetoDialog<DebridAccountVideoFile>(
                      context: context,
                      builder: (_) => CachedDownloadFileDialog(
                        downloadName: 'Unrecognized show complete season',
                        files: files,
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('cached-file:12')),
          150,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cached-file:12')));
        await tester.pumpAndSettle();
        expect(chosen?.id, '12');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cached file picker supports D-pad selection and Back cancellation',
    (tester) async {
      final files = [
        for (var i = 1; i <= 2; i++)
          DebridAccountVideoFile(
            id: '$i',
            name: 'Episode $i.mkv',
            size: 10,
            open: () async => throw StateError('Must not resolve'),
          ),
      ];
      DebridAccountVideoFile? chosen;
      var returns = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await showTetoDialog<DebridAccountVideoFile>(
                    context: context,
                    builder: (_) => CachedDownloadFileDialog(
                      downloadName: 'Unrecognized show',
                      files: files,
                    ),
                  );
                  returns++;
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen?.id, '2');
      expect(returns, 1);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(chosen, isNull);
      expect(returns, 2);
    },
  );
}
