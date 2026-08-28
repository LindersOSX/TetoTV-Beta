import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _trackingOutboxKey = 'tracking_progress_outbox_v1';
const _unavailableProfileScope = '!profile-unavailable';

Timer _systemTrackingTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);

final trackingSyncServiceProvider = Provider<TrackingSyncService>((ref) {
  final service = TrackingSyncService(
    ref.watch(secureStorageProvider),
    ref.watch(trackingTokenServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final trackingOutboxFlushProvider = FutureProvider<void>(
  (ref) => ref.watch(trackingSyncServiceProvider).flush(),
);

/// Callback type for resolving an access token for a given [TrackingProvider].
typedef TokenLookup = Future<String?> Function(TrackingProvider);

/// Callback type for reading the non-secret active account slot.
typedef TrackingProfileLookup = Future<String?> Function(TrackingProvider);

/// Injectable timer factory used to verify retry/debounce behavior without
/// sleeping in unit tests.
typedef TrackingTimerFactory =
    Timer Function(Duration delay, void Function() callback);

class TrackingSyncService with WidgetsBindingObserver {
  TrackingSyncService(
    this._storage,
    TrackingTokenService tokenService, {
    this._resumeDebounce = const Duration(milliseconds: 400),
    List<Duration> retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ],
    this._timerFactory = _systemTrackingTimer,
    this._observeLifecycle = true,
  }) : _tokenLookup = tokenService.accessToken,
       _profileLookup = tokenService.activeProfileId,
       _retryDelays = List.unmodifiable(retryDelays) {
    if (_observeLifecycle) WidgetsBinding.instance.addObserver(this);
  }

  /// Constructs a service suitable for unit tests, accepting raw lookups
  /// instead of a concrete [TrackingTokenService]. Timers and lifecycle
  /// observation stay disabled unless the test explicitly enables them.
  TrackingSyncService.withLookup(
    this._storage,
    this._tokenLookup, {
    TrackingProfileLookup? profileLookup,
    this._resumeDebounce = const Duration(milliseconds: 400),
    List<Duration> retryDelays = const [],
    this._timerFactory = _systemTrackingTimer,
    this._observeLifecycle = false,
  }) : _profileLookup = profileLookup ?? _noActiveProfile,
       _retryDelays = List.unmodifiable(retryDelays) {
    if (_observeLifecycle) WidgetsBinding.instance.addObserver(this);
  }

  final FlutterSecureStorage _storage;
  final TokenLookup _tokenLookup;
  final TrackingProfileLookup _profileLookup;
  final Duration _resumeDebounce;
  final List<Duration> _retryDelays;
  final TrackingTimerFactory _timerFactory;
  final bool _observeLifecycle;

  Future<void> _outboxTail = Future<void>.value();
  Future<void> _flushTail = Future<void>.value();
  Timer? _scheduledFlush;
  int _retryAttempt = 0;
  bool _disposed = false;

  Future<bool> syncEpisode({
    required int completedEpisodes,
    int? anilistMediaId,
    int? malMediaId,
  }) async {
    final targets = <({TrackingProvider provider, int mediaId})>[
      if (anilistMediaId != null)
        (provider: TrackingProvider.anilist, mediaId: anilistMediaId),
      if (malMediaId != null)
        (provider: TrackingProvider.myAnimeList, mediaId: malMediaId),
    ];
    if (targets.isEmpty) return false;

    // Resolve only the non-secret account slot before persistence. Token
    // lookup and every possible network operation happen after this write.
    final pending = <_PendingProgress>[];
    for (final target in targets) {
      pending.add(
        _PendingProgress(
          provider: target.provider,
          profileId: await _profileScope(target.provider),
          mediaId: target.mediaId,
          completedEpisodes: completedEpisodes,
        ),
      );
    }
    await _mutateOutbox((current) => [...current, ...pending]);

    _cancelScheduledFlush();
    await _requestFlush();
    final remaining = await _readOutbox();
    return pending.every(
      (target) => !remaining.any(
        (item) =>
            item.outboxKey == target.outboxKey &&
            item.completedEpisodes >= target.completedEpisodes,
      ),
    );
  }

  Future<void> flush() async {
    _cancelScheduledFlush();
    await _requestFlush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _disposed) return;
    _retryAttempt = 0;
    _scheduleFlush(_resumeDebounce);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelScheduledFlush();
    if (_observeLifecycle) WidgetsBinding.instance.removeObserver(this);
  }

  Future<void> _requestFlush() => _serializeFlush(_flushOutbox);

  Future<void> _flushOutbox() async {
    if (_disposed) return;
    final pending = await _readOutbox();
    if (pending.isEmpty) {
      _retryAttempt = 0;
      return;
    }

    var retryableFailure = false;
    final completed = <String, int>{};
    final activeProfiles = <TrackingProvider, String?>{};
    final unavailableProfiles = <TrackingProvider>{};

    for (final item in pending) {
      String? activeProfile;
      if (activeProfiles.containsKey(item.provider)) {
        activeProfile = activeProfiles[item.provider];
      } else if (unavailableProfiles.contains(item.provider)) {
        retryableFailure = true;
        continue;
      } else {
        try {
          activeProfile = await _profileLookup(item.provider);
          activeProfiles[item.provider] = _normalizeProfileId(activeProfile);
          activeProfile = activeProfiles[item.provider];
        } catch (_) {
          unavailableProfiles.add(item.provider);
          retryableFailure = true;
          continue;
        }
      }
      if (!_sameProfile(item.profileId, activeProfile)) continue;

      try {
        final token = await _tokenLookup(item.provider);
        if (token == null || token.isEmpty) continue;

        // A profile can be switched while MAL refreshes its access token. Read
        // the slot again before using that token and retain the queued row if
        // the account changed.
        final verifiedProfile = _normalizeProfileId(
          await _profileLookup(item.provider),
        );
        if (!_sameProfile(item.profileId, verifiedProfile)) continue;

        final repository = buildRepository(item.provider, token);
        await repository.updateProgress(
          mediaId: item.mediaId,
          completedEpisodes: item.completedEpisodes,
        );
        completed[item.outboxKey] = item.completedEpisodes;
      } catch (_) {
        retryableFailure = true;
      }
    }

    if (completed.isNotEmpty) {
      await _mutateOutbox(
        (current) => [
          for (final item in current)
            if (completed[item.outboxKey] == null ||
                item.completedEpisodes > completed[item.outboxKey]!)
              item,
        ],
      );
    }

    if (retryableFailure) {
      _scheduleRetry();
    } else {
      _retryAttempt = 0;
    }
  }

  /// Creates a [TrackingRepository] for the given [provider] and [token].
  ///
  /// Override in tests to inject a fake repository.
  TrackingRepository buildRepository(TrackingProvider provider, String token) {
    return switch (provider) {
      TrackingProvider.anilist => AniListTrackingRepository(accessToken: token),
      TrackingProvider.myAnimeList => MyAnimeListTrackingRepository(
        accessToken: token,
      ),
    };
  }

  Future<String?> _profileScope(TrackingProvider provider) async {
    try {
      return _normalizeProfileId(await _profileLookup(provider));
    } catch (_) {
      // Never collapse an unreadable account identity into the legacy null
      // scope, because that could later deliver progress through another
      // account. A later episode update can create a correctly scoped row.
      return _unavailableProfileScope;
    }
  }

  Future<List<_PendingProgress>> _readOutbox() =>
      _withOutboxLock(_readOutboxUnlocked);

  Future<List<_PendingProgress>> _readOutboxUnlocked() async {
    final value = await _storage.read(key: _trackingOutboxKey);
    if (value == null || value.isEmpty) return [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) throw const FormatException('Invalid outbox root.');
      final items = <_PendingProgress>[];
      for (final value in decoded) {
        if (value is! Map) continue;
        final item = _PendingProgress.tryParse(value);
        if (item != null) items.add(item);
      }
      final canonical = _deduplicate(items);
      if (canonical.length != decoded.length ||
          canonical.length != items.length) {
        await _writeOutboxUnlocked(canonical);
      }
      return canonical;
    } catch (_) {
      // An invalid root cannot be repaired, but one malformed row in an array
      // is skipped above without destroying every other pending update.
      await _storage.delete(key: _trackingOutboxKey);
      return [];
    }
  }

  Future<void> _mutateOutbox(
    List<_PendingProgress> Function(List<_PendingProgress> current) mutation,
  ) => _withOutboxLock(() async {
    final current = await _readOutboxUnlocked();
    await _writeOutboxUnlocked(_deduplicate(mutation(current)));
  });

  Future<void> _writeOutboxUnlocked(List<_PendingProgress> items) async {
    if (items.isEmpty) {
      await _storage.delete(key: _trackingOutboxKey);
      return;
    }
    await _storage.write(
      key: _trackingOutboxKey,
      value: jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  List<_PendingProgress> _deduplicate(List<_PendingProgress> items) {
    final result = <String, _PendingProgress>{};
    for (final item in items) {
      final existing = result[item.outboxKey];
      if (existing == null ||
          item.completedEpisodes > existing.completedEpisodes) {
        result[item.outboxKey] = item;
      }
    }
    return result.values.toList(growable: false);
  }

  Future<T> _withOutboxLock<T>(Future<T> Function() operation) {
    final previous = _outboxTail;
    final release = Completer<void>();
    _outboxTail = release.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }

  Future<T> _serializeFlush<T>(Future<T> Function() operation) {
    final previous = _flushTail;
    final release = Completer<void>();
    _flushTail = release.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }

  void _scheduleRetry() {
    if (_disposed || _retryDelays.isEmpty) return;
    final index = _retryAttempt.clamp(0, _retryDelays.length - 1);
    _retryAttempt = (_retryAttempt + 1).clamp(0, _retryDelays.length);
    _scheduleFlush(_retryDelays[index]);
  }

  void _scheduleFlush(Duration delay) {
    if (_disposed) return;
    _scheduledFlush?.cancel();
    _scheduledFlush = _timerFactory(delay, () {
      _scheduledFlush = null;
      if (!_disposed) unawaited(_requestFlush());
    });
  }

  void _cancelScheduledFlush() {
    _scheduledFlush?.cancel();
    _scheduledFlush = null;
  }
}

Future<String?> _noActiveProfile(TrackingProvider _) async => null;

String? _normalizeProfileId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool _sameProfile(String? queued, String? active) =>
    queued != _unavailableProfileScope && queued == active;

class _PendingProgress {
  const _PendingProgress({
    required this.provider,
    required this.profileId,
    required this.mediaId,
    required this.completedEpisodes,
  });

  final TrackingProvider provider;
  final String? profileId;
  final int mediaId;
  final int completedEpisodes;

  String get outboxKey =>
      '${provider.slug}:${profileId ?? '<legacy>'}:$mediaId';

  static _PendingProgress? tryParse(Map<dynamic, dynamic> json) {
    final providerSlug = json['provider'];
    final mediaId = json['media_id'];
    final completedEpisodes = json['completed_episodes'];
    final profileId = json['profile_id'];
    if (providerSlug is! String ||
        mediaId is! num ||
        mediaId.toInt() <= 0 ||
        completedEpisodes is! num ||
        completedEpisodes.toInt() < 0 ||
        (profileId != null && profileId is! String)) {
      return null;
    }
    TrackingProvider? provider;
    for (final candidate in TrackingProvider.values) {
      if (candidate.slug == providerSlug) {
        provider = candidate;
        break;
      }
    }
    if (provider == null) return null;
    final normalizedProfile = profileId is String
        ? _normalizeProfileId(profileId)
        : null;
    if (normalizedProfile != null && normalizedProfile.length > 100) {
      return null;
    }
    return _PendingProgress(
      provider: provider,
      profileId: normalizedProfile,
      mediaId: mediaId.toInt(),
      completedEpisodes: completedEpisodes.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'provider': provider.slug,
    'profile_id': profileId,
    'media_id': mediaId,
    'completed_episodes': completedEpisodes,
  };
}
