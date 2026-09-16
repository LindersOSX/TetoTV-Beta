import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:sqflite/sqflite.dart';

class AddonStore {
  const AddonStore(this.database);

  final TetoTvDatabase database;

  Future<List<AddonRepository>> repositories() async {
    final db = await database.database;
    // Older private builds seeded a third-party catalog. Public builds never
    // ship, restore, or silently enable a source catalog. Remove only records
    // marked as the legacy app default; user-added repositories and explicitly
    // installed providers remain untouched.
    await db.transaction(removeLegacyDefaultRepositories);
    final rows = await db.query(
      'addon_repositories',
      orderBy: 'url COLLATE NOCASE',
    );
    return rows
        .map(
          (row) => AddonRepository(
            url: row['url']! as String,
            enabled: row['enabled'] == 1,
            isDefault: row['is_default'] == 1,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              row['updated_at']! as int,
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<void> saveRepository(AddonRepository repository) async {
    final db = await database.database;
    await db.insert(
      'addon_repositories',
      _repositoryRow(repository),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Replaces only the repository list, retaining caches for repositories that
  /// existed before the transaction and removing caches for rolled-back adds.
  Future<void> replaceRepositories(
    Iterable<AddonRepository> repositories,
  ) async {
    final snapshot = repositories.toList(growable: false);
    final snapshotUrls = snapshot.map((item) => item.url).toSet();
    final db = await database.database;
    await db.transaction((txn) async {
      final current = await txn.query('addon_repositories', columns: ['url']);
      for (final row in current) {
        final url = row['url'] as String?;
        if (url == null || snapshotUrls.contains(url)) continue;
        await txn.delete(
          'marketplace_cache',
          where: 'repository_url = ?',
          whereArgs: [url],
        );
      }
      await txn.delete('addon_repositories');
      for (final repository in snapshot) {
        await txn.insert(
          'addon_repositories',
          _repositoryRow(repository),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> removeRepository(String url) async {
    final db = await database.database;
    await db.transaction((txn) async {
      await txn.delete(
        'addon_repositories',
        where: 'url = ?',
        whereArgs: [url],
      );
      await txn.delete(
        'marketplace_cache',
        where: 'repository_url = ?',
        whereArgs: [url],
      );
    });
  }

  Future<void> cacheCatalog(
    String repositoryUrl,
    String payload, {
    Uri? resourceBaseUri,
  }) async {
    final db = await database.database;
    await db.insert('marketplace_cache', {
      'repository_url': repositoryUrl,
      'payload_json': payload,
      'resource_base_url': resourceBaseUri?.toString(),
      'fetched_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> cachedCatalog(String repositoryUrl) async {
    return (await cachedCatalogEntry(repositoryUrl))?.payload;
  }

  Future<CachedMarketplaceCatalog?> cachedCatalogEntry(
    String repositoryUrl,
  ) async {
    final db = await database.database;
    final rows = await db.query(
      'marketplace_cache',
      columns: ['payload_json', 'resource_base_url'],
      where: 'repository_url = ?',
      whereArgs: [repositoryUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final payload = rows.first['payload_json'] as String?;
    if (payload == null) return null;
    return CachedMarketplaceCatalog(
      payload: payload,
      resourceBaseUrl: rows.first['resource_base_url'] as String?,
    );
  }

  Future<List<InstalledStreamingAddon>> installedAddons() async {
    final db = await database.database;
    final rows = await db.query(
      'installed_addons',
      orderBy: 'id COLLATE NOCASE',
    );
    final result = <InstalledStreamingAddon>[];
    for (final row in rows) {
      try {
        result.add(InstalledStreamingAddon.fromRow(row));
      } on FormatException {
        // A malformed persisted addon is ignored instead of breaking Settings
        // or stream discovery. It can still be removed by reinstalling it.
      }
    }
    return result;
  }

  /// Installed video providers only. Keeping this filter at the persistence
  /// boundary prevents a manga extension from ever entering playback search.
  Future<List<InstalledStreamingAddon>> installedStreamingAddons() async =>
      (await installedAddons())
          .where((addon) => addon.manifest.isOnlineStreamProvider)
          .toList(growable: false);

  /// Installed Seanime manga providers only.
  Future<List<InstalledStreamingAddon>> installedMangaAddons() async =>
      (await installedAddons())
          .where((addon) => addon.manifest.isMangaProvider)
          .toList(growable: false);

  Future<void> install(InstalledStreamingAddon addon) async {
    final db = await database.database;
    await db.transaction((txn) async {
      // SQLite's TEXT primary key is case-sensitive. Remove only a
      // casing-equivalent legacy row in the same transaction so an upstream
      // ID casing correction updates rather than duplicates the provider.
      await txn.delete(
        'installed_addons',
        where: 'id = ? COLLATE NOCASE AND id != ?',
        whereArgs: [addon.manifest.id, addon.manifest.id],
      );
      await txn.insert('installed_addons', {
        'id': addon.manifest.id,
        'manifest_json': jsonEncode(addon.manifest.toJson()),
        'payload': addon.payload,
        'enabled': addon.enabled ? 1 : 0,
        'repository_url': addon.manifest.repositoryUrl,
        'installed_at': addon.installedAt.millisecondsSinceEpoch,
        'updated_at': addon.updatedAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Persists current catalog health metadata without replacing installed
  /// executable metadata or crossing repository ownership boundaries.
  ///
  /// A missing same-provenance candidate intentionally leaves the last known
  /// advisory in place. This is the conservative fallback when an entry is
  /// removed, its repository is disabled, or its refresh fails; a different
  /// repository reusing the same provider ID is never treated as its owner.
  Future<void> syncInstalledCatalogAdvisories(
    Iterable<MarketplaceAddon> candidates,
  ) async {
    final byProvenance = <(String, String), MarketplaceAddon>{
      for (final candidate in candidates)
        (marketplaceAddonIdentityKey(candidate.id), candidate.repositoryUrl):
            candidate,
    };
    final db = await database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'installed_addons',
        orderBy: 'id COLLATE NOCASE',
      );
      for (final row in rows) {
        InstalledStreamingAddon current;
        try {
          current = InstalledStreamingAddon.fromRow(row);
        } on FormatException {
          continue;
        }
        final advisory =
            byProvenance[(
              marketplaceAddonIdentityKey(current.manifest.id),
              current.manifest.repositoryUrl,
            )];
        if (advisory == null ||
            !marketplaceAddonIdsMatch(current.manifest.id, advisory.id) ||
            current.manifest.repositoryUrl != advisory.repositoryUrl) {
          continue;
        }
        final nextManifest = current.manifest.withCatalogAdvisoryFrom(advisory);
        if (!_sameCatalogAdvisory(current.manifest, nextManifest)) {
          final decoded = jsonDecode(row['manifest_json']! as String);
          if (decoded is! Map) continue;
          final manifestJson = decoded.map<String, Object?>(
            (key, value) => MapEntry('$key', value),
          );
          // Remove legacy aliases as well as canonical keys so a cleared
          // advisory cannot reappear when the manifest is parsed again.
          manifestJson.removeWhere(
            (key, _) => const {
              'workingTag',
              'isWorking',
              'working',
              'brokenTag',
              'isBroken',
              'broken',
              'deprecatedTag',
              'isDeprecated',
              'deprecated',
              'lastWorkingVersion',
            }.contains(key),
          );
          if (advisory.reportedWorking != null) {
            manifestJson['workingTag'] = advisory.reportedWorking;
          }
          if (advisory.reportedBroken) manifestJson['brokenTag'] = true;
          if (advisory.isDeprecated) manifestJson['deprecatedTag'] = true;
          if (advisory.lastWorkingVersion != null) {
            manifestJson['lastWorkingVersion'] = advisory.lastWorkingVersion;
          }
          await txn.update(
            'installed_addons',
            {'manifest_json': jsonEncode(manifestJson)},
            where: 'id = ? AND repository_url = ?',
            whereArgs: [row['id'], current.manifest.repositoryUrl],
          );
        }
      }
    });
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final db = await database.database;
    await db.update(
      'installed_addons',
      {
        'enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> uninstall(String id) async {
    final db = await database.database;
    await db.delete('installed_addons', where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, ProviderHealth>> providerHealth() =>
      database.providerHealth();

  Future<void> recordProviderSuccess(String id) =>
      database.recordProviderSuccess(id);

  /// Clears transient discovery failures after a normal provider response.
  /// Unlike validated playback success, discovery alone must not make this
  /// extension the user's new last-good provider.
  Future<void> recordProviderHealthyResponse(String id) =>
      database.recordProviderHealthyResponse(id);

  Future<ProviderHealth> recordProviderFailure(
    String id,
    Object error, {
    String? stage,
    String? reason,
  }) => database.recordProviderFailure(id, error, stage: stage, reason: reason);

  Future<ProviderHealth> recordProviderCompatibilityResult(
    String id, {
    required bool passed,
    required String stage,
    required String reason,
  }) => database.recordProviderCompatibilityResult(
    id,
    passed: passed,
    stage: stage,
    reason: reason,
  );

  Future<ProviderHealth> recordProviderCompatibilityInconclusive(
    String id, {
    required String stage,
    required String reason,
  }) => database.recordProviderCompatibilityInconclusive(
    id,
    stage: stage,
    reason: reason,
  );

  Future<void> clearProviderHealth(String id) =>
      database.clearProviderHealth(id);
}

bool _sameCatalogAdvisory(MarketplaceAddon left, MarketplaceAddon right) =>
    left.reportedWorking == right.reportedWorking &&
    left.reportedBroken == right.reportedBroken &&
    left.isDeprecated == right.isDeprecated &&
    left.lastWorkingVersion == right.lastWorkingVersion;

class CachedMarketplaceCatalog {
  const CachedMarketplaceCatalog({required this.payload, this.resourceBaseUrl});

  final String payload;
  final String? resourceBaseUrl;
}

Map<String, Object> _repositoryRow(AddonRepository repository) => {
  'url': repository.url,
  'enabled': repository.enabled ? 1 : 0,
  'is_default': repository.isDefault ? 1 : 0,
  'updated_at': repository.updatedAt.millisecondsSinceEpoch,
};

/// Removes only repositories marked by an older app build as app-provided.
///
/// The public build does not retain the retired URL (even as a migration
/// string). The `is_default` bit was never user-settable, so it uniquely
/// identifies the old seeded record without deleting user-added repositories
/// or anything from `installed_addons`.
Future<void> removeLegacyDefaultRepositories(DatabaseExecutor database) async {
  final legacyDefaults = await database.query(
    'addon_repositories',
    columns: ['url'],
    where: 'is_default = 1',
  );
  for (final row in legacyDefaults) {
    final url = row['url'] as String?;
    if (url == null) continue;
    await database.delete(
      'marketplace_cache',
      where: 'repository_url = ?',
      whereArgs: [url],
    );
  }
  await database.delete('addon_repositories', where: 'is_default = 1');
}
