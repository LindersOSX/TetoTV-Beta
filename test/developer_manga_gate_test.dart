import 'dart:io';

import 'package:anime_tv/features/manga/presentation/developer_manga_gate.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('fails closed while Developer Mode is still loading', (
    tester,
  ) async {
    final controller = _MutableAppUpdateController(
      const AppUpdateState(loaded: false, developerMode: true),
    );
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateControllerProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('manga-developer-gate-loading')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manga-secret-content')), findsNothing);

    controller.replace(
      const AppUpdateState(loaded: true, developerMode: false),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('manga-developer-gate-closed')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manga-secret-content')), findsNothing);

    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(find.byKey(const ValueKey('home-content')), findsOneWidget);
  });

  testWidgets('shows the protected child only after Developer Mode is loaded', (
    tester,
  ) async {
    final controller = _MutableAppUpdateController(
      const AppUpdateState(loaded: true, developerMode: true),
    );
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateControllerProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('manga-secret-content')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manga-developer-gate-loading')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('manga-developer-gate-closed')),
      findsNothing,
    );
  });

  testWidgets('revokes the protected child when Developer Mode is disabled', (
    tester,
  ) async {
    final controller = _MutableAppUpdateController(
      const AppUpdateState(loaded: true, developerMode: true),
    );
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateControllerProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-secret-content')), findsOneWidget);

    controller.replace(
      const AppUpdateState(loaded: true, developerMode: false),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('manga-secret-content')), findsNothing);
    expect(
      find.byKey(const ValueKey('manga-developer-gate-closed')),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(find.byKey(const ValueKey('home-content')), findsOneWidget);
  });
}

GoRouter _router() => GoRouter(
  initialLocation: '/manga',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          const Scaffold(body: SizedBox(key: ValueKey('home-content'))),
    ),
    GoRoute(
      path: '/manga',
      builder: (_, _) => const DeveloperMangaGate(
        child: Scaffold(body: SizedBox(key: ValueKey('manga-secret-content'))),
      ),
    ),
  ],
);

class _MutableAppUpdateController extends AppUpdateController {
  _MutableAppUpdateController(AppUpdateState initial)
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => initial.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = initial;
  }

  void replace(AppUpdateState next) => state = next;
}

class _UnusedReleaseSource extends AppReleaseSource {
  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) =>
      throw UnimplementedError();

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => throw UnimplementedError();
}
