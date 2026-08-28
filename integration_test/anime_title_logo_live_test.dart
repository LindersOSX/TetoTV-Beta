import 'package:anime_tv/features/catalog/data/anime_title_logo_cache_manager.dart';
import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'AniZip metadata and approved artwork transport resolve a clear logo',
    (_) async {
      final logo = await AnimeTitleLogoClient(
        cacheStore: _NoOpTitleLogoCacheStore(),
      ).lookup(339);

      expect(logo, isNotNull);
      expect(logo!.tvdbId, 78814);
      expect(logo.url.host, 'artworks.thetvdb.com');

      final file = await animeTitleLogoCacheManager.getSingleFile(
        logo.url.toString(),
      );
      final bytes = await file.openRead(0, 8).expand((chunk) => chunk).toList();
      expect(bytes, <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _NoOpTitleLogoCacheStore implements AnimeTitleLogoCacheStore {
  @override
  Future<Map<String, dynamic>?> read(
    String key, {
    bool allowExpired = false,
  }) async => null;

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    required Duration maxAge,
  }) async {}
}
