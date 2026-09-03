import 'dart:convert';

import 'package:anime_tv/core/notifications/app_announcement_client.dart';
import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the constrained read-only announcement feed', () {
    const body = 'Maintenance is complete.';
    final id = 'app-announcement:${sha256.convert(utf8.encode(body))}';

    final notifications = parseAppAnnouncementFeed({
      'version': 1,
      'announcements': [
        {'id': id, 'body': body, 'created_at': '2026-09-02T12:00:00.000Z'},
      ],
    });

    expect(notifications, hasLength(1));
    expect(notifications.single.id, id);
    expect(notifications.single.kind, AppNotificationKind.announcement);
    expect(notifications.single.action, AppNotificationAction.none);
    expect(notifications.single.createdAtUtc, DateTime.utc(2026, 9, 2, 12));
  });

  test('rejects forged IDs, extra wire fields, and duplicate records', () {
    const body = 'Maintenance is complete.';
    final id = 'app-announcement:${sha256.convert(utf8.encode(body))}';
    final record = {
      'id': id,
      'body': body,
      'created_at': '2026-09-02T12:00:00.000Z',
    };

    expect(
      () => parseAppAnnouncementFeed({
        'version': 1,
        'announcements': [
          {...record, 'id': 'app-announcement:${List.filled(64, '0').join()}'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => parseAppAnnouncementFeed({
        'version': 1,
        'announcements': [
          {...record, 'author_id': '123'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => parseAppAnnouncementFeed({
        'version': 1,
        'announcements': [record, record],
      }),
      throwsFormatException,
    );
  });
}
