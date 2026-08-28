import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/marketplace/presentation/marketplace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'uninstall confirmation focuses the action and has deterministic TV traversal',
    (tester) async {
      bool? accepted;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  accepted = await showMarketplaceConfirmationDialog(
                    context,
                    title: 'Uninstall Test provider?',
                    body: 'Its web streams will no longer appear.',
                    action: 'UNINSTALL',
                    autofocusAction: true,
                  );
                },
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(find.text('UNINSTALL'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'marketplace.confirm.action',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'marketplace.confirm.cancel',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'marketplace.confirm.action',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(accepted, isTrue);
      expect(find.text('UNINSTALL'), findsNothing);
    },
  );
}
