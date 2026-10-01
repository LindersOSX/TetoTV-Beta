import 'dart:collection';
import 'dart:convert';

import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class WatchPartyClientException implements Exception {
  const WatchPartyClientException(
    this.code, {
    this.retryAfter,
    this.statusCode,
    this.transportType,
  });

  final String code;
  final Duration? retryAfter;
  final int? statusCode;
  // Keep only the closed Dio category, never its request, message, or cause.
  final DioExceptionType? transportType;

  /// These established diagnostic keys survive the database/report privacy
  /// allowlist. Unexpected server strings never become diagnostic content.
  Map<String, Object> get diagnosticDetails => {
    'reason_code': _knownWatchPartyErrorCode(code) ?? 'unknown_error',
    'phase': ?transportType?.name,
    'code': ?_safeHttpStatus(statusCode),
  };

  @override
  String toString() => code;
}

class WatchPartyCreated {
  const WatchPartyCreated({required this.session});

  final WatchPartySession session;
}

class WatchPartyJoined {
  const WatchPartyJoined({required this.session, required this.snapshot});

  final WatchPartySession session;
  final WatchPartySnapshot snapshot;
}

class WatchPartyClient {
  WatchPartyClient({required String baseUrl, Dio? dio})
    : _baseUri = _validOrigin(baseUrl),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _validOrigin(baseUrl).toString(),
              connectTimeout: const Duration(seconds: 8),
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10),
              contentType: Headers.jsonContentType,
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

  final Uri _baseUri;
  final Dio _dio;
  WatchPartyPublicIdentity? _publicIdentity;

  /// Sets the small public identity shared with authenticated room members.
  /// It remains in memory only and contains no provider or account identifier.
  void setPublicIdentity(WatchPartyPublicIdentity? identity) {
    _publicIdentity = identity;
  }

  @visibleForTesting
  WatchPartyPublicIdentity? get publicIdentityForTesting => _publicIdentity;

  /// The current public room identity, if tracker/local profile loading has
  /// completed. This is intentionally the already-sanitized public model and
  /// never exposes account credentials or tracker identifiers.
  WatchPartyPublicIdentity? get publicIdentity => _publicIdentity;

  Future<bool> health() async {
    final response = await _request(
      'GET',
      '/v1/watch-parties/health',
      authenticated: false,
    );
    return _parseResponse(response, () {
      final protocol = (response['protocol'] as num?)?.toInt() ?? 0;
      return response['status'] == 'ok' && protocol >= 1 && protocol <= 5;
    });
  }

  Future<WatchPartyCreated> create() async {
    final identity = _publicIdentity;
    Map<String, Object?> value;
    try {
      value = await _request(
        'POST',
        '/v1/watch-parties',
        authenticated: false,
        data: <String, Object>{
          if (identity != null) 'identity': identity.toJson(),
        },
      );
    } on WatchPartyClientException catch (error) {
      if (identity == null || error.code != 'invalid_payload') rethrow;
      // Identity is an append-only protocol extension. A still-running v1
      // broker can create the room without it and will use the Host fallback.
      value = await _request(
        'POST',
        '/v1/watch-parties',
        authenticated: false,
        data: const <String, Object>{},
      );
    }
    return _parseResponse(value, () {
      final roomCode = _roomCode(value['room_code']);
      final token = _token(value['host_token']);
      final expiresAt = _date(value['expires_at']);
      final watchPath =
          value['watch_url'] as String? ?? '/watch?room=$roomCode';
      final advertisedWatchUri = _baseUri.resolve(watchPath);
      if (advertisedWatchUri.origin != _baseUri.origin ||
          advertisedWatchUri.scheme != 'https') {
        throw const WatchPartyClientException('invalid_response');
      }
      // The room capability belongs only in the Authorization header. Build
      // the share URL locally so broker query data never reaches a QR code.
      final watchUri = _baseUri.resolve('/watch?room=$roomCode');
      return WatchPartyCreated(
        session: WatchPartySession(
          roomCode: roomCode,
          token: token,
          role: WatchPartyRole.host,
          expiresAt: expiresAt,
          watchUrl: watchUri,
        ),
      );
    });
  }

  Future<WatchPartyJoined> join(String rawCode) async {
    final roomCode = normalizeWatchPartyCode(rawCode);
    if (roomCode == null) {
      throw const WatchPartyClientException('invalid_room_code');
    }
    final identity = _publicIdentity;
    Map<String, Object?> value;
    try {
      value = await _request(
        'POST',
        '/v1/watch-parties/join',
        authenticated: false,
        data: <String, Object>{
          'room_code': roomCode,
          if (identity != null) 'identity': identity.toJson(),
        },
      );
    } on WatchPartyClientException catch (error) {
      if (identity == null || error.code != 'invalid_payload') rethrow;
      value = await _request(
        'POST',
        '/v1/watch-parties/join',
        authenticated: false,
        data: <String, Object>{'room_code': roomCode},
      );
    }
    return _parseResponse(value, () {
      final token = _token(value['participant_token']);
      final expiresAt = _date(value['expires_at']);
      final snapshotValue = _map(value['state']);
      final snapshot = _snapshotForRoom(snapshotValue, roomCode);
      return WatchPartyJoined(
        session: WatchPartySession(
          roomCode: roomCode,
          token: token,
          role: WatchPartyRole.guest,
          expiresAt: expiresAt,
          watchUrl: _baseUri.resolve('/watch?room=$roomCode'),
        ),
        snapshot: snapshot,
      );
    });
  }

  Future<WatchPartySnapshot> snapshot(WatchPartySession session) async =>
      _snapshotForRoom(
        await _request(
          'GET',
          '/v1/watch-parties/${session.roomCode}',
          token: session.token,
        ),
        session.roomCode,
      );

  /// Publishes an identity that became available after room entry.
  ///
  /// Tracker profiles load asynchronously during app startup. A room can be
  /// created or joined before that work finishes, so create/join alone cannot
  /// be the only time an avatar is sent to the broker.
  Future<WatchPartySnapshot> updatePublicIdentity({
    required WatchPartySession session,
    required WatchPartyPublicIdentity? identity,
  }) async => _snapshotForRoom(
    await _request(
      'POST',
      '/v1/watch-parties/${session.roomCode}/identity',
      token: session.token,
      // A null identity explicitly clears public tracker data when a user
      // signs out or removes the selected profile while the room is active.
      data: <String, Object?>{'identity': identity?.toJson()},
    ),
    session.roomCode,
  );

  Future<WatchPartySnapshot> updateState({
    required WatchPartySession session,
    required int baseRevision,
    required WatchPartyMedia? media,
    required bool playing,
    required Duration position,
    bool forceResync = false,
  }) async {
    Future<Map<String, Object?>> publish(
      WatchPartyMedia? value, {
      required bool includeForceResync,
    }) => _request(
      'PUT',
      '/v1/watch-parties/${session.roomCode}/state',
      token: session.token,
      data: <String, Object?>{
        'base_revision': baseRevision,
        'playing': playing,
        'position_ms': position.inMilliseconds.clamp(0, 86_400_000),
        'media': value?.toJson(),
        if (includeForceResync && forceResync) 'force_resync': true,
      },
    );

    final compatibilityCandidates = <WatchPartyMedia?>[
      media,
      if (media?.titleNative != null) media?.withoutNativeTitle(),
      if (media?.timelineProfile != null) media?.withoutTimelineProfile(),
      if (media?.titleNative != null && media?.timelineProfile != null)
        media?.withoutNativeTitle().withoutTimelineProfile(),
      if (media?.sourceDescriptor != null)
        media?.withoutSourceDescriptor().withoutTimelineProfile(),
      if (media?.titleNative != null && media?.sourceDescriptor != null)
        media
            ?.withoutNativeTitle()
            .withoutSourceDescriptor()
            .withoutTimelineProfile(),
    ];
    final mediaCandidates = <WatchPartyMedia?>[
      for (final candidate in compatibilityCandidates) ...[
        candidate,
        if (candidate?.format != null) candidate?.withoutFormat(),
      ],
    ];
    var includeForceResync = forceResync;
    WatchPartyClientException? lastError;
    for (final candidate in mediaCandidates) {
      while (true) {
        try {
          return _snapshotForRoom(
            await publish(candidate, includeForceResync: includeForceResync),
            session.roomCode,
          );
        } on WatchPartyClientException catch (error) {
          lastError = error;
          if (includeForceResync &&
              (error.code == 'invalid_payload' ||
                  error.code == 'invalid_state')) {
            // A protocol-v3 broker can still receive the ordinary state while
            // the protocol-v4 resync signal waits for the service rollout.
            includeForceResync = false;
            continue;
          }
          if (error.code == 'invalid_media' &&
              !identical(candidate, mediaCandidates.last)) {
            break;
          }
          rethrow;
        }
      }
    }
    throw lastError ?? const WatchPartyClientException('invalid_media');
  }

  Future<WatchPartySnapshot> setReady({
    required WatchPartySession session,
    required bool ready,
  }) async => _snapshotForRoom(
    await _request(
      'POST',
      '/v1/watch-parties/${session.roomCode}/ready',
      token: session.token,
      // Identity has its own serialized endpoint. Keeping readiness free of
      // identity prevents a slow Ready(A) request from overwriting a newer B.
      data: <String, Object>{'ready': ready},
    ),
    session.roomCode,
  );

  Future<void> leave(WatchPartySession session) async {
    await _request(
      'POST',
      '/v1/watch-parties/${session.roomCode}/leave',
      token: session.token,
      data: const <String, Object>{},
      allowNoContent: true,
    );
  }

  Future<WatchPartySnapshot> transferHost({
    required WatchPartySession session,
    required String participantId,
    required int baseRosterRevision,
  }) async => _snapshotForRoom(
    await _request(
      'POST',
      '/v1/watch-parties/${session.roomCode}/transfer-host',
      token: session.token,
      data: <String, Object>{
        'participant_id': participantId,
        'base_roster_revision': baseRosterRevision,
      },
    ),
    session.roomCode,
  );

  Future<WatchPartySnapshot> kick({
    required WatchPartySession session,
    required String participantId,
    required int baseRosterRevision,
  }) async => _snapshotForRoom(
    await _request(
      'POST',
      '/v1/watch-parties/${session.roomCode}/kick',
      token: session.token,
      data: <String, Object>{
        'participant_id': participantId,
        'base_roster_revision': baseRosterRevision,
      },
    ),
    session.roomCode,
  );

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    String? token,
    Object? data,
    bool authenticated = true,
    bool allowNoContent = false,
  }) async {
    if (authenticated && token == null) {
      throw const WatchPartyClientException('party_token_required');
    }
    Response<Object?> response;
    try {
      response = await _dio.request<dynamic>(
        path,
        data: data,
        options: Options(
          method: method,
          // Decode here so malformed successful JSON keeps its HTTP status
          // and cannot be mistaken for a DNS/socket failure by Dio's decoder.
          responseType: ResponseType.plain,
          headers: token == null
              ? null
              : <String, String>{'Authorization': 'Bearer $token'},
        ),
      );
    } on DioException catch (error) {
      final status = _safeHttpStatus(error.response?.statusCode);
      if (error.type == DioExceptionType.badResponse && status != null) {
        throw _httpResponseError(
          status: status,
          data: error.response?.data,
          headers: error.response?.headers,
          transportType: error.type,
        );
      }
      if (error.error is FormatException) {
        throw WatchPartyClientException(
          'invalid_response',
          statusCode: status,
          transportType: error.type,
        );
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.transformTimeout) {
        throw WatchPartyClientException(
          'timeout',
          statusCode: status,
          transportType: error.type,
        );
      }
      throw WatchPartyClientException(
        'network_unavailable',
        statusCode: status,
        transportType: error.type,
      );
    } on FormatException {
      throw const WatchPartyClientException('invalid_response');
    }
    final status = response.statusCode ?? 0;
    if (allowNoContent && status == 204) return const {};
    if (status < 200 || status >= 300) {
      throw _httpResponseError(
        status: status,
        data: response.data,
        headers: response.headers,
      );
    }
    try {
      final value = _decodeResponseMap(response.data);
      if (value == null) {
        throw const FormatException('Expected a JSON object.');
      }
      return _WatchPartyResponse(value, _safeHttpStatus(status));
    } on FormatException {
      throw WatchPartyClientException(
        'invalid_response',
        statusCode: _safeHttpStatus(status),
      );
    }
  }
}

Uri _validOrigin(String rawValue) {
  final value = Uri.tryParse(rawValue.trim());
  if (value == null ||
      value.scheme != 'https' ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.path != '' && value.path != '/' ||
      value.hasQuery ||
      value.hasFragment) {
    throw const FormatException('Watch Party requires a root HTTPS origin.');
  }
  return value.replace(path: '/');
}

String? normalizeWatchPartyCode(String rawValue) {
  // Spaces and hyphens are display separators only. Keep every other
  // character so pasted letters are rejected instead of silently discarded.
  final normalized = rawValue.trim().replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^[2-9]{8}$').hasMatch(normalized) ? normalized : null;
}

Map<String, Object?> _map(Object? value) {
  final mapped = _mapOrNull(value);
  if (mapped == null) {
    throw const WatchPartyClientException('invalid_response');
  }
  return mapped;
}

Map<String, Object?>? _mapOrNull(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : null;

WatchPartySnapshot _snapshotForRoom(
  Map<String, Object?> value,
  String expectedRoomCode,
) => _parseResponse(value, () {
  final role = value['role'];
  if (role != 'host' && role != 'guest') {
    throw const WatchPartyClientException('invalid_response');
  }
  final snapshot = WatchPartySnapshot.fromJson(value);
  if (snapshot.roomCode != expectedRoomCode) {
    throw const WatchPartyClientException('invalid_response');
  }
  return snapshot;
});

/// HTTP metadata travels with the response map only inside this client.
class _WatchPartyResponse extends MapView<String, Object?> {
  _WatchPartyResponse(super.map, this.statusCode);

  final int? statusCode;
}

T _parseResponse<T>(Map<String, Object?> response, T Function() parse) {
  final status = response is _WatchPartyResponse ? response.statusCode : null;
  try {
    return parse();
  } on WatchPartyClientException catch (error) {
    if (error.code != 'invalid_response' || error.statusCode != null) rethrow;
    throw WatchPartyClientException('invalid_response', statusCode: status);
  } on FormatException {
    throw WatchPartyClientException('invalid_response', statusCode: status);
  } on TypeError {
    throw WatchPartyClientException('invalid_response', statusCode: status);
  } on ArgumentError {
    throw WatchPartyClientException('invalid_response', statusCode: status);
  }
}

Map<String, Object?>? _decodeResponseMap(Object? data) =>
    _mapOrNull(data is String ? jsonDecode(data) : data);

WatchPartyClientException _httpResponseError({
  required int status,
  required Object? data,
  Headers? headers,
  DioExceptionType? transportType,
}) {
  Map<String, Object?>? value;
  try {
    value = _decodeResponseMap(data);
  } on FormatException {
    // An HTML/proxy error is still an HTTP failure, not a network outage.
  }
  final retrySeconds = int.tryParse(headers?.value('retry-after') ?? '');
  return WatchPartyClientException(
    _knownWatchPartyErrorCode(value?['error']) ?? 'server_error',
    retryAfter: retrySeconds == null || retrySeconds < 0
        ? null
        : Duration(seconds: retrySeconds.clamp(0, 86400)),
    statusCode: _safeHttpStatus(status),
    transportType: transportType,
  );
}

int? _safeHttpStatus(int? status) =>
    status != null && status >= 100 && status <= 599 ? status : null;

String? _knownWatchPartyErrorCode(Object? value) =>
    value is String && _watchPartyErrorCodes.contains(value) ? value : null;

const _watchPartyErrorCodes = <String>{
  'invalid_room_code',
  'party_not_found',
  'party_full',
  'party_capacity_reached',
  'invalid_party_token',
  'party_token_required',
  'removed_from_party',
  'stale_roster',
  'participant_not_found',
  'host_required',
  'guest_required',
  'method_not_allowed',
  'not_found',
  'rate_limited',
  'expected_json',
  'payload_too_large',
  'invalid_json',
  'invalid_payload',
  'invalid_state',
  'invalid_media',
  'invalid_ready_state',
  'invalid_public_identity',
  'invalid_roster_action',
  'stale_revision',
  'timeout',
  'network_unavailable',
  'invalid_response',
  'server_error',
};

String _roomCode(Object? value) {
  final normalized = normalizeWatchPartyCode(value as String? ?? '');
  if (normalized == null) {
    throw const WatchPartyClientException('invalid_response');
  }
  return normalized;
}

String _token(Object? value) {
  final token = value as String? ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(token)) {
    throw const WatchPartyClientException('invalid_response');
  }
  return token;
}

DateTime _date(Object? value) {
  final date = DateTime.tryParse(value as String? ?? '')?.toUtc();
  if (date == null) {
    throw const WatchPartyClientException('invalid_response');
  }
  return date;
}
