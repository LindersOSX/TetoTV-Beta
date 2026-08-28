import 'package:anime_tv/app/router.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';
import 'package:anime_tv/core/telemetry/anonymous_usage_reporter.dart';
import 'package:anime_tv/core/layout/interface_scaling.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/interaction_sound_scope.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/catalog/application/airing_release_notification_coordinator.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:anime_tv/features/player/presentation/watch_party_membership_notice.dart';
import 'package:anime_tv/features/tracking/application/tracking_sync_service.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_media_follower.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TetoTvApp extends ConsumerWidget {
  const TetoTvApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appPalette = ref.watch(
      themeStudioControllerProvider.select((state) => state.palette),
    );
    final isTelevision = ref.watch(isTelevisionProvider);
    ref.watch(trackingOutboxFlushProvider);
    // Rich Presence is opt-in. Watching the controller only restores an
    // already-linked session; fresh installs do not contact Discord.
    ref.watch(discordPresenceControllerProvider);
    // Anonymous crash delivery is consent-gated and remains dormant until the
    // encrypted preference has loaded. Native crashes are retried next launch.
    ref.watch(anonymousCrashReporterProvider);
    // Beta-only aggregate activity is separately consent-gated. The reporter
    // owns no persistent identifier and Public builds remain fully dormant.
    ref.watch(anonymousUsageReporterProvider);
    // Instantiate the durable season worker at normal app startup. Its
    // restoration is asynchronous, and watching only the notifier avoids
    // rebuilding MaterialApp for each episode's progress update.
    ref.watch(seasonDownloadControllerProvider.notifier);
    // Opt-in Calendar notifications are handed to Android AlarmManager so
    // they still arrive while the app is minimized.
    ref.watch(airingReleaseNotificationCoordinatorProvider);
    return MaterialApp.router(
      title: 'TetoTV',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkFor(appPalette),
      // A settings write must never interpolate the whole application through
      // Material's fallback colors. Theme Studio already previews its own
      // palette changes explicitly, so swapping the inherited theme in one
      // frame is both clearer and prevents the brief black-text flash seen on
      // the default dark palette.
      themeAnimationDuration: Duration.zero,
      routerConfig: appRouter,
      builder: (context, child) {
        // Keep frequently changing preferences below MaterialApp. Rebuilding
        // this Consumer updates scaling/sounds without reconstructing
        // ThemeData and restarting Material's inherited-theme transition.
        return Consumer(
          builder: (context, ref, _) {
            final preferences = ref.watch(settingsPreferencesProvider);
            final mq = MediaQuery.of(context);
            final content = WatchPartyMediaFollowScope(
              router: appRouter,
              child: InteractionSoundScope(
                navigationEnabled: preferences.navigationSounds,
                clickEnabled: preferences.clickSounds,
                child: TvShortcuts(
                  child: TetoTvGlobalOverlay(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
            final scale = interfaceCanvasScale(
              logicalWidth: mq.size.width,
              physicalWidth: View.of(context).physicalSize.width,
              detectedTelevision: isTelevision,
              mode: preferences.interfaceMode,
              userScale: preferences.interfaceScale,
            );

            return InterfaceScaleViewport(
              mediaQuery: mq,
              scale: scale,
              child: content,
            );
          },
        );
      },
    );
  }
}

/// App-wide, non-interactive overlays which must remain above every route.
///
/// This lives inside [InterfaceScaleViewport], so notices use the same TV-safe
/// coordinate system as the rest of the interface while remaining visible on
/// Home, Watch Together, and playback routes alike.
class TetoTvGlobalOverlay extends StatelessWidget {
  const TetoTvGlobalOverlay({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [child, const WatchPartyMembershipNoticeOverlay()],
  );
}
