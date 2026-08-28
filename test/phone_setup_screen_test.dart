import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
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
import 'package:anime_tv/features/settings/presentation/phone_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'portrait phone layout stacks cards, scrolls, and never opens a text field',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ScreenFixture();
      addTearDown(fixture.dispose);

      await tester.pumpWidget(fixture.app());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.byKey(const ValueKey('phone-setup-screen')), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(find.textContaining('end-to-end encryption'), findsOneWidget);

      final connectRect = tester.getRect(find.text('CONNECT YOUR PHONE'));
      final statusRect = tester.getRect(find.text('Waiting for your phone'));
      expect(statusRect.top, greaterThan(connectRect.bottom));
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.textContaining('Protected with end-to-end encryption'),
        260,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Credentials never appear'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('landscape TV layout places connection and status side-by-side', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ScreenFixture();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    final connectRect = tester.getRect(find.text('CONNECT YOUR PHONE'));
    final statusRect = tester.getRect(find.text('Waiting for your phone'));
    expect(statusRect.left, greaterThan(connectRect.right));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('phone-setup-back')))
          .autofocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back returns to setup method chooser without losing session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ScreenFixture();
    addTearDown(fixture.dispose);
    final router = GoRouter(
      initialLocation: '/setup/start',
      routes: [
        GoRoute(
          path: '/setup/start',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('SETUP METHOD CHOOSER'))),
        ),
        GoRoute(
          path: PhoneSetupScreen.routePath,
          builder: (context, state) => const PhoneSetupScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(fixture.app(router: router));
    router.push(PhoneSetupScreen.routePath);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byKey(const ValueKey('phone-setup-back')), findsOneWidget);
    expect(fixture.controller.state.session, isNotNull);

    await tester.tap(find.byKey(const ValueKey('phone-setup-back')));
    await tester.pumpAndSettle();

    expect(find.text('SETUP METHOD CHOOSER'), findsOneWidget);
    expect(fixture.api.cancelCalls, 0);
    expect(fixture.controller.state.session, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Regenerate code has stable TV focus and replaces the session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ScreenFixture();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    final regenerate = find.byKey(const ValueKey('phone-setup-regenerate'));
    expect(regenerate, findsOneWidget);
    final button = tester.widget<OutlinedButton>(regenerate);
    expect(button.focusNode?.debugLabel, 'phone-setup.regenerate');
    button.focusNode!.requestFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'phone-setup.regenerate',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (
      var attempt = 0;
      attempt < 20 && fixture.api.createCalls < 2;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 100));

    expect(fixture.api.cancelCalls, 1);
    expect(fixture.api.createCalls, 2);
    expect(find.text('WXYZ-2468'), findsOneWidget);
    expect(find.text('ABCD-EFGH'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'review preview hides account credentials and requires explicit apply',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const trackingSecret = 'TRACKING_SECRET_MUST_NOT_RENDER';
      const debridSecret = 'DEBRID_SECRET_MUST_NOT_RENDER';
      final fixture = _ScreenFixture(
        bundle: const PhoneSetupBundle(
          preferences: PhoneSetupPreferences(
            trackingProvider: 'anilist',
            debridProvider: 'realdebrid',
            showWatchParty: true,
            linkDiscord: true,
          ),
          repositoryUrls: ['https://example.test/repository.json'],
          manifestUrls: ['https://example.test/manifest.json'],
          credentials: PhoneSetupCredentials(
            trackingToken: trackingSecret,
            debridCredential: debridSecret,
          ),
        ),
        submitted: true,
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(fixture.app());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Review before applying'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-setup-apply')), findsOneWidget);
      expect(find.text('AniList'), findsOneWidget);
      expect(find.text('Real-Debrid'), findsOneWidget);
      expect(find.text('Discord'), findsOneWidget);
      expect(find.text('Connect after setup'), findsOneWidget);
      expect(find.text(trackingSecret), findsNothing);
      expect(find.text(debridSecret), findsNothing);
      expect(find.textContaining('intentionally hidden'), findsOneWidget);
      expect(fixture.controller.state.stage, PhoneSetupViewStage.review);
      expect(fixture.api.acknowledgements, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in const [Size(360, 800), Size(800, 360)]) {
    testWidgets(
      'phone setup review fits ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _ScreenFixture(
          bundle: const PhoneSetupBundle(
            preferences: PhoneSetupPreferences(
              trackingProvider: 'anilist',
              debridProvider: 'realdebrid',
              showWatchParty: true,
            ),
            repositoryUrls: ['https://example.test/repository.json'],
            manifestUrls: ['https://example.test/manifest.json'],
            credentials: PhoneSetupCredentials(
              trackingToken: 'hidden-tracking-token',
              debridCredential: 'hidden-debrid-token',
            ),
          ),
          submitted: true,
        );
        addTearDown(fixture.dispose);

        await tester.pumpWidget(fixture.app());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(find.text('Review before applying'), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-setup-apply')), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('phone-setup-apply')),
        );
        await tester.pump();
        final applyRect = tester.getRect(
          find.byKey(const ValueKey('phone-setup-apply')),
        );
        expect(applyRect.left, greaterThanOrEqualTo(0));
        expect(applyRect.top, greaterThanOrEqualTo(0));
        expect(applyRect.right, lessThanOrEqualTo(size.width));
        expect(applyRect.bottom, lessThanOrEqualTo(size.height));
        expect(find.text('hidden-tracking-token'), findsNothing);
        expect(find.text('hidden-debrid-token'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'completed phone setup offers official Discord pairing and keeps Start available',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ScreenFixture(bundle: _discordBundle(), submitted: true);
      addTearDown(fixture.dispose);
      final router = _discordCompletionRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(fixture.app(router: router));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tap(find.byKey(const ValueKey('phone-setup-apply')));
      await tester.pumpAndSettle();

      final connect = find.byKey(const ValueKey('phone-setup-connect-discord'));
      final start = find.byKey(const ValueKey('phone-setup-finish'));
      expect(connect, findsOneWidget);
      expect(tester.widget<FilledButton>(connect).autofocus, isTrue);
      expect(start, findsOneWidget);
      expect(tester.widget<OutlinedButton>(start), isNotNull);
      expect(find.text('Discord connected'), findsNothing);

      await tester.tap(connect);
      await tester.pumpAndSettle();

      expect(
        find.text('OFFICIAL DISCORD DEVICE AUTHORIZATION'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed phone setup recognizes an already linked Discord', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'discord_rich_presence_access_token': 'existing-access',
      'discord_rich_presence_refresh_token': 'existing-refresh',
      'discord_rich_presence_token_type': '1',
      'discord_rich_presence_expires_at': DateTime.now()
          .add(const Duration(days: 7))
          .millisecondsSinceEpoch
          .toString(),
      'discord_rich_presence_scopes': 'openid sdk.social_layer_presence',
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ScreenFixture(bundle: _discordBundle(), submitted: true);
    addTearDown(fixture.dispose);
    final router = _discordCompletionRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(fixture.app(router: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('phone-setup-apply')));
    await tester.pumpAndSettle();

    expect(find.text('Discord connected'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('phone-setup-connect-discord')),
      findsNothing,
    );
    final start = find.byKey(const ValueKey('phone-setup-finish'));
    expect(tester.widget<FilledButton>(start).autofocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _ScreenFixture {
  _ScreenFixture({PhoneSetupBundle? bundle, bool submitted = false})
    : bundle = bundle ?? _emptyBundle(),
      container = ProviderContainer(),
      api = _ScreenApi(submitted: submitted) {
    importer = PhoneSetupBundleImporter(
      settings: container.read(settingsPreferencesProvider.notifier),
      titleLanguage: container.read(titleLanguagePreferenceProvider.notifier),
      tracking: container.read(trackingAccountsControllerProvider.notifier),
      realDebrid: container.read(realDebridSettingsControllerProvider.notifier),
      torBox: container.read(torBoxSettingsControllerProvider.notifier),
      allDebrid: container.read(allDebridSettingsControllerProvider.notifier),
      premiumize: container.read(premiumizeSettingsControllerProvider.notifier),
      validateDebrid: (_, _) async => true,
      prepareSourceRollback: () async => () async {},
      importSources: (_) async => const SourceImportSummary(),
      commitSources: (_) {},
    );
    controller = PhoneSetupPairingController(
      const FlutterSecureStorage(),
      api,
      _ScreenCrypto(this.bundle),
      importer,
      () async {},
    );
  }

  final PhoneSetupBundle bundle;
  final ProviderContainer container;
  final _ScreenApi api;
  final _ScreenDiscordPlatform discord = _ScreenDiscordPlatform();
  late final PhoneSetupBundleImporter importer;
  late final PhoneSetupPairingController controller;

  Widget app({GoRouter? router}) => ProviderScope(
    overrides: [
      phoneSetupPairingControllerProvider.overrideWith((_) => controller),
      discordPresencePlatformProvider.overrideWithValue(discord),
    ],
    child: router == null
        ? MaterialApp(theme: AppTheme.dark, home: const PhoneSetupScreen())
        : MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
  );

  void dispose() {
    container.dispose();
  }
}

class _ScreenApi implements PhoneSetupPairingApi {
  _ScreenApi({required this.submitted});

  final bool submitted;
  final List<({int revision, bool applied})> acknowledgements = [];
  int polls = 0;
  int createCalls = 0;
  int cancelCalls = 0;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<PhoneSetupPairingSession> createSession(
    PhoneSetupKeyMaterial keyMaterial,
  ) async {
    createCalls++;
    return _session(keyMaterial, fresh: createCalls > 1);
  }

  @override
  Future<PhoneSetupPollResult> poll(PhoneSetupPairingSession session) async {
    polls++;
    if (submitted && polls == 1) {
      return PhoneSetupPollResult(
        status: PhoneSetupPairingStatus.submitted,
        revision: 1,
        envelope: PhoneSetupEncryptedSubmission(
          browserPublicKey: [0x04, ...List<int>.filled(64, 1)],
          nonce: List<int>.filled(12, 2),
          ciphertext: List<int>.filled(17, 3),
        ),
      );
    }
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
  }) async => acknowledgements.add((revision: revision, applied: applied));

  @override
  Future<void> cancel(PhoneSetupPairingSession session) async {
    cancelCalls++;
  }

  @override
  PhoneSetupPairingSession restoreSession(Object? value) =>
      throw UnimplementedError();
}

class _ScreenCrypto implements PhoneSetupCryptography {
  const _ScreenCrypto(this.bundle);

  final PhoneSetupBundle bundle;

  @override
  Future<PhoneSetupKeyMaterial> generateKeyMaterial() async => _keyMaterial();

  @override
  Future<PhoneSetupBundle> decrypt({
    required String pairingId,
    required PhoneSetupKeyMaterial deviceKey,
    required PhoneSetupEncryptedSubmission envelope,
  }) async => bundle;
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

GoRouter _discordCompletionRouter() => GoRouter(
  initialLocation: PhoneSetupScreen.routePath,
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const Scaffold(body: Text('TETOTV HOME')),
    ),
    GoRoute(
      path: PhoneSetupScreen.routePath,
      builder: (context, state) => const PhoneSetupScreen(),
    ),
    GoRoute(
      path: '/pair/discord',
      builder: (context, state) => const Scaffold(
        body: Center(child: Text('OFFICIAL DISCORD DEVICE AUTHORIZATION')),
      ),
    ),
  ],
);

class _ScreenDiscordPlatform implements DiscordPresencePlatform {
  @override
  Stream<DiscordBridgeEvent> get events => const Stream.empty();

  @override
  Future<Map<Object?, Object?>> sdkInfo() async => const {
    'available': true,
    'status': 'disconnected',
    'version': 'test',
  };

  @override
  Future<DiscordTokenBundle> authenticate() => throw UnimplementedError();

  @override
  Future<void> cancelAuthentication() async {}

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) =>
      throw UnimplementedError();

  @override
  Future<void> connect(DiscordTokenBundle token) async {}

  @override
  Future<bool> revoke(String token) async => true;

  @override
  Future<void> disconnect() async {}
}

PhoneSetupKeyMaterial _keyMaterial() => PhoneSetupKeyMaterial(
  privateD: List<int>.filled(32, 1),
  publicX: List<int>.filled(32, 2),
  publicY: List<int>.filled(32, 3),
);

PhoneSetupPairingSession _session(
  PhoneSetupKeyMaterial keyMaterial, {
  bool fresh = false,
}) {
  final now = DateTime.now().toUtc();
  return PhoneSetupPairingSession(
    pairingId: fresh ? 'pairing_fresh_123456' : 'pairing_1234567890',
    deviceCode: 'd' * 48,
    userCode: fresh ? 'WXYZ-2468' : 'ABCD-EFGH',
    verificationUri: Uri.parse('https://setup.example/setup'),
    verificationUriComplete: Uri.parse(
      'https://setup.example/setup#code=ABCD-EFGH&key=FP_12345678',
    ),
    codeExpiresAt: now.add(const Duration(hours: 24)),
    expiresAt: now.add(const Duration(days: 7)),
    pollInterval: const Duration(seconds: 30),
    keyMaterial: keyMaterial,
    deviceKeyFingerprint: 'FP_12345678',
    confirmationCode: 'SAFE 2468',
  );
}
