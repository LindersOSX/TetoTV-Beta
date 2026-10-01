enum AppNotificationKind { appUpdate, announcement }

enum AppNotificationAction { openAppUpdates, none }

const appAnnouncementInboxLifetime = Duration(days: 7);

/// A durable notification shown by TetoTV's in-app inbox.
///
/// Update notices deliberately store a constrained action instead of an
/// arbitrary URL. This keeps persisted data from becoming a navigation or
/// deep-link injection surface.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.action,
    required this.createdAtUtc,
    this.readAtUtc,
    this.targetVersion,
    this.targetVersionCode,
    this.targetChannel,
  });

  final String id;
  final AppNotificationKind kind;
  final String title;
  final String body;
  final AppNotificationAction action;
  final DateTime createdAtUtc;
  final DateTime? readAtUtc;
  final String? targetVersion;
  final int? targetVersionCode;
  final String? targetChannel;

  bool get isRead => readAtUtc != null;

  /// Announcements age out from their original publication timestamp. Update
  /// notices remain until dismissed or reconciled by the updater.
  DateTime? get autoDismissAtUtc => kind == AppNotificationKind.appUpdate
      ? null
      : createdAtUtc.toUtc().add(appAnnouncementInboxLifetime);

  AppNotification copyWith({DateTime? readAtUtc}) => AppNotification(
    id: id,
    kind: kind,
    title: title,
    body: body,
    action: action,
    createdAtUtc: createdAtUtc,
    readAtUtc: readAtUtc ?? this.readAtUtc,
    targetVersion: targetVersion,
    targetVersionCode: targetVersionCode,
    targetChannel: targetChannel,
  );
}
