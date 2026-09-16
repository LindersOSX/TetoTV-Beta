import 'dart:io';

import 'package:anime_tv/features/manga/data/manga_archive_service.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String prose(String path) =>
      File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');

  test(
    'manga disclosures separate new executable providers from retained legacy catalogs',
    () {
      final readme = prose('README.md');
      final contentPolicy = prose('CONTENT_POLICY.md');
      final repositoryGuide = prose('docs/MANGA_REPOSITORIES.md');
      final storeInventory = prose('docs/STORE_DATA_SAFETY.md');

      expect(
        readme,
        contains('The preference is enabled by default, setup asks'),
      );
      expect(readme, contains('Core Manga does not require Developer Mode'));
      expect(readme, isNot(contains('Access still requires Developer Mode')));
      expect(
        repositoryGuide,
        contains('without deleting saved local data or blocking core Manga'),
      );
      expect(
        prose('docs/MANGA_READER.md'),
        contains('core Manga reader does not require Developer Mode'),
      );
      expect(
        readme,
        contains(
          'Experimental Aniyomi compatibility remains Developer Mode-only',
        ),
      );
      expect(
        readme.toLowerCase(),
        contains('no manga catalog is bundled or recommended'),
      );
      expect(readme, contains('Tachiyomi/Mihon APK'));
      expect(readme, contains('extensions or execute code'));
      expect(
        readme,
        contains(
          'new-source UI does not offer a new OPDS/data-catalog setup flow',
        ),
      );
      expect(readme, contains('Previously saved OPDS 1.x/2.0'));
      expect(readme, contains('untrusted JavaScript or TypeScript'));
      expect(readme, contains('bounded QuickJS compatibility runtime'));
      expect(
        contentPolicy,
        contains(
          'new sources through user-supplied public HTTPS Seanime-compatible repositories',
        ),
      );
      expect(
        contentPolicy,
        contains(
          'legacy declarative TetoTV manga catalog is metadata, not executable code',
        ),
      );
      expect(
        contentPolicy,
        contains(
          'executes untrusted JavaScript/TypeScript in a bounded QuickJS isolate',
        ),
      );
      expect(
        contentPolicy,
        contains('Existing library entries and downloads are preserved'),
      );
      expect(
        repositoryGuide,
        contains('new-source UI does not offer this format'),
      );
      expect(
        repositoryGuide,
        contains(
          'No source is bundled, suggested, endorsed, or remotely enabled',
        ),
      );
      expect(
        storeInventory,
        contains('the manga reader can be disabled in Settings'),
      );
      expect(
        storeInventory,
        contains(
          'separately confirmed JavaScript/TypeScript manga-provider installs',
        ),
      );
      expect(
        storeInventory,
        contains(
          'Extensions do not receive TetoTV account/service credentials',
        ),
      );
    },
  );

  test('manga request, archive, and interruption limits stay documented', () {
    expect(maximumMangaCatalogResponseBytes, 2 * 1024 * 1024);
    expect(maximumMangaRemotePageBytes, 20 * 1024 * 1024);
    expect(maximumMangaArchivePages, 1000);
    expect(maximumMangaArchivePageBytes, 20 * 1024 * 1024);
    expect(maximumMangaArchiveUncompressedBytes, 512 * 1024 * 1024);
    expect(maximumMangaArchiveCompressionRatio, 100);
    expect(const MangaArchiveLimits().maximumEntries, 2000);

    final repositoryGuide = prose('docs/MANGA_REPOSITORIES.md');
    final privacy = prose('docs/PRIVACY.md');

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
    expect(
      privacy.toLowerCase(),
      contains('force-stop or process death ends the transfer'),
    );
    expect(
      privacy,
      contains(
        'remote page/archive URLs and request headers are deliberately not',
      ),
    );
    expect(
      privacy,
      contains(
        'Startup restores local interrupted state without automatically fetching fresh source capabilities',
      ),
    );
    expect(
      privacy,
      contains('An explicit Seanime resume uses the active profile'),
    );
    expect(privacy, contains('Paused jobs are not automatically resumed'));
    expect(
      repositoryGuide,
      contains('fingerprint still matches and their hashes/files validate'),
    );
    expect(
      repositoryGuide,
      contains(
        'legacy interrupted transfer can require reopening its original catalog/publication',
      ),
    );
  });

  test(
    'credential, Discord, and dependency disclosures match manga behavior',
    () {
      final readme = prose('README.md');
      final repositoryGuide = prose('docs/MANGA_REPOSITORIES.md');
      final privacy = prose('docs/PRIVACY.md');
      final notices = prose('docs/THIRD_PARTY_NOTICES.md');

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
      expect(privacy, contains('public book-cover URL'));
      expect(
        privacy,
        contains('no query, fragment, user info, or request headers'),
      );
      expect(privacy, contains('hides both the title and cover'));
      expect(
        privacy,
        contains('anime Rich Presence artwork behavior is unchanged'),
      );
      expect(readme, contains('retaining page/total activity'));
      expect(
        notices,
        contains(
          'previously saved OPDS 1.x feeds in the optional manga reader',
        ),
      );
      expect(
        notices,
        contains('executable providers are not data-only catalogs'),
      );
    },
  );

  test(
    'manga tracking and backup disclosures distinguish opt-in service writes and local exports',
    () {
      final storeInventory = prose('docs/STORE_DATA_SAFETY.md');
      expect(
        storeInventory,
        contains(
          'No SIMKL manga sync, silent title matching, prior-history upload',
        ),
      );
      expect(
        storeInventory,
        contains('manual retry is limited to the selected title/tracker'),
      );
      expect(storeInventory, contains('TetoTV does not save the passphrase'));
      expect(
        storeInventory,
        contains('app reset/uninstall does not remove it'),
      );
      expect(
        storeInventory,
        contains(
          'No source/account credentials, source installations, downloaded pages, resolved page capabilities, legacy OPDS titles or tracker links/outbox are included',
        ),
      );
    },
  );
}
