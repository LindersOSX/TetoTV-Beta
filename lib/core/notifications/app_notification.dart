enum AppNotificationKind { appUpdate }

enum AppNotificationAction { openAppUpdates }

/// A durable, local-only notification shown by TetoTV's in-app inbox.
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
