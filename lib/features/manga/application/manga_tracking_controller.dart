import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/application/manga_feature_availability.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_tracking_client.dart';
import 'package:anime_tv/features/manga/data/manga_tracking_state_store.dart';
import 'package:anime_tv/features/manga/domain/manga_tracking_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'package:anime_tv/features/manga/domain/manga_tracking_models.dart';

final mangaTrackingControllerProvider = Provider<MangaTrackingController>((
  ref,
) {
  final tokens = ref.watch(trackingTokenServiceProvider);
  final featureAvailable = ref.read(mangaFeatureAvailableProvider);
  final lanes = {
    for (final provider in [
      TrackingProvider.anilist,
      TrackingProvider.myAnimeList,
    ])
      provider: MangaTrackingRequestLane(),
  };
  final controller = MangaTrackingController(
    store: SecureMangaTrackingStateStore(ref.watch(secureStorageProvider)),
    ownerKey: () => ref.read(mangaOwnerKeyProvider.future),
    tokenLookup: tokens.accessToken,
    profileLookup: tokens.activeProfileId,
    clientFactory: (provider, token) => OfficialMangaTrackingClient(
      provider: provider,
      accessToken: token,
      lane: lanes[provider],
    ),
    featureAvailable: featureAvailable,
    observeLifecycle: true,
  );
  ref.listen<bool>(
    mangaFeatureAvailableProvider,
    (_, next) => controller.setFeatureAvailable(next),
  );
  ref.onDispose(controller.dispose);
  if (featureAvailable) {
    unawaited(
      controller.retryPending().catchError((_) {
        // A storage failure stays local; initialization never erases the outbox.
      }),
    );
  }
  return controller;
});

typedef MangaTrackingOwnerLookup = Future<String> Function();
typedef MangaTrackingTokenLookup =
    Future<String?> Function(TrackingProvider provider);
typedef MangaTrackingProfileLookup =
    Future<String?> Function(TrackingProvider provider);
typedef MangaTrackingTimerFactory =
    Timer Function(Duration delay, void Function() callback);

// Named injectable collaborators are part of the public test/UI contract.
// ignore_for_file: prefer_initializing_formals

class MangaTrackingController with WidgetsBindingObserver {
  MangaTrackingController({
    required MangaTrackingStateStore store,
    required MangaTrackingOwnerLookup ownerKey,
    required MangaTrackingTokenLookup tokenLookup,
    required MangaTrackingProfileLookup profileLookup,
    required MangaTrackingClientFactory clientFactory,
    DateTime Function()? now,
    String Function()? bindingId,
    MangaTrackingTimerFactory? timerFactory,
    bool featureAvailable = true,
    this.automaticRetries = true,
    this.observeLifecycle = false,
    this.maximumAttempts = 5,
    List<Duration> retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(hours: 1),
    ],
  }) : _featureAvailable = featureAvailable,
       _store = store,
       _ownerKey = ownerKey,
       _tokenLookup = tokenLookup,
       _profileLookup = profileLookup,
       _clientFactory = clientFactory,
       _now = now ?? DateTime.now,
       _bindingId = bindingId ?? _newBindingId,
       _timerFactory = timerFactory ?? Timer.new,
       _retryDelays = List.unmodifiable(retryDelays) {
    if (maximumAttempts < 1 ||
        maximumAttempts > 20 ||
        retryDelays.isEmpty ||
        retryDelays.any((delay) => delay <= Duration.zero)) {
      throw ArgumentError('Invalid manga tracking retry limits.');
    }
    if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
  }

  final MangaTrackingStateStore _store;
  final MangaTrackingOwnerLookup _ownerKey;
  final MangaTrackingTokenLookup _tokenLookup;
  final MangaTrackingProfileLookup _profileLookup;
  final MangaTrackingClientFactory _clientFactory;
  final DateTime Function() _now;
  final String Function() _bindingId;
  final MangaTrackingTimerFactory _timerFactory;
  final List<Duration> _retryDelays;
  final bool automaticRetries;
  final bool observeLifecycle;
  final int maximumAttempts;
  bool _featureAvailable;
  Future<void> _stateTail = Future<void>.value();
  Future<void> _flushTail = Future<void>.value();
  Timer? _timer;
  final Set<MangaTrackingClient> _activeClients = <MangaTrackingClient>{};
  int _featureGeneration = 0;
  bool _disposed = false;

  /// Suspends all Manga tracker network work without erasing links or outbox
  /// rows. Re-enabling retries any due durable work through the normal lane.
  void setFeatureAvailable(bool available) {
    if (_disposed || _featureAvailable == available) return;
    _featureAvailable = available;
    _featureGeneration++;
    _timer?.cancel();
    _timer = null;
    if (!available) {
      for (final client in _activeClients.toList(growable: false)) {
        client.close();
      }
      _activeClients.clear();
      return;
    }
    if (automaticRetries) unawaited(retryPending().catchError((_) {}));
  }

  Future<List<MangaTrackingSearchResult>> searchCatalog(
    TrackingProvider provider,
    String query,
  ) async {
    final access = _requireFeature();
    final owner = await _ownerKey();
    _requireFeature(access);
    final session = await _session(provider);
    try {
      final records = await session.client.search(query);
      _requireFeature(access);
      await _requireSession(session, owner);
      return records;
    } on MangaTrackingException {
      rethrow;
    } catch (_) {
      throw _temporaryTrackingFailure;
    } finally {
      _closeSession(session);
    }
  }

  Future<MangaTrackingLink> linkManga(
    MangaTrackingTitleKey title,
    MangaTrackingSearchResult selection, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw const MangaTrackingException(
        'Choose and confirm the matching manga before enabling tracking.',
      );
    }
    final access = _requireFeature();
    await _requireOwner(title.ownerKey);
    _requireFeature(access);
    final session = await _session(selection.provider);
    try {
      final record = await session.client.details(selection.mediaId);
      _requireFeature(access);
      if (record.provider != selection.provider ||
          record.mediaId != selection.mediaId) {
        throw const MangaTrackingException(
          'The tracker returned a different manga. Choose the match again.',
        );
      }
      final account = await session.client.accountId();
      _requireFeature(access);
      await _requireSession(session, title.ownerKey);
      final link = MangaTrackingLink(
        titleKey: title,
        record: record,
        profileId: session.profileId,
        accountId: account,
        bindingId: _bindingId(),
        linkedAt: _now().toUtc(),
      );
      await _withState(() async {
        await _requireOwner(title.ownerKey);
        final current = await _store.read();
        final replaced = current.links
            .where(
              (item) =>
                  item.titleKey.matches(title) &&
                  item.provider == selection.provider,
            )
            .map((item) => item.bindingId)
            .toSet();
        // The state lane/storage read may have yielded during account switching.
        // Revalidate the token-bound session immediately before committing.
        _requireFeature(access);
        await _requireSession(session, title.ownerKey);
        await _store.write(
          MangaTrackingSnapshot(
            links: [
              ...current.links.where(
                (item) => !replaced.contains(item.bindingId),
              ),
              link,
            ],
            pending: current.pending.where(
              (item) => !replaced.contains(item.bindingId),
            ),
          ),
        );
      });
      return link;
    } on MangaTrackingException {
      rethrow;
    } catch (_) {
      throw _temporaryTrackingFailure;
    } finally {
      _closeSession(session);
    }
  }

  Future<List<MangaTrackingLink>> currentLinks(
    MangaTrackingTitleKey title,
  ) async {
    await _requireOwner(title.ownerKey);
    return _withState(() async {
      final state = await _store.read();
      await _requireOwner(title.ownerKey);
      return state.links
          .where((link) => link.titleKey.matches(title))
          .toList(growable: false);
    });
  }

  Future<List<MangaTrackingPending>> pendingFor(
    MangaTrackingTitleKey title,
  ) async {
    await _requireOwner(title.ownerKey);
    return _withState(() async {
      final state = await _store.read();
      await _requireOwner(title.ownerKey);
      final ids = state.links
          .where((link) => link.titleKey.matches(title))
          .map((link) => link.bindingId)
          .toSet();
      return state.pending
          .where((row) => ids.contains(row.bindingId))
          .toList(growable: false);
    });
  }

  /// Disconnects only this local binding. It never deletes the provider's list entry.
  Future<void> unlink(
    MangaTrackingTitleKey title,
    TrackingProvider provider,
  ) async {
    await _requireOwner(title.ownerKey);
    await _withState(() async {
      final current = await _store.read();
      final removed = current.links
          .where(
            (link) => link.titleKey.matches(title) && link.provider == provider,
          )
          .map((link) => link.bindingId)
          .toSet();
      await _requireOwner(title.ownerKey);
      await _store.write(
        MangaTrackingSnapshot(
          links: current.links.where(
            (link) => !removed.contains(link.bindingId),
          ),
          pending: current.pending.where(
            (row) => !removed.contains(row.bindingId),
          ),
        ),
      );
    });
    await _scheduleNext();
  }

  Future<bool> syncCompletedChapter(
    MangaTrackingTitleKey title, {
    required int completedChapters,
    bool deferNetwork = false,
  }) async {
    mangaTrackingInt(completedChapters, 1, 100000);
    final access = _requireFeature();
    await _requireOwner(title.ownerKey);
    final bindings = await _withState(() async {
      _requireFeature(access);
      final current = await _store.read();
      _requireFeature(access);
      final links = current.links
          .where((link) => link.titleKey.matches(title))
          .toList();
      final next = {for (final item in current.pending) item.bindingId: item};
      for (final link in links) {
        final existing = next[link.bindingId];
        // Higher chapter progress replaces the target, not the durable retry
        // budget/backoff. Reading rapidly cannot reset rate-limit protection.
        if (existing == null ||
            completedChapters > existing.completedChapters) {
          next[link.bindingId] = MangaTrackingPending(
            bindingId: link.bindingId,
            completedChapters: completedChapters,
            attempts: existing?.attempts ?? 0,
            nextAttemptAt: existing?.nextAttemptAt ?? _now().toUtc(),
            serverRetryAt: existing?.serverRetryAt,
            lastError: existing?.lastError,
            needsAttention: existing?.needsAttention ?? false,
          );
        }
      }
      if (links.isNotEmpty) {
        await _requireOwner(title.ownerKey);
        _requireFeature(access);
        await _store.write(
          MangaTrackingSnapshot(links: current.links, pending: next.values),
        );
      }
      return links.map((link) => link.bindingId).toSet();
    });
    if (bindings.isEmpty) return false;
    if (deferNetwork) {
      // Reader transitions await the durable write above, never tracker HTTP.
      // Here true means safely queued, not confirmation of remote delivery.
      unawaited(retryPending().catchError((_) {}));
      return true;
    }
    await retryPending();
    _requireFeature(access);
    return _withState(
      () async => !(await _store.read()).pending.any(
        (row) =>
            bindings.contains(row.bindingId) &&
            row.completedChapters >= completedChapters,
      ),
    );
  }

  /// Automatic/lifecycle calls flush due rows for the active owner. A title UI
  /// supplies [title] and [provider] so its explicit retry cannot reset or send
  /// another title/account's pending work.
  Future<void> retryPending({
    bool manual = false,
    MangaTrackingTitleKey? title,
    TrackingProvider? provider,
  }) {
    final previous = _flushTail;
    final release = Completer<void>();
    _flushTail = release.future;
    return () async {
      await previous;
      try {
        if (_disposed) return;
        if (!_featureAvailable) {
          _timer?.cancel();
          _timer = null;
          if (manual) {
            throw const MangaTrackingException(
              'Enable Manga before syncing reading progress.',
            );
          }
          return;
        }
        final access = _featureGeneration;
        _timer?.cancel();
        _timer = null;
        final owner = await _ownerKey();
        _requireFeature(access);
        if (title != null) await _requireOwner(title.ownerKey);
        _requireFeature(access);
        if (manual) {
          await _resetManual(owner, title, provider);
          _requireFeature(access);
        }
        final snapshot = await _withState(_store.read);
        final links = {for (final link in snapshot.links) link.bindingId: link};
        for (final item in snapshot.pending) {
          if (!_featureAccessValid(access)) break;
          final link = links[item.bindingId];
          if (link == null ||
              link.titleKey.ownerKey != owner ||
              (title != null && !link.titleKey.matches(title)) ||
              (provider != null && link.provider != provider) ||
              item.needsAttention ||
              item.attempts >= maximumAttempts ||
              item.nextAttemptAt.isAfter(_now())) {
            continue;
          }
          if (await _profileLookup(link.provider) != link.profileId) continue;
          if (!_featureAccessValid(access)) break;
          if (await _ownerKey() != owner) break;
          if (!_featureAccessValid(access)) break;
          if (!await _stillLinked(link.bindingId)) continue;
          if (!_featureAccessValid(access)) break;
          final attempted = MangaTrackingPending(
            bindingId: item.bindingId,
            completedChapters: item.completedChapters,
            attempts: item.attempts + 1,
            nextAttemptAt: _now().toUtc().add(_retryDelay(item.attempts)),
            serverRetryAt: item.serverRetryAt,
          );
          await _replacePending(attempted);
          _MangaTrackingSession? session;
          try {
            session = await _session(link.provider);
            _requireFeature(access);
            if (session.profileId != link.profileId ||
                await session.client.accountId() != link.accountId) {
              throw const MangaTrackingException(
                'Select the tracking account originally linked to this manga.',
                requiresReconnect: true,
              );
            }
            _requireFeature(access);
            final existing = await session.client.currentProgress(
              link.record.mediaId,
            );
            _requireFeature(access);
            await _requireSession(session, owner);
            if (!await _stillLinked(link.bindingId)) continue;
            if (existing < item.completedChapters) {
              if (link.record.totalChapters case final total?
                  when item.completedChapters > total) {
                throw const MangaTrackingException(
                  'The chapter count exceeds the linked manga. Check the selected record.',
                );
              }
              await session.client.updateProgress(
                link.record.mediaId,
                item.completedChapters,
              );
              _requireFeature(access);
            }
            await _completePending(item.bindingId, item.completedChapters);
          } catch (error) {
            if (!_featureAccessValid(access)) {
              await _replacePending(item);
              break;
            }
            final safe = error is MangaTrackingException
                ? error
                : const MangaTrackingException(
                    'Manga tracking is temporarily unavailable. Progress is saved for retry.',
                    retryable: true,
                  );
            await _failPending(attempted, safe);
          } finally {
            if (session != null) _closeSession(session);
          }
        }
        if (_featureAccessValid(access)) await _scheduleNext();
      } finally {
        release.complete();
      }
    }();
  }

  Future<_MangaTrackingSession> _session(TrackingProvider provider) async {
    final access = _requireFeature();
    if (!supportsMangaTracking(provider)) {
      throw const MangaTrackingException(
        'Manga tracking supports AniList and MAL only.',
      );
    }
    try {
      final profile = await _profileLookup(provider);
      final token = await _tokenLookup(provider);
      if (profile == null ||
          profile.isEmpty ||
          token == null ||
          token.isEmpty ||
          await _profileLookup(provider) != profile) {
        throw const MangaTrackingException(
          'Reconnect the linked manga tracking account in Settings.',
          requiresReconnect: true,
        );
      }
      _requireFeature(access);
      final client = _clientFactory(provider, token);
      _activeClients.add(client);
      return _MangaTrackingSession(provider, profile, token, client);
    } on MangaTrackingException {
      rethrow;
    } catch (_) {
      // Refresh exceptions can contain HTTP diagnostics, never persist them.
      throw _temporaryTrackingFailure;
    }
  }

  Future<void> _requireOwner(String owner) async {
    if (_disposed || await _ownerKey() != owner) {
      throw const MangaTrackingException(
        'The active profile changed. Open manga tracking again.',
      );
    }
  }

  Future<void> _requireSession(
    _MangaTrackingSession session,
    String owner,
  ) async {
    await _requireOwner(owner);
    if (await _profileLookup(session.provider) != session.profileId ||
        await _tokenLookup(session.provider) != session.token ||
        await _profileLookup(session.provider) != session.profileId) {
      throw const MangaTrackingException(
        'The tracking account changed. Retry with the linked account.',
        requiresReconnect: true,
      );
    }
    await _requireOwner(owner);
  }

  Future<bool> _stillLinked(String id) => _withState(
    () async => (await _store.read()).links.any((link) => link.bindingId == id),
  );

  Future<void> _replacePending(MangaTrackingPending replacement) => _withState(
    () async {
      final state = await _store.read();
      if (!state.links.any((link) => link.bindingId == replacement.bindingId)) {
        return;
      }
      final current = state.pending
          .where((item) => item.bindingId == replacement.bindingId)
          .firstOrNull;
      if (current == null) return;
      await _store.write(
        MangaTrackingSnapshot(
          links: state.links,
          pending: [
            for (final item in state.pending)
              if (item.bindingId != replacement.bindingId)
                item
              else
                MangaTrackingPending(
                  bindingId: replacement.bindingId,
                  completedChapters: max(
                    current.completedChapters,
                    replacement.completedChapters,
                  ),
                  attempts: replacement.attempts,
                  nextAttemptAt: replacement.nextAttemptAt,
                  serverRetryAt: replacement.serverRetryAt,
                  lastError: replacement.lastError,
                  needsAttention: replacement.needsAttention,
                ),
          ],
        ),
      );
    },
  );

  Future<void> _completePending(String id, int completed) =>
      _withState(() async {
        final state = await _store.read();
        await _store.write(
          MangaTrackingSnapshot(
            links: state.links,
            pending: state.pending.where(
              (item) =>
                  item.bindingId != id || item.completedChapters > completed,
            ),
          ),
        );
      });

  Future<void> _failPending(
    MangaTrackingPending item,
    MangaTrackingException error,
  ) async {
    final serverRetry = error.retryAfter == null
        ? null
        : _now().toUtc().add(error.retryAfter!);
    final backoff = _now().toUtc().add(_retryDelay(item.attempts - 1));
    await _replacePending(
      MangaTrackingPending(
        bindingId: item.bindingId,
        completedChapters: item.completedChapters,
        attempts: item.attempts,
        nextAttemptAt: serverRetry != null && serverRetry.isAfter(backoff)
            ? serverRetry
            : backoff,
        serverRetryAt: serverRetry,
        lastError: error.message,
        needsAttention: !error.retryable || item.attempts >= maximumAttempts,
      ),
    );
  }

  Duration _retryDelay(int attempt) =>
      _retryDelays[attempt.clamp(0, _retryDelays.length - 1)];

  Future<void> _resetManual(
    String owner,
    MangaTrackingTitleKey? title,
    TrackingProvider? provider,
  ) => _withState(() async {
    final state = await _store.read();
    final ids = <String>{};
    for (final link in state.links) {
      if (link.titleKey.ownerKey == owner &&
          (title == null || link.titleKey.matches(title)) &&
          (provider == null || link.provider == provider) &&
          await _profileLookup(link.provider) == link.profileId) {
        ids.add(link.bindingId);
      }
    }
    final now = _now().toUtc();
    await _requireOwner(owner);
    await _store.write(
      MangaTrackingSnapshot(
        links: state.links,
        pending: [
          for (final item in state.pending)
            if (!ids.contains(item.bindingId))
              item
            else
              MangaTrackingPending(
                bindingId: item.bindingId,
                completedChapters: item.completedChapters,
                nextAttemptAt: item.serverRetryAt?.isAfter(now) == true
                    ? item.serverRetryAt!
                    : now,
                serverRetryAt: item.serverRetryAt,
              ),
        ],
      ),
    );
  });

  Future<void> _scheduleNext() async {
    if (_disposed || !_featureAvailable || !automaticRetries) return;
    final access = _featureGeneration;
    _timer?.cancel();
    final owner = await _ownerKey();
    if (!_featureAccessValid(access)) return;
    final state = await _withState(_store.read);
    if (!_featureAccessValid(access)) return;
    final links = {for (final link in state.links) link.bindingId: link};
    DateTime? next;
    for (final item in state.pending) {
      final link = links[item.bindingId];
      if (link == null ||
          link.titleKey.ownerKey != owner ||
          item.needsAttention ||
          item.attempts >= maximumAttempts ||
          await _profileLookup(link.provider) != link.profileId) {
        continue;
      }
      if (next == null || item.nextAttemptAt.isBefore(next)) {
        next = item.nextAttemptAt;
      }
    }
    if (next == null || !_featureAccessValid(access)) return;
    final delay = next.difference(_now());
    _timer = _timerFactory(
      delay < const Duration(seconds: 1) ? const Duration(seconds: 1) : delay,
      () {
        _timer = null;
        if (_featureAccessValid(access)) {
          unawaited(retryPending().catchError((_) {}));
        }
      },
    );
  }

  Future<T> _withState<T>(Future<T> Function() operation) {
    final previous = _stateTail;
    final release = Completer<void>();
    _stateTail = release.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_disposed && _featureAvailable) {
      unawaited(retryPending().catchError((_) {}));
    }
  }

  int _requireFeature([int? access]) {
    if (_disposed ||
        !_featureAvailable ||
        (access != null && access != _featureGeneration)) {
      throw const MangaTrackingException(
        'Enable Manga before using manga tracking.',
      );
    }
    return _featureGeneration;
  }

  bool _featureAccessValid(int access) =>
      !_disposed && _featureAvailable && access == _featureGeneration;

  void _closeSession(_MangaTrackingSession session) {
    if (_activeClients.remove(session.client)) session.client.close();
  }

  void dispose() {
    _disposed = true;
    _featureAvailable = false;
    _featureGeneration++;
    _timer?.cancel();
    for (final client in _activeClients.toList(growable: false)) {
      client.close();
    }
    _activeClients.clear();
    if (observeLifecycle) WidgetsBinding.instance.removeObserver(this);
  }
}

class _MangaTrackingSession {
  const _MangaTrackingSession(
    this.provider,
    this.profileId,
    this.token,
    this.client,
  );
  final TrackingProvider provider;
  final String profileId;
  final String token;
  final MangaTrackingClient client;
}

String _newBindingId() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(18, (_) => random.nextInt(256)));
}

const _temporaryTrackingFailure = MangaTrackingException(
  'Manga tracking is temporarily unavailable. Progress is saved for retry.',
  retryable: true,
);
