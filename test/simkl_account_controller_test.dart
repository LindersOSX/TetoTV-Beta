import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/data/simkl_broker_capability_client.dart';
import 'package:anime_tv/features/settings/application/simkl_account_controller.dart';
import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'keeps SIMKL unavailable when the broker capability is absent',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      var probes = 0;
      final controller = SimklAccountController(
        storage,
        capabilityProbe: (_) async {
          probes++;
          return null;
        },
        profileLoader: ({required accessToken, required clientId}) =>
            throw UnimplementedError(),
      );

      await controller.load();

      expect(controller.state.isAvailable, isFalse);
      expect(controller.state.isConnected, isFalse);
      expect(controller.state.hasSavedCredentials, isFalse);
      expect(controller.state.error, contains('not configured'));
      expect(probes, 1);
    },
  );

  test(
    'shows SIMKL as available only after a successful capability probe',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final controller = SimklAccountController(
        storage,
        capabilityProbe: (_) async => SimklBrokerCapability(
          clientId: 'public-client-id',
          callbackUri: Uri.parse(
            'https://auth.example.test/oauth/simkl/callback',
          ),
        ),
        profileLoader: ({required accessToken, required clientId}) =>
            throw UnimplementedError(),
      );

      await controller.load();

      expect(controller.state.isAvailable, isTrue);
      expect(controller.state.isConnected, isFalse);
      expect(controller.state.error, isNull);
    },
  );

  test(
    'validates a stored SIMKL account without exposing credentials',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: 'https://auth.example.test',
        simklAccessTokenStorageKey: 'private-simkl-token',
        simklClientIdStorageKey: 'public-client-id',
      });
      final controller = SimklAccountController(
        storage,
        capabilityProbe: (_) async => null,
        profileLoader: ({required accessToken, required clientId}) async {
          expect(accessToken, 'private-simkl-token');
          expect(clientId, 'public-client-id');
          return const SimklUserProfile(
            username: 'TetoFan',
            avatarUrl: 'https://simkl.in/avatars/12/user.jpg',
            plan: SimklAccountPlan.vip,
          );
        },
      );

      await controller.load();

      expect(controller.state.isConnected, isTrue);
      expect(controller.state.username, 'TetoFan');
      expect(controller.state.avatarUrl, contains('simkl.in'));
      expect(
        controller.state.toString(),
        isNot(contains('private-simkl-token')),
      );
      expect(controller.state.toString(), isNot(contains('public-client-id')));
    },
  );

  test(
    'phone setup validation bypasses the persistent account profile loader',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      var persistentProfileLoads = 0;
      var validationProfileLoads = 0;
      final controller = SimklAccountController(
        storage,
        capabilityProbe: (_) async => SimklBrokerCapability(
          clientId: 'public-client-id',
          callbackUri: Uri.parse(
            'https://auth.example.test/oauth/simkl/callback',
          ),
        ),
        profileLoader: ({required accessToken, required clientId}) async {
          persistentProfileLoads++;
          throw StateError('Persistent session must not validate setup.');
        },
        validationProfileLoader:
            ({required accessToken, required clientId}) async {
              validationProfileLoads++;
              expect(accessToken, 'private-simkl-token');
              expect(clientId, 'public-client-id');
              return const SimklUserProfile(
                username: 'Validated User',
                plan: SimklAccountPlan.free,
              );
            },
      );

      expect(await controller.validateToken(' private-simkl-token '), isTrue);
      expect(validationProfileLoads, 1);
      expect(persistentProfileLoads, 0);
    },
  );

  test('disconnect removes the complete SIMKL credential pair', () async {
    FlutterSecureStorage.setMockInitialValues({
      authBrokerUrlStorageKey: 'https://auth.example.test',
      simklAccessTokenStorageKey: 'private-simkl-token',
      simklClientIdStorageKey: 'public-client-id',
    });
    final controller = SimklAccountController(
      storage,
      capabilityProbe: (_) async => null,
      profileLoader: ({required accessToken, required clientId}) async =>
          const SimklUserProfile(
            username: 'TetoFan',
            plan: SimklAccountPlan.free,
          ),
    );

    await controller.load();
    await controller.disconnect();

    expect(await storage.read(key: simklAccessTokenStorageKey), isNull);
    expect(await storage.read(key: simklClientIdStorageKey), isNull);
    expect(controller.state.isConnected, isFalse);
    expect(controller.state.hasSavedCredentials, isFalse);
  });

  test('recovers missing public client metadata from the companion', () async {
    FlutterSecureStorage.setMockInitialValues({
      authBrokerUrlStorageKey: 'https://auth.example.test',
      simklAccessTokenStorageKey: 'private-simkl-token',
    });
    final controller = SimklAccountController(
      storage,
      capabilityProbe: (_) async => SimklBrokerCapability(
        clientId: 'recovered-public-id',
        callbackUri: Uri.parse(
          'https://auth.example.test/oauth/simkl/callback',
        ),
      ),
      profileLoader: ({required accessToken, required clientId}) async {
        expect(clientId, 'recovered-public-id');
        return const SimklUserProfile(
          username: 'Recovered',
          plan: SimklAccountPlan.unknown,
        );
      },
    );

    await controller.load();

    expect(controller.state.username, 'Recovered');
    expect(
      await storage.read(key: simklClientIdStorageKey),
      'recovered-public-id',
    );
  });
}
