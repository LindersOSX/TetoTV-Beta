import 'package:anime_tv/features/streaming/data/torbox_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';

class TorBoxException implements DebridProviderFailure {
  const TorBoxException(this.message, {this.code, this.category});

  final String message;
  final String? code;
  final DebridFailureCategory? category;

  @override
  DebridFailureCategory get failureCategory =>
      category ?? _torBoxFailureCategory(code);

  @override
  String toString() => message;
}

class TorBoxClient {
  TorBoxClient({required String token, Dio? dio})
    : _token = token,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.torbox.app/v1/api',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: false,
              maxRedirects: 0,
              headers: {
                'Accept': 'application/json',
                'Authorization': 'Bearer $token',
              },
            ),
          );

  final String _token;
  final Dio _dio;

  Future<TorBoxAccount> account() async {
    final body = await _get('/user/me', query: const {'settings': false});
    return TorBoxAccount.fromJson(_dataMap(body));
  }

  Future<int> createTorrent(
    String magnetUri, {
    required bool addOnlyIfCached,
  }) async {
    final body = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/torrents/createtorrent',
        data: FormData.fromMap({
          'magnet': magnetUri,
          'seed': 1,
          'allow_zip': false,
          'add_only_if_cached': addOnlyIfCached,
        }),
      ),
    );
    final torrentId = _asInt(_dataMap(body)['torrent_id']);
    if (torrentId <= 0) {
      throw const TorBoxException(
        'TorBox returned an invalid torrent ID. Try another stream.',
      );
    }
    return torrentId;
  }

  Future<bool> isTorrentCached(String infoHash) async {
    final normalized = infoHash.trim().toLowerCase();
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(normalized)) {
      throw const TorBoxException(
        'The torrent source returned an invalid torrent hash.',
        code: 'INVALID_HASH',
        category: DebridFailureCategory.releaseUnavailable,
      );
    }
    final body = await _get(
      '/torrents/checkcached',
      query: {'hash': normalized, 'format': 'object', 'list_files': false},
    );
    final data = body['data'];
    if (data == null) return false;
    if (data is List) return data.isNotEmpty;
    if (data is Map) {
      if (data.isEmpty) return false;
      for (final entry in data.entries) {
        if (entry.key.toString().toLowerCase() == normalized) {
          return entry.value != null && entry.value != false;
        }
      }
    }
    return false;
  }

  Future<TorBoxTorrent> torrentInfo(
    int torrentId, {
    bool bypassCache = true,
  }) async {
    final body = await _get(
      '/torrents/mylist',
      query: {'id': torrentId, 'bypass_cache': bypassCache},
    );
    final data = body['data'];
    final item = switch (data) {
      final Map<String, dynamic> value => value,
      final List<dynamic> values when values.isNotEmpty =>
        values.first as Map<String, dynamic>,
      _ => throw const TorBoxException(
        'TorBox torrent was not found.',
        category: DebridFailureCategory.releaseUnavailable,
      ),
    };
    return TorBoxTorrent.fromJson(item);
  }

  Future<Uri> requestDownloadLink({
    required int torrentId,
    required int fileId,
  }) async {
    final body = await _get(
      '/torrents/requestdl',
      query: {
        'token': _token,
        'torrent_id': torrentId,
        'file_id': fileId,
        'zip_link': false,
        'redirect': false,
        'append_name': true,
      },
    );
    final value = body['data'];
    if (value is! String || !value.startsWith('https://')) {
      throw const TorBoxException(
        'TorBox did not return a secure streaming link.',
        category: DebridFailureCategory.releaseUnavailable,
      );
    }
    return Uri.parse(value);
  }

  Future<void> deleteTorrent(int torrentId) async {
    await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/torrents/controltorrent',
        data: {'torrent_id': torrentId, 'operation': 'delete'},
        options: Options(contentType: Headers.jsonContentType),
      ),
    );
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) {
    return _request(
      () => _dio.get<Map<String, dynamic>>(path, queryParameters: query),
    );
  }

  Future<Map<String, dynamic>> _request(
    Future<Response<Map<String, dynamic>>> Function() operation,
  ) async {
    try {
      final response = await operation();
      final body = response.data ?? const <String, dynamic>{};
      if (body['success'] != true) {
        throw TorBoxException(
          body['detail'] as String? ?? 'TorBox request failed.',
          code: body['error'] as String?,
        );
      }
      return body;
    } on TorBoxException {
      rethrow;
    } on DioException catch (error) {
      final data = error.response?.data;
      if (data is Map<String, dynamic>) {
        throw TorBoxException(
          data['detail'] as String? ?? 'TorBox request failed.',
          code: data['error'] as String?,
        );
      }
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        throw const TorBoxException(
          'That TorBox API token is invalid or API access is unavailable.',
          code: 'AUTH_ERROR',
          category: DebridFailureCategory.authorization,
        );
      }
      throw TorBoxException(
        error.message ?? 'Could not reach TorBox.',
        code: '${error.response?.statusCode ?? ''}',
      );
    }
  }
}

Map<String, dynamic> _dataMap(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is Map<String, dynamic>) return data;
  throw const TorBoxException('TorBox returned an unexpected response.');
}

int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};

DebridFailureCategory _torBoxFailureCategory(String? rawCode) {
  final code = rawCode?.trim().toUpperCase() ?? '';
  final status = int.tryParse(code);
  if (status == 401 || status == 403) {
    return DebridFailureCategory.authorization;
  }
  if (status == 402) return DebridFailureCategory.account;
  if (status == 429) return DebridFailureCategory.rateLimited;

  if (const {
    'AUTH_ERROR',
    'BAD_TOKEN',
    'INVALID_TOKEN',
    'TOKEN_EXPIRED',
    'API_KEY_INVALID',
  }.contains(code)) {
    return DebridFailureCategory.authorization;
  }
  if (const {
    'ACTIVE_LIMIT',
    'DOWNLOAD_LIMIT_REACHED',
    'MONTHLY_LIMIT_REACHED',
    'NO_SPACE',
    'ACCOUNT_DISABLED',
    'SUBSCRIPTION_REQUIRED',
  }.contains(code)) {
    return DebridFailureCategory.account;
  }
  if (const {
    'RATE_LIMITED',
    'RATE_LIMIT_EXCEEDED',
    'TOO_MANY_REQUESTS',
  }.contains(code)) {
    return DebridFailureCategory.rateLimited;
  }
  if (const {
    'DOWNLOAD_NOT_CACHED',
    'INVALID_HASH',
    'INVALID_TORRENT',
    'TORRENT_NOT_FOUND',
    'NO_PLAYABLE_FILES',
  }.contains(code)) {
    return DebridFailureCategory.releaseUnavailable;
  }
  return DebridFailureCategory.serviceUnavailable;
}
