import 'package:anime_tv/features/catalog/data/anime_title_logo_cache_manager.dart';
import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live lookup returns only verified English artwork or text fallback',
    (_) async {
      final logo = await AnimeTitleLogoClient(
        cacheStore: _NoOpTitleLogoCacheStore(),
      ).lookup(154587);

      // Artwork providers can change their default image independently. The
      // untagged legacy response must therefore be ignored in favor of the
      // language-aware endpoint's explicitly English logo, which is then
      // downloaded through the dedicated safe artwork transport.
      expect(logo, isNotNull);
      expect(logo!.languageCode, 'en');
      expect(logo.source, AnimeTitleLogoSource.aniZipTmdb);
      expect(logo.url.host, 'image.tmdb.org');

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
