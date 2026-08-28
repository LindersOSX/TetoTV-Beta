import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  final now = DateTime.utc(2026, 8, 22, 18);

  test(
    'stale catalog fallback rejects entries older than the hard age',
    () async {
      final database = _CacheExecutor(
        updatedAt: now
            .subtract(const Duration(hours: 24, milliseconds: 1))
            .millisecondsSinceEpoch,
        expiresAt: now
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );

      final value = await loadCachedJson(
        database,
        'catalog-key',
        allowExpired: true,
        maxStaleAge: const Duration(hours: 24),
        now: now,
      );

      expect(value, isNull);
    },
  );

  test('stale catalog fallback includes the exact hard-age boundary', () async {
    final database = _CacheExecutor(
      updatedAt: now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch,
      expiresAt: now
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch,
    );

    final value = await loadCachedJson(
      database,
      'catalog-key',
      allowExpired: true,
      maxStaleAge: const Duration(hours: 24),
      now: now,
    );

    expect(value, {'value': 1});
  });
}

class _CacheExecutor implements DatabaseExecutor {
  _CacheExecutor({required this.updatedAt, required this.expiresAt});

  final int updatedAt;
  final int expiresAt;

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
    expect(table, 'catalog_cache');
    expect(limit, 1);
    if (whereArgs == null || whereArgs.first != 'catalog-key') return const [];
    final boundary = (whereArgs[1] as num).toInt();
    final included = where == 'cache_key = ? AND updated_at >= ?'
        ? updatedAt >= boundary
        : where == 'cache_key = ? AND expires_at > ?'
        ? expiresAt > boundary
        : true;
    return included
        ? [
            {
              'cache_key': 'catalog-key',
              'payload_json': '{"value":1}',
              'expires_at': expiresAt,
              'updated_at': updatedAt,
            },
          ]
        : const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
