import 'package:anime_tv/core/platform/android_tv_bridge.dart';

enum DiscordDevicePairingPollStatus { pending, slowDown, authorized, expired }

enum DiscordDevicePairingStage {
  idle,
  starting,
  waiting,
  linking,
  completed,
  expired,
  failed,
  stopped,
}

class DiscordDevicePairingSession {
  const DiscordDevicePairingSession({
    required this.pairingId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresAt,
    required this.pollInterval,
  });

  final String pairingId;

  /// Private, high-entropy proof used only when polling or cancelling.
  ///
  /// UI must display [userCode], never this value.
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Uri verificationUriComplete;
  final DateTime expiresAt;
  final Duration pollInterval;

  /// Deliberately omits the private device code and public confirmation code.
  @override
  String toString() =>
      'DiscordDevicePairingSession(pairingId: $pairingId, '
      'expiresAt: $expiresAt, pollInterval: $pollInterval)';
}

class DiscordDevicePairingPollResult {
  const DiscordDevicePairingPollResult({required this.status, this.token});

  final DiscordDevicePairingPollStatus status;
  final DiscordTokenBundle? token;
}

class DiscordDevicePairingState {
  const DiscordDevicePairingState({
    this.stage = DiscordDevicePairingStage.idle,
    this.session,
    this.message,
  });

  final DiscordDevicePairingStage stage;
  final DiscordDevicePairingSession? session;
  final String? message;
}
