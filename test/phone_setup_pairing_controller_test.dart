import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:anime_tv/features/settings/application/all_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/phone_setup_bundle_importer.dart';
import 'package:anime_tv/features/settings/application/phone_setup_pairing_controller.dart';
import 'package:anime_tv/features/settings/application/premiumize_settings_controller.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/torbox_settings_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/settings/data/phone_setup_crypto.dart';
import 'package:anime_tv/features/settings/data/phone_setup_pairing_client.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/failure_injecting_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  group('PhoneSetupPairingController lifecycle', () {
    test(
      'creates, securely persists, polls, and exposes review before apply',
      () async {
        final api = _FakeApi()
          ..pollResults.add(
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.submitted,
              revision: 1,
              envelope: _envelope(),
            ),
          );
        final crypto = _FakeCrypto(_emptyBundle());
        final importer = _ImporterFixture();
        var setupCompleteCalls = 0;
        final controller = PhoneSetupPairingController(
          storage,
          api,
          crypto,
          importer.importer,
          () async => setupCompleteCalls++,
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(
          () => controller.state.stage == PhoneSetupViewStage.review,
        );

        expect(api.ensureReadyCalls, 1);
        expect(api.createCalls, 1);
        expect(api.pollCalls, 1);
        expect(crypto.decryptCalls, 1);
        expect(controller.state.bundle, isNotNull);
        expect(controller.state.revision, 1);
        expect(setupCompleteCalls, 0);
        final saved = await storage.read(key: phoneSetupSessionStorageKey);
        expect(saved, isNotNull);
        expect(saved, contains('pairing_1234567890'));
        expect(saved, isNot(contains('tracker-secret')));
      },
    );

    test(
      'applies only after review, acknowledges once, clears state, and completes setup',
      () async {
        final api = _FakeApi()
          ..pollResults.add(
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.submitted,
              revision: 3,
              envelope: _envelope(),
            ),
          );
        final importer = _ImporterFixture();
        var setupCompleteCalls = 0;
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_discordBundle()),
          importer.importer,
          () async => setupCompleteCalls++,
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(
          () => controller.state.stage == PhoneSetupViewStage.review,
        );
        expect(api.acknowledgements, isEmpty);

        await controller.applyReviewedSetup();

        expect(controller.state.stage, PhoneSetupViewStage.completed);
        expect(controller.state.result?.applied, isTrue);
        expect(controller.state.linkDiscordRequested, isTrue);
        expect(api.acknowledgements, [(revision: 3, applied: true)]);
        expect(setupCompleteCalls, 1);
        expect(await storage.read(key: phoneSetupSessionStorageKey), isNull);
      },
    );

    test(
      'version-two Discord authorization imports without a second link',
      () async {
        final expiresAt = DateTime.now().toUtc().add(const Duration(days: 7));
        final bundle = PhoneSetupBundle(
          protocolVersion: 2,
          preferences: const PhoneSetupPreferences(linkDiscord: true),
          repositoryUrls: const [],
          manifestUrls: const [],
          credentials: PhoneSetupCredentials(
            discord: PhoneSetupDiscordCredentials(
              accessToken: 'discord-access-token',
              refreshToken: 'discord-refresh-token',
              tokenType: 1,
              expiresAt: expiresAt,
              scopes: const ['openid', 'sdk.social_layer_presence'],
            ),
          ),
        );
        final api = _FakeApi()
          ..pollResults.add(
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.submitted,
              revision: 4,
              envelope: _envelope(),
            ),
          );
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(bundle),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(
          () => controller.state.stage == PhoneSetupViewStage.review,
        );
        await controller.applyReviewedSetup();

        expect(controller.state.stage, PhoneSetupViewStage.completed);
        expect(controller.state.result?.discordConnected, isTrue);
        expect(controller.state.linkDiscordRequested, isFalse);
        expect(importer.importedDiscord, hasLength(1));
        expect(
          importer.importedDiscord.single.accessToken,
          'discord-access-token',
        );
      },
    );

    test(
      'reject returns the revision to the phone without importing it',
      () async {
        final api = _FakeApi()
          ..pollResults.add(
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.submitted,
              revision: 5,
              envelope: _envelope(),
            ),
          );
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_emptyBundle()),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(
          () => controller.state.stage == PhoneSetupViewStage.review,
        );
        await controller.rejectReviewedSetup();

        expect(controller.state.stage, PhoneSetupViewStage.bound);
        expect(controller.state.bundle, isNull);
        expect(api.acknowledgements, [(revision: 5, applied: false)]);
        expect(await storage.read(key: phoneSetupSessionStorageKey), isNotNull);
      },
    );

    test(
      'invalid credential is rejected without leaking it or completing setup',
      () async {
        const secret = 'SUPER_SECRET_DO_NOT_LEAK';
        final bundle = PhoneSetupBundle(
          preferences: const PhoneSetupPreferences(
            debridProvider: 'realdebrid',
          ),
          repositoryUrls: const [],
          manifestUrls: const [],
          credentials: const PhoneSetupCredentials(debridCredential: secret),
        );
        final api = _FakeApi()
          ..pollResults.add(
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.submitted,
              revision: 7,
              envelope: _envelope(),
            ),
          );
        final importer = _ImporterFixture(debridIsValid: false);
        var setupCompleteCalls = 0;
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(bundle),
          importer.importer,
          () async => setupCompleteCalls++,
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(
          () => controller.state.stage == PhoneSetupViewStage.review,
        );
        await controller.applyReviewedSetup();

        expect(controller.state.stage, PhoneSetupViewStage.bound);
        expect(controller.state.bundle, isNull);
        expect(controller.state.message, isNot(contains(secret)));
        expect(api.acknowledgements, [(revision: 7, applied: false)]);
        expect(setupCompleteCalls, 0);
      },
    );

    test('retired Classic Layout phone payload imports as Automatic', () async {
      final importer = _ImporterFixture();
      addTearDown(importer.dispose);

      final result = await importer.importer.apply(
        const PhoneSetupBundle(
          preferences: PhoneSetupPreferences(interfaceMode: 'phone'),
          repositoryUrls: [],
          manifestUrls: [],
          credentials: PhoneSetupCredentials(),
        ),
      );

      expect(result.applied, isTrue);
      expect(
        importer.container.read(settingsPreferencesProvider).interfaceMode,
        InterfaceMode.automatic,
      );
    });

    test(
      'late Discord failure restores the previously linked Real-Debrid session',
      () async {
        final oldExpiry = DateTime.utc(2026, 8, 30).toIso8601String();
        FlutterSecureStorage.setMockInitialValues({
          realDebridTokenStorageKey: 'old-access',
          realDebridRefreshTokenStorageKey: 'old-refresh',
          realDebridClientIdStorageKey: 'old-client-id',
          realDebridClientSecretStorageKey: 'old-client-secret',
          realDebridAccessExpiryStorageKey: oldExpiry,
        });
        final importer = _ImporterFixture(discordImportFails: true);
        addTearDown(importer.dispose);
        await importer.container
            .read(realDebridSettingsControllerProvider.notifier)
            .load();
        final result = await importer.importer.apply(
          PhoneSetupBundle(
            protocolVersion: 2,
            preferences: const PhoneSetupPreferences(
              debridProvider: 'realdebrid',
              linkDiscord: true,
            ),
            repositoryUrls: const [],
            manifestUrls: const [],
            credentials: PhoneSetupCredentials(
              debrid: PhoneSetupDebridCredentials(
                provider: 'realdebrid',
                accessToken: 'new-access',
                refreshToken: 'new-refresh',
                clientId: 'new-client-id',
                clientSecret: 'new-client-secret',
                expiresAt: DateTime.utc(2026, 10, 1),
              ),
              discord: PhoneSetupDiscordCredentials(
                accessToken: 'new-discord-access',
                refreshToken: 'new-discord-refresh',
                tokenType: 1,
                expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
                scopes: const ['openid', 'sdk.social_layer_presence'],
              ),
            ),
          ),
        );

        expect(result.applied, isFalse);
        expect(
          await storage.read(key: realDebridTokenStorageKey),
          'old-access',
        );
        expect(
          await storage.read(key: realDebridRefreshTokenStorageKey),
          'old-refresh',
        );
        expect(
          await storage.read(key: realDebridClientIdStorageKey),
          'old-client-id',
        );
        expect(
          await storage.read(key: realDebridClientSecretStorageKey),
          'old-client-secret',
        );
        expect(
          await storage.read(key: realDebridAccessExpiryStorageKey),
          oldExpiry,
        );
      },
    );

    test(
      'partial source failure restores prior sources and Real-Debrid session',
      () async {
        final oldExpiry = DateTime.utc(2026, 8, 30).toIso8601String();
        FlutterSecureStorage.setMockInitialValues({
          realDebridTokenStorageKey: 'old-access',
          realDebridRefreshTokenStorageKey: 'old-refresh',
          realDebridClientIdStorageKey: 'old-client-id',
          realDebridClientSecretStorageKey: 'old-client-secret',
          realDebridAccessExpiryStorageKey: oldExpiry,
        });
        const existingSource = 'https://existing.example/marketplace.json';
        final importer = _ImporterFixture(
          sourceImportFails: true,
          initialSources: const [existingSource],
        );
        addTearDown(importer.dispose);
        await importer.container
            .read(realDebridSettingsControllerProvider.notifier)
            .load();
        final result = await importer.importer.apply(
          PhoneSetupBundle(
            protocolVersion: 2,
            preferences: const PhoneSetupPreferences(
              debridProvider: 'realdebrid',
            ),
            repositoryUrls: const ['https://example.test/marketplace.json'],
            manifestUrls: const [],
            credentials: PhoneSetupCredentials(
              debrid: PhoneSetupDebridCredentials(
                provider: 'realdebrid',
                accessToken: 'new-access',
                refreshToken: 'new-refresh',
                clientId: 'new-client-id',
                clientSecret: 'new-client-secret',
                expiresAt: DateTime.utc(2026, 10, 1),
              ),
            ),
          ),
        );

        expect(result.applied, isFalse);
        expect(
          await storage.read(key: realDebridTokenStorageKey),
          'old-access',
        );
        expect(
          await storage.read(key: realDebridRefreshTokenStorageKey),
          'old-refresh',
        );
        expect(
          await storage.read(key: realDebridClientIdStorageKey),
          'old-client-id',
        );
        expect(
          await storage.read(key: realDebridClientSecretStorageKey),
          'old-client-secret',
        );
        expect(
          await storage.read(key: realDebridAccessExpiryStorageKey),
          oldExpiry,
        );
        expect(importer.importedSources, const [existingSource]);
      },
    );

    test(
      'preference persistence failure restores storage and controller state',
      () async {
        const preferenceKey = 'player_preferred_audio';
        final failingStorage = FailureInjectingSecureStorage({
          preferenceKey: PlaybackAudioPreference.dub.name,
        });
        final importer = _ImporterFixture(secureStorage: failingStorage);
        addTearDown(importer.dispose);
        final settings = importer.container.read(
          settingsPreferencesProvider.notifier,
        );
        await settings.load();
        expect(
          importer.container.read(settingsPreferencesProvider).preferredAudio,
          PlaybackAudioPreference.dub,
        );
        failingStorage.failNextWrite(preferenceKey);

        final result = await importer.importer.apply(
          const PhoneSetupBundle(
            protocolVersion: 2,
            preferences: PhoneSetupPreferences(preferredAudio: 'sub'),
            repositoryUrls: [],
            manifestUrls: [],
            credentials: PhoneSetupCredentials(),
          ),
        );

        expect(result.applied, isFalse);
        expect(
          failingStorage.values[preferenceKey],
          PlaybackAudioPreference.dub.name,
        );
        expect(
          importer.container.read(settingsPreferencesProvider).preferredAudio,
          PlaybackAudioPreference.dub,
        );
      },
    );

    test(
      'resumes a saved session rather than creating a second session',
      () async {
        final session = _session();
        FlutterSecureStorage.setMockInitialValues({
          phoneSetupSessionStorageKey: jsonEncode({
            'version': 1,
            'session': session.toJson(),
            'applied_revision': null,
          }),
        });
        final api = _FakeApi();
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_emptyBundle()),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(() => api.pollCalls == 1);

        expect(api.restoreCalls, 1);
        expect(api.createCalls, 0);
        expect(controller.state.session?.pairingId, session.pairingId);
        expect(controller.state.stage, PhoneSetupViewStage.waiting);
        expect(controller.state.linkDiscordRequested, isFalse);
      },
    );

    test(
      'retries only the pending acknowledgement after process restart',
      () async {
        final session = _session();
        FlutterSecureStorage.setMockInitialValues({
          phoneSetupSessionStorageKey: jsonEncode({
            'version': 1,
            'session': session.toJson(),
            'applied_revision': 11,
            'link_discord_requested': true,
          }),
        });
        final api = _FakeApi()..ackFailuresRemaining = 1;
        final crypto = _FakeCrypto(_emptyBundle());
        final importer = _ImporterFixture();
        var setupCompleteCalls = 0;
        final controller = PhoneSetupPairingController(
          storage,
          api,
          crypto,
          importer.importer,
          () async => setupCompleteCalls++,
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        expect(controller.state.stage, PhoneSetupViewStage.waiting);
        expect(api.acknowledgements, [(revision: 11, applied: true)]);
        expect(api.createCalls, 0);
        expect(api.pollCalls, 0);
        expect(crypto.decryptCalls, 0);
        expect(setupCompleteCalls, 0);
        expect(await storage.read(key: phoneSetupSessionStorageKey), isNotNull);

        await controller.pollNow();

        expect(controller.state.stage, PhoneSetupViewStage.completed);
        expect(controller.state.linkDiscordRequested, isTrue);
        expect(api.acknowledgements, [
          (revision: 11, applied: true),
          (revision: 11, applied: true),
        ]);
        expect(crypto.decryptCalls, 0);
        expect(setupCompleteCalls, 1);
        expect(await storage.read(key: phoneSetupSessionStorageKey), isNull);
      },
    );

    test(
      'does not accept a lower replayed revision after observing a newer one',
      () async {
        final api = _FakeApi()
          ..pollResults.addAll(const [
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.bound,
              revision: 6,
            ),
            PhoneSetupPollResult(
              status: PhoneSetupPairingStatus.pending,
              revision: 5,
            ),
          ]);
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_emptyBundle()),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(
          () => controller.state.stage == PhoneSetupViewStage.bound,
        );
        await controller.pollNow();

        expect(controller.state.stage, PhoneSetupViewStage.bound);
        expect(controller.state.message, contains('interrupted'));
        expect(api.pollCalls, 2);
      },
    );

    test('clears expired saved state and creates a fresh session', () async {
      final expired = _session(
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      );
      FlutterSecureStorage.setMockInitialValues({
        phoneSetupSessionStorageKey: jsonEncode({
          'version': 1,
          'session': expired.toJson(),
          'applied_revision': null,
        }),
      });
      final api = _FakeApi();
      final importer = _ImporterFixture();
      final controller = PhoneSetupPairingController(
        storage,
        api,
        _FakeCrypto(_emptyBundle()),
        importer.importer,
        () async {},
      );
      addTearDown(() {
        controller.dispose();
        importer.dispose();
      });

      await controller.startOrResume();
      await _waitFor(() => api.pollCalls == 1);

      expect(api.restoreCalls, 1);
      expect(api.createCalls, 1);
      expect(
        controller.state.session?.expiresAt.isAfter(DateTime.now()),
        isTrue,
      );
    });

    test(
      'regenerate invalidates the old session before persisting one fresh code',
      () async {
        final api = _FakeApi();
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_emptyBundle()),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });

        await controller.startOrResume();
        await _waitFor(() => api.pollCalls == 1);
        final oldId = controller.state.session!.pairingId;

        await controller.regenerate();

        final freshId = controller.state.session!.pairingId;
        expect(freshId, isNot(oldId));
        expect(api.createCalls, 2);
        expect(api.cancelledPairingIds, [oldId]);
        expect(api.events, [
          'create:$oldId',
          'cancel:$oldId',
          'create:$freshId',
        ]);
        final saved = await storage.read(key: phoneSetupSessionStorageKey);
        expect(saved, contains(freshId));
        expect(saved, isNot(contains(oldId)));
        expect(controller.state.stage, PhoneSetupViewStage.waiting);
      },
    );

    test(
      'concurrent regenerate requests create only one replacement',
      () async {
        final api = _FakeApi();
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_emptyBundle()),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });
        await controller.startOrResume();
        await _waitFor(() => api.pollCalls == 1);

        api.cancelGate = Completer<void>();
        final first = controller.regenerate();
        await _waitFor(() => api.cancelCalls == 1);
        final duplicate = controller.regenerate();
        api.cancelGate!.complete();
        await Future.wait([first, duplicate]);

        expect(api.cancelCalls, 1);
        expect(api.createCalls, 2);
        expect(controller.state.stage, PhoneSetupViewStage.waiting);
      },
    );

    test(
      'does not create a new code when old-session invalidation fails',
      () async {
        final api = _FakeApi();
        final importer = _ImporterFixture();
        final controller = PhoneSetupPairingController(
          storage,
          api,
          _FakeCrypto(_emptyBundle()),
          importer.importer,
          () async {},
        );
        addTearDown(() {
          controller.dispose();
          importer.dispose();
        });
        await controller.startOrResume();
        await _waitFor(() => api.pollCalls == 1);
        final oldId = controller.state.session!.pairingId;
        api.cancelShouldFail = true;

        await controller.regenerate();

        expect(api.createCalls, 1);
        expect(controller.state.stage, PhoneSetupViewStage.failed);
        expect(controller.state.session?.pairingId, oldId);
        expect(
          await storage.read(key: phoneSetupSessionStorageKey),
          contains(oldId),
        );
      },
    );
  });
}

class _FakeApi implements PhoneSetupPairingApi {
  final List<PhoneSetupPollResult> pollResults = [];
  final List<({int revision, bool applied})> acknowledgements = [];
  final List<String> cancelledPairingIds = [];
  final List<String> events = [];
  int ensureReadyCalls = 0;
  int createCalls = 0;
  int pollCalls = 0;
  int restoreCalls = 0;
  int cancelCalls = 0;
  int ackFailuresRemaining = 0;
  bool cancelShouldFail = false;
  Completer<void>? cancelGate;

  @override
  Future<void> ensureReady() async => ensureReadyCalls++;

  @override
  Future<PhoneSetupPairingSession> createSession(
    PhoneSetupKeyMaterial keyMaterial,
  ) async {
    createCalls++;
    final session = _session(
      keyMaterial: keyMaterial,
      pairingId: createCalls == 1
          ? 'pairing_1234567890'
          : 'pairing_fresh_${createCalls.toString().padLeft(4, '0')}',
    );
    events.add('create:${session.pairingId}');
    return session;
  }

  @override
  Future<PhoneSetupPollResult> poll(PhoneSetupPairingSession session) async {
    pollCalls++;
    if (pollResults.isNotEmpty) return pollResults.removeAt(0);
    return const PhoneSetupPollResult(
      status: PhoneSetupPairingStatus.pending,
      revision: 0,
    );
  }

  @override
  Future<void> acknowledge(
    PhoneSetupPairingSession session, {
    required int revision,
    required bool applied,
  }) async {
    acknowledgements.add((revision: revision, applied: applied));
    if (ackFailuresRemaining > 0) {
      ackFailuresRemaining--;
      throw StateError('temporary failure');
    }
  }

  @override
  Future<void> cancel(PhoneSetupPairingSession session) async {
    cancelCalls++;
    cancelledPairingIds.add(session.pairingId);
    events.add('cancel:${session.pairingId}');
    if (cancelGate case final gate?) await gate.future;
    if (cancelShouldFail) throw StateError('cancel failed');
  }

  @override
  PhoneSetupPairingSession restoreSession(Object? value) {
    restoreCalls++;
    if (value is! Map) throw const FormatException('invalid saved session');
    final expiresAt = DateTime.parse('${value['expires_at']}');
    return _session(
      keyMaterial: PhoneSetupKeyMaterial.fromJson(value['key']),
      expiresAt: expiresAt,
    );
  }
}

class _FakeCrypto implements PhoneSetupCryptography {
  _FakeCrypto(this.bundle);

  final PhoneSetupBundle bundle;
  int generateCalls = 0;
  int decryptCalls = 0;

  @override
  Future<PhoneSetupKeyMaterial> generateKeyMaterial() async {
    generateCalls++;
    return _keyMaterial();
  }

  @override
  Future<PhoneSetupBundle> decrypt({
    required String pairingId,
    required PhoneSetupKeyMaterial deviceKey,
    required PhoneSetupEncryptedSubmission envelope,
  }) async {
    decryptCalls++;
    return bundle;
  }
}

class _ImporterFixture {
  _ImporterFixture({
    bool debridIsValid = true,
    bool discordImportFails = false,
    bool sourceImportFails = false,
    List<String> initialSources = const [],
    FlutterSecureStorage? secureStorage,
  }) : container = ProviderContainer(
         overrides: [
           if (secureStorage != null)
             secureStorageProvider.overrideWithValue(secureStorage),
           realDebridClientFactoryProvider.overrideWithValue(
             (_) => _ValidRealDebridClient(),
           ),
           discordPresencePlatformProvider.overrideWithValue(
             _InactiveDiscordPlatform(),
           ),
         ],
       ) {
    importedSources.addAll(initialSources);
    final discord = container.read(discordPresenceControllerProvider.notifier);
    importer = PhoneSetupBundleImporter(
      settings: container.read(settingsPreferencesProvider.notifier),
      titleLanguage: container.read(titleLanguagePreferenceProvider.notifier),
      tracking: container.read(trackingAccountsControllerProvider.notifier),
      realDebrid: container.read(realDebridSettingsControllerProvider.notifier),
      torBox: container.read(torBoxSettingsControllerProvider.notifier),
      allDebrid: container.read(allDebridSettingsControllerProvider.notifier),
      premiumize: container.read(premiumizeSettingsControllerProvider.notifier),
      validateDebrid: (_, _) async => debridIsValid,
      importDiscord: (credentials) async {
        if (discordImportFails) {
          throw StateError('Injected Discord import failure.');
        }
        importedDiscord.add(credentials);
      },
      snapshotDiscord: discord.snapshotForImport,
      restoreDiscord: discord.restoreImportSnapshot,
      commitDiscord: discord.connectImportedToken,
      prepareSourceRollback: () async {
        final snapshot = List<String>.of(importedSources);
        return () async {
          importedSources
            ..clear()
            ..addAll(snapshot);
        };
      },
      importSources: (payload) async {
        importedSources
          ..addAll(payload.repositoryUrls)
          ..addAll(payload.manifestUrls);
        if (sourceImportFails) {
          throw StateError('Injected source import failure.');
        }
        return SourceImportSummary(
          repositoriesAdded: payload.repositoryUrls.length,
          manifestsAdded: payload.manifestUrls.length,
        );
      },
      commitSources: (_) {},
    );
  }

  final ProviderContainer container;
  final List<PhoneSetupDiscordCredentials> importedDiscord = [];
  final List<String> importedSources = [];
  late final PhoneSetupBundleImporter importer;

  void dispose() => container.dispose();
}

class _ValidRealDebridClient extends RealDebridClient {
  _ValidRealDebridClient() : super(token: 'test');

  @override
  Future<RealDebridAccount> account() async =>
      const RealDebridAccount(id: 1, username: 'test-user', type: 'premium');
}

class _InactiveDiscordPlatform implements DiscordPresencePlatform {
  @override
  Stream<DiscordBridgeEvent> get events => const Stream.empty();

  @override
  Future<Map<Object?, Object?>> sdkInfo() async => const {
    'available': false,
    'status': 'disconnected',
  };

  @override
  Future<void> cancelAuthentication() async {}

  @override
  Future<void> connect(DiscordTokenBundle token) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> revoke(String token) async => true;

  @override
  Future<DiscordTokenBundle> authenticate() =>
      throw UnsupportedError('Not used by phone-setup importer tests.');

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) =>
      throw UnsupportedError('Not used by phone-setup importer tests.');
}

PhoneSetupBundle _emptyBundle() => const PhoneSetupBundle(
  preferences: PhoneSetupPreferences(),
  repositoryUrls: [],
  manifestUrls: [],
  credentials: PhoneSetupCredentials(),
);

PhoneSetupBundle _discordBundle() => const PhoneSetupBundle(
  preferences: PhoneSetupPreferences(linkDiscord: true),
  repositoryUrls: [],
  manifestUrls: [],
  credentials: PhoneSetupCredentials(),
);

PhoneSetupEncryptedSubmission _envelope() => PhoneSetupEncryptedSubmission(
  browserPublicKey: [0x04, ...List<int>.filled(64, 1)],
  nonce: List<int>.filled(12, 2),
  ciphertext: List<int>.filled(17, 3),
);

PhoneSetupKeyMaterial _keyMaterial() => PhoneSetupKeyMaterial(
  privateD: List<int>.filled(32, 1),
  publicX: List<int>.filled(32, 2),
  publicY: List<int>.filled(32, 3),
);

PhoneSetupPairingSession _session({
  PhoneSetupKeyMaterial? keyMaterial,
  DateTime? expiresAt,
  String pairingId = 'pairing_1234567890',
}) {
  final now = DateTime.now().toUtc();
  return PhoneSetupPairingSession(
    pairingId: pairingId,
    deviceCode: 'd' * 48,
    userCode: 'ABCD-EFGH',
    verificationUri: Uri.parse('https://setup.example/setup'),
    verificationUriComplete: Uri.parse(
      'https://setup.example/setup#code=ABCD-EFGH&key=FP_12345678',
    ),
    codeExpiresAt: now.add(const Duration(hours: 24)),
    expiresAt: expiresAt ?? now.add(const Duration(days: 7)),
    pollInterval: const Duration(seconds: 30),
    keyMaterial: keyMaterial ?? _keyMaterial(),
    deviceKeyFingerprint: 'FP_12345678',
    confirmationCode: 'SAFE 2468',
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous controller state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
