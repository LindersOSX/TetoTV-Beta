import 'dart:io';

import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('Public Updates shows its release date beside the version', (
    tester,
  ) async {
    final release = _release(
      '1.0.2',
      releasedAtUtc: DateTime.utc(2026, 8, 16, 19, 24),
    );
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.upToDate,
        currentVersion: '1.0.2+410001',
        latestVersion: release.version,
        release: release,
        updateChannel: AppUpdateChannel.public,
      ),
    );

    expect(find.text('TetoTV 1.0.2+410001 • Aug 16, 2026'), findsOneWidget);
    expect(find.textContaining('Latest 1.0.2 • Aug 16, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Beta Updates and release history show release dates', (
    tester,
  ) async {
    final latest = _release(
      '2.0.10',
      releasedAtUtc: DateTime.utc(2026, 8, 20, 2, 5),
    );
    final previous = _release(
      '2.0.9',
      releasedAtUtc: DateTime.utc(2026, 8, 12, 17, 30),
    );
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.available,
        currentVersion: '2.0.9+410000',
        latestVersion: latest.version,
        release: latest,
        updateChannel: AppUpdateChannel.beta,
        developerMode: true,
        releaseHistory: [latest, previous],
      ),
    );

    expect(
      find.textContaining('Latest 2.0.10 Beta • Aug 20, 2026'),
      findsWidgets,
    );
    expect(find.text('2.0.10 Beta • Aug 20, 2026'), findsOneWidget);
    await tester.tap(find.text('2.0.10 Beta • Aug 20, 2026'));
    await tester.pumpAndSettle();
    expect(find.text('2.0.9 Beta • Aug 12, 2026'), findsOneWidget);
    expect(
      find.text('Installed version: 2.0.9 • Aug 12, 2026'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing GitHub dates leave the version label clean', (
    tester,
  ) async {
    final release = _release('1.0.2');
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.upToDate,
        currentVersion: '1.0.2+410001',
        latestVersion: release.version,
        release: release,
      ),
    );

    expect(find.text('TetoTV 1.0.2+410001'), findsOneWidget);
    expect(find.textContaining('Jan 1, 1970'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpSystemUpdates(
  WidgetTester tester,
  AppUpdateState state,
) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = _FixedAppUpdateController(state);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [appUpdateControllerProvider.overrideWith((_) => controller)],
      child: const MaterialApp(home: AccountsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('System'));
  await tester.pumpAndSettle();
}

AppReleaseInfo _release(
  String version, {
  DateTime? releasedAtUtc,
}) => AppReleaseInfo(
  tagName: 'v$version',
  version: version,
  name: 'TetoTV $version',
  releasedAtUtc: releasedAtUtc,
  asset: AppReleaseAsset(
    name: 'TetoTV-v$version-universal.apk',
    apiUrl:
        'https://api.github.com/repos/LindersOSX/TetoTV-Beta/releases/assets/1',
    publicUrl:
        'https://github.com/LindersOSX/TetoTV-Beta/releases/download/'
        'v$version/TetoTV-v$version-universal.apk',
    size: 2 * 1024 * 1024,
  ),
);

class _FixedAppUpdateController extends AppUpdateController {
  _FixedAppUpdateController(AppUpdateState fixedState)
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => fixedState.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = fixedState;
  }
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
