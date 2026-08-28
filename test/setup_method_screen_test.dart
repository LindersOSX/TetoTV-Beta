import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/presentation/phone_setup_screen.dart';
import 'package:anime_tv/features/settings/presentation/setup_method_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'waits for setup start, then uses an explicit landscape D-pad graph',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gate = Completer<void>();
      final progress = _GatedSetupProgressController(gate);
      final router = _testRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(_TestApp(router: router, progress: progress));
      await tester.pump();

      expect(progress.startCalls, 1);
      expect(find.text('Setup on device'), findsOneWidget);
      expect(find.text('Setup on another device'), findsOneWidget);
      expect(
        find.text('Complete every setup step directly on this device.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Use a phone, tablet, or computer while this device stays on the setup screen.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('setup-method-preparing')),
        findsOneWidget,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('setup-method.tv'),
      );

      await tester.tap(
        find.byKey(const ValueKey('setup-method-tv')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tv-setup-destination')), findsNothing);

      gate.complete();
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('setup-method-ready-message')),
        findsOneWidget,
      );
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup-method.tv');

      final tvRect = tester.getRect(
        find.byKey(const ValueKey('setup-method-tv')),
      );
      final phoneRect = tester.getRect(
        find.byKey(const ValueKey('setup-method-phone')),
      );
      expect(phoneRect.left, greaterThan(tvRect.right));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'setup-method.phone',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'setup-method.phone',
        reason: 'cross-axis input must not escape the two-choice focus graph',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup-method.tv');

      await tester.tap(find.byKey(const ValueKey('setup-method-tv')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tv-setup-destination')),
        findsOneWidget,
      );
      expect(router.canPop(), isFalse);

      await tester.tap(find.byKey(const ValueKey('tv-setup-back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('setup-method-screen')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup-method.tv');
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('setup-method-phone')),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isFalse,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'setup-method.phone',
      );
      tester
          .widget<TvFocusable>(
            find.descendant(
              of: find.byKey(const ValueKey('setup-method-phone')),
              matching: find.byType(TvFocusable),
            ),
          )
          .onPressed();
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        PhoneSetupScreen.routePath,
      );
      await tester.tap(find.byKey(const ValueKey('phone-setup-back')));
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'setup-method.phone',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portrait layout stacks touch targets and opens phone route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final progress = _ImmediateSetupProgressController();
    final router = _testRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_TestApp(router: router, progress: progress));
    await tester.pumpAndSettle();

    expect(find.text('Setup on device'), findsOneWidget);
    expect(find.text('Setup on another device'), findsOneWidget);
    expect(
      find.text('Complete every setup step directly on this device.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Use a phone, tablet, or computer while this device stays on the setup screen.',
      ),
      findsOneWidget,
    );

    final tvRect = tester.getRect(
      find.byKey(const ValueKey('setup-method-tv')),
    );
    final phoneRect = tester.getRect(
      find.byKey(const ValueKey('setup-method-phone')),
    );
    expect(phoneRect.top, greaterThan(tvRect.bottom));
    expect(tvRect.width, greaterThanOrEqualTo(320));
    expect(phoneRect.width, greaterThanOrEqualTo(320));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup-method.tv');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup-method.phone',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup-method.phone',
      reason: 'cross-axis input must stay on the selected portrait card',
    );

    tester.view.physicalSize = const Size(800, 360);
    await tester.pumpAndSettle();

    final rotatedTvRect = tester.getRect(
      find.byKey(const ValueKey('setup-method-tv')),
    );
    final rotatedPhoneRect = tester.getRect(
      find.byKey(const ValueKey('setup-method-phone')),
    );
    expect(rotatedPhoneRect.left, greaterThan(rotatedTvRect.right));
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setup-method.tv');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'setup-method.phone',
    );

    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

GoRouter _testRouter() => GoRouter(
  initialLocation: SetupMethodScreen.routePath,
  routes: [
    GoRoute(
      path: SetupMethodScreen.routePath,
      builder: (context, state) => SetupMethodScreen(
        focusPhoneOnReady: state.uri.queryParameters['focus'] == 'phone',
      ),
    ),
    GoRoute(
      path: '/setup',
      builder: (context, state) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('tv-setup-back'),
            onPressed: () => context.go('/setup/start?focus=tv'),
            child: const SizedBox(key: ValueKey('tv-setup-destination')),
          ),
        ),
      ),
    ),
    GoRoute(
      path: PhoneSetupScreen.routePath,
      builder: (context, state) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('phone-setup-back'),
            onPressed: () => context.go('/setup/start?focus=phone'),
            child: const SizedBox(key: ValueKey('phone-setup-destination')),
          ),
        ),
      ),
    ),
  ],
);

class _TestApp extends StatelessWidget {
  const _TestApp({required this.router, required this.progress});

  final GoRouter router;
  final SetupProgressController progress;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [setupProgressProvider.overrideWith((_) => progress)],
    child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
  );
}

class _GatedSetupProgressController extends SetupProgressController {
  _GatedSetupProgressController(this.gate)
    : super(const FlutterSecureStorage());

  final Completer<void> gate;
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    await gate.future;
  }
}

class _ImmediateSetupProgressController extends SetupProgressController {
  _ImmediateSetupProgressController() : super(const FlutterSecureStorage());

  @override
  Future<void> start() async {}
}
