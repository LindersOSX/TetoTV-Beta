import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Keeps Android from treating an explicitly started offline transfer as idle
/// when TetoTV is sent to the background.
///
/// This is a best-effort foreground-service lease, not a scheduled job. It
/// covers normal Home/minimize and task switching, but Android still stops all
/// app work after a force-stop and may enforce platform foreground-service time
/// limits on unusually long batches.
abstract interface class OfflineDownloadKeepAlive {
  Future<OfflineDownloadKeepAliveLease> acquire();
}

abstract interface class OfflineDownloadKeepAliveLease {
  Future<void> release();
}

final offlineDownloadKeepAliveProvider = Provider<OfflineDownloadKeepAlive>(
  (_) => AndroidOfflineDownloadKeepAlive(),
);

class AndroidOfflineDownloadKeepAlive implements OfflineDownloadKeepAlive {
  AndroidOfflineDownloadKeepAlive({AndroidTvBridge? bridge})
    : _bridge = bridge ?? AndroidTvBridge.instance;

  final AndroidTvBridge _bridge;
  static int _nextLease = 0;

  @override
  Future<OfflineDownloadKeepAliveLease> acquire() async {
    final leaseId = 'offline-${++_nextLease}';
    final acquired = await _bridge.acquireOfflineDownloadKeepAlive(leaseId);
    if (!acquired) return const NoopOfflineDownloadKeepAliveLease();
    return _AndroidOfflineDownloadKeepAliveLease(_bridge, leaseId);
  }
}

class _AndroidOfflineDownloadKeepAliveLease
    implements OfflineDownloadKeepAliveLease {
  _AndroidOfflineDownloadKeepAliveLease(this._bridge, this._leaseId);

  final AndroidTvBridge _bridge;
  final String _leaseId;
  Future<void>? _release;

  @override
  Future<void> release() =>
      _release ??= _bridge.releaseOfflineDownloadKeepAlive(_leaseId);
}

class NoopOfflineDownloadKeepAlive implements OfflineDownloadKeepAlive {
  const NoopOfflineDownloadKeepAlive();

  @override
  Future<OfflineDownloadKeepAliveLease> acquire() async =>
      const NoopOfflineDownloadKeepAliveLease();
}

class NoopOfflineDownloadKeepAliveLease
    implements OfflineDownloadKeepAliveLease {
  const NoopOfflineDownloadKeepAliveLease();

  @override
  Future<void> release() async {}
}

/// Acquires a lease without allowing platform notification failures to stop a
/// download the user explicitly requested.
Future<OfflineDownloadKeepAliveLease> acquireOfflineDownloadKeepAliveSafely(
  OfflineDownloadKeepAlive keepAlive,
) async {
  try {
    return await keepAlive.acquire();
  } catch (_) {
    return const NoopOfflineDownloadKeepAliveLease();
  }
}

Future<void> releaseOfflineDownloadKeepAliveSafely(
  OfflineDownloadKeepAliveLease lease,
) async {
  try {
    await lease.release();
  } catch (_) {
    // Releasing the native notification is best effort. Android also clears
    // the non-sticky service when the app process ends.
  }
}
