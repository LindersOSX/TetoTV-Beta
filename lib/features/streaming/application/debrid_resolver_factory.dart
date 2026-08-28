import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

StreamResolver createDebridStreamResolver({
  required DebridService service,
  required String token,
  required ReleaseSource source,
}) => switch (service) {
  DebridService.realDebrid => RealDebridStreamResolver(
    RealDebridClient(token: token),
    source,
  ),
  DebridService.torBox => TorBoxStreamResolver(
    TorBoxClient(token: token),
    source,
  ),
  DebridService.allDebrid => AllDebridStreamResolver(
    AllDebridClient(token: token),
    source,
  ),
  DebridService.premiumize => PremiumizeStreamResolver(
    PremiumizeClient(token: token),
    source,
  ),
};
