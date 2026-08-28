import 'dart:io';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class DiagnosticsExporter {
  const DiagnosticsExporter();

  Future<File> export() async {
    final directory = await getApplicationDocumentsDirectory();
    final profile = await AndroidTvBridge.instance.getDeviceProfile(
      refresh: true,
    );
    final version = await AndroidTvBridge.instance.getAppVersion();
    final database = await TetoTvDatabase.instance.diagnosticsSnapshot();
    final crashHistory = await AndroidTvBridge.instance
        .getRecentLocalCrashSummaries()
        .catchError((_) => const LocalCrashSummaryHistory.empty());
    final isTelevision = await AndroidTvBridge.instance.isTelevision(
      refresh: true,
    );
    final report = buildRedactedDiagnosticsText(
      version: version,
      profile: profile,
      isTelevision: isTelevision,
      diagnostics: attachRecentCrashSummaries(
        database,
        crashHistory.summaries,
        sourceDroppedOutsideWindow: crashHistory.droppedOutsideWindow,
        sourceDroppedForCapacity: crashHistory.droppedForCapacity,
      ),
      generatedAt: DateTime.now().toUtc(),
    );
    final file = File(path.join(directory.path, 'tetotv-diagnostics.json'));
    return file.writeAsString(report, flush: true);
  }
}
