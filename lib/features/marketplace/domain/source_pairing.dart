enum SourcePairingPollStatus { pending, submitted, expired }

class SourcePairingSession {
  const SourcePairingSession({
    required this.pairingId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresAt,
    required this.pollInterval,
  });

  final String pairingId;
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Uri verificationUriComplete;
  final DateTime expiresAt;
  final Duration pollInterval;
}

class SourcePairingPayload {
  const SourcePairingPayload({
    this.repositoryUrls = const [],
    this.manifestUrls = const [],
  });

  final List<String> repositoryUrls;
  final List<String> manifestUrls;
}

class SourcePairingPollResult {
  const SourcePairingPollResult({required this.status, this.payload});

  final SourcePairingPollStatus status;
  final SourcePairingPayload? payload;
}

enum SourcePairingStage {
  idle,
  starting,
  waiting,
  validating,
  completed,
  expired,
  failed,
  stopped,
}

class SourceImportSummary {
  const SourceImportSummary({
    this.repositoriesAdded = 0,
    this.manifestsAdded = 0,
    this.errors = const [],
  });

  final int repositoriesAdded;
  final int manifestsAdded;
  final List<String> errors;

  int get totalAdded => repositoriesAdded + manifestsAdded;

  String get message {
    final added = <String>[];
    if (repositoriesAdded > 0) {
      added.add(
        '$repositoriesAdded ${repositoriesAdded == 1 ? 'repository' : 'repositories'}',
      );
    }
    if (manifestsAdded > 0) {
      added.add(
        '$manifestsAdded torrent ${manifestsAdded == 1 ? 'manifest' : 'manifests'}',
      );
    }
    final success = added.isEmpty
        ? 'No sources were added.'
        : 'Added ${added.join(' and ')}.';
    if (errors.isEmpty) return success;
    return '$success ${errors.length} ${errors.length == 1 ? 'item was' : 'items were'} rejected.';
  }
}

class SourcePairingState {
  const SourcePairingState({
    this.stage = SourcePairingStage.idle,
    this.session,
    this.summary,
    this.message,
    this.canRetryImport = false,
    this.canRetryAcknowledgement = false,
  });

  final SourcePairingStage stage;
  final SourcePairingSession? session;
  final SourceImportSummary? summary;
  final String? message;
  final bool canRetryImport;
  final bool canRetryAcknowledgement;
}
