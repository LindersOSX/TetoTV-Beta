import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';

class AppNotificationStore {
  const AppNotificationStore(this._database);

  final TetoTvDatabase _database;

  Future<List<AppNotification>> load() async {
    final database = await _database.database;
    final rows = await database.query(
      'app_notifications',
      orderBy: 'created_at DESC, id ASC',
    );
    return rows.map(_notificationFromRow).toList(growable: false);
  }

  /// Creates or refreshes a notification without making a previously-read
  /// item unread again.
  Future<void> upsert(AppNotification notification) async {
    final database = await _database.database;
    await database.transaction((transaction) async {
      final existing = await transaction.query(
        'app_notifications',
        columns: const ['id'],
        where: 'id = ?',
        whereArgs: [notification.id],
        limit: 1,
      );
      final values = _notificationToRow(notification);
      if (existing.isEmpty) {
        await transaction.insert('app_notifications', values);
        return;
      }
      values
        ..remove('created_at')
        ..remove('read_at');
      await transaction.update(
        'app_notifications',
        values,
        where: 'id = ?',
        whereArgs: [notification.id],
      );
    });
  }

  Future<void> markRead(String id, DateTime readAtUtc) async {
    final database = await _database.database;
    await database.update(
      'app_notifications',
      {'read_at': readAtUtc.toUtc().millisecondsSinceEpoch},
      where: 'id = ? AND read_at IS NULL',
      whereArgs: [id],
    );
  }

  Future<void> markAllRead(DateTime readAtUtc) async {
    final database = await _database.database;
    await database.update('app_notifications', {
      'read_at': readAtUtc.toUtc().millisecondsSinceEpoch,
    }, where: 'read_at IS NULL');
  }

  Future<void> deleteIds(Iterable<String> ids) async {
    final normalized = ids.toSet().toList(growable: false);
    if (normalized.isEmpty) return;
    final database = await _database.database;
    await database.transaction((transaction) async {
      for (final id in normalized) {
        await transaction.delete(
          'app_notifications',
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<void> deleteAppUpdatesForChannel(String channel) async {
    final database = await _database.database;
    await database.delete(
      'app_notifications',
      where: 'kind = ? AND target_channel = ?',
      whereArgs: ['app_update', channel],
    );
  }
}

Map<String, Object?> _notificationToRow(AppNotification notification) => {
  'id': notification.id,
  'kind': _kindName(notification.kind),
  'title': notification.title,
  'body': notification.body,
  'action': _actionName(notification.action),
  'target_version': notification.targetVersion,
  'target_version_code': notification.targetVersionCode,
  'target_channel': notification.targetChannel,
  'created_at': notification.createdAtUtc.toUtc().millisecondsSinceEpoch,
  'read_at': notification.readAtUtc?.toUtc().millisecondsSinceEpoch,
};

AppNotification _notificationFromRow(Map<String, Object?> row) {
  final kind = switch (row['kind']) {
    'app_update' => AppNotificationKind.appUpdate,
    _ => throw const FormatException('Unknown app notification kind.'),
  };
  final action = switch (row['action']) {
    'open_app_updates' => AppNotificationAction.openAppUpdates,
    _ => throw const FormatException('Unknown app notification action.'),
  };
  return AppNotification(
    id: row['id']! as String,
    kind: kind,
    title: row['title']! as String,
    body: row['body']! as String,
    action: action,
    targetVersion: row['target_version'] as String?,
    targetVersionCode: row['target_version_code'] as int?,
    targetChannel: row['target_channel'] as String?,
    createdAtUtc: DateTime.fromMillisecondsSinceEpoch(
      row['created_at']! as int,
      isUtc: true,
    ),
    readAtUtc: switch (row['read_at']) {
      final int value => DateTime.fromMillisecondsSinceEpoch(
        value,
        isUtc: true,
      ),
      _ => null,
    },
  );
}

String _kindName(AppNotificationKind kind) => switch (kind) {
  AppNotificationKind.appUpdate => 'app_update',
};

String _actionName(AppNotificationAction action) => switch (action) {
  AppNotificationAction.openAppUpdates => 'open_app_updates',
};
