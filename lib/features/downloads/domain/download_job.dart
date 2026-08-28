import 'dart:collection';

/// Transport used to materialize an offline episode.
///
/// Direct peer jobs are represented explicitly so a build without a durable
/// native torrent worker can fail safely instead of silently exposing the
/// viewer's public IP address.
enum DownloadTransport { https, directPeer }

enum DownloadJobStatus {
  queued,
  resolving,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
  unsupported,
}

extension DownloadJobStatusUi on DownloadJobStatus {
  bool get isActive =>
      this == DownloadJobStatus.resolving ||
      this == DownloadJobStatus.downloading;

  bool get isTerminal =>
      this == DownloadJobStatus.completed ||
      this == DownloadJobStatus.cancelled ||
      this == DownloadJobStatus.unsupported;

  bool get canPause =>
      this == DownloadJobStatus.queued ||
      this == DownloadJobStatus.resolving ||
      this == DownloadJobStatus.downloading;

  bool get canResume =>
      this == DownloadJobStatus.paused || this == DownloadJobStatus.failed;
}

/// Persisted unit of work for one offline episode.
///
/// This object intentionally contains no request headers, credentials, or
/// cookies. Debrid download links may be persisted in the app-private SQLite
/// database so an interrupted transfer can resume after process death, but
/// callers must never include [sourceUri] in diagnostics or exports.
class DownloadJob {
  DownloadJob({
    required this.id,
    required this.anilistMediaId,
    required this.episode,
    required this.seriesTitle,
    required this.sourceLabel,
    required this.transport,
    required this.status,
    required this.relativePath,
    required this.queuePosition,
    required this.createdAt,
    required this.updatedAt,
    this.malMediaId,
    this.episodeTitle,
    this.sourceUri,
    this.providerId,
    this.providerName,
    this.quality,
    this.audioLabel,
    this.mimeType,
    this.expectedBytes,
    this.receivedBytes = 0,
    this.speedBytesPerSecond = 0,
    this.retryCount = 0,
    this.errorCode,
    this.errorMessage,
    this.remoteTransferId,
  }) {
    if (id.trim().isEmpty || id.length > 160) {
      throw ArgumentError.value(id, 'id', 'must be a bounded identifier');
    }
    if (anilistMediaId <= 0 || episode <= 0) {
      throw ArgumentError('Media and episode identifiers must be positive.');
    }
    if (seriesTitle.trim().isEmpty || sourceLabel.trim().isEmpty) {
      throw ArgumentError('Series and source labels must not be empty.');
    }
    if (relativePath.trim().isEmpty) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    if (queuePosition < 0 || receivedBytes < 0 || speedBytesPerSecond < 0) {
      throw ArgumentError('Queue and transfer counters must not be negative.');
    }
    if (expectedBytes != null && expectedBytes! <= 0) {
      throw ArgumentError.value(expectedBytes, 'expectedBytes');
    }
    if (transport == DownloadTransport.https &&
        sourceUri != null &&
        sourceUri!.scheme.toLowerCase() != 'https') {
      throw ArgumentError.value(
        sourceUri,
        'sourceUri',
        'Persistent HTTP downloads require HTTPS.',
      );
    }
  }

  final String id;
  final int anilistMediaId;
  final int? malMediaId;
  final int episode;
  final String seriesTitle;
  final String? episodeTitle;
  final String sourceLabel;
  final DownloadTransport transport;
  final DownloadJobStatus status;
  final Uri? sourceUri;
  final String? providerId;
  final String? providerName;
  final String relativePath;
  final String? quality;
  final String? audioLabel;
  final String? mimeType;
  final int? expectedBytes;
  final int receivedBytes;
  final int speedBytesPerSecond;
  final int retryCount;
  final String? errorCode;
  final String? errorMessage;
  final String? remoteTransferId;
  final int queuePosition;
  final DateTime createdAt;
  final DateTime updatedAt;

  double? get progress {
    final total = expectedBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1).toDouble();
  }

  String get partRelativePath => '$relativePath.part';

  DownloadJob copyWith({
    DownloadJobStatus? status,
    Uri? sourceUri,
    bool clearSourceUri = false,
    String? mimeType,
    bool clearMimeType = false,
    int? expectedBytes,
    bool clearExpectedBytes = false,
    int? receivedBytes,
    int? speedBytesPerSecond,
    int? retryCount,
    String? errorCode,
    bool clearErrorCode = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? remoteTransferId,
    bool clearRemoteTransferId = false,
    int? queuePosition,
    DateTime? updatedAt,
  }) => DownloadJob(
    id: id,
    anilistMediaId: anilistMediaId,
    malMediaId: malMediaId,
    episode: episode,
    seriesTitle: seriesTitle,
    episodeTitle: episodeTitle,
    sourceLabel: sourceLabel,
    transport: transport,
    status: status ?? this.status,
    sourceUri: clearSourceUri ? null : sourceUri ?? this.sourceUri,
    providerId: providerId,
    providerName: providerName,
    relativePath: relativePath,
    quality: quality,
    audioLabel: audioLabel,
    mimeType: clearMimeType ? null : mimeType ?? this.mimeType,
    expectedBytes: clearExpectedBytes
        ? null
        : expectedBytes ?? this.expectedBytes,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    retryCount: retryCount ?? this.retryCount,
    errorCode: clearErrorCode ? null : errorCode ?? this.errorCode,
    errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
    remoteTransferId: clearRemoteTransferId
        ? null
        : remoteTransferId ?? this.remoteTransferId,
    queuePosition: queuePosition ?? this.queuePosition,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  DownloadJob transition(
    DownloadJobStatus next, {
    DateTime? at,
    String? errorCode,
    String? errorMessage,
  }) {
    if (next != status && !_allowedTransitions[status]!.contains(next)) {
      throw StateError('Invalid download transition: $status -> $next');
    }
    return copyWith(
      status: next,
      updatedAt: at ?? DateTime.now().toUtc(),
      speedBytesPerSecond: next == DownloadJobStatus.downloading
          ? speedBytesPerSecond
          : 0,
      errorCode: errorCode,
      clearErrorCode: errorCode == null,
      errorMessage: errorMessage,
      clearErrorMessage: errorMessage == null,
    );
  }

  Map<String, Object?> toDatabase() => {
    'id': id,
    'anilist_media_id': anilistMediaId,
    'mal_media_id': malMediaId,
    'episode': episode,
    'series_title': seriesTitle,
    'episode_title': episodeTitle,
    'source_label': sourceLabel,
    'transport': transport.name,
    'status': status.name,
    'source_uri': sourceUri?.toString(),
    'provider_id': providerId,
    'provider_name': providerName,
    'relative_path': relativePath,
    'quality': quality,
    'audio_label': audioLabel,
    'mime_type': mimeType,
    'expected_bytes': expectedBytes,
    'received_bytes': receivedBytes,
    'speed_bps': speedBytesPerSecond,
    'retry_count': retryCount,
    'error_code': errorCode,
    'error_message': errorMessage,
    'remote_transfer_id': remoteTransferId,
    'queue_position': queuePosition,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory DownloadJob.fromDatabase(Map<String, Object?> row) {
    T enumValue<T extends Enum>(List<T> values, Object? raw, String field) {
      final name = raw as String?;
      for (final value in values) {
        if (value.name == name) return value;
      }
      throw FormatException('Unknown $field: $name');
    }

    final sourceValue = row['source_uri'] as String?;
    return DownloadJob(
      id: row['id']! as String,
      anilistMediaId: (row['anilist_media_id']! as num).toInt(),
      malMediaId: (row['mal_media_id'] as num?)?.toInt(),
      episode: (row['episode']! as num).toInt(),
      seriesTitle: row['series_title']! as String,
      episodeTitle: row['episode_title'] as String?,
      sourceLabel: row['source_label']! as String,
      transport: enumValue(
        DownloadTransport.values,
        row['transport'],
        'transport',
      ),
      status: enumValue(DownloadJobStatus.values, row['status'], 'status'),
      sourceUri: sourceValue == null ? null : Uri.parse(sourceValue),
      providerId: row['provider_id'] as String?,
      providerName: row['provider_name'] as String?,
      relativePath: row['relative_path']! as String,
      quality: row['quality'] as String?,
      audioLabel: row['audio_label'] as String?,
      mimeType: row['mime_type'] as String?,
      expectedBytes: (row['expected_bytes'] as num?)?.toInt(),
      receivedBytes: (row['received_bytes'] as num?)?.toInt() ?? 0,
      speedBytesPerSecond: (row['speed_bps'] as num?)?.toInt() ?? 0,
      retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
      errorCode: row['error_code'] as String?,
      errorMessage: row['error_message'] as String?,
      remoteTransferId: row['remote_transfer_id'] as String?,
      queuePosition: (row['queue_position']! as num).toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at']! as num).toInt(),
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at']! as num).toInt(),
        isUtc: true,
      ),
    );
  }
}

const Map<DownloadJobStatus, Set<DownloadJobStatus>> _allowedTransitions = {
  DownloadJobStatus.queued: {
    DownloadJobStatus.resolving,
    DownloadJobStatus.downloading,
    DownloadJobStatus.paused,
    DownloadJobStatus.cancelled,
    DownloadJobStatus.unsupported,
    DownloadJobStatus.failed,
  },
  DownloadJobStatus.resolving: {
    DownloadJobStatus.queued,
    DownloadJobStatus.downloading,
    DownloadJobStatus.paused,
    DownloadJobStatus.failed,
    DownloadJobStatus.cancelled,
    DownloadJobStatus.unsupported,
  },
  DownloadJobStatus.downloading: {
    DownloadJobStatus.queued,
    DownloadJobStatus.paused,
    DownloadJobStatus.completed,
    DownloadJobStatus.failed,
    DownloadJobStatus.cancelled,
  },
  DownloadJobStatus.paused: {
    DownloadJobStatus.queued,
    DownloadJobStatus.cancelled,
  },
  DownloadJobStatus.failed: {
    DownloadJobStatus.queued,
    DownloadJobStatus.cancelled,
  },
  DownloadJobStatus.completed: {},
  DownloadJobStatus.cancelled: {},
  DownloadJobStatus.unsupported: {DownloadJobStatus.cancelled},
};

/// Input accepted by the persistent queue.
class OfflineDownloadRequest {
  OfflineDownloadRequest({
    required this.anilistMediaId,
    required this.episode,
    required this.seriesTitle,
    required this.sourceLabel,
    required this.transport,
    this.malMediaId,
    this.episodeTitle,
    this.sourceUri,
    this.providerId,
    this.providerName,
    this.quality,
    this.audioLabel,
    this.mimeType,
    this.expectedBytes,
    this.fileExtension,
    this.directPeerCapability,
    Map<String, String> requestHeaders = const {},
  }) : requestHeaders = UnmodifiableMapView(Map.of(requestHeaders)) {
    if (transport == DownloadTransport.https) {
      final uri = sourceUri;
      if (uri == null ||
          uri.scheme.toLowerCase() != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.fragment.isNotEmpty) {
        throw ArgumentError.value(
          uri,
          'sourceUri',
          'HTTP download sources must be public HTTPS URLs.',
        );
      }
    }
    for (final entry in requestHeaders.entries) {
      if (!_headerName.hasMatch(entry.key) ||
          entry.value.contains(RegExp(r'[\r\n]'))) {
        throw ArgumentError.value(entry.key, 'requestHeaders');
      }
    }
  }

  final int anilistMediaId;
  final int? malMediaId;
  final int episode;
  final String seriesTitle;
  final String? episodeTitle;
  final String sourceLabel;
  final DownloadTransport transport;
  final Uri? sourceUri;
  final String? providerId;
  final String? providerName;
  final String? quality;
  final String? audioLabel;
  final String? mimeType;
  final int? expectedBytes;
  final String? fileExtension;

  /// Process-local native capability used by an injected direct-peer worker.
  /// It is intentionally never serialized. Restored peer jobs must be
  /// re-resolved before they can retry.
  final Object? directPeerCapability;

  /// Ephemeral only. These values are never written to SQLite.
  final Map<String, String> requestHeaders;
}

final RegExp _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
