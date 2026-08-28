import 'dart:async';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/source_pairing_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef SourcePairingApiFactory = SourcePairingApi Function(String baseUrl);
typedef SourcePairingBaseUrlLoader = Future<String?> Function();
typedef SourcePayloadImporter =
    Future<SourceImportSummary> Function(SourcePairingPayload payload);
typedef SourcePairingRetryDelay = Future<void> Function(Duration duration);
typedef SourcePairingDiagnosticRecorder =
    Future<void> Function(Map<String, Object?> details);
typedef PairedRepositoryAdder =
    Future<String?> Function(String url, {bool refreshAfterAdd});
typedef PairedManifestAdder = Future<String?> Function(String url);

final sourcePairingControllerProvider =
    StateNotifierProvider.autoDispose<
      SourcePairingController,
      SourcePairingState
    >((ref) {
      final marketplace = ref.read(marketplaceControllerProvider.notifier);
      final torrentSources = ref.read(
        userTorrentSourcesControllerProvider.notifier,
      );
      return SourcePairingController(
        () async {
          final origin = AppConfig.sourcePairingBrokerBaseUrl.trim();
          return origin.isEmpty ? null : origin;
        },
        (baseUrl) => SourcePairingClient(baseUrl: baseUrl),
        (payload) => importPairedSources(
          payload,
          marketplace: marketplace,
          torrentSources: torrentSources,
        ),
        diagnosticRecorder: (details) =>
            TetoTvDatabase.instance.recordDiagnosticEvent(
              category: 'source-pairing',
              message: 'Source pairing stage',
              details: details,
            ),
      );
    });

class SourcePairingController extends StateNotifier<SourcePairingState> {
  SourcePairingController(
    this._baseUrlLoader,
    this._clientFactory,
    this._importer, {
    SourcePairingRetryDelay? retryDelay,
    this.diagnosticRecorder,
    this.configurationTimeout = const Duration(seconds: 2),
    this.healthTimeout = const Duration(seconds: 12),
    this.sessionCreationTimeout = const Duration(seconds: 15),
  }) : _retryDelay = retryDelay ?? Future<void>.delayed,
       super(const SourcePairingState());

  final SourcePairingBaseUrlLoader _baseUrlLoader;
  final SourcePairingApiFactory _clientFactory;
  final SourcePayloadImporter _importer;
  final SourcePairingRetryDelay _retryDelay;
  final SourcePairingDiagnosticRecorder? diagnosticRecorder;
  final Duration configurationTimeout;
  final Duration healthTimeout;
  final Duration sessionCreationTimeout;
  SourcePairingApi? _client;
  Timer? _pollTimer;
  int? _pollingGeneration;
  int _generation = 0;
  int _consecutivePollFailures = 0;
  SourcePairingPayload? _pendingPayload;
  SourceImportSummary? _pendingAcknowledgement;
  bool _deliveryHandled = false;

  Future<void> start() async {
    final previousClient = _client;
    final previousSession = state.session;
    final previousDeliveryHandled = _deliveryHandled;
    final generation = ++_generation;
    _pollTimer?.cancel();
    _pollingGeneration = null;
    _client = null;
    _consecutivePollFailures = 0;
    _pendingPayload = null;
    _pendingAcknowledgement = null;
    _deliveryHandled = false;
    if (!previousDeliveryHandled &&
        previousClient != null &&
        previousSession != null) {
      unawaited(_cancelBestEffort(previousClient, previousSession));
    }
    final startedAt = DateTime.now();
    var phase = 'configuration';
    var phaseStartedAt = startedAt;
    state = const SourcePairingState(
      stage: SourcePairingStage.starting,
      message: 'Preparing the secure pairing service…',
    );
    _recordDiagnostic(phase: phase, outcome: 'started', startedAt: startedAt);
    try {
      final baseUrl = await _baseUrlLoader().timeout(configurationTimeout);
      if (!mounted || generation != _generation) return;
      if (baseUrl == null) {
        throw StateError(
          'This TetoTV build does not have its trusted HTTPS pairing service configured.',
        );
      }
      _recordDiagnostic(phase: phase, outcome: 'success', startedAt: startedAt);
      final client = _clientFactory(baseUrl);
      _client = client;
      phase = 'health';
      phaseStartedAt = DateTime.now();
      state = const SourcePairingState(
        stage: SourcePairingStage.starting,
        message: 'Checking the secure pairing service…',
      );
      _recordDiagnostic(
        phase: phase,
        outcome: 'started',
        startedAt: phaseStartedAt,
      );
      await client.ensureReady().timeout(healthTimeout);
      if (!mounted || generation != _generation) return;
      _recordDiagnostic(
        phase: phase,
        outcome: 'success',
        startedAt: phaseStartedAt,
      );
      phase = 'session-create';
      phaseStartedAt = DateTime.now();
      state = const SourcePairingState(
        stage: SourcePairingStage.starting,
        message: 'Requesting a private one-time code…',
      );
      _recordDiagnostic(
        phase: phase,
        outcome: 'started',
        startedAt: phaseStartedAt,
      );
      final session = await client.createSession().timeout(
        sessionCreationTimeout,
      );
      if (!mounted || generation != _generation) return;
      _recordDiagnostic(
        phase: phase,
        outcome: 'success',
        startedAt: phaseStartedAt,
      );
      state = SourcePairingState(
        stage: SourcePairingStage.waiting,
        session: session,
      );
      _pollTimer = Timer.periodic(
        session.pollInterval,
        (_) => unawaited(pollNow()),
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final timedOut = error is TimeoutException;
      _recordDiagnostic(
        phase: phase,
        outcome: timedOut ? 'timeout' : 'failed',
        reason: _sourcePairingFailureReason(error),
        startedAt: phaseStartedAt,
      );
      state = SourcePairingState(
        stage: SourcePairingStage.failed,
        message: timedOut
            ? 'The one-time code took too long to create. Check your connection and try again.'
            : _safeMessage(error),
      );
    }
  }

  void _recordDiagnostic({
    required String phase,
    required String outcome,
    required DateTime startedAt,
    String? reason,
  }) {
    final recorder = diagnosticRecorder;
    if (recorder == null) return;
    final elapsed = DateTime.now().difference(startedAt);
    unawaited(
      recorder({
        'stage': phase,
        'status': outcome,
        'reason_code': ?reason,
        'duration_ms': elapsed.inMilliseconds.clamp(0, 120000),
      }).catchError((_) {}),
    );
  }

  Future<void> pollNow() async {
    if (!mounted) return;
    final session = state.session;
    final client = _client;
    if (state.stage != SourcePairingStage.waiting ||
        session == null ||
        client == null) {
      return;
    }
    final generation = _generation;
    if (_pollingGeneration == generation) return;
    _pollingGeneration = generation;
    try {
      final result = await client.poll(session);
      if (!mounted || generation != _generation) return;
      _consecutivePollFailures = 0;
      switch (result.status) {
        case SourcePairingPollStatus.pending:
          return;
        case SourcePairingPollStatus.expired:
          _pollTimer?.cancel();
          state = SourcePairingState(
            stage: SourcePairingStage.expired,
            session: session,
            message: 'The one-time source code expired. Create a new code.',
          );
          return;
        case SourcePairingPollStatus.submitted:
          final payload = result.payload;
          if (payload == null) {
            throw const FormatException(
              'The pairing service returned an empty submission.',
            );
          }
          _pollTimer?.cancel();
          _pendingPayload = payload;
          // From this point the broker payload must remain available until an
          // authenticated completion acknowledgement. Closing or backgrounding
          // the app must not DELETE it while local persistence is in progress.
          _deliveryHandled = true;
          await _importAndAcknowledge(
            payload,
            client: client,
            session: session,
            generation: generation,
          );
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _consecutivePollFailures++;
      if (_consecutivePollFailures >= 3) {
        _pollTimer?.cancel();
        state = SourcePairingState(
          stage: SourcePairingStage.failed,
          session: session,
          message: _safeMessage(error),
        );
      }
    } finally {
      if (_pollingGeneration == generation) {
        _pollingGeneration = null;
      }
    }
  }

  Future<void> retryImport() async {
    if (!mounted ||
        state.stage != SourcePairingStage.failed ||
        !state.canRetryImport) {
      return;
    }
    final payload = _pendingPayload;
    final client = _client;
    final session = state.session;
    if (payload == null || client == null || session == null) return;
    await _importAndAcknowledge(
      payload,
      client: client,
      session: session,
      generation: _generation,
    );
  }

  Future<void> _importAndAcknowledge(
    SourcePairingPayload payload, {
    required SourcePairingApi client,
    required SourcePairingSession session,
    required int generation,
  }) async {
    state = SourcePairingState(
      stage: SourcePairingStage.validating,
      session: session,
      message: 'Received. Validating public HTTPS destinations…',
    );
    late final SourceImportSummary summary;
    try {
      summary = await _importer(payload);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      state = SourcePairingState(
        stage: SourcePairingStage.failed,
        session: session,
        message:
            'Sources were received but could not be saved safely. Retry without re-entering the URLs.',
        canRetryImport: true,
      );
      return;
    }
    if (!mounted || generation != _generation) return;

    // Persistence has finished before the broker is told to clear the URLs.
    // A closing dialog must not cancel this result while the phone reads it.
    _pendingAcknowledgement = summary;
    final acknowledged = await _acknowledgeWithRetry(
      client,
      session,
      summary,
      generation,
    );
    if (!mounted || generation != _generation) return;
    _pendingPayload = null;
    if (acknowledged) _pendingAcknowledgement = null;
    state = SourcePairingState(
      stage: summary.totalAdded > 0
          ? SourcePairingStage.completed
          : SourcePairingStage.failed,
      session: session,
      summary: summary,
      message: acknowledged
          ? summary.message
          : '${summary.message} Saved locally, but the phone confirmation could not be updated.',
      canRetryAcknowledgement: !acknowledged,
    );
  }

  Future<void> retryAcknowledgement() async {
    if (!mounted || !state.canRetryAcknowledgement) return;
    final client = _client;
    final session = state.session;
    final summary = _pendingAcknowledgement;
    if (client == null || session == null || summary == null) return;

    final generation = _generation;
    state = SourcePairingState(
      stage: SourcePairingStage.validating,
      session: session,
      summary: summary,
      message: 'Sources are saved. Updating the phone confirmation…',
    );
    final acknowledged = await _acknowledgeWithRetry(
      client,
      session,
      summary,
      generation,
    );
    if (!mounted || generation != _generation) return;
    if (acknowledged) _pendingAcknowledgement = null;
    state = SourcePairingState(
      stage: summary.totalAdded > 0
          ? SourcePairingStage.completed
          : SourcePairingStage.failed,
      session: session,
      summary: summary,
      message: acknowledged
          ? summary.message
          : '${summary.message} Saved locally, but the phone confirmation still could not be updated.',
      canRetryAcknowledgement: !acknowledged,
    );
  }

  Future<bool> _acknowledgeWithRetry(
    SourcePairingApi client,
    SourcePairingSession session,
    SourceImportSummary summary,
    int generation,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await client.acknowledge(session, summary);
        return true;
      } catch (_) {
        if (!mounted || generation != _generation) return false;
        if (attempt < 2) {
          await _retryDelay(Duration(milliseconds: 200 * (attempt + 1)));
        }
      }
    }
    return false;
  }

  void stop() {
    if (!mounted) return;
    final client = _client;
    final session = state.session;
    _generation++;
    _pollTimer?.cancel();
    _pollingGeneration = null;
    _client = null;
    if (!_deliveryHandled && client != null && session != null) {
      unawaited(_cancelBestEffort(client, session));
    }
    if (mounted &&
        state.stage != SourcePairingStage.completed &&
        state.stage != SourcePairingStage.failed) {
      state = const SourcePairingState(stage: SourcePairingStage.stopped);
    }
  }

  @override
  void dispose() {
    final client = _client;
    final session = state.session;
    _generation++;
    _pollTimer?.cancel();
    _pollingGeneration = null;
    _client = null;
    if (!_deliveryHandled && client != null && session != null) {
      unawaited(_cancelBestEffort(client, session));
    }
    super.dispose();
  }
}

Future<void> _cancelBestEffort(
  SourcePairingApi client,
  SourcePairingSession session,
) async {
  try {
    await client.cancel(session);
  } catch (_) {
    // The broker still expires abandoned sessions after ten minutes.
  }
}

Future<SourceImportSummary> importPairedSources(
  SourcePairingPayload payload, {
  required MarketplaceController marketplace,
  required UserTorrentSourcesController torrentSources,
  Future<void> Function(Uri uri)? repositoryTargetValidator,
  bool refreshRepositoriesAfterImport = true,
}) => importPairedSourcesWithOperations(
  payload,
  addRepository: marketplace.addRepository,
  refreshRepositories: () => marketplace.refresh(),
  addManifest: torrentSources.add,
  repositoryTargetValidator: repositoryTargetValidator,
  refreshRepositoriesAfterImport: refreshRepositoriesAfterImport,
);

final class PairedSourcesImportSnapshot {
  const PairedSourcesImportSnapshot._(this.marketplace, this.torrentSources);

  final MarketplaceImportSnapshot marketplace;
  final UserTorrentSourcesImportSnapshot torrentSources;
}

final class PairedSourcesRollbackException implements Exception {
  const PairedSourcesRollbackException();

  @override
  String toString() => 'Paired source rollback failed.';
}

Future<PairedSourcesImportSnapshot> snapshotPairedSources({
  required MarketplaceController marketplace,
  required UserTorrentSourcesController torrentSources,
}) async {
  final marketplaceSnapshot = await marketplace.snapshotForImport();
  final torrentSnapshot = await torrentSources.snapshotForImport();
  return PairedSourcesImportSnapshot._(marketplaceSnapshot, torrentSnapshot);
}

Future<void> restorePairedSources(
  PairedSourcesImportSnapshot snapshot, {
  required MarketplaceController marketplace,
  required UserTorrentSourcesController torrentSources,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  try {
    await torrentSources.restoreImportSnapshot(snapshot.torrentSources);
  } catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }
  try {
    await marketplace.restoreImportSnapshot(snapshot.marketplace);
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }
  if (firstError != null) {
    Error.throwWithStackTrace(
      const PairedSourcesRollbackException(),
      firstStackTrace ?? StackTrace.current,
    );
  }
}

void commitPairedSources(
  SourceImportSummary summary, {
  required MarketplaceController marketplace,
}) {
  if (summary.repositoriesAdded == 0) return;
  unawaited(marketplace.refresh().catchError((_) {}));
}

/// Applies a one-time submission through the same validated controller
/// operations used by manual entry. Exposed separately so atomic/partial bulk
/// behavior can be verified without replacing the application controllers.
Future<SourceImportSummary> importPairedSourcesWithOperations(
  SourcePairingPayload payload, {
  required PairedRepositoryAdder addRepository,
  required Future<void> Function() refreshRepositories,
  required PairedManifestAdder addManifest,
  Future<void> Function(Uri uri)? repositoryTargetValidator,
  bool refreshRepositoriesAfterImport = true,
}) async {
  var repositoriesAdded = 0;
  var manifestsAdded = 0;
  final errors = <String>[];

  for (var index = 0; index < payload.repositoryUrls.length; index++) {
    final value = payload.repositoryUrls[index];
    final uri = safePublicHttpsUri(value);
    if (uri == null) {
      errors.add('Repository ${index + 1}: invalid public HTTPS URL.');
      continue;
    }
    try {
      // Validate DNS before MarketplaceController persists the repository.
      // Marketplace network requests pin the validated public address again.
      await (repositoryTargetValidator ?? validatePublicNetworkTarget)(uri);
      final error = await addRepository(uri.toString(), refreshAfterAdd: false);
      if (error == null || _alreadySaved(error)) {
        repositoriesAdded++;
      } else {
        errors.add('Repository ${index + 1}: $error');
      }
    } catch (_) {
      errors.add('Repository ${index + 1}: host is not a public address.');
    }
  }

  for (var index = 0; index < payload.manifestUrls.length; index++) {
    try {
      final error = await addManifest(payload.manifestUrls[index]);
      if (error == null || _alreadySaved(error)) {
        manifestsAdded++;
      } else {
        errors.add('Torrent manifest ${index + 1}: $error');
      }
    } catch (_) {
      errors.add('Torrent manifest ${index + 1}: could not be saved.');
    }
  }

  if (repositoriesAdded > 0 && refreshRepositoriesAfterImport) {
    // Persistence is complete before any third-party repository is fetched.
    // A slow or broken catalog must not delay torrent-manifest storage, the
    // app acknowledgement, or the phone's saved confirmation.
    unawaited(refreshRepositories().catchError((_) {}));
  }

  return SourceImportSummary(
    repositoriesAdded: repositoriesAdded,
    manifestsAdded: manifestsAdded,
    errors: List<String>.unmodifiable(errors),
  );
}

bool _alreadySaved(String message) =>
    message.toLowerCase().contains('already added');

String _safeMessage(Object error) {
  final value = error.toString().replaceFirst(
    RegExp(r'^(?:Bad state|[A-Za-z]+(?:Exception|Error)):\s*'),
    '',
  );
  return value.length <= 220 ? value : '${value.substring(0, 220)}…';
}

String _sourcePairingFailureReason(Object error) {
  if (error is TimeoutException) return 'timeout';
  final value = error.toString().toLowerCase();
  if (value.contains('updated') || value.contains('protocol')) {
    return 'protocol_unavailable';
  }
  if (value.contains('configured')) return 'not_configured';
  if (value.contains('capacity') || value.contains('busy')) {
    return 'capacity';
  }
  if (value.contains('rate') || value.contains('429')) return 'rate_limited';
  return 'unreachable';
}
