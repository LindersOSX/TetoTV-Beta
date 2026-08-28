import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/application/source_pairing_controller.dart';
import 'package:anime_tv/features/marketplace/domain/source_pairing.dart';
import 'package:anime_tv/features/settings/application/all_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/premiumize_settings_controller.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/torbox_settings_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PhoneSetupApplyResult {
  const PhoneSetupApplyResult({
    required this.applied,
    required this.preferenceCount,
    required this.repositoriesAdded,
    required this.manifestsAdded,
    this.trackerConnected = false,
    this.debridConnected = false,
    this.discordConnected = false,
    this.warnings = const [],
    this.message,
  });

  final bool applied;
  final int preferenceCount;
  final int repositoriesAdded;
  final int manifestsAdded;
  final bool trackerConnected;
  final bool debridConnected;
  final bool discordConnected;
  final List<String> warnings;
  final String? message;
}

final phoneSetupBundleImporterProvider = Provider<PhoneSetupBundleImporter>((
  ref,
) {
  final tracking = ref.read(trackingAccountsControllerProvider.notifier);
  final marketplace = ref.read(marketplaceControllerProvider.notifier);
  final torrentSources = ref.read(
    userTorrentSourcesControllerProvider.notifier,
  );
  return PhoneSetupBundleImporter(
    settings: ref.read(settingsPreferencesProvider.notifier),
    titleLanguage: ref.read(titleLanguagePreferenceProvider.notifier),
    tracking: tracking,
    realDebrid: ref.read(realDebridSettingsControllerProvider.notifier),
    torBox: ref.read(torBoxSettingsControllerProvider.notifier),
    allDebrid: ref.read(allDebridSettingsControllerProvider.notifier),
    premiumize: ref.read(premiumizeSettingsControllerProvider.notifier),
    validateDebrid: (provider, credential) async {
      try {
        return switch (provider) {
          DebridService.realDebrid =>
            (await ref
                    .read(realDebridClientFactoryProvider)(credential)
                    .account())
                .isPremium,
          DebridService.torBox =>
            (await ref.read(torBoxClientFactoryProvider)(credential).account())
                .hasApiStreaming,
          DebridService.allDebrid =>
            (await ref
                    .read(allDebridClientFactoryProvider)(credential)
                    .account())
                .isPremium,
          DebridService.premiumize =>
            (await ref
                    .read(premiumizeClientFactoryProvider)(credential)
                    .account())
                .isPremium,
        };
      } catch (_) {
        return false;
      }
    },
    importDiscord: (credentials) => ref
        .read(discordPresenceControllerProvider.notifier)
        .importLinkedToken(
          DiscordTokenBundle(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            tokenType: credentials.tokenType,
            expiresAt: credentials.expiresAt,
            scopes: credentials.scopes.join(' '),
          ),
          connectAfterStore: false,
        ),
    snapshotDiscord: () => ref
        .read(discordPresenceControllerProvider.notifier)
        .snapshotForImport(),
    restoreDiscord: (snapshot) => ref
        .read(discordPresenceControllerProvider.notifier)
        .restoreImportSnapshot(snapshot),
    commitDiscord: () => ref
        .read(discordPresenceControllerProvider.notifier)
        .connectImportedToken(),
    prepareSourceRollback: () async {
      final snapshot = await snapshotPairedSources(
        marketplace: marketplace,
        torrentSources: torrentSources,
      );
      return () => restorePairedSources(
        snapshot,
        marketplace: marketplace,
        torrentSources: torrentSources,
      );
    },
    importSources: (payload) => importPairedSources(
      payload,
      marketplace: marketplace,
      torrentSources: torrentSources,
      refreshRepositoriesAfterImport: false,
    ),
    commitSources: (summary) =>
        commitPairedSources(summary, marketplace: marketplace),
  );
});

typedef PhoneSetupDebridValidator =
    Future<bool> Function(DebridService provider, String credential);
typedef PhoneSetupSourceImporter =
    Future<SourceImportSummary> Function(SourcePairingPayload payload);
typedef PhoneSetupRollback = Future<void> Function();
typedef PhoneSetupSourceRollbackPreparer =
    Future<PhoneSetupRollback> Function();
typedef PhoneSetupSourceCommitter = void Function(SourceImportSummary summary);
typedef PhoneSetupDiscordImporter =
    Future<void> Function(PhoneSetupDiscordCredentials credentials);
typedef PhoneSetupDiscordSnapshotter = Future<DiscordImportSnapshot> Function();
typedef PhoneSetupDiscordRestorer =
    Future<void> Function(DiscordImportSnapshot snapshot);
typedef PhoneSetupDiscordCommitter = Future<void> Function();

class PhoneSetupBundleImporter {
  const PhoneSetupBundleImporter({
    required this.settings,
    required this.titleLanguage,
    required this.tracking,
    required this.realDebrid,
    required this.torBox,
    required this.allDebrid,
    required this.premiumize,
    required this.validateDebrid,
    required this.prepareSourceRollback,
    required this.importSources,
    required this.commitSources,
    this.importDiscord,
    this.snapshotDiscord,
    this.restoreDiscord,
    this.commitDiscord,
  });

  final SettingsPreferencesController settings;
  final TitleLanguagePreferenceController titleLanguage;
  final TrackingAccountsController tracking;
  final RealDebridSettingsController realDebrid;
  final TorBoxSettingsController torBox;
  final AllDebridSettingsController allDebrid;
  final PremiumizeSettingsController premiumize;
  final PhoneSetupDebridValidator validateDebrid;
  final PhoneSetupSourceRollbackPreparer prepareSourceRollback;
  final PhoneSetupSourceImporter importSources;
  final PhoneSetupSourceCommitter commitSources;
  final PhoneSetupDiscordImporter? importDiscord;
  final PhoneSetupDiscordSnapshotter? snapshotDiscord;
  final PhoneSetupDiscordRestorer? restoreDiscord;
  final PhoneSetupDiscordCommitter? commitDiscord;

  Future<PhoneSetupApplyResult> apply(PhoneSetupBundle bundle) async {
    final preferences = bundle.preferences;
    final structuredTracking = bundle.credentials.tracking;
    final structuredDebrid = bundle.credentials.debrid;
    final discordCredentials = bundle.credentials.discord;
    final trackingProvider = _trackingProvider(
      structuredTracking?.provider ?? preferences.trackingProvider,
    );
    final debridProvider = DebridService.fromSlug(
      structuredDebrid?.provider ?? preferences.debridProvider,
    );
    final trackingToken =
        structuredTracking?.accessToken ?? bundle.credentials.trackingToken;
    final debridCredential =
        structuredDebrid?.validationCredential ??
        bundle.credentials.debridCredential;

    // Validate every secret before changing any preference or source. A token
    // is never included in the returned message or controller state.
    if (trackingToken != null &&
        (trackingProvider == null ||
            !await tracking.validateToken(trackingProvider, trackingToken))) {
      return const PhoneSetupApplyResult(
        applied: false,
        preferenceCount: 0,
        repositoriesAdded: 0,
        manifestsAdded: 0,
        message:
            'The selected tracker could not verify that account. Update it on your phone and send again.',
      );
    }
    if (debridCredential != null &&
        (debridProvider == null ||
            !await validateDebrid(debridProvider, debridCredential))) {
      return const PhoneSetupApplyResult(
        applied: false,
        preferenceCount: 0,
        repositoriesAdded: 0,
        manifestsAdded: 0,
        message:
            'The selected debrid service could not verify an active account. Update it on your phone and send again.',
      );
    }
    if (discordCredentials != null &&
        (discordCredentials.expiresAt.isBefore(DateTime.now().toUtc()) ||
            importDiscord == null ||
            snapshotDiscord == null ||
            restoreDiscord == null)) {
      return const PhoneSetupApplyResult(
        applied: false,
        preferenceCount: 0,
        repositoriesAdded: 0,
        manifestsAdded: 0,
        message:
            'The Discord authorization expired or could not be imported. Link Discord again on your phone.',
      );
    }

    final rollbacks = <PhoneSetupRollback>[];
    try {
      if (trackingToken != null && trackingProvider != null) {
        final snapshot = await tracking.snapshotForImport(trackingProvider);
        rollbacks.add(() => tracking.restoreImportSnapshot(snapshot));
        if (structuredTracking != null) {
          await tracking.saveTokenSet(
            trackingProvider,
            accessToken: structuredTracking.accessToken,
            refreshToken: structuredTracking.refreshToken,
            expiresAt: structuredTracking.expiresAt,
            refreshState: false,
          );
        } else {
          await tracking.save(
            trackingProvider,
            trackingToken,
            refreshState: false,
          );
        }
      }

      if (debridCredential != null && debridProvider != null) {
        await _snapshotDebrid(debridProvider, rollbacks);
        final saved = await switch (debridProvider) {
          DebridService.realDebrid when structuredDebrid != null =>
            realDebrid.saveOAuthAndValidate(
              accessToken: structuredDebrid.accessToken!,
              refreshToken: structuredDebrid.refreshToken!,
              clientId: structuredDebrid.clientId!,
              clientSecret: structuredDebrid.clientSecret!,
              expiresAt:
                  structuredDebrid.expiresAt ??
                  DateTime.now().toUtc().add(const Duration(hours: 1)),
            ),
          DebridService.realDebrid => realDebrid.saveAndValidate(
            debridCredential,
          ),
          DebridService.torBox => torBox.saveAndValidate(debridCredential),
          DebridService.allDebrid => allDebrid.saveAndValidate(
            debridCredential,
          ),
          DebridService.premiumize => premiumize.saveAndValidate(
            debridCredential,
          ),
        };
        if (!saved) {
          throw const _PhoneSetupImportFailure(
            'The debrid account was verified but could not be saved securely. Try again.',
          );
        }
      }

      if (discordCredentials != null) {
        final snapshot = await snapshotDiscord!();
        rollbacks.add(() => restoreDiscord!(snapshot));
        await importDiscord!(discordCredentials);
      }

      if (bundle.repositoryUrls.isNotEmpty || bundle.manifestUrls.isNotEmpty) {
        rollbacks.add(await prepareSourceRollback());
      }
      final sourceSummary = await importSources(
        SourcePairingPayload(
          repositoryUrls: bundle.repositoryUrls,
          manifestUrls: bundle.manifestUrls,
        ),
      );
      final settingsSnapshot = await settings.snapshotForImport();
      final titleLanguageSnapshot = await titleLanguage.snapshotForImport();
      rollbacks
        ..add(() => settings.restoreImportSnapshot(settingsSnapshot))
        ..add(() => titleLanguage.restoreImportSnapshot(titleLanguageSnapshot));
      await settings.runWithStrictPersistence(
        () => titleLanguage.runWithStrictPersistence(
          () => _applyPreferences(
            preferences,
            linkedTrackingProvider: structuredTracking == null
                ? null
                : trackingProvider,
            linkedDebridProvider: structuredDebrid == null
                ? null
                : debridProvider,
          ),
        ),
      );

      // Credential storage is now committed. UI/native refreshes happen only
      // after every fallible setup mutation has completed, so they cannot
      // create profile or connection side effects that rollback must unwind.
      if (trackingToken != null) {
        try {
          await tracking.refreshAfterImport();
        } catch (_) {}
      }
      if (discordCredentials != null && commitDiscord != null) {
        await commitDiscord!();
      }
      commitSources(sourceSummary);
      return PhoneSetupApplyResult(
        applied: true,
        preferenceCount: preferences.choiceCount,
        repositoriesAdded: sourceSummary.repositoriesAdded,
        manifestsAdded: sourceSummary.manifestsAdded,
        trackerConnected: trackingToken != null,
        debridConnected: debridCredential != null,
        discordConnected: discordCredentials != null,
        warnings: sourceSummary.errors,
        message: sourceSummary.errors.isEmpty
            ? 'Phone setup applied securely.'
            : 'Phone setup applied. ${sourceSummary.errors.length} source ${sourceSummary.errors.length == 1 ? 'entry was' : 'entries were'} skipped.',
      );
    } catch (error) {
      final restored = await _rollbackChanges(rollbacks);
      final message = !restored
          ? 'Phone setup could not finish, and the previous settings could not be restored completely. Review affected accounts, sources, and preferences in Settings.'
          : error is _PhoneSetupImportFailure
          ? error.message
          : 'Phone setup could not be applied. Your previous settings were restored.';
      return PhoneSetupApplyResult(
        applied: false,
        preferenceCount: 0,
        repositoriesAdded: 0,
        manifestsAdded: 0,
        message: message,
      );
    }
  }

  Future<void> _snapshotDebrid(
    DebridService provider,
    List<PhoneSetupRollback> rollbacks,
  ) async {
    switch (provider) {
      case DebridService.realDebrid:
        final snapshot = await realDebrid.snapshotForImport();
        rollbacks.add(() => realDebrid.restoreImportSnapshot(snapshot));
      case DebridService.torBox:
        final snapshot = await torBox.snapshotForImport();
        rollbacks.add(() => torBox.restoreImportSnapshot(snapshot));
      case DebridService.allDebrid:
        final snapshot = await allDebrid.snapshotForImport();
        rollbacks.add(() => allDebrid.restoreImportSnapshot(snapshot));
      case DebridService.premiumize:
        final snapshot = await premiumize.snapshotForImport();
        rollbacks.add(() => premiumize.restoreImportSnapshot(snapshot));
    }
  }

  Future<bool> _rollbackChanges(List<PhoneSetupRollback> rollbacks) async {
    var restored = true;
    for (final rollback in rollbacks.reversed) {
      try {
        await rollback();
      } catch (_) {
        restored = false;
      }
    }
    return restored;
  }

  Future<void> _applyPreferences(
    PhoneSetupPreferences value, {
    TrackingProvider? linkedTrackingProvider,
    DebridService? linkedDebridProvider,
  }) async {
    final operations = <Future<void>>[];
    if (value.preferredAudio case final preference?) {
      operations.add(
        settings.setPreferredAudio(
          preference == 'sub'
              ? PlaybackAudioPreference.sub
              : PlaybackAudioPreference.dub,
        ),
      );
    }
    if (value.titleLanguage case final preference?) {
      operations.add(
        titleLanguage.setPreference(
          preference == 'romaji'
              ? TitleLanguagePreference.romaji
              : TitleLanguagePreference.english,
        ),
      );
    }
    if (value.useBuiltInKeyboard case final enabled?) {
      operations.add(settings.setUseBuiltInKeyboard(enabled));
    }
    if (value.autoSkipIntros case final enabled?) {
      operations.add(settings.setAutoSkipIntros(enabled));
    }
    if (value.autoSkipOutros case final enabled?) {
      operations.add(settings.setAutoSkipOutros(enabled));
    }
    if (value.homeLayout case final layout?) {
      operations.add(
        settings.setHomeLayout(
          layout == 'compact' ? HomeLayout.compact : HomeLayout.cinematic,
        ),
      );
    }
    if (value.showHero case final enabled?) {
      operations.add(settings.setShowHero(enabled));
    }
    if (value.showPosterMetadata case final enabled?) {
      operations.add(settings.setShowPosterMetadata(enabled));
    }
    if (value.showMyList case final enabled?) {
      operations.add(settings.setShowMyList(enabled));
    }
    if (value.showDiscover case final enabled?) {
      operations.add(settings.setShowDiscover(enabled));
    }
    if (value.showCalendar case final enabled?) {
      operations.add(settings.setShowCalendar(enabled));
    }
    if (value.showWatchParty case final enabled?) {
      operations.add(settings.setShowWatchTogether(enabled));
    }
    if (value.showDownloads case final enabled?) {
      operations.add(settings.setShowDownloads(enabled));
    }
    if (value.anonymousCrashReporting case final enabled?) {
      operations.add(settings.setAnonymousCrashReportingEnabled(enabled));
    }
    if (value.anonymousUsageCount case final enabled?) {
      operations.add(settings.setAnonymousUsageCountEnabled(enabled));
    }
    if (_trackingProvider(value.trackingProvider) ?? linkedTrackingProvider
        case final provider?) {
      operations.add(settings.setTrackingProvider(provider));
    }
    if (DebridService.fromSlug(value.debridProvider) ?? linkedDebridProvider
        case final provider?) {
      operations.add(settings.setDebridProvider(provider));
    }
    await Future.wait(operations);

    // Interface mode can rescale and rebuild the current route, so persist it
    // last after every other choice is durable.
    if (value.interfaceMode case final mode?) {
      await settings.setInterfaceMode(switch (mode) {
        'television' => InterfaceMode.television,
        // Classic Layout was retired. Old phone-setup payloads still decode,
        // but migrate to Automatic so TV devices receive Modern Layout while
        // physical phones keep their optimized handheld presentation.
        'phone' => InterfaceMode.automatic,
        _ => InterfaceMode.automatic,
      });
    }
  }
}

TrackingProvider? _trackingProvider(String? value) => switch (value) {
  'anilist' => TrackingProvider.anilist,
  'myanimelist' => TrackingProvider.myAnimeList,
  _ => null,
};

final class _PhoneSetupImportFailure implements Exception {
  const _PhoneSetupImportFailure(this.message);

  final String message;
}
