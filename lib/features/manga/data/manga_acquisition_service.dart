// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/manga/data/manga_archive_service.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_image_safety.dart'
    show
        MangaImageValidationException,
        MangaImageValidationFailure,
        inspectMangaImage;
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_acquisition_models.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

enum MangaAcquisitionPhase {
  queued,
  resolving,
  downloading,
  extracting,
  completed,
  failed,
  cancelled,
}

enum MangaAcquisitionFailureCode {
  cancelled,
  invalidRequest,
  unsafeTarget,
  redirectRejected,
  tooManyRedirects,
  httpFailure,
  responseTooLarge,
  unsupportedContent,
  integrityFailure,
  storageFailure,
  archiveFailure,
  unknown,
}

class MangaAcquisitionException implements Exception {
  const MangaAcquisitionException(this.code, this.message);

  final MangaAcquisitionFailureCode code;
  final String message;

  @override
  String toString() => 'MangaAcquisitionException: $message';
}

sealed class MangaChapterAcquisition {
  const MangaChapterAcquisition();

  int? get knownPageCount;
}

/// A ZIP/CBZ chapter acquisition selected by the manga hub.
///
/// The URI is deliberately kept in memory. It is never accepted by
/// [MangaStoreAcquisitionPersistence], so signed links cannot reach SQLite.
final class MangaCbzDownloadAcquisition extends MangaChapterAcquisition {
  MangaCbzDownloadAcquisition(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) : headers = _validatedEphemeralHeaders(headers),
       uri = requireMangaPublicHttpsUri(
         uri.toString(),
         field: 'CBZ acquisition URL',
       );

  factory MangaCbzDownloadAcquisition.fromSelection(
    MangaCbzAcquisitionSource selection,
  ) => MangaCbzDownloadAcquisition(selection.uri, headers: selection.headers);

  final Uri uri;
  final Map<String, String> headers;

  @override
  int? get knownPageCount => null;
}

class MangaReadingOrderPage {
  MangaReadingOrderPage({
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    this.pixelWidth,
    this.pixelHeight,
    this.isCover = false,
  }) : headers = _validatedEphemeralPageHeaders(headers),
       uri = requireMangaPublicHttpsUri(
         uri.toString(),
         field: 'Manga page URL',
       ) {
    if ((pixelWidth == null) != (pixelHeight == null) ||
        (pixelWidth != null && (pixelWidth! <= 0 || pixelWidth! > 100000)) ||
        (pixelHeight != null && (pixelHeight! <= 0 || pixelHeight! > 100000))) {
      throw ArgumentError('Manga page dimensions are invalid.');
    }
  }

  final Uri uri;
  final Map<String, String> headers;
  final int? pixelWidth;
  final int? pixelHeight;
  final bool isCover;
}

/// An OPDS 2/Web Publication reading-order acquisition.
final class MangaReadingOrderAcquisition extends MangaChapterAcquisition {
  MangaReadingOrderAcquisition(Iterable<MangaReadingOrderPage> pages)
    : pages = List<MangaReadingOrderPage>.unmodifiable(pages) {
    if (this.pages.isEmpty || this.pages.length > maximumMangaArchivePages) {
      throw ArgumentError.value(
        this.pages.length,
        'pages',
        'A reading order must contain between 1 and 1000 pages.',
      );
    }
  }

  final List<MangaReadingOrderPage> pages;

  @override
  int get knownPageCount => pages.length;
}

class MangaAcquisitionRequest {
  factory MangaAcquisitionRequest.fromCbzSelection({
    required String jobId,
    required MangaCbzAcquisitionSource selection,
    required String chapterId,
    required String seriesTitle,
    required String chapterTitle,
    double? chapterNumber,
    int initialPageIndex = 0,
  }) => MangaAcquisitionRequest(
    jobId: jobId,
    sourceId: selection.sourceId,
    publicationId: selection.publicationId,
    chapterId: chapterId,
    seriesTitle: seriesTitle,
    chapterTitle: chapterTitle,
    acquisition: MangaCbzDownloadAcquisition.fromSelection(selection),
    chapterNumber: chapterNumber,
    initialPageIndex: initialPageIndex,
  );

  MangaAcquisitionRequest({
    required String jobId,
    required String sourceId,
    required String publicationId,
    required String chapterId,
    required String seriesTitle,
    required String chapterTitle,
    required this.acquisition,
    Uri? credentialOrigin,
    this.chapterNumber,
    this.initialPageIndex = 0,
  }) : jobId = _boundedValue(jobId, 'jobId', 128),
       sourceId = _sourceId(sourceId),
       publicationId = _boundedValue(publicationId, 'publicationId', 512),
       chapterId = _boundedValue(chapterId, 'chapterId', 512),
       seriesTitle = _boundedValue(seriesTitle, 'seriesTitle', 512),
       chapterTitle = _boundedValue(chapterTitle, 'chapterTitle', 512),
       credentialOrigin = credentialOrigin == null
           ? null
           : requireMangaPublicHttpsUri(
               credentialOrigin.toString(),
               field: 'Manga credential origin',
             ) {
    final pageCount = acquisition.knownPageCount;
    if (initialPageIndex < 0 ||
        initialPageIndex >= (pageCount ?? maximumMangaArchivePages)) {
      throw ArgumentError.value(
        initialPageIndex,
        'initialPageIndex',
        'Initial manga page is out of range.',
      );
    }
    if (chapterNumber != null &&
        (!chapterNumber!.isFinite ||
            chapterNumber! <= 0 ||
            chapterNumber! > 100000)) {
      throw ArgumentError.value(chapterNumber, 'chapterNumber');
    }
  }

  final String jobId;
  final String sourceId;
  final String publicationId;
  final String chapterId;
  final String seriesTitle;
  final String chapterTitle;
  final MangaChapterAcquisition acquisition;

  /// Origin that owns the source credential. Credentials are requested from
  /// protected storage and attached only to resources on this exact origin.
  final Uri? credentialOrigin;
  final double? chapterNumber;
  final int initialPageIndex;
}

class MangaAcquisitionProgress {
  const MangaAcquisitionProgress({
    required this.jobId,
    required this.phase,
    this.pageCount,
    this.completedPages = 0,
    this.receivedBytes = 0,
    this.currentPageIndex,
  });

  final String jobId;
  final MangaAcquisitionPhase phase;
  final int? pageCount;
  final int completedPages;
  final int receivedBytes;
  final int? currentPageIndex;

  double? get fraction => pageCount == null || pageCount == 0
      ? null
      : (completedPages / pageCount!).clamp(0, 1);
}

class MangaAcquisitionOperation {
  MangaAcquisitionOperation._(this.request)
    : _progressController =
          StreamController<MangaAcquisitionProgress>.broadcast(sync: true),
      _completion = Completer<MangaReaderRequest>(),
      _cancellation = MangaAcquisitionCancellationToken(),
      _current = MangaAcquisitionProgress(
        jobId: request.jobId,
        phase: MangaAcquisitionPhase.queued,
        pageCount: request.acquisition.knownPageCount,
      );

  final MangaAcquisitionRequest request;
  final StreamController<MangaAcquisitionProgress> _progressController;
  final Completer<MangaReaderRequest> _completion;
  final MangaAcquisitionCancellationToken _cancellation;
  MangaAcquisitionProgress _current;

  Stream<MangaAcquisitionProgress> get progress => _progressController.stream;
  Future<MangaReaderRequest> get completed => _completion.future;
  MangaAcquisitionProgress get currentProgress => _current;
  bool get isCancelled => _cancellation.isCancelled;

  Future<void> cancel() async => _cancellation.cancel();

  void _emit(MangaAcquisitionProgress progress) {
    _current = progress;
    if (!_progressController.isClosed) _progressController.add(progress);
  }

  Future<void> _succeed(MangaReaderRequest request) async {
    if (!_completion.isCompleted) _completion.complete(request);
    await _progressController.close();
  }

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (!_completion.isCompleted) _completion.completeError(error, stackTrace);
    await _progressController.close();
  }
}

class MangaAcquisitionCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void throwIfCancelled() {
    if (_cancelled) {
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.cancelled,
        'The manga download was cancelled.',
      );
    }
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

class MangaAcquisitionHttpResponse {
  MangaAcquisitionHttpResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required this.body,
    Future<void> Function()? discard,
    void Function()? release,
  }) : headers = Map<String, String>.unmodifiable({
         for (final entry in headers.entries)
           entry.key.toLowerCase(): entry.value,
       }),
       _discard = discard,
       _release = release;

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final Future<void> Function()? _discard;
  final void Function()? _release;

  String? header(String name) => headers[name.toLowerCase()];

  Future<void> discard() async {
    _release?.call();
    await _discard?.call();
  }

  void release() => _release?.call();
}

abstract interface class MangaAcquisitionTransport {
  Future<MangaAcquisitionHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required MangaAcquisitionCancellationToken cancellation,
  });
}

class DioMangaAcquisitionTransport implements MangaAcquisitionTransport {
  DioMangaAcquisitionTransport({
    Dio? dio,
    this.connectTimeout = const Duration(seconds: 12),
    this.receiveTimeout = const Duration(seconds: 20),
  }) : _dio =
           dio ??
           createPinnedPublicHttpsDio(
             BaseOptions(
               connectTimeout: connectTimeout,
               receiveTimeout: receiveTimeout,
               sendTimeout: connectTimeout,
               responseType: ResponseType.stream,
               followRedirects: false,
               persistentConnection: false,
             ),
           );

  final Dio _dio;
  final Duration connectTimeout;
  final Duration receiveTimeout;

  @override
  Future<MangaAcquisitionHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required MangaAcquisitionCancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final cancelToken = CancelToken();
    final removeCancellation = cancellation.onCancel(
      () => cancelToken.cancel('Manga acquisition cancelled.'),
    );
    try {
      final response = await _dio
          .get<ResponseBody>(
            uri.toString(),
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              persistentConnection: false,
              headers: <String, Object>{
                HttpHeaders.userAgentHeader: 'TetoTV/2 manga-acquisition',
                ...headers,
              },
              validateStatus: (_) => true,
            ),
          )
          .timeout(connectTimeout + receiveTimeout);
      final responseBody = response.data;
      return MangaAcquisitionHttpResponse(
        statusCode: response.statusCode ?? 0,
        headers: _flattenResponseHeaders(response.headers),
        body: responseBody?.stream ?? const Stream<List<int>>.empty(),
        discard: () => _cancelResponseBody(responseBody),
        release: removeCancellation,
      );
    } on DioException catch (error) {
      removeCancellation();
      if (CancelToken.isCancel(error) || cancellation.isCancelled) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.cancelled,
          'The manga download was cancelled.',
        );
      }
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.httpFailure,
        'The manga server could not be reached.',
      );
    } on TimeoutException {
      cancelToken.cancel('Manga acquisition timed out.');
      removeCancellation();
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.httpFailure,
        'The manga server timed out.',
      );
    }
  }
}

abstract interface class MangaAcquisitionPersistence {
  Future<MangaDownloadJob?> job(String jobId);
  Future<List<MangaDownloadJob>> listJobs();
  Future<List<MangaDownloadPage>> pages(String jobId);
  Future<void> putJob(MangaDownloadJob job);
  Future<void> putPage(MangaDownloadPage page);
  Future<void> clearPages(String jobId);
  Future<void> deleteJob(String jobId);
}

class MangaStoreAcquisitionPersistence implements MangaAcquisitionPersistence {
  const MangaStoreAcquisitionPersistence(this.store);

  final MangaStore store;

  @override
  Future<MangaDownloadJob?> job(String jobId) => store.downloadJob(jobId);

  @override
  Future<List<MangaDownloadJob>> listJobs() => store.downloadJobs();

  @override
  Future<List<MangaDownloadPage>> pages(String jobId) =>
      store.downloadPages(jobId);

  @override
  Future<void> putJob(MangaDownloadJob job) => store.upsertDownloadJob(job);

  @override
  Future<void> putPage(MangaDownloadPage page) =>
      store.upsertDownloadPage(page);

  @override
  Future<void> clearPages(String jobId) async {
    final existing = await store.downloadPages(jobId);
    for (final page in existing) {
      await store.deleteDownloadPage(jobId, page.pageIndex);
    }
  }

  @override
  Future<void> deleteJob(String jobId) => store.deleteDownloadJob(jobId);
}

typedef MangaCredentialHeaders =
    Future<Map<String, String>> Function(String sourceId);
typedef MangaAcquisitionTargetValidator = Future<void> Function(Uri uri);

class MangaAcquisitionService {
  factory MangaAcquisitionService({
    required MangaStore store,
    required MangaStorageRoots storageRoots,
    required MangaSourceCredentialStore credentials,
    MangaArchiveService archiveService = const MangaArchiveService(),
    MangaAcquisitionTransport? transport,
    MangaAcquisitionTargetValidator? validateTarget,
    OfflineDownloadKeepAlive? keepAlive,
    Duration receiveTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) => MangaAcquisitionService.withDependencies(
    persistence: MangaStoreAcquisitionPersistence(store),
    storageRoots: storageRoots,
    credentialHeaders: credentials.requestHeaders,
    archiveService: archiveService,
    transport: transport,
    validateTarget: validateTarget,
    keepAlive: keepAlive ?? AndroidOfflineDownloadKeepAlive(),
    receiveTimeout: receiveTimeout,
    clock: clock,
  );

  MangaAcquisitionService.withDependencies({
    required MangaAcquisitionPersistence persistence,
    required MangaStorageRoots storageRoots,
    MangaCredentialHeaders? credentialHeaders,
    MangaArchiveService archiveService = const MangaArchiveService(),
    MangaAcquisitionTransport? transport,
    MangaAcquisitionTargetValidator? validateTarget,
    OfflineDownloadKeepAlive keepAlive = const NoopOfflineDownloadKeepAlive(),
    this.receiveTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _persistence = persistence,
       _storageRoots = storageRoots,
       _credentialHeaders = credentialHeaders ?? _noCredentialHeaders,
       _archiveService = archiveService,
       _transport = transport ?? DioMangaAcquisitionTransport(),
       _validateTarget = validateTarget ?? validatePublicNetworkTarget,
       _keepAlive = keepAlive,
       _clock = clock ?? DateTime.now {
    if (receiveTimeout <= Duration.zero) {
      throw ArgumentError.value(receiveTimeout, 'receiveTimeout');
    }
  }

  final MangaAcquisitionPersistence _persistence;
  final MangaStorageRoots _storageRoots;
  final MangaCredentialHeaders _credentialHeaders;
  final MangaArchiveService _archiveService;
  final MangaAcquisitionTransport _transport;
  final MangaAcquisitionTargetValidator _validateTarget;
  final OfflineDownloadKeepAlive _keepAlive;
  final DateTime Function() _clock;
  final Duration receiveTimeout;
  final Map<String, MangaAcquisitionOperation> _active =
      <String, MangaAcquisitionOperation>{};

  MangaAcquisitionOperation start(MangaAcquisitionRequest request) =>
      _start(request, isRetry: false);

  MangaAcquisitionOperation retry(MangaAcquisitionRequest request) =>
      _start(request, isRetry: true);

  MangaAcquisitionOperation? activeOperation(String jobId) => _active[jobId];

  Future<void> cancel(String jobId) async => _active[jobId]?.cancel();

  Future<List<MangaDownloadJob>> jobs() => _persistence.listJobs();

  /// Converts transfers interrupted by process death into explicit, retryable
  /// rows. Remote URLs and credentials are intentionally not durable, so a
  /// fresh user-authorized acquisition request is required to retry them.
  Future<List<MangaDownloadJob>> recoverStaleJobs() async {
    final existing = await _persistence.listJobs();
    for (final job in existing) {
      if (_active.containsKey(job.id) || !_isInterruptedStatus(job.status)) {
        continue;
      }
      await _cleanupFailedDownload(
        job.id,
        _ownedJobDirectory(job.relativeDirectory),
      );
      await _persistence.putJob(
        _updatedJob(
          job,
          status: MangaDownloadJobStatus.needsReauthorization,
          completedPages: 0,
          receivedBytes: 0,
          errorCode: 'interrupted',
          errorMessage: 'Reconnect to the manga source to retry this download.',
          updatedAt: _clock(),
        ),
      );
    }
    return _persistence.listJobs();
  }

  /// Reopens a completed local download without reconstructing its remote URL
  /// or credential capability.
  Future<MangaReaderRequest?> openCompleted(String jobId) async {
    final job = await _persistence.job(jobId);
    if (job == null || job.status != MangaDownloadJobStatus.completed) {
      return null;
    }
    final pages = await _persistence.pages(jobId);
    if (pages.isEmpty || job.pageCount != pages.length) {
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.integrityFailure,
        'The downloaded manga chapter is incomplete.',
      );
    }
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      if (page.pageIndex != index) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.integrityFailure,
          'The downloaded manga pages are out of order.',
        );
      }
      final file = _storageRoots.resolvePage(
        MangaTrustedLocalPageResource(
          area: MangaLocalStorageArea.downloadedPages,
          relativePath: page.relativePath,
        ),
      );
      if (!await file.exists() || await file.length() != page.byteLength) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.integrityFailure,
          'A downloaded manga page is missing or damaged.',
        );
      }
      final digest = sha256.convert(await file.readAsBytes()).toString();
      if (digest != page.sha256) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.integrityFailure,
          'A downloaded manga page failed its integrity check.',
        );
      }
    }
    return _readerRequestFromStored(job, pages);
  }

  Future<void> delete(String jobId) async {
    final operation = _active[jobId];
    if (operation != null) {
      await operation.cancel();
      try {
        await operation.completed;
      } catch (_) {
        // Cancellation is the expected terminal state before deletion.
      }
    }
    final job = await _persistence.job(jobId);
    if (job != null) {
      await _cleanupFailedDownload(
        jobId,
        _ownedJobDirectory(job.relativeDirectory),
      );
    } else {
      await _persistence.clearPages(jobId);
    }
    await _persistence.deleteJob(jobId);
  }

  /// Deletes every app-owned file and durable row for a source before the
  /// source itself is removed. Calling this after the source-row cascade would
  /// lose the only safe relative-directory references needed for cleanup.
  Future<int> deleteDownloadsForSource(String sourceId) async {
    final normalizedSourceId = _sourceId(sourceId);
    final jobIds = <String>{
      for (final job in await _persistence.listJobs())
        if (_belongsToSourceTree(job.sourceId, normalizedSourceId)) job.id,
      for (final operation in _active.values)
        if (_belongsToSourceTree(
          operation.request.sourceId,
          normalizedSourceId,
        ))
          operation.request.jobId,
    };
    for (final jobId in jobIds) {
      await delete(jobId);
    }
    return jobIds.length;
  }

  MangaAcquisitionOperation _start(
    MangaAcquisitionRequest request, {
    required bool isRetry,
  }) {
    final existing = _active[request.jobId];
    if (existing != null) return existing;
    final operation = MangaAcquisitionOperation._(request);
    _active[request.jobId] = operation;
    unawaited(_runOperation(operation, isRetry: isRetry));
    return operation;
  }

  Future<void> _runOperation(
    MangaAcquisitionOperation operation, {
    required bool isRetry,
  }) async {
    try {
      final result = await _run(operation, isRetry: isRetry);
      _active.remove(operation.request.jobId);
      await operation._succeed(result);
    } catch (error, stackTrace) {
      _active.remove(operation.request.jobId);
      await operation._fail(error, stackTrace);
    } finally {
      _active.remove(operation.request.jobId);
    }
  }

  Future<MangaReaderRequest> _run(
    MangaAcquisitionOperation operation, {
    required bool isRetry,
  }) async {
    final request = operation.request;
    final previous = await _persistence.job(request.jobId);
    if (previous?.status == MangaDownloadJobStatus.completed) {
      final restored = await _restoreCompletedRequest(request, previous!);
      if (restored != null) {
        operation._emit(
          MangaAcquisitionProgress(
            jobId: request.jobId,
            phase: MangaAcquisitionPhase.completed,
            pageCount: restored.pages.length,
            completedPages: restored.pages.length,
            receivedBytes: previous.receivedBytes,
          ),
        );
        return restored;
      }
    }

    final relativeDirectory = _jobRelativeDirectory(request.jobId);
    final jobDirectory = _ownedJobDirectory(relativeDirectory);
    await _resetPartialDownload(request.jobId, jobDirectory);

    final now = _clock();
    final retryCount = previous == null
        ? 0
        : previous.retryCount + (isRetry ? 1 : 0);
    var job = MangaDownloadJob(
      id: request.jobId,
      sourceId: request.sourceId,
      entryId: request.publicationId,
      chapterId: request.chapterId,
      seriesTitle: request.seriesTitle,
      chapterLabel: request.chapterTitle,
      status: MangaDownloadJobStatus.queued,
      relativeDirectory: relativeDirectory,
      pageCount: request.acquisition.knownPageCount,
      completedPages: 0,
      receivedBytes: 0,
      queuePosition: 0,
      retryCount: retryCount,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
    await _persistence.putJob(job);

    final lease = await acquireOfflineDownloadKeepAliveSafely(_keepAlive);
    try {
      operation._cancellation.throwIfCancelled();
      job = _updatedJob(
        job,
        status: MangaDownloadJobStatus.resolving,
        updatedAt: _clock(),
      );
      await _persistence.putJob(job);
      operation._emit(
        MangaAcquisitionProgress(
          jobId: request.jobId,
          phase: MangaAcquisitionPhase.resolving,
          pageCount: request.acquisition.knownPageCount,
        ),
      );

      await jobDirectory.create(recursive: true);
      final credentials = await _credentialsFor(request);
      final pages = switch (request.acquisition) {
        MangaCbzDownloadAcquisition acquisition => await _downloadCbz(
          operation,
          request,
          acquisition,
          credentials,
          jobDirectory,
          job,
        ),
        MangaReadingOrderAcquisition acquisition => await _downloadPages(
          operation,
          request,
          acquisition,
          credentials,
          jobDirectory,
          job,
        ),
      };
      operation._cancellation.throwIfCancelled();

      final receivedBytes = pages.fold<int>(
        0,
        (total, page) => total + page.byteLength,
      );
      job = _updatedJob(
        job,
        status: MangaDownloadJobStatus.completed,
        pageCount: pages.length,
        completedPages: pages.length,
        receivedBytes: receivedBytes,
        updatedAt: _clock(),
      );
      await _persistence.putJob(job);
      operation._emit(
        MangaAcquisitionProgress(
          jobId: request.jobId,
          phase: MangaAcquisitionPhase.completed,
          pageCount: pages.length,
          completedPages: pages.length,
          receivedBytes: receivedBytes,
        ),
      );
      return _readerRequest(request, pages);
    } on MangaAcquisitionException catch (error) {
      await _cleanupFailedDownload(request.jobId, jobDirectory);
      final cancelled =
          error.code == MangaAcquisitionFailureCode.cancelled ||
          operation.isCancelled;
      await _persistence.putJob(
        _updatedJob(
          job,
          status: cancelled
              ? MangaDownloadJobStatus.cancelled
              : MangaDownloadJobStatus.failed,
          completedPages: 0,
          receivedBytes: 0,
          errorCode: cancelled ? 'cancelled' : error.code.name,
          errorMessage: error.message,
          updatedAt: _clock(),
        ),
      );
      operation._emit(
        MangaAcquisitionProgress(
          jobId: request.jobId,
          phase: cancelled
              ? MangaAcquisitionPhase.cancelled
              : MangaAcquisitionPhase.failed,
          pageCount: request.acquisition.knownPageCount,
        ),
      );
      rethrow;
    } catch (_) {
      await _cleanupFailedDownload(request.jobId, jobDirectory);
      const error = MangaAcquisitionException(
        MangaAcquisitionFailureCode.unknown,
        'The manga download could not be completed.',
      );
      await _persistence.putJob(
        _updatedJob(
          job,
          status: MangaDownloadJobStatus.failed,
          completedPages: 0,
          receivedBytes: 0,
          errorCode: error.code.name,
          errorMessage: error.message,
          updatedAt: _clock(),
        ),
      );
      operation._emit(
        MangaAcquisitionProgress(
          jobId: request.jobId,
          phase: MangaAcquisitionPhase.failed,
          pageCount: request.acquisition.knownPageCount,
        ),
      );
      throw error;
    } finally {
      await releaseOfflineDownloadKeepAliveSafely(lease);
    }
  }

  Future<_CredentialCapability> _credentialsFor(
    MangaAcquisitionRequest request,
  ) async {
    final acquisition = request.acquisition;
    if (acquisition is MangaCbzDownloadAcquisition &&
        acquisition.headers.isNotEmpty) {
      return _CredentialCapability(
        origin: acquisition.uri,
        headers: acquisition.headers,
      );
    }
    if (request.credentialOrigin == null) {
      return const _CredentialCapability();
    }
    return _CredentialCapability(
      origin: request.credentialOrigin,
      headers: _validatedEphemeralHeaders(
        await _credentialHeaders(request.sourceId),
      ),
    );
  }

  Future<List<MangaDownloadPage>> _downloadCbz(
    MangaAcquisitionOperation operation,
    MangaAcquisitionRequest request,
    MangaCbzDownloadAcquisition acquisition,
    _CredentialCapability credentials,
    Directory jobDirectory,
    MangaDownloadJob job,
  ) async {
    await _storageRoots.extractedArchives.create(recursive: true);
    final temporaryDirectory = await _storageRoots.extractedArchives.createTemp(
      'manga-acquire-',
    );
    final partFile = File(
      path.join(temporaryDirectory.path, 'chapter.cbz.part'),
    );
    final archiveFile = File(path.join(temporaryDirectory.path, 'chapter.cbz'));
    try {
      operation._emit(
        MangaAcquisitionProgress(
          jobId: request.jobId,
          phase: MangaAcquisitionPhase.downloading,
        ),
      );
      final downloadedBytes = await _downloadToPart(
        operation: operation,
        uri: acquisition.uri,
        credentials: credentials,
        partFile: partFile,
        maximumBytes: maximumMangaArchiveUncompressedBytes,
        onProgress: (received) {
          operation._emit(
            MangaAcquisitionProgress(
              jobId: request.jobId,
              phase: MangaAcquisitionPhase.downloading,
              receivedBytes: received,
            ),
          );
        },
      );
      if (downloadedBytes <= 0) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.unsupportedContent,
          'The manga archive was empty.',
        );
      }
      await partFile.rename(archiveFile.path);
      operation._cancellation.throwIfCancelled();
      operation._emit(
        MangaAcquisitionProgress(
          jobId: request.jobId,
          phase: MangaAcquisitionPhase.extracting,
          receivedBytes: downloadedBytes,
        ),
      );

      final MangaArchiveExtraction extraction;
      final extractionCancellation = Completer<void>();
      final removeExtractionCancellation = operation._cancellation.onCancel(() {
        if (!extractionCancellation.isCompleted) {
          extractionCancellation.complete();
        }
      });
      try {
        extraction = await _archiveService.extract(
          archiveFile: archiveFile,
          stagingDirectory: jobDirectory,
          cancellation: extractionCancellation.future,
        );
      } on MangaArchiveException catch (error) {
        if (error.code == MangaArchiveFailureCode.cancelled ||
            operation.isCancelled) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.cancelled,
            'The manga download was cancelled.',
          );
        }
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.archiveFailure,
          'The downloaded CBZ archive was invalid.',
        );
      } finally {
        removeExtractionCancellation();
      }
      final pages = <MangaDownloadPage>[];
      for (final extracted in extraction.pages) {
        operation._cancellation.throwIfCancelled();
        final relativePath = _relativeDownloadedPath(extracted.file);
        final digest = sha256
            .convert(await extracted.file.readAsBytes())
            .toString();
        final page = MangaDownloadPage(
          jobId: request.jobId,
          pageIndex: extracted.index,
          relativePath: relativePath,
          mimeType: extracted.mimeType,
          byteLength: extracted.byteLength,
          sha256: digest,
        );
        await _persistence.putPage(page);
        pages.add(page);
        operation._emit(
          MangaAcquisitionProgress(
            jobId: request.jobId,
            phase: MangaAcquisitionPhase.extracting,
            pageCount: extraction.pages.length,
            completedPages: pages.length,
            receivedBytes: downloadedBytes,
            currentPageIndex: extracted.index,
          ),
        );
      }
      await _persistence.putJob(
        _updatedJob(
          job,
          status: MangaDownloadJobStatus.downloading,
          pageCount: pages.length,
          completedPages: pages.length,
          receivedBytes: pages.fold<int>(
            0,
            (total, page) => total + page.byteLength,
          ),
          updatedAt: _clock(),
        ),
      );
      return pages;
    } finally {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }

  Future<List<MangaDownloadPage>> _downloadPages(
    MangaAcquisitionOperation operation,
    MangaAcquisitionRequest request,
    MangaReadingOrderAcquisition acquisition,
    _CredentialCapability credentials,
    Directory jobDirectory,
    MangaDownloadJob job,
  ) async {
    var totalBytes = 0;
    final pages = <MangaDownloadPage>[];
    operation._emit(
      MangaAcquisitionProgress(
        jobId: request.jobId,
        phase: MangaAcquisitionPhase.downloading,
        pageCount: acquisition.pages.length,
      ),
    );

    for (var index = 0; index < acquisition.pages.length; index++) {
      operation._cancellation.throwIfCancelled();
      final sourcePage = acquisition.pages[index];
      final partFile = File(
        path.join(jobDirectory.path, '${_pageBase(index)}.part'),
      );
      final remaining = maximumMangaArchiveUncompressedBytes - totalBytes;
      if (remaining <= 0) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.responseTooLarge,
          'The chapter exceeds the download size limit.',
        );
      }
      final maximum = remaining < maximumMangaArchivePageBytes
          ? remaining
          : maximumMangaArchivePageBytes;
      final response = await _openResponse(
        sourcePage.uri,
        sourcePage.headers.isEmpty
            ? credentials
            : _CredentialCapability(
                origin: sourcePage.uri,
                headers: sourcePage.headers,
                stripHeadersOnCrossOriginRedirect: true,
              ),
        operation._cancellation,
      );
      var bodyStarted = false;
      try {
        final declaredType = _declaredImageType(
          response.header(HttpHeaders.contentTypeHeader),
        );
        final declaredMime = _normalizedMime(
          response.header(HttpHeaders.contentTypeHeader),
        );
        if (declaredMime != null &&
            declaredMime != 'application/octet-stream' &&
            declaredType == null) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.unsupportedContent,
            'A reading-order resource was not a supported image.',
          );
        }
        final downloaded = await _writeImageResponse(
          operation: operation,
          response: response,
          partFile: partFile,
          maximumBytes: maximum,
          expectedType: declaredType,
          onBodyStarted: () => bodyStarted = true,
          onProgress: (pageBytes) {
            operation._emit(
              MangaAcquisitionProgress(
                jobId: request.jobId,
                phase: MangaAcquisitionPhase.downloading,
                pageCount: acquisition.pages.length,
                completedPages: pages.length,
                receivedBytes: totalBytes + pageBytes,
                currentPageIndex: index,
              ),
            );
          },
        );
        final finalFile = File(
          path.join(
            jobDirectory.path,
            '${_pageBase(index)}${downloaded.type.extension}',
          ),
        );
        await partFile.rename(finalFile.path);
        totalBytes += downloaded.byteLength;
        final page = MangaDownloadPage(
          jobId: request.jobId,
          pageIndex: index,
          relativePath: _relativeDownloadedPath(finalFile),
          mimeType: downloaded.type.mimeType,
          byteLength: downloaded.byteLength,
          sha256: downloaded.sha256,
        );
        await _persistence.putPage(page);
        pages.add(page);
        await _persistence.putJob(
          _updatedJob(
            job,
            status: MangaDownloadJobStatus.downloading,
            pageCount: acquisition.pages.length,
            completedPages: pages.length,
            receivedBytes: totalBytes,
            updatedAt: _clock(),
          ),
        );
      } finally {
        if (bodyStarted) {
          response.release();
        } else {
          await response.discard();
        }
      }
    }
    return pages;
  }

  Future<int> _downloadToPart({
    required MangaAcquisitionOperation operation,
    required Uri uri,
    required _CredentialCapability credentials,
    required File partFile,
    required int maximumBytes,
    required void Function(int receivedBytes) onProgress,
  }) async {
    final response = await _openResponse(
      uri,
      credentials,
      operation._cancellation,
    );
    IOSink? sink;
    var received = 0;
    var bodyStarted = false;
    try {
      final declaredLength = _contentLength(response);
      if (declaredLength != null && declaredLength > maximumBytes) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.responseTooLarge,
          'The manga response exceeds the download size limit.',
        );
      }
      sink = partFile.openWrite(mode: FileMode.writeOnly);
      bodyStarted = true;
      await for (final chunk in response.body.timeout(receiveTimeout)) {
        operation._cancellation.throwIfCancelled();
        received += chunk.length;
        if (received > maximumBytes) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.responseTooLarge,
            'The manga response exceeds the download size limit.',
          );
        }
        sink.add(chunk);
        onProgress(received);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      operation._cancellation.throwIfCancelled();
      return received;
    } on TimeoutException {
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.httpFailure,
        'The manga server timed out.',
      );
    } finally {
      await sink?.close();
      if (bodyStarted) {
        response.release();
      } else {
        await response.discard();
      }
      if (operation.isCancelled && await partFile.exists()) {
        await partFile.delete();
      }
    }
  }

  Future<_DownloadedImage> _writeImageResponse({
    required MangaAcquisitionOperation operation,
    required MangaAcquisitionHttpResponse response,
    required File partFile,
    required int maximumBytes,
    required MangaArchiveImageType? expectedType,
    required void Function() onBodyStarted,
    required void Function(int receivedBytes) onProgress,
  }) async {
    IOSink? sink;
    var received = 0;
    final prefix = <int>[];
    try {
      final declaredLength = _contentLength(response);
      if (declaredLength != null && declaredLength > maximumBytes) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.responseTooLarge,
          'A manga page exceeds the per-page size limit.',
        );
      }
      sink = partFile.openWrite(mode: FileMode.writeOnly);
      onBodyStarted();
      await for (final chunk in response.body.timeout(receiveTimeout)) {
        operation._cancellation.throwIfCancelled();
        received += chunk.length;
        if (received > maximumBytes) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.responseTooLarge,
            'A manga page exceeds the per-page size limit.',
          );
        }
        if (prefix.length < 12) {
          final remaining = 12 - prefix.length;
          prefix.addAll(
            chunk.take(chunk.length < remaining ? chunk.length : remaining),
          );
        }
        sink.add(chunk);
        onProgress(received);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      operation._cancellation.throwIfCancelled();
      final type = detectMangaImageType(prefix);
      if (type == null || (expectedType != null && type != expectedType)) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.unsupportedContent,
          'A reading-order resource failed image validation.',
        );
      }
      if (received <= 0) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.unsupportedContent,
          'A manga page was empty.',
        );
      }
      final bytes = await partFile.readAsBytes();
      try {
        final image = inspectMangaImage(bytes);
        if (image.type != type) {
          throw const MangaImageValidationException(
            MangaImageValidationFailure.unsupported,
            'The manga page container changed during validation.',
          );
        }
      } on MangaImageValidationException {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.unsupportedContent,
          'A reading-order resource failed safe image validation.',
        );
      }
      final digest = sha256.convert(bytes).toString();
      return _DownloadedImage(type: type, byteLength: received, sha256: digest);
    } on TimeoutException {
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.httpFailure,
        'The manga server timed out.',
      );
    } finally {
      await sink?.close();
    }
  }

  Future<MangaAcquisitionHttpResponse> _openResponse(
    Uri initialUri,
    _CredentialCapability credentials,
    MangaAcquisitionCancellationToken cancellation,
  ) async {
    var current = requireMangaPublicHttpsUri(
      initialUri.toString(),
      field: 'Manga acquisition URL',
    );
    var sentCredentials = false;
    for (var redirects = 0; ; redirects++) {
      cancellation.throwIfCancelled();
      try {
        await _validateTarget(current);
      } catch (_) {
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.unsafeTarget,
          'The manga server is not a permitted public HTTPS target.',
        );
      }
      final useCredentials =
          credentials.origin != null &&
          _sameOrigin(credentials.origin!, current);
      final headers = useCredentials
          ? credentials.headers
          : const <String, String>{};
      sentCredentials |= headers.isNotEmpty;
      final response = await _transport.get(
        current,
        headers: headers,
        cancellation: cancellation,
      );
      if (_redirectStatuses.contains(response.statusCode)) {
        if (redirects >= 5) {
          await response.discard();
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.tooManyRedirects,
            'The manga server redirected too many times.',
          );
        }
        final location = response.header(HttpHeaders.locationHeader);
        await response.discard();
        if (location == null || location.trim().isEmpty) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.redirectRejected,
            'The manga server returned an invalid redirect.',
          );
        }
        final Uri redirected;
        try {
          redirected = resolveMangaPublicHttpsReference(
            current,
            location,
            field: 'Manga acquisition redirect',
          );
        } on FormatException {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.redirectRejected,
            'The manga server returned an unsafe redirect.',
          );
        }
        if (sentCredentials &&
            !_sameOrigin(current, redirected) &&
            !credentials.stripHeadersOnCrossOriginRedirect) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.redirectRejected,
            'An authenticated manga download cannot change origin.',
          );
        }
        current = redirected;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.discard();
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.httpFailure,
          'The manga server rejected the download request.',
        );
      }
      try {
        await _validateTarget(current);
      } catch (_) {
        await response.discard();
        throw const MangaAcquisitionException(
          MangaAcquisitionFailureCode.unsafeTarget,
          'The manga server is not a permitted public HTTPS target.',
        );
      }
      return response;
    }
  }

  Future<MangaReaderRequest?> _restoreCompletedRequest(
    MangaAcquisitionRequest request,
    MangaDownloadJob job,
  ) async {
    final pages = await _persistence.pages(request.jobId);
    if (pages.isEmpty ||
        job.pageCount != pages.length ||
        pages.length > maximumMangaArchivePages) {
      return null;
    }
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      if (page.pageIndex != index ||
          !await _storageRoots
              .resolvePage(
                MangaTrustedLocalPageResource(
                  area: MangaLocalStorageArea.downloadedPages,
                  relativePath: page.relativePath,
                ),
              )
              .exists()) {
        return null;
      }
    }
    return _readerRequest(request, pages);
  }

  MangaReaderRequest _readerRequest(
    MangaAcquisitionRequest request,
    List<MangaDownloadPage> pages,
  ) => MangaReaderRequest(
    sourceId: request.sourceId,
    publicationId: request.publicationId,
    chapterId: request.chapterId,
    seriesTitle: request.seriesTitle,
    chapterTitle: request.chapterTitle,
    chapterNumber: request.chapterNumber,
    initialPageIndex: request.initialPageIndex < pages.length
        ? request.initialPageIndex
        : 0,
    pages: <MangaReaderPage>[
      for (final page in pages)
        MangaReaderPage(
          id: sha256
              .convert('${request.jobId}:${page.pageIndex}'.codeUnits)
              .toString()
              .substring(0, 32),
          index: page.pageIndex,
          resource: MangaTrustedLocalPageResource(
            area: MangaLocalStorageArea.downloadedPages,
            relativePath: page.relativePath,
          ),
          pixelWidth: request.acquisition is MangaReadingOrderAcquisition
              ? (request.acquisition as MangaReadingOrderAcquisition)
                    .pages[page.pageIndex]
                    .pixelWidth
              : null,
          pixelHeight: request.acquisition is MangaReadingOrderAcquisition
              ? (request.acquisition as MangaReadingOrderAcquisition)
                    .pages[page.pageIndex]
                    .pixelHeight
              : null,
          isCover: request.acquisition is MangaReadingOrderAcquisition
              ? (request.acquisition as MangaReadingOrderAcquisition)
                    .pages[page.pageIndex]
                    .isCover
              : page.pageIndex == 0,
        ),
    ],
  );

  MangaReaderRequest _readerRequestFromStored(
    MangaDownloadJob job,
    List<MangaDownloadPage> pages,
  ) => MangaReaderRequest(
    sourceId: job.sourceId,
    publicationId: job.entryId,
    chapterId: job.chapterId,
    seriesTitle: job.seriesTitle,
    chapterTitle: job.chapterLabel,
    pages: <MangaReaderPage>[
      for (final page in pages)
        MangaReaderPage(
          id: sha256
              .convert('${job.id}:${page.pageIndex}'.codeUnits)
              .toString()
              .substring(0, 32),
          index: page.pageIndex,
          resource: MangaTrustedLocalPageResource(
            area: MangaLocalStorageArea.downloadedPages,
            relativePath: page.relativePath,
          ),
          isCover: page.pageIndex == 0,
        ),
    ],
  );

  Future<void> _resetPartialDownload(
    String jobId,
    Directory jobDirectory,
  ) async {
    await _persistence.clearPages(jobId);
    if (await jobDirectory.exists()) await jobDirectory.delete(recursive: true);
  }

  Future<void> _cleanupFailedDownload(
    String jobId,
    Directory jobDirectory,
  ) async {
    try {
      await _persistence.clearPages(jobId);
    } catch (_) {
      // Preserve the transfer failure; stale rows contain no URLs or secrets.
    }
    try {
      if (await jobDirectory.exists()) {
        await jobDirectory.delete(recursive: true);
      }
      final jobsDirectory = jobDirectory.parent;
      if (await jobsDirectory.exists() && await jobsDirectory.list().isEmpty) {
        await jobsDirectory.delete();
      }
    } on FileSystemException {
      // Cache maintenance can retry this app-owned directory later.
    }
  }

  Directory _ownedJobDirectory(String relativeDirectory) {
    final root = _storageRoots.downloadedPages.absolute;
    final directory = Directory(
      path.normalize(path.join(root.path, relativeDirectory)),
    ).absolute;
    if (!path.isWithin(root.path, directory.path)) {
      throw StateError('Manga download storage escaped its app-owned root.');
    }
    return directory;
  }

  String _relativeDownloadedPath(File file) {
    final root = _storageRoots.downloadedPages.absolute;
    final absolute = file.absolute;
    if (!path.isWithin(root.path, absolute.path)) {
      throw StateError('Manga page escaped its app-owned storage root.');
    }
    return path.relative(absolute.path, from: root.path).replaceAll('\\', '/');
  }
}

class _DownloadedImage {
  const _DownloadedImage({
    required this.type,
    required this.byteLength,
    required this.sha256,
  });

  final MangaArchiveImageType type;
  final int byteLength;
  final String sha256;
}

class _CredentialCapability {
  const _CredentialCapability({
    this.origin,
    this.headers = const <String, String>{},
    this.stripHeadersOnCrossOriginRedirect = false,
  });

  final Uri? origin;
  final Map<String, String> headers;
  final bool stripHeadersOnCrossOriginRedirect;
}

MangaDownloadJob _updatedJob(
  MangaDownloadJob value, {
  required MangaDownloadJobStatus status,
  int? pageCount,
  int? completedPages,
  int? receivedBytes,
  String? errorCode,
  String? errorMessage,
  required DateTime updatedAt,
}) => MangaDownloadJob(
  id: value.id,
  sourceId: value.sourceId,
  entryId: value.entryId,
  chapterId: value.chapterId,
  seriesTitle: value.seriesTitle,
  chapterLabel: value.chapterLabel,
  status: status,
  relativeDirectory: value.relativeDirectory,
  pageCount: pageCount ?? value.pageCount,
  completedPages: completedPages ?? value.completedPages,
  receivedBytes: receivedBytes ?? value.receivedBytes,
  manifestFingerprint: value.manifestFingerprint,
  queuePosition: value.queuePosition,
  retryCount: value.retryCount,
  errorCode: errorCode,
  errorMessage: errorMessage,
  createdAt: value.createdAt,
  updatedAt: updatedAt,
);

MangaArchiveImageType? _declaredImageType(String? contentType) {
  return switch (_normalizedMime(contentType)) {
    'image/jpeg' || 'image/jpg' => MangaArchiveImageType.jpeg,
    'image/png' => MangaArchiveImageType.png,
    'image/webp' => MangaArchiveImageType.webp,
    'image/gif' => MangaArchiveImageType.gif,
    _ => null,
  };
}

String? _normalizedMime(String? contentType) {
  if (contentType == null) return null;
  final value = contentType.split(';').first.trim().toLowerCase();
  return value.isEmpty ? null : value;
}

int? _contentLength(MangaAcquisitionHttpResponse response) {
  final raw = response.header(HttpHeaders.contentLengthHeader);
  if (raw == null) return null;
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed < 0) {
    throw const MangaAcquisitionException(
      MangaAcquisitionFailureCode.unsupportedContent,
      'The manga server returned an invalid content length.',
    );
  }
  return parsed;
}

String _jobRelativeDirectory(String jobId) =>
    'jobs/${sha256.convert(jobId.codeUnits).toString().substring(0, 32)}';

String _pageBase(int index) => (index + 1).toString().padLeft(4, '0');

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

bool _isInterruptedStatus(MangaDownloadJobStatus status) => switch (status) {
  MangaDownloadJobStatus.queued ||
  MangaDownloadJobStatus.resolving ||
  MangaDownloadJobStatus.downloading ||
  MangaDownloadJobStatus.paused => true,
  MangaDownloadJobStatus.completed ||
  MangaDownloadJobStatus.failed ||
  MangaDownloadJobStatus.cancelled ||
  MangaDownloadJobStatus.needsReauthorization => false,
};

bool _belongsToSourceTree(String candidate, String root) =>
    candidate == root || candidate.startsWith('$root.child.');

String _sourceId(String value) {
  final normalized = value.trim();
  if (!_sourceIdPattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, 'sourceId', 'Invalid manga source id.');
  }
  return normalized;
}

String _boundedValue(String value, String field, int maximum) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      normalized.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw ArgumentError.value(value, field, 'Invalid manga value.');
  }
  return normalized;
}

Map<String, String> _validatedEphemeralHeaders(Map<String, String> headers) {
  return _validatedEphemeralHeaderMap(headers, allowPageMetadata: false);
}

Map<String, String> _validatedEphemeralPageHeaders(
  Map<String, String> headers,
) {
  return _validatedEphemeralHeaderMap(headers, allowPageMetadata: true);
}

Map<String, String> _validatedEphemeralHeaderMap(
  Map<String, String> headers, {
  required bool allowPageMetadata,
}) {
  if (headers.length > 32) {
    throw const FormatException('Too many manga acquisition headers.');
  }
  final normalizedNames = <String>{};
  final safe = <String, String>{};
  var totalLength = 0;
  for (final entry in headers.entries) {
    final name = entry.key.trim();
    final lowerName = name.toLowerCase();
    final value = entry.value;
    final canonicalPageMetadata = allowPageMetadata
        ? switch (lowerName) {
            'origin' => canonicalMangaPageOriginHeader(value),
            'referer' => canonicalMangaPageRefererHeader(value),
            _ => value,
          }
        : value;
    if (!_acquisitionHeaderNamePattern.hasMatch(name) ||
        !(allowPageMetadata
            ? _allowedMangaPageHeader(lowerName)
            : _allowedAcquisitionCredentialHeader(lowerName)) ||
        canonicalPageMetadata == null ||
        !normalizedNames.add(lowerName) ||
        canonicalPageMetadata.length > 8192 ||
        canonicalPageMetadata.codeUnits.any(
          (unit) => unit < 0x20 || unit == 0x7f,
        )) {
      throw const FormatException('Invalid manga acquisition header.');
    }
    totalLength += name.length + canonicalPageMetadata.length;
    if (totalLength > 16 * 1024) {
      throw const FormatException('Manga acquisition headers are too large.');
    }
    safe[name] = canonicalPageMetadata;
  }
  return Map<String, String>.unmodifiable(safe);
}

bool _allowedAcquisitionCredentialHeader(String name) =>
    !_blockedAcquisitionHeaders.contains(name) &&
    !name.startsWith('proxy-') &&
    !name.startsWith('sec-');

bool _allowedMangaPageHeader(String name) {
  if (_blockedMangaPageHeaders.contains(name) ||
      name.startsWith('proxy-') ||
      name.startsWith('sec-')) {
    return false;
  }
  return true;
}

Future<Map<String, String>> _noCredentialHeaders(String _) async =>
    const <String, String>{};

Future<void> _cancelResponseBody(ResponseBody? body) async {
  if (body == null) return;
  final subscription = body.stream.listen((_) {});
  await subscription.cancel();
}

Map<String, String> _flattenResponseHeaders(Headers headers) {
  final flattened = <String, String>{};
  for (final name in headers.map.keys) {
    final value = headers.value(name);
    if (value != null) flattened[name] = value;
  }
  return flattened;
}

const Set<int> _redirectStatuses = <int>{301, 302, 303, 307, 308};
const Set<String> _blockedAcquisitionHeaders = <String>{
  'accept-encoding',
  'connection',
  'content-length',
  'cookie',
  'expect',
  'forwarded',
  'host',
  'origin',
  'referer',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'user-agent',
};
const Set<String> _blockedMangaPageHeaders = <String>{
  'accept-encoding',
  'connection',
  'content-length',
  'expect',
  'forwarded',
  'host',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};
final RegExp _sourceIdPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$',
);
final RegExp _acquisitionHeaderNamePattern = RegExp(
  r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]+$",
);
