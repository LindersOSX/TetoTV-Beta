import 'package:anime_tv/app/router.dart';
import 'package:anime_tv/features/local_media/presentation/local_media_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('legacy library route opens integrated source management', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    addTearDown(() => appRouter.go('/'));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    appRouter.go('/library');
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: appRouter)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LocalMediaScreen), findsOneWidget);
    expect(
      appRouter.routeInformationProvider.value.uri.path,
      '/settings/local-media',
    );
    expect(find.text('Media sources'), findsOneWidget);
    expect(find.text('SEARCH YOUR MEDIA'), findsNothing);
    expect(find.text('Add local video'), findsOneWidget);
    expect(find.text('Back'), findsNothing);
    expect(_railSelection(tester, const ValueKey('main-nav-settings')), isTrue);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.choose-video',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.choose-video',
    );

    for (final expected in const [
      'local-media.jellyfin.address',
      'local-media.jellyfin.username',
      'local-media.jellyfin.password',
      'local-media.jellyfin.connect',
      'local-media.plex.address',
      'local-media.plex.token',
      'local-media.plex.connect',
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        expected,
        reason: 'every media-source management control stays D-pad reachable',
      );
    }

    appRouter.go('/settings/local-media');
    await tester.pumpAndSettle();
    expect(find.byType(LocalMediaScreen), findsOneWidget);
    expect(
      appRouter.routeInformationProvider.value.uri.path,
      '/settings/local-media',
      reason: 'the previous Settings deep link stays compatible',
    );
    expect(_railSelection(tester, const ValueKey('main-nav-settings')), isTrue);
    expect(tester.takeException(), isNull);
  });
}

bool _railSelection(WidgetTester tester, Key key) {
  final semantics = tester
      .widgetList<Semantics>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.selected != null,
          ),
        ),
      )
      .single;
  return semantics.properties.selected!;
}
