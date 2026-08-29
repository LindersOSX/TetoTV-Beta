import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/application/discord_device_pairing_controller.dart';
import 'package:anime_tv/features/discord/data/discord_device_pairing_client.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:anime_tv/features/discord/domain/discord_minimum_age_confirmation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const confirmation = DiscordMinimumAgeConfirmation.current();

  test(
    'does not create a device code before age eligibility is confirmed',
    () async {
      final client = _FakePairingApi(
        session: _session(pollInterval: const Duration(hours: 1)),
      );
      final controller = DiscordDevicePairingController(
        client,
        (_, _) async {},
      );
      addTearDown(controller.dispose);

      await controller.start(
        const DiscordMinimumAgeConfirmation(version: 1, confirmed: false),
      );

      expect(client.createCalls, 0);
      expect(controller.state.stage, DiscordDevicePairingStage.failed);
      expect(controller.state.message, contains('minimum age'));
    },
  );

  test(
    'slow_down persists for pending polls instead of reverting cadence',
    () async {
      final client = _FakePairingApi(
        session: _session(pollInterval: const Duration(milliseconds: 15)),
        results: const [
          DiscordDevicePairingPollResult(
            status: DiscordDevicePairingPollStatus.slowDown,
          ),
          DiscordDevicePairingPollResult(
            status: DiscordDevicePairingPollStatus.pending,
          ),
          DiscordDevicePairingPollResult(
            status: DiscordDevicePairingPollStatus.pending,
          ),
        ],
      );
      final controller = DiscordDevicePairingController(
        client,
        (_, _) async {},
        slowDownPenalty: const Duration(milliseconds: 80),
      );
      addTearDown(controller.dispose);
      await controller.start(confirmation);

      await controller.pollNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.pollCalls, 1);

      await _waitFor(() => client.pollCalls >= 2);
      final firstGap = client.pollTimes[1].difference(client.pollTimes[0]);
      expect(firstGap, greaterThanOrEqualTo(const Duration(milliseconds: 75)));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.pollCalls, 2);
      await _waitFor(() => client.pollCalls >= 3);
      final secondGap = client.pollTimes[2].difference(client.pollTimes[1]);
      expect(secondGap, greaterThanOrEqualTo(const Duration(milliseconds: 75)));
    },
  );

  test('three consecutive transient failures end polling safely', () async {
    const secret = 'private-device-code-that-must-not-escape';
    final client = _FakePairingApi(
      session: _session(pollInterval: const Duration(hours: 1)),
      results: [StateError(secret), StateError(secret), StateError(secret)],
    );
    final controller = DiscordDevicePairingController(client, (_, _) async {});
    addTearDown(controller.dispose);
    await controller.start(confirmation);

    await controller.pollNow();
    expect(controller.state.stage, DiscordDevicePairingStage.waiting);
    await controller.pollNow();
    expect(controller.state.stage, DiscordDevicePairingStage.waiting);
    await controller.pollNow();

    expect(client.pollCalls, 3);
    expect(controller.state.stage, DiscordDevicePairingStage.failed);
    expect(controller.state.message, isNot(contains(secret)));
  });

  test('stop cancels locally and ignores a late authorized response', () async {
    final pendingPoll = Completer<DiscordDevicePairingPollResult>();
    final client = _FakePairingApi(
      session: _session(pollInterval: const Duration(hours: 1)),
      pollCompleter: pendingPoll,
    );
    var accepted = 0;
    final controller = DiscordDevicePairingController(client, (_, _) async {
      accepted++;
    });
    addTearDown(controller.dispose);
    await controller.start(confirmation);
    final polling = controller.pollNow();

    controller.stop();
    await _flush();
    expect(client.cancelCalls, 1);
    expect(controller.state.stage, DiscordDevicePairingStage.stopped);

    pendingPoll.complete(
      DiscordDevicePairingPollResult(
        status: DiscordDevicePairingPollStatus.authorized,
        token: _deviceToken(),
      ),
    );
    await polling;
    expect(accepted, 0);
    expect(controller.state.stage, DiscordDevicePairingStage.stopped);
  });

  test(
    'dispose cancels the session and ignores late poll completion',
    () async {
      final pendingPoll = Completer<DiscordDevicePairingPollResult>();
      final client = _FakePairingApi(
        session: _session(pollInterval: const Duration(hours: 1)),
        pollCompleter: pendingPoll,
      );
      var accepted = 0;
      final controller = DiscordDevicePairingController(client, (_, _) async {
        accepted++;
      });
      await controller.start(confirmation);
      final polling = controller.pollNow();

      controller.dispose();
      await _flush();
      expect(client.cancelCalls, 1);

      pendingPoll.complete(
        DiscordDevicePairingPollResult(
          status: DiscordDevicePairingPollStatus.authorized,
          token: _deviceToken(),
        ),
      );
      await polling;
      expect(accepted, 0);
    },
  );

  test(
    'concurrent lifecycle polls deliver an approved token only once',
    () async {
      final pendingPoll = Completer<DiscordDevicePairingPollResult>();
      final client = _FakePairingApi(
        session: _session(pollInterval: const Duration(hours: 1)),
        pollCompleter: pendingPoll,
      );
      var accepted = 0;
      final controller = DiscordDevicePairingController(client, (_, _) async {
        accepted++;
      });
      addTearDown(controller.dispose);
      await controller.start(confirmation);

      final first = controller.pollNow();
      final second = controller.pollNow();
      expect(client.pollCalls, 1);
      pendingPoll.complete(
        DiscordDevicePairingPollResult(
          status: DiscordDevicePairingPollStatus.authorized,
          token: _deviceToken(),
        ),
      );
      await Future.wait([first, second]);

      expect(accepted, 1);
      expect(controller.state.stage, DiscordDevicePairingStage.completed);
    },
  );
}

class _FakePairingApi implements DiscordDevicePairingApi {
  _FakePairingApi({
    required this.session,
    this.results = const [],
    this.pollCompleter,
  });

  final DiscordDevicePairingSession session;
  final List<Object> results;
  final Completer<DiscordDevicePairingPollResult>? pollCompleter;
  int pollCalls = 0;
  int createCalls = 0;
  int cancelCalls = 0;
  final List<DateTime> pollTimes = [];

  @override
  Future<DiscordDevicePairingSession> createSession() async {
    createCalls++;
    return session;
  }

  @override
  Future<DiscordDevicePairingPollResult> poll(
    DiscordDevicePairingSession session,
  ) async {
    pollTimes.add(DateTime.now());
    final index = pollCalls++;
    if (pollCompleter != null) return pollCompleter!.future;
    if (index >= results.length) {
      return const DiscordDevicePairingPollResult(
        status: DiscordDevicePairingPollStatus.pending,
      );
    }
    final result = results[index];
    if (result is DiscordDevicePairingPollResult) return result;
    throw result;
  }

  @override
  Future<void> cancel(DiscordDevicePairingSession session) async {
    cancelCalls++;
  }
}

DiscordDevicePairingSession _session({required Duration pollInterval}) =>
    DiscordDevicePairingSession(
      pairingId: 'discord-device',
      deviceCode: 'd' * 48,
      userCode: 'ABCD-EFGH',
      verificationUri: Uri.parse('https://discord.com/activate'),
      verificationUriComplete: Uri.parse(
        'https://discord.com/activate?user_code=ABCD-EFGH',
      ),
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      pollInterval: pollInterval,
    );

DiscordTokenBundle _deviceToken() => DiscordTokenBundle(
  accessToken: 'a' * 48,
  refreshToken: 'r' * 48,
  tokenType: 1,
  expiresAt: DateTime.now().add(const Duration(days: 7)),
  scopes: 'openid sdk.social_layer_presence',
);

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous polling.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);
