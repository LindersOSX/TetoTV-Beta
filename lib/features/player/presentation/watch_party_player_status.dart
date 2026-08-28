import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';

/// Keeps legacy controller/broker copy migration-safe while the player UI
/// consistently presents the feature's current product name.
String watchPartyPlayerCopy(String value) =>
    value.replaceAll('Watch Together', 'Watch Party');

String? watchPartyPlayerStatus(WatchPartyState state) {
  final session = state.session;
  if (session == null) return null;
  final connection = state.connection == WatchPartyConnection.connected
      ? ''
      : ' • RECONNECTING';
  if (state.isHost) {
    return 'PARTY ${session.roomCode} • HOST$connection';
  }
  final status = switch (state.timelineCompatibility) {
    WatchPartyTimelineCompatibility.exact => 'EXACT SOURCE',
    WatchPartyTimelineCompatibility.compatible => 'SOURCE ALIGNED',
    WatchPartyTimelineCompatibility.adjusted => 'TIMELINE ADJUSTED',
    WatchPartyTimelineCompatibility.differentCut => 'DIFFERENT CUT',
    WatchPartyTimelineCompatibility.unverified => 'VERIFYING',
  };
  return 'PARTY ${session.roomCode} • $status$connection';
}

String watchPartyTimelineDetail(WatchPartyState state) =>
    switch (state.session?.role) {
      WatchPartyRole.host => 'Host timeline • everyone follows this player',
      WatchPartyRole.guest => switch (state.timelineCompatibility) {
        WatchPartyTimelineCompatibility.exact =>
          'Exact source • scene timing verified',
        WatchPartyTimelineCompatibility.compatible =>
          'Different source • matching timeline',
        WatchPartyTimelineCompatibility.adjusted =>
          'Different source • intro/outro timing aligned',
        WatchPartyTimelineCompatibility.differentCut =>
          'Different cut • use the sync adjustment if scenes do not match',
        WatchPartyTimelineCompatibility.unverified =>
          'Verifying this episode and source',
      },
      null => 'Watch Party is not active',
    };
