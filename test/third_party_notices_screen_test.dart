import 'package:anime_tv/features/settings/presentation/third_party_notices_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('notices adapt to phone and TV D-pad navigation', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ThirdPartyNoticesScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The responsive header and the bundled document both carry this title.
    expect(find.text('Third-party notices'), findsNWidgets(2));
    expect(find.text('Package licenses'), findsOneWidget);
    expect(find.textContaining('media_kit_libs_android_video'), findsOneWidget);
    expect(find.textContaining('AndroidX Media3'), findsNothing);
    expect(find.textContaining('libVLC'), findsNothing);
    expect(find.textContaining('Kasane Teto name and artwork'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'notices.back');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'notices.packages');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'notices.back');
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1280, 720);
    await tester.pump(const Duration(milliseconds: 300));

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'notices.back');
    expect(find.text('Flutter package licenses'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'notices.packages');

    final document = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(document.controller!.offset, 0);
    expect(document.controller!.position.maxScrollExtent, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(document.controller!.offset, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
