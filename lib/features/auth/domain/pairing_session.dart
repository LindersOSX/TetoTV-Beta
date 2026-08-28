enum PairingStatus { pending, authorized, expired }

class PairingSession {
  const PairingSession({
    required this.pairingId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresAt,
    required this.pollInterval,
    this.status = PairingStatus.pending,
  });

  final String pairingId;
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final DateTime expiresAt;
  final Duration pollInterval;
  final PairingStatus status;

  PairingSession copyWith({PairingStatus? status}) {
    return PairingSession(
      pairingId: pairingId,
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      verificationUriComplete: verificationUriComplete,
      expiresAt: expiresAt,
      pollInterval: pollInterval,
      status: status ?? this.status,
    );
  }
}

class PairingPollResult {
  const PairingPollResult({
    required this.status,
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final PairingStatus status;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
}

class TrackingTokenSet {
  const TrackingTokenSet({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
}
