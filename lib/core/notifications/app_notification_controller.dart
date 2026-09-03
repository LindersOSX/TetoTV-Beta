import 'dart:async';

import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:anime_tv/core/notifications/app_notification_store.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final appNotificationControllerProvider =
    StateNotifierProvider<AppNotificationController, AppNotificationState>((
      ref,
    ) {
      final controller = AppNotificationController(
        AppNotificationStore(ref.watch(tetoTvDatabaseProvider)),
      );
      unawaited(controller.load());
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

class AppNotificationController extends StateNotifier<AppNotificationState> {
  AppNotificationController(this._store, {this._clock = _utcNow})
    : super(const AppNotificationState());

  final AppNotificationStore _store;
  final AppNotificationClock _clock;
  Future<void> _pendingMutation = Future.value();

  Future<void> load() => _enqueue(() async {
    await _reload();
  });

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

  Future<void> markAllRead() => _enqueue(() async {
    await _store.markAllRead(_clock().toUtc());
    await _reload();
  });

  Future<void> _reload() async {
    final items = await _store.load();
    if (!mounted) return;
    state = state.copyWith(loaded: true, items: items, clearError: true);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _pendingMutation.then((_) async {
      try {
        await operation();
      } catch (_) {
        if (mounted) {
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
