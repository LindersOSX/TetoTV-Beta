import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/application/manga_tracking_controller.dart';
import 'package:anime_tv/features/manga/data/manga_tracking_client.dart';
import 'package:anime_tv/features/manga/data/manga_tracking_state_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements MangaTrackingStateStore {
  MangaTrackingSnapshot state = MangaTrackingSnapshot();
  bool failWrites = false;
  Future<void> Function()? onRead;
  @override
  Future<MangaTrackingSnapshot> read() async {
    await onRead?.call();
    return state;
  }

  @override
  Future<void> write(MangaTrackingSnapshot snapshot) async {
    if (failWrites) throw StateError('protected storage unavailable');
    // Encode/decode on each write to exercise actual restart representation.
    state = MangaTrackingSnapshot(
      links: snapshot.links.map(
        (row) => MangaTrackingLink.fromJson(
          jsonDecode(jsonEncode(row.toJson())) as Map<String, dynamic>,
        ),
      ),
      pending: snapshot.pending.map(
        (row) => MangaTrackingPending.fromJson(
          jsonDecode(jsonEncode(row.toJson())) as Map<String, dynamic>,
        ),
      ),
    );
  }
}

class _Backend {
  String account = '77';
  int progress = 0;
  Object? error;
  final updates = <int>[];
  int calls = 0;
  Future<void> Function()? onProgress;
  Future<void> Function()? onUpdate;
  MangaTrackingSearchResult record(TrackingProvider provider, {int id = 42}) =>
      MangaTrackingSearchResult(
        provider: provider,
        mediaId: id,
        title: 'Chosen Manga',
        totalChapters: 100,
      );
}

class _Client implements MangaTrackingClient {
  _Client(this.backend, this.provider);
  final _Backend backend;
  final TrackingProvider provider;
  void _call() {
    backend.calls++;
    if (backend.error case final error?) throw error;
  }

  @override
  Future<String> accountId() async {
    _call();
    return backend.account;
  }

  @override
  Future<List<MangaTrackingSearchResult>> search(String query) async {
    _call();
    return [backend.record(provider)];
  }

  @override
  Future<MangaTrackingSearchResult> details(int mediaId) async {
    _call();
    return backend.record(provider, id: mediaId);
  }

  @override
  Future<int> currentProgress(int mediaId) async {
    _call();
    await backend.onProgress?.call();
    return backend.progress;
  }

  @override
  Future<void> updateProgress(int mediaId, int completedChapters) async {
    _call();
    await backend.onUpdate?.call();
    backend.progress = completedChapters;
    backend.updates.add(completedChapters);
  }

  @override
  void close() {}
}

class _Fixture {
  final store = _MemoryStore();
  final backend = _Backend();
  String owner = 'owner-1';
  String? profile = 'profile-1';
  String? token = 'private-access-capability';
  Object? tokenError;
  var now = DateTime.utc(2026, 9, 5);
  var nextBinding = 0;
  final controllers = <MangaTrackingController>[];
  MangaTrackingTitleKey get title => MangaTrackingTitleKey(
    ownerKey: 'owner-1',
    sourceId: 'seanime',
    publicationId: 'durable-publication',
  );
  MangaTrackingController create({
    int maximumAttempts = 3,
    bool featureAvailable = true,
  }) {
    final controller = MangaTrackingController(
      store: store,
      ownerKey: () async => owner,
      profileLookup: (_) async => profile,
      tokenLookup: (_) async {
        if (tokenError case final error?) throw error;
        return token;
      },
      clientFactory: (provider, _) => _Client(backend, provider),
      now: () => now,
      bindingId: () => 'binding-${++nextBinding}',
      maximumAttempts: maximumAttempts,
      featureAvailable: featureAvailable,
      automaticRetries: false,
      retryDelays: const [
        Duration(seconds: 5),
        Duration(seconds: 30),
        Duration(minutes: 2),
      ],
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> link(
    MangaTrackingController controller, {
    TrackingProvider provider = TrackingProvider.anilist,
  }) => controller.linkManga(title, backend.record(provider), confirmed: true);
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.dispose());

  for (final switchKind in ['owner', 'profile', 'token']) {
    test(
      'link rechecks $switchKind after awaiting protected state read',
      () async {
        final controller = fixture.create();
        fixture.store.onRead = () async {
          switch (switchKind) {
            case 'owner':
              fixture.owner = 'owner-2';
            case 'profile':
              fixture.profile = 'profile-2';
            case 'token':
              fixture.token = 'new-account-token';
          }
        };
        await expectLater(
          fixture.link(controller),
          throwsA(isA<MangaTrackingException>()),
        );
        expect(fixture.store.state.links, isEmpty);
        expect(fixture.backend.updates, isEmpty);
      },
    );
  }

  test(
    'manual title/provider retry preserves unrelated failed pending rows',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      await fixture.link(controller, provider: TrackingProvider.myAnimeList);
      final otherTitle = MangaTrackingTitleKey(
        ownerKey: 'owner-1',
        sourceId: 'seanime',
        publicationId: 'other',
      );
      await controller.linkManga(
        otherTitle,
        fixture.backend.record(TrackingProvider.anilist, id: 84),
        confirmed: true,
      );
      final links = fixture.store.state.links;
      fixture.store.state = MangaTrackingSnapshot(
        links: links,
        pending: [
          for (final link in links)
            MangaTrackingPending(
              bindingId: link.bindingId,
              completedChapters: 5,
              attempts: 3,
              needsAttention: true,
              nextAttemptAt: fixture.now.add(const Duration(days: 1)),
              lastError: 'Needs attention',
            ),
        ],
      );
      final untouched = fixture.store.state.pending
          .skip(1)
          .map((row) => jsonEncode(row.toJson()))
          .toList();
      await controller.retryPending(
        manual: true,
        title: fixture.title,
        provider: TrackingProvider.anilist,
      );
      expect(fixture.backend.updates, [5]);
      expect(
        fixture.store.state.pending.map((row) => jsonEncode(row.toJson())),
        untouched,
      );
    },
  );

  test(
    'manual title retry rejects another owner without changing the outbox',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.error = Exception('offline');
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 3,
      );
      final before = jsonEncode(fixture.store.state.pending.single.toJson());
      fixture.owner = 'owner-2';
      await expectLater(
        controller.retryPending(manual: true, title: fixture.title),
        throwsA(isA<MangaTrackingException>()),
      );
      expect(jsonEncode(fixture.store.state.pending.single.toJson()), before);
    },
  );

  test('deferred sync awaits durable storage but not tracker HTTP', () async {
    final controller = fixture.create();
    await fixture.link(controller);
    final entered = Completer<void>();
    final release = Completer<void>();
    fixture.backend.onProgress = () async {
      entered.complete();
      await release.future;
    };
    expect(
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 7,
        deferNetwork: true,
      ),
      true,
    );
    expect(fixture.store.state.pending.single.completedChapters, 7);
    await entered.future;
    expect(fixture.backend.updates, isEmpty);
    release.complete();
    await controller.retryPending();
    expect(fixture.backend.updates, [7]);
    expect(fixture.store.state.pending, isEmpty);
  });

  test(
    'matching is explicitly confirmed and no link means no remote activity',
    () async {
      final controller = fixture.create();
      await expectLater(
        controller.linkManga(
          fixture.title,
          fixture.backend.record(TrackingProvider.anilist),
          confirmed: false,
        ),
        throwsA(isA<MangaTrackingException>()),
      );
      expect(
        await controller.syncCompletedChapter(
          fixture.title,
          completedChapters: 4,
        ),
        false,
      );
      expect(fixture.backend.calls, 0);
      expect(fixture.store.state.links, isEmpty);
    },
  );

  test(
    'explicit link binds profile/account; linking never changes remote progress',
    () async {
      final controller = fixture.create();
      final found = await controller.searchCatalog(
        TrackingProvider.anilist,
        'Chosen',
      );
      final link = await controller.linkManga(
        fixture.title,
        found.single,
        confirmed: true,
      );
      expect(link.accountId, '77');
      expect(link.profileId, 'profile-1');
      expect(fixture.backend.updates, isEmpty);
      expect(await controller.currentLinks(fixture.title), hasLength(1));
      expect(
        await controller.syncCompletedChapter(
          fixture.title,
          completedChapters: 4,
        ),
        true,
      );
      expect(fixture.backend.updates, [4]);
      expect(fixture.store.state.pending, isEmpty);
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 2,
      );
      expect(
        fixture.backend.updates,
        [4],
        reason: 'Existing higher progress is never deliberately reduced',
      );
    },
  );

  test(
    'offline completion survives restart and retries without credentials in state',
    () async {
      final first = fixture.create();
      await fixture.link(first);
      fixture.backend.error = Exception(
        'Authorization: private-access-capability',
      );
      expect(
        await first.syncCompletedChapter(fixture.title, completedChapters: 9),
        false,
      );
      final row = fixture.store.state.pending.single;
      expect(row.attempts, 1);
      expect(row.nextAttemptAt, fixture.now.add(const Duration(seconds: 5)));
      expect(
        jsonEncode(row.toJson()),
        isNot(contains('private-access-capability')),
      );
      first.dispose();
      fixture.backend.error = null;
      final second = fixture.create();
      await second.retryPending();
      expect(fixture.backend.updates, isEmpty);
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await second.retryPending();
      expect(fixture.backend.updates, [9]);
      expect(fixture.store.state.pending, isEmpty);
    },
  );

  test(
    'attempt is durable before mutation; ambiguous process death retry is idempotent',
    () async {
      final first = fixture.create();
      await fixture.link(first);
      fixture.backend.onUpdate = () async {
        expect(fixture.store.state.pending.single.attempts, 1);
        // Server accepted but the response never reached the old process.
        fixture.backend.progress = 12;
        throw Exception('connection lost after server accepted');
      };
      expect(
        await first.syncCompletedChapter(fixture.title, completedChapters: 12),
        false,
      );
      first.dispose();
      fixture.backend.onUpdate = null;
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await fixture.create().retryPending();
      expect(fixture.backend.progress, 12);
      expect(
        fixture.backend.updates,
        isEmpty,
        reason: 'Read-before-write recovers accepted remote state',
      );
      expect(fixture.store.state.pending, isEmpty);
    },
  );

  test(
    'higher completions coalesce without resetting persisted attempts/backoff',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.error = Exception('offline');
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 2,
      );
      final calls = fixture.backend.calls;
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 8,
      );
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 3,
      );
      final row = fixture.store.state.pending.single;
      expect(row.completedChapters, 8);
      expect(row.attempts, 1);
      expect(fixture.backend.calls, calls);
      fixture.backend.error = null;
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await controller.retryPending();
      expect(fixture.backend.updates, [8]);
    },
  );

  test(
    'max attempts and backoff survive recreation; manual action resets budget',
    () async {
      var controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.error = Exception('offline');
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 5,
      );
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      controller.dispose();
      controller = fixture.create();
      await controller.retryPending();
      expect(fixture.store.state.pending.single.attempts, 2);
      fixture.now = fixture.now.add(const Duration(seconds: 30));
      await controller.retryPending();
      expect(fixture.store.state.pending.single.attempts, 3);
      expect(fixture.store.state.pending.single.needsAttention, true);
      final calls = fixture.backend.calls;
      fixture.now = fixture.now.add(const Duration(days: 1));
      await controller.retryPending();
      expect(fixture.backend.calls, calls);
      fixture.backend.error = null;
      await controller.retryPending(manual: true);
      expect(fixture.backend.updates, [5]);
      expect(fixture.store.state.pending, isEmpty);
    },
  );

  test('manual retry never bypasses provider Retry-After', () async {
    final controller = fixture.create();
    await fixture.link(controller);
    fixture.backend.error = const MangaTrackingException(
      'Rate limited',
      retryable: true,
      retryAfter: Duration(minutes: 3),
    );
    await controller.syncCompletedChapter(fixture.title, completedChapters: 5);
    final calls = fixture.backend.calls;
    fixture.backend.error = null;
    await controller.retryPending(manual: true);
    expect(fixture.backend.calls, calls);
    fixture.now = fixture.now.add(const Duration(minutes: 3));
    await controller.retryPending();
    expect(fixture.backend.updates, [5]);
  });

  test(
    'other owner or inactive tracker profile cannot flush a durable binding',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.profile = 'profile-2';
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 3,
      );
      final calls = fixture.backend.calls;
      fixture.owner = 'owner-2';
      fixture.profile = 'profile-1';
      await controller.retryPending(manual: true);
      expect(fixture.backend.calls, calls);
      await expectLater(
        controller.currentLinks(fixture.title),
        throwsA(isA<MangaTrackingException>()),
      );
      fixture.owner = 'owner-1';
      await controller.retryPending();
      expect(fixture.backend.updates, [3]);
    },
  );

  test(
    'same local profile with a different remote account requires reconnection',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.account = '88';
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 3,
      );
      expect(fixture.backend.updates, isEmpty);
      expect(fixture.store.state.pending.single.needsAttention, true);
      expect(
        fixture.store.state.pending.single.lastError,
        contains('originally linked'),
      );
    },
  );

  test('token/profile switch during remote read prevents mutation', () async {
    final controller = fixture.create();
    await fixture.link(controller);
    fixture.backend.onProgress = () async {
      fixture.token = 'other-account-token';
    };
    await controller.syncCompletedChapter(fixture.title, completedChapters: 3);
    expect(fixture.backend.updates, isEmpty);
    expect(fixture.store.state.pending.single.needsAttention, true);
  });

  test(
    'unlink during remote read invalidates in-flight generation and queued update',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.onProgress = () =>
          controller.unlink(fixture.title, TrackingProvider.anilist);
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 3,
      );
      expect(fixture.backend.updates, isEmpty);
      expect(fixture.store.state.pending, isEmpty);
      expect(fixture.store.state.links, isEmpty);
    },
  );

  test(
    'relink invalidates old failed outbox without deleting remote entries',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.error = Exception('offline');
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 7,
      );
      final binding = fixture.store.state.links.single.bindingId;
      fixture.backend.error = null;
      await fixture.link(controller);
      expect(fixture.store.state.links.single.bindingId, isNot(binding));
      expect(fixture.store.state.pending, isEmpty);
      expect(fixture.backend.updates, isEmpty);
    },
  );

  test('known total blocks chapter mapping above the matched record', () async {
    final controller = fixture.create();
    await fixture.link(controller);
    await controller.syncCompletedChapter(
      fixture.title,
      completedChapters: 101,
    );
    expect(fixture.backend.updates, isEmpty);
    expect(fixture.store.state.pending.single.needsAttention, true);
  });

  test(
    'AniList and MAL bindings coexist, and unlink affects only selected provider',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      await fixture.link(controller, provider: TrackingProvider.myAnimeList);
      expect(await controller.currentLinks(fixture.title), hasLength(2));
      await controller.unlink(fixture.title, TrackingProvider.anilist);
      expect(
        (await controller.currentLinks(fixture.title)).single.provider,
        TrackingProvider.myAnimeList,
      );
    },
  );

  test(
    'failed durable enqueue sends nothing; token refresh errors are sanitized',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.store.failWrites = true;
      await expectLater(
        controller.syncCompletedChapter(fixture.title, completedChapters: 3),
        throwsStateError,
      );
      expect(fixture.backend.updates, isEmpty);
      fixture.tokenError = Exception(
        'Authorization: private-access-capability',
      );
      await expectLater(
        controller.searchCatalog(TrackingProvider.anilist, 'Chosen'),
        throwsA(
          isA<MangaTrackingException>().having(
            (e) => e.message,
            'safe',
            isNot(contains('private-access-capability')),
          ),
        ),
      );
    },
  );

  test(
    'outbox retains a concurrent higher completion when the first send finishes',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.backend.onProgress = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final first = controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 2,
      );
      await entered.future;
      final second = controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 8,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.store.state.pending.single.completedChapters, 8);
      release.complete();
      await Future.wait([first, second]);
      expect(fixture.store.state.pending.single.completedChapters, 8);
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await controller.retryPending();
      expect(fixture.backend.updates, [2, 8]);
    },
  );

  test(
    'Manga opt-out blocks tracker network work and preserves the outbox',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      fixture.backend.error = Exception('offline');
      await controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 6,
      );
      final preserved = jsonEncode(fixture.store.state.pending.single.toJson());
      fixture.backend.error = null;
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      controller.setFeatureAvailable(false);
      final calls = fixture.backend.calls;

      await controller.retryPending();
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.backend.calls, calls);
      expect(
        jsonEncode(fixture.store.state.pending.single.toJson()),
        preserved,
      );
      await expectLater(
        controller.retryPending(manual: true),
        throwsA(isA<MangaTrackingException>()),
      );
      await expectLater(
        controller.searchCatalog(TrackingProvider.anilist, 'Chosen'),
        throwsA(isA<MangaTrackingException>()),
      );
      await expectLater(
        controller.linkManga(
          fixture.title,
          fixture.backend.record(TrackingProvider.anilist),
          confirmed: true,
        ),
        throwsA(isA<MangaTrackingException>()),
      );
      await expectLater(
        controller.syncCompletedChapter(fixture.title, completedChapters: 7),
        throwsA(isA<MangaTrackingException>()),
      );
      expect(fixture.backend.calls, calls);

      controller.setFeatureAvailable(true);
      await controller.retryPending();
      expect(fixture.backend.updates, [6]);
      expect(fixture.store.state.pending, isEmpty);
    },
  );

  test(
    'Manga opt-out invalidates an in-flight retry without spending its budget',
    () async {
      final controller = fixture.create();
      await fixture.link(controller);
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.backend.onProgress = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final sync = controller.syncCompletedChapter(
        fixture.title,
        completedChapters: 8,
      );
      await entered.future;

      controller.setFeatureAvailable(false);
      release.complete();
      await expectLater(sync, throwsA(isA<MangaTrackingException>()));
      expect(fixture.backend.updates, isEmpty);
      expect(fixture.store.state.pending.single.completedChapters, 8);
      expect(fixture.store.state.pending.single.attempts, 0);

      fixture.backend.onProgress = null;
      controller.setFeatureAvailable(true);
      await controller.retryPending();
      expect(fixture.backend.updates, [8]);
      expect(fixture.store.state.pending, isEmpty);
    },
  );

  test(
    'secure state round-trip is bounded and preserves corrupt data',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      const secure = SecureMangaTrackingStateStore(storage);
      final controller = fixture.create();
      await fixture.link(controller);
      await secure.write(fixture.store.state);
      expect((await secure.read()).links.single.accountId, '77');
      final encoded = await storage.read(key: mangaTrackingStateStorageKey);
      expect(encoded, isNot(contains('private-access-capability')));
      final invalid = jsonEncode({
        'version': 1,
        'links': [],
        'pending': [
          MangaTrackingPending(
            bindingId: 'missing-link',
            completedChapters: 4,
            nextAttemptAt: fixture.now,
          ).toJson(),
        ],
      });
      await storage.write(key: mangaTrackingStateStorageKey, value: invalid);
      await expectLater(secure.read(), throwsA(isA<MangaTrackingException>()));
      expect(await storage.read(key: mangaTrackingStateStorageKey), invalid);
      await expectLater(
        secure.write(
          MangaTrackingSnapshot(
            links: List.filled(501, fixture.store.state.links.single),
          ),
        ),
        throwsA(isA<MangaTrackingException>()),
      );
    },
  );
}
