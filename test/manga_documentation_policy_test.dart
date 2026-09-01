import 'dart:io';

import 'package:anime_tv/features/manga/data/manga_archive_service.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public manga claims keep the user-added data-only boundary', () {
    final readme = File('README.md').readAsStringSync();
    final contentPolicy = File('CONTENT_POLICY.md').readAsStringSync();
    final repositoryGuide = File(
      'docs/MANGA_REPOSITORIES.md',
    ).readAsStringSync();
    final storeInventory = File('docs/STORE_DATA_SAFETY.md').readAsStringSync();

    expect(readme, contains('Hidden unless Developer Mode is enabled'));
    expect(readme, contains('no manga catalog is bundled or recommended'));
    expect(readme, contains('Tachiyomi/Mihon APK'));
    expect(readme, contains('extensions or execute code'));
    expect(contentPolicy, contains('user-added public HTTPS OPDS'));
    expect(contentPolicy, contains('metadata, not executable code'));
    expect(
      repositoryGuide,
      contains(
        'No source is bundled, suggested, endorsed, or remotely enabled',
      ),
    );
    expect(
      storeInventory,
      contains('Developer Mode and the Manga Preview are optional'),
    );
  });

  test('manga request, archive, and interruption limits stay documented', () {
    expect(maximumMangaCatalogResponseBytes, 2 * 1024 * 1024);
    expect(maximumMangaRemotePageBytes, 20 * 1024 * 1024);
    expect(maximumMangaArchivePages, 1000);
    expect(maximumMangaArchivePageBytes, 20 * 1024 * 1024);
    expect(maximumMangaArchiveUncompressedBytes, 512 * 1024 * 1024);
    expect(maximumMangaArchiveCompressionRatio, 100);

    final repositoryGuide = File(
      'docs/MANGA_REPOSITORIES.md',
    ).readAsStringSync();
    final privacy = File('docs/PRIVACY.md').readAsStringSync();

    for (final disclosure in const <String>[
      'limited to 2 MiB',
      'not retried automatically',
      'at most five redirects',
      'at most 1,000 image pages',
      '2,000 total ZIP entries',
      'at most 20 MiB per page',
      '512 MiB total',
      'maximum 100:1 compression ratio',
      '32 megapixels',
    ]) {
      expect(repositoryGuide, contains(disclosure));
    }
    expect(
      repositoryGuide,
      contains('force-stop or process death ends the transfer'),
    );
    expect(privacy, contains('remote reading-order/archive URL'));
    expect(privacy, contains('marked as needing'));
    expect(privacy, contains('reauthorization'));
  });

  test(
    'credential, Discord, and dependency disclosures match manga behavior',
    () {
      final readme = File('README.md').readAsStringSync();
      final repositoryGuide = File(
        'docs/MANGA_REPOSITORIES.md',
      ).readAsStringSync();
      final privacy = File('docs/PRIVACY.md').readAsStringSync();
      final notices = File('docs/THIRD_PARTY_NOTICES.md').readAsStringSync();

      expect(
        repositoryGuide,
        contains('Reader-page redirects may change origin, but TetoTV strips'),
      );
      expect(
        privacy,
        contains(
          'A reader-page redirect may change origin, but TetoTV removes',
        ),
      );
      expect(readme, contains('Keystore-backed secure storage'));
      expect(readme, contains('never forwards a user-added'));
      expect(privacy, contains('cover or page URL'));
      expect(
        privacy,
        contains('anime Rich Presence artwork behavior is unchanged'),
      );
      expect(readme, contains('retaining chapter/page activity'));
      expect(
        notices,
        contains(
          'user-added OPDS 1.x feeds in the Developer Mode Manga Preview',
        ),
      );
    },
  );
}
