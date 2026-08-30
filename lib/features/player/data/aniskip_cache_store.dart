import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/player/application/skip_segment_service.dart';

class TetoTvAniSkipCacheStore implements AniSkipCacheStore {
  const TetoTvAniSkipCacheStore(this.database);

  static const maximumStaleAge = Duration(days: 90);

  final TetoTvDatabase database;

  @override
  Future<Map<String, dynamic>?> read(String key, {bool allowExpired = false}) =>
      database.cachedJson(
        key,
        allowExpired: allowExpired,
        maxStaleAge: allowExpired ? maximumStaleAge : null,
      );

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> payload, {
    required Duration maxAge,
  }) => database.cacheJson(key, payload, maxAge: maxAge);
}
