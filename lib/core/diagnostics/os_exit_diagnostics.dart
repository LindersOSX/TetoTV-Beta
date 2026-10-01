/// Non-identifying Android process-exit evidence for explicit support reports.
/// An OS kill is not necessarily a crash, and an unavailable query is not an
/// empty successful scan. Keep those distinctions separate from crash reports.
Map<String, Object?> sanitizeProcessExitHistory(
  Object? value, {
  required DateTime now,
}) {
  final input = value is Map ? value : const <Object?, Object?>{};
  final scanStatus = switch (input['scan_status']) {
    'scanned' => 'scanned',
    'unsupported' => 'unsupported',
    _ => 'unavailable',
  };
  final end = now.toUtc().millisecondsSinceEpoch;
  final start = end - const Duration(hours: 48).inMilliseconds;
  final records = <Map<String, Object?>>[];
  final exits = input['exits'];
  if (scanStatus == 'scanned' && exits is List) {
    for (final item in exits.take(300)) {
      if (item is! Map) continue;
      final timestamp = item['occurred_at_ms'];
      if (timestamp is! num ||
          !timestamp.isFinite ||
          timestamp < start ||
          timestamp > end) {
        continue;
      }
      final reason = switch (item['reason']) {
        'self_exit' => 'self_exit',
        'signal' => 'signal',
        'low_memory' => 'low_memory',
        'java_crash' => 'java_crash',
        'native_crash' => 'native_crash',
        'anr' => 'anr',
        'initialization_failure' => 'initialization_failure',
        'permission_change' => 'permission_change',
        'excessive_resource_usage' => 'excessive_resource_usage',
        'user_requested' => 'user_requested',
        'user_stopped' => 'user_stopped',
        'dependency_died' => 'dependency_died',
        'other' => 'other',
        _ => 'unknown',
      };
      records.add({
        'occurred_at_ms': timestamp.toInt(),
        'reason': reason,
        'reason_code': _boundedNumber(item['reason_code'], 0, 999),
        'status': _boundedNumber(item['status'], -999, 999),
        'importance': switch (item['importance']) {
          'foreground' => 'foreground',
          'foreground_service' => 'foreground_service',
          'visible' => 'visible',
          'perceptible' => 'perceptible',
          'service' => 'service',
          'cached' => 'cached',
          _ => 'unknown',
        },
        'pss_mb': _boundedNumber(item['pss_mb'], 0, 1048576),
        'rss_mb': _boundedNumber(item['rss_mb'], 0, 1048576),
        'process_role': switch (item['process_role']) {
          'main' => 'main',
          'aniyomi_worker' => 'aniyomi_worker',
          _ => 'other',
        },
        // Never trust an arbitrary caller to reclassify a memory kill or
        // intentional exit as a crash. This field is explanatory only;
        // crash capture/upload uses its existing separate consent policy.
        'reportable_crash': const {
          'java_crash',
          'native_crash',
          'anr',
        }.contains(reason),
      });
    }
  }
  records.sort(
    (left, right) => (left['occurred_at_ms']! as int).compareTo(
      right['occurred_at_ms']! as int,
    ),
  );
  return {
    'schema': 'tetotv-os-exit-history-v1',
    'scan_status': scanStatus,
    'low_memory_kill_report_supported':
        scanStatus == 'scanned' &&
            input['low_memory_kill_report_supported'] is bool
        ? input['low_memory_kill_report_supported']
        : null,
    'hours': 48,
    'capacity': 12,
    'exits': records.length > 12
        ? records.sublist(records.length - 12)
        : records,
  };
}

int _boundedNumber(Object? value, int minimum, int maximum) =>
    value is num && value.isFinite ? value.toInt().clamp(minimum, maximum) : 0;
