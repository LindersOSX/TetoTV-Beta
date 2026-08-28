import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  test(
    'removes only the legacy app-default repository and its cache',
    () async {
      final database = _MigrationDatabase();

      await removeLegacyDefaultRepositories(database);

      expect(database.queries, ['addon_repositories|is_default = 1']);
      expect(database.deletes, [
        'marketplace_cache|repository_url = ?|legacy-app-default',
        'addon_repositories|is_default = 1|',
      ]);
      expect(
        database.deletes.any((value) => value.contains('installed_addons')),
        isFalse,
      );
    },
  );
}

class _MigrationDatabase implements DatabaseExecutor {
  final queries = <String>[];
  final deletes = <String>[];

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    queries.add('$table|$where');
    return const [
      {'url': 'legacy-app-default'},
    ];
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    deletes.add('$table|$where|${whereArgs?.join(',') ?? ''}');
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
