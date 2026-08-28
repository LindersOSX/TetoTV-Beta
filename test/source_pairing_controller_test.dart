import 'dart:async';
import 'dart:collection';

import 'package:anime_tv/features/marketplace/application/source_pairing_controller.dart';
import 'package:anime_tv/features/marketplace/data/source_pairing_client.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';

void main() {
  test(
    'bulk import batches repository refresh and reports a URL-safe partial result',
    () async {
      final repositoryRefreshFlags = <bool>[];
      final validatedHosts = <String>[];
      var refreshCalls = 0;
      var manifestCalls = 0;
      const repositoryOne = 'https://repo-one.example/marketplace.json';
      const repositoryTwo = 'https://repo-two.example/catalog.json';
      const acceptedManifest =
          'https://addons.example/manifest.json?key=accepted-secret';
      const rejectedManifest =
          'https://broken.example/manifest.json?key=rejected-secret';

      final summary = await importPairedSourcesWithOperations(
        const SourcePairingPayload(
          repositoryUrls: [repositoryOne, repositoryTwo],
          manifestUrls: [acceptedManifest, rejectedManifest],
        ),
        repositoryTargetValidator: (uri) async {
          validatedHosts.add(uri.host);
        },
        addRepository: (url, {refreshAfterAdd = true}) async {
          repositoryRefreshFlags.add(refreshAfterAdd);
          return null;
        },
        refreshRepositories: () async {
          refreshCalls++;
        },
        addManifest: (url) async {
          manifestCalls++;
          return url == rejectedManifest ? 'manifest was rejected' : null;
        },
      );

      expect(validatedHosts, ['repo-one.example', 'repo-two.example']);
      expect(repositoryRefreshFlags, [false, false]);
      expect(refreshCalls, 1);
      expect(manifestCalls, 2);
      expect(summary.repositoriesAdded, 2);
      expect(summary.manifestsAdded, 1);
      expect(summary.errors, ['Torrent manifest 2: manifest was rejected']);
      expect(
        summary.message,
        contains('Added 2 repositories and 1 torrent manifest.'),
      );
      expect(summary.message, contains('1 item was rejected.'));
      expect(manifestCalls, 2);
      for (final error in summary.errors) {
        expect(error, isNot(contains(repositoryOne)));
        expect(error, isNot(contains(repositoryTwo)));
        expect(error, isNot(contains(acceptedManifest)));
        expect(error, isNot(contains(rejectedManifest)));
        expect(error, isNot(contains('secret')));
      }
    },
  );

  test('persists both source types before a slow catalog refresh', () async {
    FlutterSecureStorage.setMockInitialValues({});
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
    const storage = FlutterSecureStorage();
    final torrentSources = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );
    final savedRepositories = <String>[];
    final refreshNeverFinishes = Completer<void>();

    final summary = await importPairedSourcesWithOperations(
      const SourcePairingPayload(
        repositoryUrls: ['https://repo.example/marketplace.json'],
        manifestUrls: ['https://addon.example/manifest.json'],
      ),
      repositoryTargetValidator: (_) async {},
      addRepository: (url, {refreshAfterAdd = true}) async {
        savedRepositories.add(url);
        return null;
      },
      refreshRepositories: () => refreshNeverFinishes.future,
      addManifest: torrentSources.add,
    );

    expect(summary.repositoriesAdded, 1);
    expect(summary.manifestsAdded, 1);
    expect(savedRepositories, ['https://repo.example/marketplace.json']);
    final restarted = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );
    await restarted.load();
    expect(restarted.state.manifestUrls, [
      'https://addon.example/manifest.json',
    ]);
  });

  test(
    'treats already-persisted URLs as saved during safe redelivery',
    () async {
      final summary = await importPairedSourcesWithOperations(
        const SourcePairingPayload(
          repositoryUrls: ['https://repo.example/marketplace.json'],
          manifestUrls: ['https://addon.example/manifest.json'],
        ),
        repositoryTargetValidator: (_) async {},
        addRepository: (url, {refreshAfterAdd = true}) async =>
            'That repository is already added.',
        refreshRepositories: () async {},
        addManifest: (_) async => 'That torrent source is already added.',
      );

      expect(summary.repositoriesAdded, 1);
      expect(summary.manifestsAdded, 1);
      expect(summary.errors, isEmpty);
    },
  );

  group('SourcePairingController', () {
    test('completes with a partial-import summary', () async {
      final api = _FakeSourcePairingApi(
        session: _session('partial'),
        polls: [
          () async => const SourcePairingPollResult(
            status: SourcePairingPollStatus.submitted,
            payload: SourcePairingPayload(
              repositoryUrls: ['https://example.com/marketplace.json'],
              manifestUrls: ['https://example.com/manifest.json'],
            ),
          ),
        ],
      );
      final controller = SourcePairingController(
        () async => 'https://pair.example',
        (_) => api,
        (_) async => const SourceImportSummary(
          repositoriesAdded: 1,
          errors: ['Torrent manifest 1: invalid manifest.'],
        ),
      );
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.state.stage, SourcePairingStage.waiting);

      await controller.pollNow();

      expect(controller.state.stage, SourcePairingStage.completed);
      expect(controller.state.summary?.repositoriesAdded, 1);
      expect(controller.state.summary?.manifestsAdded, 0);
      expect(controller.state.summary?.errors, hasLength(1));
      expect(controller.state.message, contains('Added 1 repository.'));
      expect(controller.state.message, contains('1 item was rejected.'));
      expect(api.acknowledgeCalls, 1);
    });

    test(
      'retries a transient acknowledgement without importing twice',
      () async {
        var importCalls = 0;
        final api = _FakeSourcePairingApi(
          session: _session('ack-retry'),
          polls: [
            () async => const SourcePairingPollResult(
              status: SourcePairingPollStatus.submitted,
              payload: SourcePairingPayload(
                manifestUrls: ['https://example.com/manifest.json'],
              ),
            ),
          ],
          acknowledgementFailures: 2,
        );
        final controller = SourcePairingController(
          () async => 'https://pair.example',
          (_) => api,
          (_) async {
            importCalls++;
            return const SourceImportSummary(manifestsAdded: 1);
          },
          retryDelay: (_) async {},
        );
        addTearDown(controller.dispose);

        await controller.start();
        await controller.pollNow();

        expect(controller.state.stage, SourcePairingStage.completed);
        expect(importCalls, 1);
        expect(api.acknowledgeCalls, 3);
      },
    );

    test('can retry the phone confirmation after local persistence', () async {
      var importCalls = 0;
      final api = _FakeSourcePairingApi(
        session: _session('ack-manual-retry'),
        polls: [
          () async => const SourcePairingPollResult(
            status: SourcePairingPollStatus.submitted,
            payload: SourcePairingPayload(
              manifestUrls: ['https://example.com/manifest.json'],
            ),
          ),
        ],
        acknowledgementFailures: 3,
      );
      final controller = SourcePairingController(
        () async => 'https://pair.example',
        (_) => api,
        (_) async {
          importCalls++;
          return const SourceImportSummary(manifestsAdded: 1);
        },
        retryDelay: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.pollNow();

      expect(controller.state.stage, SourcePairingStage.completed);
      expect(controller.state.canRetryAcknowledgement, isTrue);
      expect(controller.state.message, contains('Saved locally'));
      expect(importCalls, 1);
      expect(api.acknowledgeCalls, 3);

      await controller.retryAcknowledgement();

      expect(controller.state.stage, SourcePairingStage.completed);
      expect(controller.state.canRetryAcknowledgement, isFalse);
      expect(controller.state.message, 'Added 1 torrent manifest.');
      expect(importCalls, 1);
      expect(api.acknowledgeCalls, 4);
    });

    test('an import failure can retry without re-entering URLs', () async {
      var importCalls = 0;
      final api = _FakeSourcePairingApi(
        session: _session('import-retry'),
        polls: [
          () async => const SourcePairingPollResult(
            status: SourcePairingPollStatus.submitted,
            payload: SourcePairingPayload(
              repositoryUrls: ['https://example.com/marketplace.json'],
            ),
          ),
        ],
      );
      final controller = SourcePairingController(
        () async => 'https://pair.example',
        (_) => api,
        (_) async {
          importCalls++;
          if (importCalls == 1) throw StateError('private URL detail');
          return const SourceImportSummary(repositoriesAdded: 1);
        },
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.pollNow();
      expect(controller.state.stage, SourcePairingStage.failed);
      expect(controller.state.canRetryImport, isTrue);
      expect(controller.state.message, isNot(contains('private URL detail')));

      await controller.retryImport();
      expect(controller.state.stage, SourcePairingStage.completed);
      expect(importCalls, 2);
      expect(api.acknowledgeCalls, 1);
    });

    test(
      'broker readiness errors omit StateError implementation jargon',
      () async {
        final api = _FakeSourcePairingApi(
          session: _session('not-created'),
          polls: const [],
          readyError: StateError(
            'The TetoTV pairing service must be updated before sources can be saved with confirmation.',
          ),
        );
        final controller = SourcePairingController(
          () async => 'https://pair.example',
          (_) => api,
          (_) async => const SourceImportSummary(),
        );
        addTearDown(controller.dispose);

        await controller.start();

        expect(controller.state.stage, SourcePairingStage.failed);
        expect(controller.state.message, isNot(startsWith('Bad state:')));
        expect(
          controller.state.message,
          startsWith('The TetoTV pairing service'),
        );
      },
    );

    test(
      'a stalled health check leaves the spinner with a safe failure',
      () async {
        final healthNeverFinishes = Completer<void>();
        final diagnostics = <Map<String, Object?>>[];
        final api = _FakeSourcePairingApi(
          session: _session('health-timeout'),
          polls: const [],
          readyFuture: healthNeverFinishes.future,
        );
        final controller = SourcePairingController(
          () async => 'https://pair.example/private?token=hidden',
          (_) => api,
          (_) async => const SourceImportSummary(),
          healthTimeout: const Duration(milliseconds: 5),
          diagnosticRecorder: (details) async => diagnostics.add(details),
        );
        addTearDown(controller.dispose);

        await controller.start();

        expect(controller.state.stage, SourcePairingStage.failed);
        expect(controller.state.message, contains('took too long'));
        expect(api.createCalls, 0);
        expect(
          diagnostics.any(
            (details) =>
                details['stage'] == 'health' &&
                details['status'] == 'timeout' &&
                details['reason_code'] == 'timeout',
          ),
          isTrue,
        );
        expect(diagnostics.toString(), isNot(contains('pair.example')));
        expect(diagnostics.toString(), isNot(contains('hidden')));
      },
    );

    test(
      'a stalled session request can be retried with a fresh client',
      () async {
        final creationNeverFinishes = Completer<SourcePairingSession>();
        final stalled = _FakeSourcePairingApi(
          session: _session('stalled'),
          polls: const [],
          createFuture: creationNeverFinishes.future,
        );
        final working = _FakeSourcePairingApi(
          session: _session('working'),
          polls: const [],
        );
        final clients = Queue<SourcePairingApi>.of([stalled, working]);
        final controller = SourcePairingController(
          () async => 'https://pair.example',
          (_) => clients.removeFirst(),
          (_) async => const SourceImportSummary(),
          sessionCreationTimeout: const Duration(milliseconds: 5),
        );
        addTearDown(controller.dispose);

        await controller.start();
        expect(controller.state.stage, SourcePairingStage.failed);
        expect(controller.state.message, contains('took too long'));

        await controller.start();
        expect(controller.state.stage, SourcePairingStage.waiting);
        expect(controller.state.session?.pairingId, 'working');

        creationNeverFinishes.complete(_session('late-stale'));
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.session?.pairingId, 'working');
      },
    );

    test(
      'an importer exception becomes an immediate terminal failure',
      () async {
        final api = _FakeSourcePairingApi(
          session: _session('import-error'),
          polls: [
            () async => const SourcePairingPollResult(
              status: SourcePairingPollStatus.submitted,
              payload: SourcePairingPayload(
                repositoryUrls: ['https://example.com/marketplace.json'],
              ),
            ),
          ],
        );
        final controller = SourcePairingController(
          () async => 'https://pair.example',
          (_) => api,
          (_) async => throw StateError('sensitive source URL'),
        );
        addTearDown(controller.dispose);

        await controller.start();
        await controller.pollNow();

        expect(controller.state.stage, SourcePairingStage.failed);
        expect(controller.state.session?.pairingId, 'import-error');
        expect(controller.state.message, contains('could not be saved safely'));
        expect(
          controller.state.message,
          isNot(contains('sensitive source URL')),
        );
      },
    );

    test(
      'a restart can poll the new session while the old poll is pending',
      () async {
        final oldPoll = Completer<SourcePairingPollResult>();
        final oldApi = _FakeSourcePairingApi(
          session: _session('old'),
          polls: [() => oldPoll.future],
        );
        final newApi = _FakeSourcePairingApi(
          session: _session('new'),
          polls: [
            () async => const SourcePairingPollResult(
              status: SourcePairingPollStatus.submitted,
              payload: SourcePairingPayload(
                manifestUrls: ['https://example.com/manifest.json'],
              ),
            ),
          ],
        );
        final clients = Queue<SourcePairingApi>.of([oldApi, newApi]);
        final controller = SourcePairingController(
          () async => 'https://pair.example',
          (_) => clients.removeFirst(),
          (_) async => const SourceImportSummary(manifestsAdded: 1),
        );
        addTearDown(controller.dispose);

        await controller.start();
        final stalePoll = controller.pollNow();
        await Future<void>.delayed(Duration.zero);

        await controller.start();
        expect(controller.state.session?.pairingId, 'new');
        await controller.pollNow();
        expect(controller.state.stage, SourcePairingStage.completed);
        expect(controller.state.session?.pairingId, 'new');

        oldPoll.complete(
          const SourcePairingPollResult(
            status: SourcePairingPollStatus.expired,
          ),
        );
        await stalePoll;

        expect(controller.state.stage, SourcePairingStage.completed);
        expect(controller.state.session?.pairingId, 'new');
        expect(oldApi.cancelCalls, 1);
      },
    );

    test('stop cancels the session and ignores a late poll result', () async {
      final latePoll = Completer<SourcePairingPollResult>();
      final api = _FakeSourcePairingApi(
        session: _session('stopped'),
        polls: [() => latePoll.future],
      );
      final controller = SourcePairingController(
        () async => 'https://pair.example',
        (_) => api,
        (_) async => const SourceImportSummary(manifestsAdded: 1),
      );
      addTearDown(controller.dispose);

      await controller.start();
      final pending = controller.pollNow();
      await Future<void>.delayed(Duration.zero);
      controller.stop();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.stage, SourcePairingStage.stopped);
      expect(api.cancelCalls, 1);

      latePoll.complete(
        const SourcePairingPollResult(
          status: SourcePairingPollStatus.submitted,
          payload: SourcePairingPayload(
            manifestUrls: ['https://example.com/manifest.json'],
          ),
        ),
      );
      await pending;

      expect(controller.state.stage, SourcePairingStage.stopped);
    });

    test(
      'dispose cancels the session and safely ignores a late poll',
      () async {
        final latePoll = Completer<SourcePairingPollResult>();
        final api = _FakeSourcePairingApi(
          session: _session('disposed'),
          polls: [() => latePoll.future],
        );
        final controller = SourcePairingController(
          () async => 'https://pair.example',
          (_) => api,
          (_) async => const SourceImportSummary(manifestsAdded: 1),
        );

        await controller.start();
        final pending = controller.pollNow();
        await Future<void>.delayed(Duration.zero);
        controller.dispose();
        await Future<void>.delayed(Duration.zero);

        expect(api.cancelCalls, 1);
        latePoll.complete(
          const SourcePairingPollResult(
            status: SourcePairingPollStatus.pending,
          ),
        );
        await pending;
      },
    );
  });
}

SourcePairingSession _session(String id) => SourcePairingSession(
  pairingId: id,
  deviceCode: 'd' * 48,
  userCode: 'ABCD-EFGH',
  verificationUri: Uri.parse('https://pair.example/source-pair'),
  verificationUriComplete: Uri.parse(
    'https://pair.example/source-pair?code=ABCD-EFGH',
  ),
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  pollInterval: const Duration(hours: 1),
);

class _FakeSourcePairingApi implements SourcePairingApi {
  _FakeSourcePairingApi({
    required this.session,
    required List<_Poll> polls,
    this.acknowledgementFailures = 0,
    this.readyError,
    this.readyFuture,
    this.createFuture,
  }) : _polls = Queue<_Poll>.of(polls);

  final SourcePairingSession session;
  final Queue<_Poll> _polls;
  int cancelCalls = 0;
  int acknowledgeCalls = 0;
  final int acknowledgementFailures;
  final Object? readyError;
  final Future<void>? readyFuture;
  final Future<SourcePairingSession>? createFuture;
  int createCalls = 0;

  @override
  Future<void> ensureReady() async {
    final error = readyError;
    if (error != null) throw error;
    await (readyFuture ?? Future<void>.value());
  }

  @override
  Future<SourcePairingSession> createSession() {
    createCalls++;
    return createFuture ?? Future.value(session);
  }

  @override
  Future<SourcePairingPollResult> poll(SourcePairingSession session) {
    if (_polls.isEmpty) {
      return Future.value(
        const SourcePairingPollResult(status: SourcePairingPollStatus.pending),
      );
    }
    return _polls.removeFirst()();
  }

  @override
  Future<void> acknowledge(
    SourcePairingSession session,
    SourceImportSummary summary,
  ) async {
    acknowledgeCalls++;
    if (acknowledgeCalls <= acknowledgementFailures) {
      throw StateError('temporary acknowledgement failure');
    }
  }

  @override
  Future<void> cancel(SourcePairingSession session) async {
    cancelCalls++;
  }
}

typedef _Poll = Future<SourcePairingPollResult> Function();
