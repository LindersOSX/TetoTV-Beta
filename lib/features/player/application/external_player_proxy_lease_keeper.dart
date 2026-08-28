import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/marketplace/data/web_playback_proxy.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

typedef ExternalProxyLeaseRetainer = PlaybackResourceLease? Function(Uri uri);

/// Keeps an opaque, app-owned web proxy capability alive after TetoTV hands
/// playback to another Android app and disposes its own player route.
///
/// The external app receives only the loopback capability URL. Provider URLs,
/// request headers, and credentials remain inside [WebPlaybackProxy]. Android
/// reports when the external activity returns so the extra capability can be
/// revoked immediately.
class ExternalPlayerProxyLeaseKeeper {
  ExternalPlayerProxyLeaseKeeper({
    required Stream<void> playerReturns,
    required this.retainOwnedProxy,
  }) {
    _returnSubscription = playerReturns.listen((_) {
      unawaited(release());
    });
  }

  static final instance = ExternalPlayerProxyLeaseKeeper(
    playerReturns: AndroidTvBridge.instance.externalPlayerReturns,
    retainOwnedProxy: WebPlaybackProxy.instance.retainSessionForUri,
  );

  final ExternalProxyLeaseRetainer retainOwnedProxy;
  late final StreamSubscription<void> _returnSubscription;
  PlaybackResourceLease? _activeLease;
  int _generation = 0;

  bool get hasActiveLease => _activeLease != null;

  /// Retains [uri] only when it belongs to TetoTV's active playback proxy.
  /// Public URLs and granted local content need no additional Dart lifetime.
  Future<bool> retainForHandoff(Uri? uri) async {
    if (uri == null) return false;
    final next = retainOwnedProxy(uri);
    if (next == null) return false;
    final generation = ++_generation;
    final previous = _activeLease;
    _activeLease = next;
    if (previous != null && !identical(previous, next)) {
      await previous.close();
    }
    if (generation != _generation) {
      if (identical(_activeLease, next)) _activeLease = null;
      // A return/release can arrive while the superseded lease above is
      // closing. Never report a lease as retained after that newer lifecycle
      // event revoked it. PlaybackResourceLease.close is required to be
      // idempotent, so this is safe when release() already closed [next].
      await next.close();
      return false;
    }
    return true;
  }

  Future<void> release() async {
    _generation++;
    final lease = _activeLease;
    _activeLease = null;
    await lease?.close();
  }

  Future<void> dispose() async {
    await _returnSubscription.cancel();
    await release();
  }
}
