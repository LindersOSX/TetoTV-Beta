import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/application/tracking_sync_service.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// In-memory FlutterSecureStorage for unit tests.
// Uses Fake to avoid declaring every platform-specific parameter.
// ---------------------------------------------------------------------------

class _FakeStorage extends Fake implements FlutterSecureStorage {
  final _data = <String, String>{};

  // The public API surface we actually use; all optional keyword args that
  // differ between versions are fine to omit because Fake ignores them.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('read')) {
      final key = invocation.namedArguments[#key] as String;
      return Future<String?>.value(_data[key]);
    }
    if (name.contains('write')) {
      final key = invocation.namedArguments[#key] as String;
      final value = invocation.namedArguments[#value] as String?;
      if (value == null) {
        _data.remove(key);
      } else {
        _data[key] = value;
      }
      return Future<void>.value();
    }
    if (name.contains('delete')) {
      final key = invocation.namedArguments[#key] as String;
      _data.remove(key);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

// ---------------------------------------------------------------------------
// Fake tracking repository that records update calls.
// ---------------------------------------------------------------------------

class _FakeRepo implements TrackingRepository, ExternalIdTrackingRepository {
  final List<({int mediaId, int episodes})> updates = [];
  final List<({TrackingMediaIds ids, int episodes})> externalUpdates = [];
  final List<({int mediaId, TrackingListStatus status})> statuses = [];
  final List<({TrackingMediaIds ids, TrackingListStatus status})>
  externalStatuses = [];
  final List<String> operations = [];
  bool shouldFail = false;
  bool statusShouldFail = false;
  Object? externalFailure;
  Duration updateDelay = Duration.zero;

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async => const [];

  @override
  Future<int?> currentProgress(int mediaId) async => 0;

  @override
  Future<void> removeFromList({required int mediaId}) async {}

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) async {
    if (updateDelay > Duration.zero) await Future<void>.delayed(updateDelay);
    if (shouldFail) throw Exception('network error');
    operations.add('progress');
    updates.add((mediaId: mediaId, episodes: completedEpisodes));
  }

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    if (shouldFail || statusShouldFail) throw Exception('network error');
    operations.add('watching');
    statuses.add((mediaId: mediaId, status: status));
  }

  @override
  Future<int?> currentProgressByIds(TrackingMediaIds ids) async => 0;

  @override
  Future<void> removeFromListByIds(TrackingMediaIds ids) async {}

  @override
  Future<void> updateProgressByIds({
    required TrackingMediaIds ids,
    required int completedEpisodes,
  }) async {
    if (externalFailure case final failure?) throw failure;
    if (shouldFail) throw Exception('network error');
    operations.add('progress');
    externalUpdates.add((ids: ids, episodes: completedEpisodes));
  }

  @override
  Future<void> updateStatusByIds({
    required TrackingMediaIds ids,
    required TrackingListStatus status,
  }) async {
    if (externalFailure case final failure?) throw failure;
    if (shouldFail || statusShouldFail) throw Exception('network error');
    operations.add('watching');
    externalStatuses.add((ids: ids, status: status));
  }
}

class _CompletionRepo extends _FakeRepo
    implements AutomaticCompletionTrackingRepository {
  final completionCalls = <({TrackingMediaIds ids, int episodes})>[];
  bool completionShouldFail = false;

  @override
  Future<void> updateProgressAndCompletion({
    required TrackingMediaIds ids,
    required int completedEpisodes,
  }) async {
    completionCalls.add((ids: ids, episodes: completedEpisodes));
    if (shouldFail) throw Exception('offline');
    operations.add('progress');
    if (completionShouldFail) throw Exception('status write failed');
    operations.add('completed');
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

// ---------------------------------------------------------------------------
// Testable subclass that uses fake repositories.
// ---------------------------------------------------------------------------

class _TestSyncService extends TrackingSyncService {
  _TestSyncService(
    super.storage,
    super.tokenLookup, {
    required this.anilistRepo,
    required this.malRepo,
    super.profileLookup,
    super.verifiedProfileLookup,
    super.resumeDebounce = const Duration(milliseconds: 400),
    super.retryDelays = const [],
    super.timerFactory = _testTimer,
    super.onProgressDelivered,
    super.statusRecorder,
  }) : super.withLookup();

  final _FakeRepo anilistRepo;
  final _FakeRepo malRepo;

  @override
  TrackingRepository buildRepository(TrackingProvider provider, String token) {
    return switch (provider) {
      TrackingProvider.anilist => anilistRepo,
      TrackingProvider.myAnimeList => malRepo,
      TrackingProvider.kitsu => anilistRepo,
      TrackingProvider.simkl => anilistRepo,
    };
  }
}

Timer _testTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);

// ---------------------------------------------------------------------------
// Outbox JSON helpers operating directly on _FakeStorage._data.
// ---------------------------------------------------------------------------

const _outboxKey = 'tracking_progress_outbox_v1';

List<Map<String, dynamic>> _readOutbox(_FakeStorage s) {
  final raw = s._data[_outboxKey];
  if (raw == null || raw.isEmpty) return const [];
  return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
}

void _writeOutbox(_FakeStorage s, List<Map<String, dynamic>> entries) {
  s._data[_outboxKey] = jsonEncode(entries);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _FakeStorage storage;
  late _FakeRepo anilistRepo;
  late _FakeRepo malRepo;

  _TestSyncService buildService({
    Map<TrackingProvider, String?> tokens = const {
      TrackingProvider.anilist: 'al-tok',
      TrackingProvider.myAnimeList: 'mal-tok',
    },
    Map<TrackingProvider, String?> profiles = const {},
    TrackingVerifiedProfileLookup? verifiedProfileLookup,
    List<Duration> retryDelays = const [],
    TrackingTimerFactory timerFactory = _testTimer,
    Duration resumeDebounce = const Duration(milliseconds: 400),
    void Function()? onProgressDelivered,
    TrackingSyncStatusRecorder? statusRecorder,
  }) {
    return _TestSyncService(
      storage,
      (provider) async => tokens[provider],
      profileLookup: (provider) async => profiles[provider],
      verifiedProfileLookup: verifiedProfileLookup,
      retryDelays: retryDelays,
      timerFactory: timerFactory,
      resumeDebounce: resumeDebounce,
      onProgressDelivered: onProgressDelivered,
      statusRecorder: statusRecorder,
      anilistRepo: anilistRepo,
      malRepo: malRepo,
    );
  }

  setUp(() {
    storage = _FakeStorage();
    anilistRepo = _FakeRepo();
    malRepo = _FakeRepo();
  });

  group('syncWatching', () {
    test(
      'successful Watching delivery refreshes cached tracking views',
      () async {
        var refreshes = 0;
        await buildService(
          onProgressDelivered: () => refreshes++,
        ).syncWatching(anilistMediaId: 101);
        expect(refreshes, 1);
      },
    );

    test(
      'adds a previously absent title to both lists without progress',
      () async {
        expect(
          await buildService().syncWatching(
            anilistMediaId: 101,
            malMediaId: 202,
          ),
          isTrue,
        );
        expect(anilistRepo.statuses, [
          (mediaId: 101, status: TrackingListStatus.watching),
        ]);
        expect(malRepo.statuses, [
          (mediaId: 202, status: TrackingListStatus.watching),
        ]);
        expect(anilistRepo.updates, isEmpty);
        expect(malRepo.updates, isEmpty);
        expect(_readOutbox(storage), isEmpty);
      },
    );

    test(
      'fans out through verified Kitsu and SIMKL catalog identities',
      () async {
        final service = buildService(
          tokens: const {
            TrackingProvider.anilist: 'al-token',
            TrackingProvider.myAnimeList: 'mal-token',
            TrackingProvider.kitsu: 'kitsu-token',
            TrackingProvider.simkl: 'simkl-token',
          },
          verifiedProfileLookup: (provider, _) async =>
              '${provider.slug}-profile',
        );
        expect(
          await service.syncWatching(anilistMediaId: 101, malMediaId: 202),
          isTrue,
        );
        expect(anilistRepo.statuses, hasLength(1));
        expect(malRepo.statuses, hasLength(1));
        expect(anilistRepo.externalStatuses, hasLength(2));
        for (final update in anilistRepo.externalStatuses) {
          expect(update.ids.anilistId, 101);
          expect(update.ids.malId, 202);
          expect(update.status, TrackingListStatus.watching);
        }
        expect(anilistRepo.updates, isEmpty);
        expect(anilistRepo.externalUpdates, isEmpty);
      },
    );

    test(
      'keeps a start row separate from queued completion progress',
      () async {
        anilistRepo.shouldFail = true;
        final service = buildService();
        await service.syncEpisode(completedEpisodes: 6, anilistMediaId: 101);
        await service.syncWatching(anilistMediaId: 101);
        await service.syncWatching(anilistMediaId: 101);
        final rows = _readOutbox(storage);
        expect(rows, hasLength(2));
        expect(rows.where((row) => row['action'] == 'watching'), hasLength(1));
        expect(
          rows.singleWhere(
            (row) => row['action'] == null,
          )['completed_episodes'],
          6,
        );
        anilistRepo.shouldFail = false;
        await service.flush();
        expect(anilistRepo.operations, ['watching', 'progress']);
        expect(anilistRepo.updates.single.episodes, 6);
        expect(_readOutbox(storage), isEmpty);
      },
    );

    test('a failed start cannot arrive after completion progress', () async {
      anilistRepo.statusShouldFail = true;
      final service = buildService();
      await service.syncWatching(anilistMediaId: 101);
      await service.syncEpisode(completedEpisodes: 12, anilistMediaId: 101);
      expect(anilistRepo.updates, isEmpty);
      expect(_readOutbox(storage), hasLength(2));
      anilistRepo.statusShouldFail = false;
      await service.flush();
      expect(anilistRepo.operations, ['watching', 'progress']);
      expect(_readOutbox(storage), isEmpty);
    });

    test(
      'one unavailable tracker does not stop another list being added',
      () async {
        anilistRepo.shouldFail = true;
        final service = buildService();
        expect(
          await service.syncWatching(anilistMediaId: 101, malMediaId: 202),
          isFalse,
        );
        expect(malRepo.statuses, hasLength(1));
        expect(_readOutbox(storage), hasLength(1));
        expect(_readOutbox(storage).single['provider'], 'anilist');
        expect(_readOutbox(storage).single['action'], 'watching');
      },
    );

    test(
      'does not send an old start update to a newly selected account',
      () async {
        anilistRepo.shouldFail = true;
        final original = buildService(
          profiles: const {TrackingProvider.anilist: 'account-a'},
        );
        await original.syncWatching(anilistMediaId: 101);
        original.dispose();
        anilistRepo.shouldFail = false;
        await buildService(
          profiles: const {TrackingProvider.anilist: 'account-b'},
        ).flush();
        expect(anilistRepo.statuses, isEmpty);
        expect(_readOutbox(storage).single['profile_id'], 'account-a');
      },
    );

    test(
      'external starts never use an unverified account or guessed title',
      () async {
        await buildService(
          tokens: const {
            TrackingProvider.kitsu: 'kitsu-token',
            TrackingProvider.simkl: 'simkl-token',
          },
        ).syncWatching(anilistMediaId: 101);
        expect(anilistRepo.externalStatuses, isEmpty);
        expect(
          _readOutbox(storage).where(
            (row) => row['provider'] == 'kitsu' || row['provider'] == 'simkl',
          ),
          isEmpty,
        );
      },
    );

    test('unknown queued action cannot become a progress update', () async {
      _writeOutbox(storage, [
        {
          'provider': 'anilist',
          'media_id': 101,
          'completed_episodes': 0,
          'action': 'unexpected-action',
        },
      ]);
      await buildService().flush();
      expect(anilistRepo.statuses, isEmpty);
      expect(anilistRepo.updates, isEmpty);
    });

    test('no catalog identity is a no-op', () async {
      expect(await buildService().syncWatching(), isFalse);
      expect(anilistRepo.statuses, isEmpty);
      expect(malRepo.statuses, isEmpty);
    });
  });

  group('syncEpisode', () {
    test('persists progress before looking up a token', () async {
      var tokenLookups = 0;
      final service = _TestSyncService(
        storage,
        (provider) async {
          tokenLookups++;
          final outbox = _readOutbox(storage);
          expect(outbox, hasLength(1));
          expect(outbox.single['media_id'], 101);
          expect(outbox.single['completed_episodes'], 5);
          return provider == TrackingProvider.anilist ? 'token' : null;
        },
        anilistRepo: anilistRepo,
        malRepo: malRepo,
      );

      expect(
        await service.syncEpisode(completedEpisodes: 5, anilistMediaId: 101),
        isTrue,
      );
      expect(tokenLookups, 3);
      expect(_readOutbox(storage), isEmpty);
    });

    test('syncs to both trackers when both IDs are supplied', () async {
      final synced = await buildService().syncEpisode(
        completedEpisodes: 5,
        anilistMediaId: 101,
        malMediaId: 202,
      );

      expect(synced, isTrue);
      expect(anilistRepo.updates, hasLength(1));
      expect(anilistRepo.updates.first.mediaId, 101);
      expect(anilistRepo.updates.first.episodes, 5);
      expect(malRepo.updates, hasLength(1));
      expect(malRepo.updates.first.mediaId, 202);
      expect(malRepo.updates.first.episodes, 5);
    });

    test('refreshes tracking views after delivered progress', () async {
      var refreshes = 0;
      final service = buildService(onProgressDelivered: () => refreshes++);

      expect(
        await service.syncEpisode(completedEpisodes: 5, anilistMediaId: 101),
        isTrue,
      );
      expect(refreshes, 1);
    });

    test('does not persist an update for an unreadable account slot', () async {
      final service = _TestSyncService(
        storage,
        (_) async => 'token',
        profileLookup: (_) async => throw StateError('storage unavailable'),
        anilistRepo: anilistRepo,
        malRepo: malRepo,
      );

      await expectLater(
        service.syncEpisode(completedEpisodes: 5, anilistMediaId: 101),
        throwsStateError,
      );
      expect(_readOutbox(storage), isEmpty);
      expect(anilistRepo.updates, isEmpty);
    });

    test('maps episode progress to a verified Kitsu account', () async {
      final synced = await buildService(
        tokens: const {
          TrackingProvider.anilist: 'al-token',
          TrackingProvider.myAnimeList: 'mal-token',
          TrackingProvider.kitsu: 'kitsu-token',
        },
        verifiedProfileLookup: (provider, token) async =>
            provider == TrackingProvider.kitsu ? 'kitsu-profile' : null,
      ).syncEpisode(completedEpisodes: 6, anilistMediaId: 101, malMediaId: 202);

      expect(synced, isTrue);
      expect(anilistRepo.externalUpdates, hasLength(1));
      expect(anilistRepo.externalUpdates.single.ids.anilistId, 101);
      expect(anilistRepo.externalUpdates.single.ids.malId, 202);
      expect(anilistRepo.externalUpdates.single.episodes, 6);
    });

    test('skips tracker when its token is absent', () async {
      final synced = await buildService(
        tokens: {
          TrackingProvider.anilist: null,
          TrackingProvider.myAnimeList: 'mal-tok',
        },
      ).syncEpisode(completedEpisodes: 3, anilistMediaId: 101, malMediaId: 202);

      expect(synced, isFalse);
      expect(anilistRepo.updates, isEmpty);
      expect(malRepo.updates, hasLength(1));
      expect(_readOutbox(storage), hasLength(1));
      expect(_readOutbox(storage).single['provider'], 'anilist');
    });

    test(
      'diagnostics explain queued progress without exposing media IDs',
      () async {
        final statuses = <Map<String, Object?>>[];
        final service = buildService(
          tokens: const {
            TrackingProvider.anilist: null,
            TrackingProvider.myAnimeList: null,
          },
          statusRecorder: (details) async => statuses.add(details),
        );

        expect(
          await service.syncEpisode(completedEpisodes: 4, anilistMediaId: 101),
          isFalse,
        );
        expect(
          statuses,
          containsAll([
            {'provider': 'anilist', 'stage': 'queued'},
            {
              'provider': 'anilist',
              'stage': 'deferred',
              'reason': 'token_missing',
            },
          ]),
        );
        expect(
          statuses.every((details) => !details.containsKey('media_id')),
          isTrue,
        );
      },
    );

    test('queues progress when token lookup fails', () async {
      final service = _TestSyncService(
        storage,
        (provider) async => throw Exception('refresh failed'),
        anilistRepo: anilistRepo,
        malRepo: malRepo,
      );

      final synced = await service.syncEpisode(
        completedEpisodes: 6,
        anilistMediaId: 101,
      );

      expect(synced, isFalse);
      expect(anilistRepo.updates, isEmpty);
      expect(_readOutbox(storage).single['completed_episodes'], 6);
    });

    test(
      'an unverified SIMKL token does not block primary tracker flushing',
      () async {
        final service = buildService(
          tokens: const {
            TrackingProvider.anilist: 'al-token',
            TrackingProvider.myAnimeList: null,
            TrackingProvider.simkl: 'replacement-simkl-token',
          },
          profiles: const {
            TrackingProvider.anilist: 'anilist-profile',
            TrackingProvider.simkl: 'old-simkl-profile',
          },
          verifiedProfileLookup: (_, _) async => null,
        );

        expect(
          await service.syncEpisode(completedEpisodes: 6, anilistMediaId: 101),
          isTrue,
        );
        expect(anilistRepo.updates, [(mediaId: 101, episodes: 6)]);
        expect(_readOutbox(storage), isEmpty);
      },
    );

    test('is a no-op when no media IDs are supplied', () async {
      final synced = await buildService().syncEpisode(completedEpisodes: 7);

      expect(synced, isFalse);
      expect(anilistRepo.updates, isEmpty);
      expect(malRepo.updates, isEmpty);
      expect(_readOutbox(storage), isEmpty);
    });

    test('writes failed sync to outbox', () async {
      anilistRepo.shouldFail = true;

      final synced = await buildService().syncEpisode(
        completedEpisodes: 4,
        anilistMediaId: 101,
      );

      expect(synced, isFalse);
      final outbox = _readOutbox(storage);
      expect(outbox, hasLength(1));
      expect(outbox.first['media_id'], 101);
      expect(outbox.first['completed_episodes'], 4);
      expect(outbox.first['provider'], 'anilist');
    });

    test('concurrent failures retain every queued progress update', () async {
      anilistRepo
        ..shouldFail = true
        ..updateDelay = const Duration(milliseconds: 10);
      final service = buildService();

      await Future.wait([
        service.syncEpisode(completedEpisodes: 2, anilistMediaId: 101),
        service.syncEpisode(completedEpisodes: 4, anilistMediaId: 102),
      ]);

      final outbox = _readOutbox(storage);
      expect(outbox, hasLength(2));
      expect(outbox.map((item) => item['media_id']), containsAll([101, 102]));
    });
  });

  group('flush', () {
    test('retains outbox entry while its tracker is disconnected', () async {
      _writeOutbox(storage, [
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 3},
      ]);

      await buildService(
        tokens: const {
          TrackingProvider.anilist: null,
          TrackingProvider.myAnimeList: null,
        },
      ).flush();

      expect(_readOutbox(storage), hasLength(1));
    });

    test('succeeds and clears outbox entry', () async {
      _writeOutbox(storage, [
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 3},
      ]);

      await buildService().flush();

      expect(_readOutbox(storage), isEmpty);
      expect(anilistRepo.updates.first.episodes, 3);
    });

    test('retains only failed entries after partial flush', () async {
      anilistRepo.shouldFail = true;
      _writeOutbox(storage, [
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 4},
        {'provider': 'myanimelist', 'media_id': 202, 'completed_episodes': 4},
      ]);

      await buildService().flush();

      final remaining = _readOutbox(storage);
      expect(remaining, hasLength(1));
      expect(remaining.first['provider'], 'anilist');
      expect(malRepo.updates, hasLength(1));
    });

    test('deduplication in outbox keeps highest episode on failure', () async {
      // If the sync fails, the retry outbox should only keep one entry per
      // media – the one with the highest episode count.
      anilistRepo.shouldFail = true;
      _writeOutbox(storage, [
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 2},
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 5},
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 3},
      ]);

      await buildService().flush();

      // All 3 were attempted but all failed; the outbox should now contain
      // only 1 entry – the one with completedEpisodes == 5.
      final outbox = _readOutbox(storage);
      expect(outbox, hasLength(1));
      expect(outbox.first['completed_episodes'], 5);
    });

    test('no-op when outbox is empty', () async {
      await buildService().flush();

      expect(anilistRepo.updates, isEmpty);
      expect(malRepo.updates, isEmpty);
    });

    test('ignores malformed outbox JSON gracefully', () async {
      storage._data[_outboxKey] = 'NOT_JSON{{';

      // Should not throw; should treat as empty outbox.
      await expectLater(buildService().flush(), completes);
      expect(storage._data[_outboxKey], isNull);
    });

    test('skips one malformed row without erasing valid progress', () async {
      _writeOutbox(storage, [
        {'provider': 'invalid', 'media_id': 'bad'},
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 3},
      ]);

      await buildService().flush();

      expect(anilistRepo.updates, [(mediaId: 101, episodes: 3)]);
      expect(_readOutbox(storage), isEmpty);
    });
  });

  group('profile-scoped outbox', () {
    test(
      'writes the active saved profile identity into a queued row',
      () async {
        anilistRepo.shouldFail = true;

        await buildService(
          profiles: const {TrackingProvider.anilist: 'anilist-profile-a'},
        ).syncEpisode(completedEpisodes: 4, anilistMediaId: 101);

        final row = _readOutbox(storage).single;
        expect(row['profile_id'], 'anilist-profile-a');
      },
    );

    test('never looks up a token for another active profile', () async {
      _writeOutbox(storage, [
        {
          'provider': 'anilist',
          'profile_id': 'anilist-profile-a',
          'media_id': 101,
          'completed_episodes': 4,
        },
      ]);
      var tokenLookups = 0;
      final service = _TestSyncService(
        storage,
        (provider) async {
          tokenLookups++;
          return 'wrong-account-token';
        },
        profileLookup: (provider) async => 'anilist-profile-b',
        anilistRepo: anilistRepo,
        malRepo: malRepo,
      );

      await service.flush();

      expect(tokenLookups, 0);
      expect(anilistRepo.updates, isEmpty);
      expect(_readOutbox(storage), hasLength(1));
    });

    test(
      'never flushes SIMKL progress through an unverified token slot',
      () async {
        _writeOutbox(storage, [
          {
            'provider': 'simkl',
            'profile_id': 'old-simkl-profile',
            'media_id': 101,
            'anilist_media_id': 101,
            'completed_episodes': 4,
          },
        ]);
        var verifiedLookups = 0;
        final service = _TestSyncService(
          storage,
          (provider) async => 'replacement-simkl-token',
          profileLookup: (provider) async => 'old-simkl-profile',
          verifiedProfileLookup: (provider, token) async {
            verifiedLookups++;
            expect(provider, TrackingProvider.simkl);
            expect(token, 'replacement-simkl-token');
            return null;
          },
          anilistRepo: anilistRepo,
          malRepo: malRepo,
        );

        await service.flush();

        expect(verifiedLookups, 1);
        expect(anilistRepo.updates, isEmpty);
        expect(_readOutbox(storage), hasLength(1));
      },
    );

    test(
      'deduplicates within a profile but keeps another profile separate',
      () async {
        _writeOutbox(storage, [
          {
            'provider': 'anilist',
            'profile_id': 'anilist-profile-a',
            'media_id': 101,
            'completed_episodes': 2,
          },
          {
            'provider': 'anilist',
            'profile_id': 'anilist-profile-a',
            'media_id': 101,
            'completed_episodes': 6,
          },
          {
            'provider': 'anilist',
            'profile_id': 'anilist-profile-b',
            'media_id': 101,
            'completed_episodes': 3,
          },
        ]);

        await buildService(
          profiles: const {TrackingProvider.anilist: 'different-profile'},
        ).flush();

        final rows = _readOutbox(storage);
        expect(rows, hasLength(2));
        expect(
          rows
              .where((row) => row['profile_id'] == 'anilist-profile-a')
              .single['completed_episodes'],
          6,
        );
        expect(
          rows
              .where((row) => row['profile_id'] == 'anilist-profile-b')
              .single['completed_episodes'],
          3,
        );
      },
    );
  });

  group('automatic retry', () {
    test('app resume debounce replaces the earlier scheduled flush', () async {
      _writeOutbox(storage, [
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 3},
      ]);
      final timers = <_FakeTimer>[];
      final service = buildService(
        resumeDebounce: const Duration(milliseconds: 250),
        timerFactory: (delay, callback) {
          final timer = _FakeTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(timers, hasLength(2));
      expect(timers.first.isActive, isFalse);
      expect(timers.last.delay, const Duration(milliseconds: 250));
      timers.last.fire();
      await service.flush();
      expect(anilistRepo.updates, [(mediaId: 101, episodes: 3)]);
      service.dispose();
    });

    test('failed network work schedules a bounded retry flush', () async {
      anilistRepo.shouldFail = true;
      final timers = <_FakeTimer>[];
      final service = buildService(
        retryDelays: const [Duration(seconds: 5)],
        timerFactory: (delay, callback) {
          final timer = _FakeTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );

      expect(
        await service.syncEpisode(completedEpisodes: 4, anilistMediaId: 101),
        isFalse,
      );
      expect(timers.single.delay, const Duration(seconds: 5));
      expect(_readOutbox(storage), hasLength(1));

      anilistRepo.shouldFail = false;
      timers.single.fire();
      await service.flush();
      expect(_readOutbox(storage), isEmpty);
      expect(anilistRepo.updates, [(mediaId: 101, episodes: 4)]);
      service.dispose();
    });

    test('permanent Kitsu mapping miss is removed without retry', () async {
      _writeOutbox(storage, [
        {
          'provider': 'kitsu',
          'profile_id': 'kitsu-profile',
          'media_id': 101,
          'anilist_media_id': 101,
          'completed_episodes': 4,
        },
      ]);
      anilistRepo.externalFailure =
          const TrackingMediaMappingNotFoundException();
      final timers = <_FakeTimer>[];
      final service = buildService(
        tokens: const {TrackingProvider.kitsu: 'kitsu-token'},
        verifiedProfileLookup: (provider, token) async => 'kitsu-profile',
        retryDelays: const [Duration(seconds: 5)],
        timerFactory: (delay, callback) {
          final timer = _FakeTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );

      await service.flush();

      expect(_readOutbox(storage), isEmpty);
      expect(anilistRepo.externalUpdates, isEmpty);
      expect(timers, isEmpty);
      service.dispose();
    });

    test('transient Kitsu mapping request failure remains retryable', () async {
      _writeOutbox(storage, [
        {
          'provider': 'kitsu',
          'profile_id': 'kitsu-profile',
          'media_id': 101,
          'anilist_media_id': 101,
          'completed_episodes': 4,
        },
      ]);
      anilistRepo.externalFailure = Exception('temporary network failure');
      final timers = <_FakeTimer>[];
      final service = buildService(
        tokens: const {TrackingProvider.kitsu: 'kitsu-token'},
        verifiedProfileLookup: (provider, token) async => 'kitsu-profile',
        retryDelays: const [Duration(seconds: 5)],
        timerFactory: (delay, callback) {
          final timer = _FakeTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );

      await service.flush();

      expect(_readOutbox(storage), hasLength(1));
      expect(timers.single.delay, const Duration(seconds: 5));
      service.dispose();
    });
  });

  group('automatic Completed outbox', () {
    for (final provider in TrackingProvider.values) {
      test(
        '${provider.name} delivers completion through verified IDs',
        () async {
          final repo = _CompletionRepo();
          anilistRepo = repo;
          malRepo = repo;
          final service = buildService(
            tokens: {provider: 'unused-token'},
            profiles: {provider: 'profile'},
            verifiedProfileLookup: (_, _) async => 'profile',
          );
          addTearDown(service.dispose);
          await service.syncEpisode(
            completedEpisodes: 12,
            anilistMediaId: 101,
            malMediaId: 202,
          );
          expect(repo.completionCalls, hasLength(1));
          final ids = repo.completionCalls.single.ids;
          if (provider == TrackingProvider.anilist) {
            expect(ids.anilistId, 101);
          } else if (provider == TrackingProvider.myAnimeList) {
            expect(ids.malId, 202);
          } else {
            expect(ids.anilistId, 101);
            expect(ids.malId, 202);
          }
          expect(repo.operations, ['progress', 'completed']);
          expect(
            _readOutbox(
              storage,
            ).where((row) => row['provider'] == provider.slug),
            isEmpty,
          );
        },
      );
    }

    test(
      'failed Completed persists across restart without replaying Watching',
      () async {
        final repo = _CompletionRepo()..completionShouldFail = true;
        anilistRepo = repo;
        var refreshes = 0;
        final service = buildService(
          tokens: const {TrackingProvider.anilist: 'token'},
          onProgressDelivered: () => refreshes++,
        );
        await service.syncWatching(anilistMediaId: 101);
        expect(refreshes, 1);
        await service.syncEpisode(completedEpisodes: 12, anilistMediaId: 101);
        expect(_readOutbox(storage), hasLength(1));
        expect(refreshes, 1);
        service.dispose();
        repo.completionShouldFail = false;
        final restored = buildService(
          tokens: const {TrackingProvider.anilist: 'token'},
          onProgressDelivered: () => refreshes++,
        );
        addTearDown(restored.dispose);
        await restored.flush();
        expect(repo.operations, [
          'watching',
          'progress',
          'progress',
          'completed',
        ]);
        expect(_readOutbox(storage), isEmpty);
        expect(refreshes, 2);
      },
    );

    test('failed Watching defers Completed until Watching succeeds', () async {
      final repo = _CompletionRepo()..statusShouldFail = true;
      anilistRepo = repo;
      final service = buildService(
        tokens: const {TrackingProvider.anilist: 'token'},
      );
      addTearDown(service.dispose);
      await service.syncWatching(anilistMediaId: 101);
      await service.syncEpisode(completedEpisodes: 12, anilistMediaId: 101);
      expect(repo.completionCalls, isEmpty);
      expect(_readOutbox(storage), hasLength(2));
      repo.statusShouldFail = false;
      await service.flush();
      expect(repo.operations, ['watching', 'progress', 'completed']);
      expect(_readOutbox(storage), isEmpty);
    });

    test(
      'another linked tracker still completes if one tracker fails',
      () async {
        final failed = _CompletionRepo()..completionShouldFail = true;
        final successful = _CompletionRepo();
        anilistRepo = failed;
        malRepo = successful;
        final service = buildService();
        addTearDown(service.dispose);
        await service.syncEpisode(
          completedEpisodes: 12,
          anilistMediaId: 101,
          malMediaId: 202,
        );
        expect(successful.operations, ['progress', 'completed']);
        expect(_readOutbox(storage).single['provider'], 'anilist');
      },
    );

    test('pending completion cannot cross into another account', () async {
      final repo = _CompletionRepo();
      anilistRepo = repo;
      _writeOutbox(storage, [
        {
          'provider': 'anilist',
          'profile_id': 'original',
          'media_id': 101,
          'completed_episodes': 12,
        },
      ]);
      final service = buildService(
        profiles: const {TrackingProvider.anilist: 'replacement'},
      );
      addTearDown(service.dispose);
      await service.flush();
      expect(repo.completionCalls, isEmpty);
      expect(_readOutbox(storage), hasLength(1));
    });
  });

  group('deduplication across syncEpisode + existing outbox', () {
    test('higher episode number wins when same media is in outbox', () async {
      // Seed the outbox with a lower episode count for the same media.
      _writeOutbox(storage, [
        {'provider': 'anilist', 'media_id': 101, 'completed_episodes': 2},
      ]);
      anilistRepo.shouldFail = true; // Force both attempts to fail.

      await buildService().syncEpisode(
        completedEpisodes: 6,
        anilistMediaId: 101,
      );

      // The outbox should contain only episode 6, not both 2 and 6.
      final outbox = _readOutbox(storage);
      expect(outbox, hasLength(1));
      expect(outbox.first['completed_episodes'], 6);
    });
  });
}
