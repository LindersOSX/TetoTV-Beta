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

  Future<void> cacheCatalog(String repositoryUrl, String payload) async {
    final db = await database.database;
    await db.insert('marketplace_cache', {
      'repository_url': repositoryUrl,
      'payload_json': payload,
      'fetched_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> cachedCatalog(String repositoryUrl) async {
    final db = await database.database;
    final rows = await db.query(
      'marketplace_cache',
      columns: ['payload_json'],
      where: 'repository_url = ?',
      whereArgs: [repositoryUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['payload_json'] as String?;
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
