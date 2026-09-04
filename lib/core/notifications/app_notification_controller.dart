import 'dart:async';

import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:anime_tv/core/notifications/app_announcement_client.dart';
import 'package:anime_tv/core/notifications/app_notification_store.dart';
import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const foregroundAnnouncementRefreshInterval = Duration(minutes: 1);
const foregroundUpdateRefreshInterval = Duration(minutes: 5);

final appNotificationControllerProvider =
    StateNotifierProvider<AppNotificationController, AppNotificationState>((
      ref,
    ) {
      // Widget tests and source-development builds must never contact the
      // production announcement authority. Installed APKs are release builds;
      // parser/controller tests inject their own client explicitly.
      final announcementClient = kReleaseMode
          ? AppAnnouncementClient(baseUrl: AppConfig.appAnnouncementBaseUrl)
          : null;
      final controller = AppNotificationController(
        AppNotificationStore(ref.watch(tetoTvDatabaseProvider)),
        announcementApi: announcementClient,
      );
      unawaited(controller.load());
      AppNotificationRefreshScheduler? refreshScheduler;
      if (announcementClient != null) {
        unawaited(controller.refreshAnnouncements());
        refreshScheduler = AppNotificationRefreshScheduler(
          refreshAnnouncements: controller.refreshAnnouncements,
          refreshAppUpdate: () => ref
              .read(appUpdateControllerProvider.notifier)
              .checkForUpdates(
                automatic: true,
                launchInstaller: false,
                // Automatic-download consent is enforced by the updater. This
                // foreground check still discovers release metadata when the
                // preference is off, and downloads when it is on.
                downloadAvailable: true,
              ),
        );
        refreshScheduler.start();
      }
      ref.onDispose(() {
        refreshScheduler?.dispose();
        announcementClient?.close();
      });
      // Download progress can update the updater state once per percentage.
      // Reconcile only when notification-relevant identity/state changes so a
      // large APK does not enqueue a hundred redundant SQLite transactions.
      ref.listen(
        appUpdateControllerProvider.select(
          (state) => (
            loaded: state.loaded,
            phase: state.phase,
            currentVersion: state.currentVersion,
            releaseVersion: state.release?.version,
            releaseVersionCode: state.release?.androidVersionCode,
            releaseNotes: state.release?.notes,
            channel: state.updateChannel,
          ),
        ),
        (_, _) => unawaited(
          controller.syncAppUpdate(ref.read(appUpdateControllerProvider)),
        ),
        fireImmediately: true,
      );
      return controller;
    });

class AppNotificationState {
  const AppNotificationState({
    this.loaded = false,
    this.items = const [],
    this.errorMessage,
  });

  final bool loaded;
  final List<AppNotification> items;
  final String? errorMessage;

  int get unreadCount => items.where((item) => !item.isRead).length;

  /// Notifications that still belong in the visible inbox.
  ///
  /// A read timestamp doubles as a durable dismissal tombstone. Remote
  /// announcement refreshes and update reconciliation preserve that timestamp,
  /// so a dismissed message cannot reappear on the next poll or app launch.
  List<AppNotification> get inboxItems =>
      List.unmodifiable(items.where((item) => !item.isRead));

  AppNotificationState copyWith({
    bool? loaded,
    List<AppNotification>? items,
    String? errorMessage,
    bool clearError = false,
  }) => AppNotificationState(
    loaded: loaded ?? this.loaded,
    items: items ?? this.items,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

typedef AppNotificationClock = DateTime Function();

/// Keeps the inbox current while TetoTV is visible without waking a suspended
/// TV or stacking network calls when a slow request outlives its interval.
///
/// The first announcement fetch and first update check remain owned by their
/// existing startup paths. Resuming the app refreshes both immediately, while
/// normal foreground use follows the bounded polling intervals below.
class AppNotificationRefreshScheduler with WidgetsBindingObserver {
  AppNotificationRefreshScheduler({
    required this.refreshAnnouncements,
    required this.refreshAppUpdate,
    this.announcementInterval = foregroundAnnouncementRefreshInterval,
    this.updateInterval = foregroundUpdateRefreshInterval,
  });

  final Future<void> Function() refreshAnnouncements;
  final Future<void> Function() refreshAppUpdate;
  final Duration announcementInterval;
  final Duration updateInterval;

  Timer? _announcementTimer;
  Timer? _updateTimer;
  bool _announcementRefreshInFlight = false;
  bool _updateRefreshInFlight = false;
  bool _foreground = false;
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _startForegroundTimers();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      _startForegroundTimers();
      _runAnnouncementRefresh();
      _runUpdateRefresh();
    } else {
      _stopForegroundTimers();
    }
  }

  void _startForegroundTimers() {
    _foreground = true;
    _announcementTimer ??= Timer.periodic(
      announcementInterval,
      (_) => _runAnnouncementRefresh(),
    );
    _scheduleNextUpdateRefresh();
  }

  void _stopForegroundTimers() {
    _foreground = false;
    _announcementTimer?.cancel();
    _announcementTimer = null;
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  void _scheduleNextUpdateRefresh({bool reset = false}) {
    if (_disposed || !_foreground) return;
    if (reset) {
      _updateTimer?.cancel();
      _updateTimer = null;
    }
    _updateTimer ??= Timer(updateInterval, () {
      _updateTimer = null;
      _runUpdateRefresh();
    });
  }

  void _runAnnouncementRefresh() {
    if (_disposed || _announcementRefreshInFlight) return;
    _announcementRefreshInFlight = true;
    unawaited(_guardAnnouncementRefresh());
  }

  Future<void> _guardAnnouncementRefresh() async {
    try {
      await refreshAnnouncements();
    } catch (_) {
      // Foreground refresh is best-effort and must never disrupt the app.
    } finally {
      _announcementRefreshInFlight = false;
    }
  }

  void _runUpdateRefresh() {
    if (_disposed || _updateRefreshInFlight) return;
    _updateRefreshInFlight = true;
    unawaited(_guardUpdateRefresh());
  }

  Future<void> _guardUpdateRefresh() async {
    try {
      await refreshAppUpdate();
    } catch (_) {
      // A failed background check can retry on the next interval or resume.
    } finally {
      _updateRefreshInFlight = false;
      // Measure the throttle-compatible interval from completion, rather than
      // from scheduler startup. Network latency must not make the next tick
      // arrive just before the updater's own five-minute check window.
      _scheduleNextUpdateRefresh(reset: true);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopForegroundTimers();
    if (_started) WidgetsBinding.instance.removeObserver(this);
  }
}

class AppNotificationController extends StateNotifier<AppNotificationState> {
  AppNotificationController(
    this._store, {
    this.announcementApi,
    this._clock = _utcNow,
  }) : super(const AppNotificationState());

  final AppNotificationStore _store;
  final AppAnnouncementApi? announcementApi;
  final AppNotificationClock _clock;
  Future<void> _pendingMutation = Future.value();

  Future<void> load() => _enqueue(() async {
    await _reload();
  });

  Future<void> refreshAnnouncements() {
    final api = announcementApi;
    if (api == null) return Future.value();
    return _enqueue(() async {
      final announcements = await api.fetch();
      await _store.syncAnnouncements(announcements);
      await _reload();
    }, exposeError: false);
  }

  /// Reconciles the inbox with the validated state produced by the updater.
  ///
  /// The call is serialized and fully caught so a database problem can never
  /// bubble through an updater listener and break the update itself.
  Future<void> syncAppUpdate(AppUpdateState update) => _enqueue(() async {
    if (!update.loaded) return;
    if (!state.loaded) await _reload();

    // Only the selected channel can be checked or installed. Keeping a notice
    // from the previous channel would give it a button that cannot act on the
    // release it describes, so discard it as soon as the preference changes.
    await _store.deleteAppUpdatesOutsideChannel(update.updateChannel.name);

    final obsolete = state.items
        .where((item) => _isInstalledUpdate(item, update.currentVersion))
        .map((item) => item.id);
    await _store.deleteIds(obsolete);

    if (update.phase == AppUpdatePhase.upToDate) {
      await _store.deleteAppUpdatesForChannel(update.updateChannel.name);
    } else if (_canCreateUpdateNotification(update)) {
      final notification = _notificationFor(update, _clock().toUtc());
      await _store.deleteIds(
        state.items
            .where(
              (item) =>
                  item.kind == AppNotificationKind.appUpdate &&
                  item.targetChannel == update.updateChannel.name &&
                  item.id != notification.id,
            )
            .map((item) => item.id),
      );
      await _store.upsert(notification);
    }
    await _reload();
  });

  Future<void> markRead(String id) => _enqueue(() async {
    await _store.markRead(id, _clock().toUtc());
    await _reload();
  });

  /// Removes one message from the visible inbox without deleting the durable
  /// record that prevents a provider refresh from recreating it.
  Future<void> dismiss(String id) => markRead(id);

  Future<void> markAllRead() => _enqueue(() async {
    await _store.markAllRead(_clock().toUtc());
    await _reload();
  });

  Future<void> _reload() async {
    final items = await _store.load();
    if (!mounted) return;
    state = state.copyWith(loaded: true, items: items, clearError: true);
  }

  Future<void> _enqueue(
    Future<void> Function() operation, {
    bool exposeError = true,
  }) {
    final next = _pendingMutation.then((_) async {
      try {
        await operation();
      } catch (_) {
        if (mounted && exposeError) {
          state = state.copyWith(
            loaded: true,
            errorMessage: 'Could not update notifications.',
          );
        }
      }
    });
    _pendingMutation = next;
    return next;
  }
}

bool _canCreateUpdateNotification(AppUpdateState update) {
  final release = update.release;
  if (release == null) return false;
  final relevantPhase = switch (update.phase) {
    AppUpdatePhase.available ||
    AppUpdatePhase.downloading ||
    AppUpdatePhase.ready ||
    AppUpdatePhase.installing => true,
    _ => false,
  };
  return relevantPhase &&
      shouldOfferAppRelease(
        currentVersion: update.currentVersion,
        releaseVersion: release.version,
        channel: update.updateChannel,
        releaseVersionCode: release.androidVersionCode,
      );
}

AppNotification _notificationFor(AppUpdateState update, DateTime createdAtUtc) {
  final release = update.release!;
  final channel = update.updateChannel;
  final targetVersion = normalizeAppVersion(release.version);
  final identity = release.androidVersionCode == null
      ? targetVersion
      : '$targetVersion@${release.androidVersionCode}';
  return AppNotification(
    id: 'app-update:${channel.name}:$identity',
    kind: AppNotificationKind.appUpdate,
    title: 'TetoTV ${channel.versionLabel(targetVersion)} is available',
    body: _releaseNotesSummary(release.notes, channel),
    action: AppNotificationAction.openAppUpdates,
    createdAtUtc: createdAtUtc,
    targetVersion: targetVersion,
    targetVersionCode: release.androidVersionCode,
    targetChannel: channel.name,
  );
}

bool _isInstalledUpdate(AppNotification item, String currentVersion) {
  if (item.kind != AppNotificationKind.appUpdate ||
      item.targetVersion == null ||
      item.targetChannel == null ||
      currentVersion == 'unknown') {
    return false;
  }
  AppUpdateChannel? channel;
  for (final candidate in AppUpdateChannel.values) {
    if (candidate.name == item.targetChannel) {
      channel = candidate;
      break;
    }
  }
  if (channel == null ||
      appVersionMajor(currentVersion) != channel.releaseMajor) {
    return false;
  }
  return !shouldOfferAppRelease(
    currentVersion: currentVersion,
    releaseVersion: item.targetVersion!,
    channel: channel,
    releaseVersionCode: item.targetVersionCode,
  );
}

DateTime _utcNow() => DateTime.now().toUtc();

String _releaseNotesSummary(String notes, AppUpdateChannel channel) {
  var plainText = notes
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ')
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]*\)'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[#>*_`~|]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (plainText.isEmpty) {
    return 'A new ${channel.displayName} update is ready to install from TetoTV settings.';
  }
  const maximumLength = 480;
  if (plainText.length <= maximumLength) return plainText;
  plainText = plainText.substring(0, maximumLength - 1).trimRight();
  final lastSpace = plainText.lastIndexOf(' ');
  if (lastSpace >= maximumLength ~/ 2) {
    plainText = plainText.substring(0, lastSpace);
  }
  return '$plainText…';
}
