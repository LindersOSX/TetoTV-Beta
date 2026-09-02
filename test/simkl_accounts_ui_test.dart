import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/simkl_account_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Accounts visibly lists SIMKL with a secure connect action', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          simklAccountControllerProvider.overrideWith(
            (_) => _ReadySimklController(),
          ),
        ],
        child: const MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-area-accounts')));
    await tester.pumpAndSettle();

    expect(find.text('SIMKL'), findsOneWidget);
    expect(find.text('Connect SIMKL'), findsOneWidget);
    expect(find.byKey(const ValueKey('accounts-simkl-action')), findsOneWidget);
    expect(
      find.text('Link SIMKL securely through its official sign-in page.'),
      findsOneWidget,
    );

    final simklFocusable = tester
        .widgetList<TvFocusable>(find.byType(TvFocusable))
        .singleWhere(
          (widget) => widget.focusNode?.debugLabel == 'accounts.simkl',
        );
    simklFocusable.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.settings-section.profiles',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.tracking.local-profiles',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.settings-section.profiles',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'accounts.simkl');
  });

  testWidgets('failed SIMKL verification offers a direct reconnect action', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          simklAccountControllerProvider.overrideWith(
            (_) => _FailedSimklController(),
          ),
        ],
        child: const MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-area-accounts')));
    await tester.pumpAndSettle();

    expect(find.text('RECONNECT'), findsOneWidget);
    expect(find.text('Reconnect SIMKL'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
    expect(
      find.text('Replace the saved connection through SIMKL’s secure sign-in.'),
      findsOneWidget,
    );
  });
}

class _ReadySimklController extends SimklAccountController {
  _ReadySimklController()
    : super(
        const FlutterSecureStorage(),
        capabilityProbe: (_) async => null,
        profileLoader: ({required accessToken, required clientId}) =>
            throw UnimplementedError(),
      ) {
    state = const SimklAccountState(isAvailable: true);
  }

  @override
  Future<void> load({bool force = false}) async {}
}

class _FailedSimklController extends SimklAccountController {
  _FailedSimklController()
    : super(
        const FlutterSecureStorage(),
        capabilityProbe: (_) async => null,
        profileLoader: ({required accessToken, required clientId}) =>
            throw UnimplementedError(),
      ) {
    state = const SimklAccountState(
      isAvailable: true,
      hasSavedCredentials: true,
      error: 'The saved SIMKL account could not be verified. Reconnect it.',
    );
  }

  @override
  Future<void> load({bool force = false}) async {}
}
