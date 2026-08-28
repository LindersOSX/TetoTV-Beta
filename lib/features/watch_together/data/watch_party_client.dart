import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';

class WatchPartyClientException implements Exception {
  const WatchPartyClientException(this.code, {this.retryAfter});

  final String code;
  final Duration? retryAfter;

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

  Future<bool> health() async {
    final response = await _request(
      'GET',
      '/v1/watch-parties/health',
      authenticated: false,
    );
    final protocol = (response['protocol'] as num?)?.toInt() ?? 0;
    return response['status'] == 'ok' && protocol >= 1 && protocol <= 4;
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
    final roomCode = _roomCode(value['room_code']);
    final token = _token(value['host_token']);
    final expiresAt = _date(value['expires_at']);
    final watchPath = value['watch_url'] as String? ?? '/watch?room=$roomCode';
    final advertisedWatchUri = _baseUri.resolve(watchPath);
    if (advertisedWatchUri.origin != _baseUri.origin ||
        advertisedWatchUri.scheme != 'https') {
      throw const WatchPartyClientException('invalid_response');
    }
    // The room capability belongs only in the Authorization header. Build the
    // public share URL locally so an accidental query value in a broker
    // response can never enter a QR code, clipboard, or native player HUD.
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

    final mediaCandidates = <WatchPartyMedia?>[
      media,
      if (media?.timelineProfile != null) media?.withoutTimelineProfile(),
      if (media?.sourceDescriptor != null)
        media?.withoutSourceDescriptor().withoutTimelineProfile(),
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
  }) async {
    final identity = _publicIdentity;
    Map<String, Object?> value;
    try {
      value = await _request(
        'POST',
        '/v1/watch-parties/${session.roomCode}/ready',
        token: session.token,
        data: <String, Object>{
          'ready': ready,
          if (identity != null) 'identity': identity.toJson(),
        },
      );
    } on WatchPartyClientException catch (error) {
      if (identity == null ||
          error.code != 'invalid_ready_state' &&
              error.code != 'invalid_payload') {
        rethrow;
      }
      value = await _request(
        'POST',
        '/v1/watch-parties/${session.roomCode}/ready',
        token: session.token,
        data: <String, Object>{'ready': ready},
      );
    }
    return _snapshotForRoom(value, session.roomCode);
  }

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
      response = await _dio.request<Object?>(
        path,
        data: data,
        options: Options(
          method: method,
          headers: token == null
              ? null
              : <String, String>{'Authorization': 'Bearer $token'},
        ),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw const WatchPartyClientException('timeout');
      }
      throw const WatchPartyClientException('network_unavailable');
    }
    final status = response.statusCode ?? 0;
    if (allowNoContent && status == 204) return const {};
    final value = _mapOrNull(response.data);
    if (status < 200 || status >= 300) {
      final retrySeconds = int.tryParse(
        response.headers.value('retry-after') ?? '',
      );
      throw WatchPartyClientException(
        value?['error'] as String? ?? 'server_error',
        retryAfter: retrySeconds == null
            ? null
            : Duration(seconds: retrySeconds),
      );
    }
    if (value == null) {
      throw const WatchPartyClientException('invalid_response');
    }
    return value;
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
) {
  final role = value['role'];
  if (role != 'host' && role != 'guest') {
    throw const WatchPartyClientException('invalid_response');
  }
  final snapshot = WatchPartySnapshot.fromJson(value);
  if (snapshot.roomCode != expectedRoomCode) {
    throw const WatchPartyClientException('invalid_response');
  }
  return snapshot;
}

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
