import 'dart:async';
import 'dart:io';

import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';

/// Describes whether retrying a different release can recover a failed
/// Real-Debrid request.
enum RealDebridFailureKind {
  /// The selected file or torrent cannot be handled, but another release may
  /// still work.
  releaseUnavailable,

  /// The access token is missing, invalid, or lacks permission.
  authorization,

  /// The account is locked, inactive, out of traffic, or otherwise unable to
  /// perform downloads until the user fixes the account.
  account,

  /// Real-Debrid asked the client to slow down.
  rateLimited,

  /// A temporary provider or network-side failure.
  transient,

  /// The API did not provide enough information to classify the failure.
  unknown,
}

class RealDebridException implements DebridProviderFailure {
  const RealDebridException(
    this.message, {
    this.code,
    this.kind = RealDebridFailureKind.unknown,
    this.retryAfter,
  });

  final String message;
  final int? code;
  final RealDebridFailureKind kind;
  final Duration? retryAfter;

  /// Authentication and account failures apply to every release. Candidate
  /// failover must stop and let the user repair their Real-Debrid connection.
  bool get isTerminalAccountFailure =>
      kind == RealDebridFailureKind.authorization ||
      kind == RealDebridFailureKind.account;

  bool get isCandidateSpecific =>
      kind == RealDebridFailureKind.releaseUnavailable;

  /// Whether selecting a different torrent/file is a meaningful recovery.
  /// Refused requests count against Real-Debrid limits, so transient, rate,
  /// account, authorization, and unknown failures must not fan out.
  bool get canTryAnotherRelease => isCandidateSpecific;

  @override
  DebridFailureCategory get failureCategory => switch (kind) {
    RealDebridFailureKind.releaseUnavailable =>
      DebridFailureCategory.releaseUnavailable,
    RealDebridFailureKind.authorization => DebridFailureCategory.authorization,
    RealDebridFailureKind.account => DebridFailureCategory.account,
    RealDebridFailureKind.rateLimited => DebridFailureCategory.rateLimited,
    RealDebridFailureKind.transient ||
    RealDebridFailureKind.unknown => DebridFailureCategory.serviceUnavailable,
  };

  factory RealDebridException.fromApi({
    required int? code,
    int? httpStatus,
    Duration? retryAfter,
  }) {
    // HTTP 429 is authoritative even if the response also contains a
    // release-shaped error code. Treating that response as candidate-specific
    // would fan out addMagnet calls while the account is being throttled.
    if (httpStatus == 429) {
      return RealDebridException.rateLimited(
        code: code ?? httpStatus,
        retryAfter: retryAfter,
      );
    }
    if (code != null) {
      if (_authorizationErrorCodes.contains(code)) {
        return RealDebridException(
          'Your Real-Debrid connection has expired or is not authorized. '
          'Reconnect it in Accounts.',
          code: code,
          kind: RealDebridFailureKind.authorization,
        );
      }
      if (_accountErrorCodes.contains(code)) {
        return RealDebridException(
          'Your Real-Debrid account cannot start downloads right now. '
          'Check the account status and Premium traffic, then try again.',
          code: code,
          kind: RealDebridFailureKind.account,
        );
      }
      if (_releaseErrorCodes.contains(code)) {
        return RealDebridException(
          _releaseFailureMessage(code),
          code: code,
          kind: RealDebridFailureKind.releaseUnavailable,
        );
      }
      if (_rateLimitErrorCodes.contains(code)) {
        return RealDebridException.rateLimited(
          code: code,
          retryAfter: retryAfter,
        );
      }
      if (_transientErrorCodes.contains(code)) {
        return RealDebridException(
          'Real-Debrid is temporarily unable to process this release. Try '
          'again shortly.',
          code: code,
          kind: RealDebridFailureKind.transient,
        );
      }
    }
    if (httpStatus == 401 || httpStatus == 403) {
      return RealDebridException(
        'Your Real-Debrid connection has expired or is not authorized. '
        'Reconnect it in Accounts.',
        code: code ?? httpStatus,
        kind: RealDebridFailureKind.authorization,
      );
    }
    if (httpStatus != null && httpStatus >= 500) {
      return RealDebridException(
        'Real-Debrid is temporarily unavailable. Try again shortly.',
        code: code ?? httpStatus,
        kind: RealDebridFailureKind.transient,
      );
    }
    return RealDebridException(
      'Real-Debrid could not process this request.',
      code: code ?? httpStatus,
    );
  }

  factory RealDebridException.rateLimited({int? code, Duration? retryAfter}) =>
      RealDebridException(
        _rateLimitMessage(retryAfter),
        code: code,
        kind: RealDebridFailureKind.rateLimited,
        retryAfter: retryAfter,
      );

  @override
  String toString() => message;
}

/// Process-wide backoff for Real-Debrid requests that create torrent work.
///
/// Resolvers construct short-lived clients, so keeping this state on one
/// client would allow another episode to immediately call `addMagnet` again.
/// The shared gate retains only a deadline; it never retains account tokens or
/// source data.
class RealDebridRateLimitGate {
  RealDebridRateLimitGate({
    DateTime Function()? now,
    this.defaultCooldown = const Duration(seconds: 30),
    this.minimumCooldown = const Duration(seconds: 1),
    this.maximumCooldown = const Duration(minutes: 2),
  }) : assert(!minimumCooldown.isNegative),
       assert(maximumCooldown >= minimumCooldown),
       assert(defaultCooldown >= minimumCooldown),
       assert(defaultCooldown <= maximumCooldown),
       _now = now ?? (() => DateTime.now().toUtc());

  static final RealDebridRateLimitGate shared = RealDebridRateLimitGate();

  final DateTime Function() _now;
  final Duration defaultCooldown;
  final Duration minimumCooldown;
  final Duration maximumCooldown;
  DateTime? _blockedUntil;

  Duration? get remaining {
    final blockedUntil = _blockedUntil;
    if (blockedUntil == null) return null;
    final value = blockedUntil.difference(_now().toUtc());
    if (value <= Duration.zero) {
      _blockedUntil = null;
      return null;
    }
    return value > maximumCooldown ? maximumCooldown : value;
  }

  void throwIfBlocked() {
    final retryAfter = remaining;
    if (retryAfter != null) {
      throw RealDebridException.rateLimited(retryAfter: retryAfter);
    }
  }

  /// Starts or extends the cooldown and returns its bounded remaining time.
  Duration register(String? retryAfterHeader) {
    final now = _now().toUtc();
    final requested = _parseRetryAfter(retryAfterHeader, now);
    final bounded = _boundedCooldown(requested ?? defaultCooldown);
    final candidate = now.add(bounded);
    final current = _blockedUntil;
    if (current == null || candidate.isAfter(current)) {
      _blockedUntil = candidate;
    }
    return remaining ?? bounded;
  }

  Duration _boundedCooldown(Duration value) {
    if (value < minimumCooldown) return minimumCooldown;
    if (value > maximumCooldown) return maximumCooldown;
    return value;
  }
}

/// Process-wide pacing for Real-Debrid requests that create torrent work.
///
/// Candidate failover can construct several short-lived clients in rapid
/// succession. Spacing `addMagnet` calls here prevents those clients from
/// producing an account-wide request burst while still allowing a different
/// release to recover from a release-specific error. Only timing state is
/// retained; tokens, magnets, and media details never leave the client call.
class RealDebridRequestPacer {
  RealDebridRequestPacer({
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.minimumInterval = const Duration(milliseconds: 1250),
  }) : assert(!minimumInterval.isNegative),
       _now = now ?? (() => DateTime.now().toUtc()),
       _delay = delay ?? Future<void>.delayed;

  static final RealDebridRequestPacer shared = RealDebridRequestPacer();

  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Duration minimumInterval;

  Future<void> _tail = Future<void>.value();
  DateTime? _lastStart;

  Future<void> waitTurn() {
    final turn = _tail.then((_) async {
      final lastStart = _lastStart;
      if (lastStart != null) {
        final elapsed = _now().toUtc().difference(lastStart);
        // Wall clocks can move backwards after a device time correction. Do
        // not turn that correction into an unexpectedly long playback wait.
        final remaining = elapsed.isNegative
            ? minimumInterval
            : minimumInterval - elapsed;
        if (remaining > Duration.zero) await _delay(remaining);
      }
      _lastStart = _now().toUtc();
    });
    // A failed clock/delay implementation must not permanently poison the
    // shared queue. The caller still receives the original failure.
    _tail = turn.then<void>((_) {}, onError: (_, _) {});
    return turn;
  }
}

// Real-Debrid REST API error codes. Keep the raw API message out of the UI:
// values such as `infringing_file` are implementation details and make it
// sound as if the whole episode is unavailable when only one release failed.
const _authorizationErrorCodes = {8, 9, 10, 11, 12, 13};
const _accountErrorCodes = {14, 15, 20, 21, 22, 23, 36};
const _releaseErrorCodes = {7, 16, 24, 28, 29, 30, 33, 35};
const _rateLimitErrorCodes = {5, 34};
const _transientErrorCodes = {6, 17, 18, 19, 25, 37};

String _releaseFailureMessage(int code) => switch (code) {
  29 => 'This release is too large for Real-Debrid. Choose another release.',
  30 => 'This release contains an invalid torrent. Choose another release.',
  33 =>
    'This release is already in the Real-Debrid account. TetoTV will reuse '
        'it when it is ready.',
  35 =>
    'Real-Debrid cannot provide this release. TetoTV can try a different '
        'release.',
  _ =>
    'This release is unavailable through Real-Debrid. Choose another release.',
};

Duration? _parseRetryAfter(String? value, DateTime now) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final seconds = int.tryParse(normalized);
  if (seconds != null) return Duration(seconds: seconds);
  try {
    final deadline = HttpDate.parse(normalized).toUtc();
    final duration = deadline.difference(now);
    return duration.isNegative ? Duration.zero : duration;
  } on HttpException {
    return null;
  }
}

String _rateLimitMessage(Duration? retryAfter) {
  if (retryAfter == null) {
    return 'Real-Debrid is receiving too many requests. Wait a moment and try '
        'again.';
  }
  final seconds = retryAfter.inSeconds.clamp(1, 120);
  return 'Real-Debrid is receiving too many requests. Try again in about '
      '$seconds second${seconds == 1 ? '' : 's'}.';
}

class RealDebridClient {
  RealDebridClient({
    required String token,
    Dio? dio,
    RealDebridRateLimitGate? rateLimitGate,
    RealDebridRequestPacer? requestPacer,
  }) : _rateLimitGate = rateLimitGate ?? RealDebridRateLimitGate.shared,
       _requestPacer = requestPacer ?? RealDebridRequestPacer.shared,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://api.real-debrid.com/rest/1.0',
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 20),
               followRedirects: false,
               maxRedirects: 0,
               headers: {
                 'Accept': 'application/json',
                 'Authorization': 'Bearer $token',
               },
             ),
           );

  final Dio _dio;
  final RealDebridRateLimitGate _rateLimitGate;
  final RealDebridRequestPacer _requestPacer;

  Future<RealDebridAccount> account() async {
    final response = await _request<Map<String, dynamic>>(
      () => _dio.get('/user'),
    );
    return RealDebridAccount.fromJson(response.data!);
  }

  Future<String> addMagnet(String magnetUri) async {
    _rateLimitGate.throwIfBlocked();
    await _requestPacer.waitTurn();
    // Another request may have received a rate limit while this call waited
    // for its turn. Recheck locally before creating more provider traffic.
    _rateLimitGate.throwIfBlocked();
    final response = await _request<Map<String, dynamic>>(
      () => _dio.post(
        '/torrents/addMagnet',
        data: {'magnet': magnetUri},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      ),
    );
    return response.data!['id'] as String;
  }

  Future<RealDebridTorrentInfo> torrentInfo(String id) async {
    final response = await _request<Map<String, dynamic>>(
      () => _dio.get('/torrents/info/$id'),
    );
    return RealDebridTorrentInfo.fromJson(response.data!);
  }

  /// Finds a matching account torrent when addMagnet reports that the hash is
  /// already active, or when a previously playable completed copy may still
  /// be reused. The bounded list prevents an account-wide request explosion.
  Future<RealDebridTorrentInfo?> findAccountTorrentByHash(
    String infoHash, {
    int limit = 100,
    bool downloadedOnly = false,
  }) async {
    final normalizedHash = infoHash.trim().toLowerCase();
    if (normalizedHash.isEmpty) return null;
    final response = await _request<List<dynamic>>(
      () => _dio.get(
        '/torrents',
        queryParameters: {'limit': limit.clamp(1, 100)},
      ),
    );
    for (final value in response.data ?? const <dynamic>[]) {
      if (value is! Map<String, dynamic>) continue;
      final candidate = RealDebridTorrentInfo.fromJson(value);
      if (candidate.hash == normalizedHash &&
          (!downloadedOnly || candidate.isDownloaded)) {
        // List responses are intentionally compact on some API versions.
        return torrentInfo(candidate.id);
      }
    }
    return null;
  }

  Future<void> selectFiles(String id, Iterable<int> fileIds) async {
    final selected = fileIds.join(',');
    if (selected.isEmpty) {
      throw const RealDebridException('No playable torrent files were found.');
    }
    await _request<void>(
      () => _dio.post(
        '/torrents/selectFiles/$id',
        data: {'files': selected},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (status) =>
              status != null && (status == 202 || status < 400),
        ),
      ),
    );
  }

  Future<void> deleteTorrent(String id) async {
    await _request<void>(
      () => _dio.delete(
        '/torrents/delete/$id',
        options: Options(
          validateStatus: (status) =>
              status != null && (status == 204 || status == 404),
        ),
      ),
    );
  }

  Future<RealDebridUnrestrictedLink> unrestrict(String link) async {
    final response = await _request<Map<String, dynamic>>(
      () => _dio.post(
        '/unrestrict/link',
        data: {'link': link},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      ),
    );
    return RealDebridUnrestrictedLink.fromJson(response.data!);
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() operation,
  ) async {
    try {
      return await operation();
    } on DioException catch (error) {
      final data = error.response?.data;
      final status = error.response?.statusCode;
      final code = data is Map<String, dynamic>
          ? switch (data['error_code']) {
              final int value => value,
              final num value => value.toInt(),
              final String value => int.tryParse(value),
              _ => null,
            }
          : null;
      final retryAfter = status == 429 || _rateLimitErrorCodes.contains(code)
          ? _rateLimitGate.register(
              error.response?.headers.value(HttpHeaders.retryAfterHeader),
            )
          : null;
      if (data is Map<String, dynamic>) {
        throw RealDebridException.fromApi(
          code: code,
          httpStatus: status,
          retryAfter: retryAfter,
        );
      }
      if (status != null) {
        throw RealDebridException.fromApi(
          httpStatus: status,
          code: null,
          retryAfter: retryAfter,
        );
      }
      throw RealDebridException(
        error.message ?? 'Could not reach Real-Debrid.',
        code: error.response?.statusCode,
      );
    }
  }
}
