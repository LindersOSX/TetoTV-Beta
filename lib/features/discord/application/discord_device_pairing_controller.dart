import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/discord/data/discord_device_pairing_client.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef DiscordDeviceTokenAcceptor =
    Future<void> Function(DiscordTokenBundle token);

final discordDevicePairingControllerProvider =
    StateNotifierProvider.autoDispose<
      DiscordDevicePairingController,
      DiscordDevicePairingState
    >((ref) {
      return DiscordDevicePairingController(
        DiscordDeviceAuthClient(),
        ref.read(discordPresenceControllerProvider.notifier).acceptLinkedToken,
      );
    });

class DiscordDevicePairingController
    extends StateNotifier<DiscordDevicePairingState> {
  DiscordDevicePairingController(
    this._client,
    this._acceptToken, {
    this.slowDownPenalty = const Duration(seconds: 5),
  }) : super(const DiscordDevicePairingState());

  final DiscordDevicePairingApi _client;
  final DiscordDeviceTokenAcceptor _acceptToken;
  final Duration slowDownPenalty;
  Timer? _pollTimer;
  Duration? _effectivePollInterval;
  int _generation = 0;
  int? _pollingGeneration;
  int _consecutivePollFailures = 0;
  bool _tokenDelivered = false;

  Future<void> start() async {
    final previousSession = state.session;
    final generation = ++_generation;
    _pollTimer?.cancel();
    _pollingGeneration = null;
    _effectivePollInterval = null;
    _consecutivePollFailures = 0;
    _tokenDelivered = false;
    if (previousSession != null) {
      unawaited(_cancelBestEffort(previousSession));
    }
    state = const DiscordDevicePairingState(
      stage: DiscordDevicePairingStage.starting,
    );
    try {
      final session = await _client.createSession();
      if (!mounted || generation != _generation) {
        unawaited(_cancelBestEffort(session));
        return;
      }
      state = DiscordDevicePairingState(
        stage: DiscordDevicePairingStage.waiting,
        session: session,
      );
      _effectivePollInterval = session.pollInterval;
      _schedulePoll(_effectivePollInterval!);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      state = DiscordDevicePairingState(
        stage: DiscordDevicePairingStage.failed,
        message: _safeMessage(error),
      );
    }
  }

  Future<void> pollNow() async {
    if (!mounted || state.stage != DiscordDevicePairingStage.waiting) return;
    final session = state.session;
    if (session == null) return;
    final generation = _generation;
    if (_pollingGeneration == generation) return;
    if (!session.expiresAt.isAfter(DateTime.now())) {
      _expire(session);
      return;
    }
    _pollingGeneration = generation;
    try {
      final result = await _client.poll(session);
      if (!mounted || generation != _generation) return;
      _consecutivePollFailures = 0;
      switch (result.status) {
        case DiscordDevicePairingPollStatus.pending:
          _schedulePoll(_effectivePollInterval ?? session.pollInterval);
          return;
        case DiscordDevicePairingPollStatus.slowDown:
          final increased =
              (_effectivePollInterval ?? session.pollInterval) +
              slowDownPenalty;
          _effectivePollInterval = increased > const Duration(seconds: 60)
              ? const Duration(seconds: 60)
              : increased;
          _schedulePoll(_effectivePollInterval!);
          return;
        case DiscordDevicePairingPollStatus.expired:
          _expire(session);
          return;
        case DiscordDevicePairingPollStatus.authorized:
          final token = result.token;
          if (token == null || _tokenDelivered) {
            throw const DiscordDeviceAuthException(
              'Discord did not return a usable account token.',
            );
          }
          _pollTimer?.cancel();
          state = DiscordDevicePairingState(
            stage: DiscordDevicePairingStage.linking,
            session: session,
          );
          // Mark delivery before crossing the async storage boundary. A late
          // timer or resumed lifecycle callback must never store/connect twice.
          _tokenDelivered = true;
          await _acceptToken(token);
          if (!mounted || generation != _generation) return;
          state = DiscordDevicePairingState(
            stage: DiscordDevicePairingStage.completed,
            session: session,
          );
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _consecutivePollFailures++;
      if (_tokenDelivered || _consecutivePollFailures >= 3) {
        _pollTimer?.cancel();
        state = DiscordDevicePairingState(
          stage: DiscordDevicePairingStage.failed,
          session: session,
          message: _tokenDelivered
              ? 'Discord approved the link, but TetoTV could not save it securely. Create a new code and try again.'
              : _safeMessage(error),
        );
      } else {
        _schedulePoll(_effectivePollInterval ?? session.pollInterval);
      }
    } finally {
      if (_pollingGeneration == generation) {
        _pollingGeneration = null;
      }
    }
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () => unawaited(pollNow()));
  }

  void _expire(DiscordDevicePairingSession session) {
    _pollTimer?.cancel();
    state = DiscordDevicePairingState(
      stage: DiscordDevicePairingStage.expired,
      session: session,
      message: 'The one-time Discord code expired. Create a new code.',
    );
  }

  void stop() {
    if (!mounted) return;
    final session = state.session;
    _generation++;
    _pollTimer?.cancel();
    _pollingGeneration = null;
    _effectivePollInterval = null;
    if (session != null && !_tokenDelivered) {
      unawaited(_cancelBestEffort(session));
    }
    if (state.stage != DiscordDevicePairingStage.completed &&
        state.stage != DiscordDevicePairingStage.failed) {
      state = const DiscordDevicePairingState(
        stage: DiscordDevicePairingStage.stopped,
      );
    }
  }

  Future<void> _cancelBestEffort(DiscordDevicePairingSession session) async {
    try {
      await _client.cancel(session);
    } catch (_) {
      // Discord independently expires abandoned device codes.
    }
  }

  @override
  void dispose() {
    final session = state.session;
    _generation++;
    _pollTimer?.cancel();
    _pollingGeneration = null;
    _effectivePollInterval = null;
    if (session != null && !_tokenDelivered) {
      unawaited(_cancelBestEffort(session));
    }
    super.dispose();
  }
}

String _safeMessage(Object error) {
  if (error is DiscordDeviceAuthException) return error.message;
  return 'Discord linking could not be completed. Check the connection and try again.';
}
