import 'dart:async';
import 'package:anime_tv/app/app.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';
import 'package:anime_tv/core/legal/bundled_licenses.dart';
import 'package:anime_tv/core/performance/performance_monitor.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/platform/startup_device_classification.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledThirdPartyLicenses();
  FlutterError.onError = (details) {
    // Full framework exceptions can contain signed media URLs supplied by a
    // decoder or network stack. Keep rich console output for development, but
    // rely on the redacted on-device diagnostics store in release builds.
    if (kDebugMode) FlutterError.presentError(details);
    unawaited(
      TetoTvDatabase.instance.recordDiagnosticEvent(
        category: 'flutter',
        message: details.exceptionAsString(),
        details: details.stack?.toString(),
      ),
    );
    unawaited(
      recordAnonymousCrash(
        kind: 'flutter',
        error: details.exception,
        stack: details.stack,
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      TetoTvDatabase.instance.recordDiagnosticEvent(
        category: 'platform',
        message: error,
        details: stack.toString(),
      ),
    );
    unawaited(
      recordAnonymousCrash(kind: 'platform', error: error, stack: stack),
    );
    return true;
  };
  MediaKit.ensureInitialized();
  PerformanceMonitor.instance.start();
  final themeControllerFuture = preloadThemeStudioController();
  final startupView = PlatformDispatcher.instance.implicitView;
  final fallbackTelevision = inferStartupTelevisionFromViewport(
    platform: defaultTargetPlatform,
    physicalSize: startupView?.physicalSize ?? Size.zero,
    devicePixelRatio: startupView?.devicePixelRatio ?? 0,
  );
  final deviceClassification = await startDeviceClassification(
    loadDeviceCategory: ({required refresh}) =>
        AndroidTvBridge.instance.getDeviceCategory(refresh: refresh),
  );
  final themeController = await themeControllerFuture;
  runApp(
    ProviderScope(
      observers: [AnonymousHandledErrorObserver()],
      overrides: [
        startupDeviceCategoryProvider.overrideWith(
          (_) => deviceClassification.initialCategory,
        ),
        startupTelevisionFallbackProvider.overrideWithValue(fallbackTelevision),
        themeStudioControllerProvider.overrideWith((_) => themeController),
      ],
      child: _StartupDeviceCategoryCorrection(
        lateCategory: deviceClassification.lateCategory,
        child: const TetoTvApp(),
      ),
    ),
  );
}

class _StartupDeviceCategoryCorrection extends ConsumerStatefulWidget {
  const _StartupDeviceCategoryCorrection({
    required this.lateCategory,
    required this.child,
  });

  final Future<AndroidDeviceCategory>? lateCategory;
  final Widget child;

  @override
  ConsumerState<_StartupDeviceCategoryCorrection> createState() =>
      _StartupDeviceCategoryCorrectionState();
}

class _StartupDeviceCategoryCorrectionState
    extends ConsumerState<_StartupDeviceCategoryCorrection> {
  @override
  void initState() {
    super.initState();
    unawaited(_applyLateCategory());
  }

  Future<void> _applyLateCategory() async {
    final category =
        await (widget.lateCategory ??
            Future.value(AndroidDeviceCategory.unknown));
    if (!mounted || category == AndroidDeviceCategory.unknown) return;
    ref.read(startupDeviceCategoryProvider.notifier).state = category;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
