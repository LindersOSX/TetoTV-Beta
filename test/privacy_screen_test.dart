import 'package:anime_tv/features/settings/presentation/privacy_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('privacy disclosure fits a phone and supports D-pad scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: PrivacyScreen()));
    await tester.pumpAndSettle();

    final bundledPolicy = await rootBundle.loadString('docs/PRIVACY.md');
    expect(bundledPolicy, contains('Effective date: August 28, 2026'));
    expect(
      bundledPolicy,
      contains('Offline downloads, background operation, and external players'),
    );
    expect(bundledPolicy, contains('dataSync'));
    expect(
      bundledPolicy.replaceAll('\r\n', '\n'),
      contains('private-server\nheaders'),
    );

    expect(find.text('Privacy & data'), findsOneWidget);
    expect(find.textContaining('TetoTV privacy disclosure'), findsOneWidget);
    expect(
      find.textContaining('Effective date: August 28, 2026'),
      findsOneWidget,
    );
    expect(find.textContaining('does not sell personal data'), findsOneWidget);
    expect(
      find.textContaining(
        'Offline downloads, background operation, and external players',
      ),
      findsOneWidget,
    );
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'privacy.back');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
