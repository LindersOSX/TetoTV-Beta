import 'dart:convert';

import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

abstract interface class AppAnnouncementApi {
  Future<List<AppNotification>> fetch();
}

class AppAnnouncementClient implements AppAnnouncementApi {
  AppAnnouncementClient({required String baseUrl, Dio? dio})
    : _origin = _validOrigin(baseUrl),
      _ownsDio = dio == null,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
              responseType: ResponseType.json,
              followRedirects: false,
              maxRedirects: 0,
              headers: const {
                Headers.acceptHeader: Headers.jsonContentType,
                'User-Agent': 'TetoTV/2 Android',
              },
              validateStatus: (status) => status != null && status < 600,
            ),
          );

  final Uri _origin;
  final bool _ownsDio;
  final Dio _dio;
  final CancelToken _cancelToken = CancelToken();
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _cancelToken.cancel('Announcement client closed.');
    if (_ownsDio) _dio.close(force: true);
  }

  @override
  Future<List<AppNotification>> fetch() async {
    if (_closed) throw StateError('The announcement client is closed.');
    final response = await _dio.get<Object?>(
      _origin.resolve('/v1/app-announcements').toString(),
      cancelToken: _cancelToken,
    );
    if (response.statusCode != 200) {
      throw StateError('The announcement service is unavailable.');
    }
    return parseAppAnnouncementFeed(response.data);
  }
}

List<AppNotification> parseAppAnnouncementFeed(Object? value) {
  if (value is! Map || value.length != 2) {
    throw const FormatException('Invalid app announcement feed.');
  }
  if (value['version'] != 1 || value['announcements'] is! List) {
    throw const FormatException('Unsupported app announcement feed.');
  }
  final records = value['announcements']! as List;
  if (records.length > 100) {
    throw const FormatException('App announcement feed is too large.');
  }
  final ids = <String>{};
  final result = <AppNotification>[];
  for (final candidate in records) {
    if (candidate is! Map || candidate.length != 3) {
      throw const FormatException('Invalid app announcement record.');
    }
    final id = candidate['id'];
    final body = candidate['body'];
    final createdAtValue = candidate['created_at'];
    if (id is! String ||
        !RegExp(r'^app-announcement:[a-f0-9]{64}$').hasMatch(id) ||
        body is! String ||
        body.isEmpty ||
        body.length > 1000 ||
        RegExp(
          r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u202A-\u202E\u2066-\u2069]',
        ).hasMatch(body) ||
        createdAtValue is! String) {
      throw const FormatException('Invalid app announcement record.');
    }
    final expectedId = 'app-announcement:${sha256.convert(utf8.encode(body))}';
    final createdAt = DateTime.tryParse(createdAtValue)?.toUtc();
    if (id != expectedId ||
        createdAt == null ||
        createdAt.toIso8601String() != createdAtValue ||
        !ids.add(id)) {
      throw const FormatException('Invalid app announcement identity.');
    }
    result.add(
      AppNotification(
        id: id,
        kind: AppNotificationKind.announcement,
        title: 'TetoTV announcement',
        body: body,
        action: AppNotificationAction.none,
        createdAtUtc: createdAt,
      ),
    );
  }
  return List.unmodifiable(result);
}

Uri _validOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ArgumentError.value(value, 'baseUrl', 'Use one root HTTPS origin.');
  }
  return uri.replace(path: '/');
}
