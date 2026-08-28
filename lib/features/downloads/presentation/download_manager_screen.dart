import 'dart:async';

import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/features/downloads/application/downloaded_episode_source_service.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class DownloadManagerScreen extends ConsumerStatefulWidget {
  const DownloadManagerScreen({this.autofocusNavigation = false, super.key});

  final bool autofocusNavigation;

  @override
  ConsumerState<DownloadManagerScreen> createState() =>
      _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends ConsumerState<DownloadManagerScreen> {
  final _refreshFocus = FocusNode(debugLabel: 'downloads.refresh');
  final _firstContentFocus = FocusNode(debugLabel: 'downloads.content.first');
  final _classicNavigationFocus = FocusNode(debugLabel: 'downloads.navigation');

  @override
  void dispose() {
    _refreshFocus.dispose();
    _firstContentFocus.dispose();
    _classicNavigationFocus.dispose();
    super.dispose();
  }

  void _refresh(DownloadManagerController controller) {
    unawaited(controller.initialize());
    unawaited(controller.refreshStorageUsage());
  }

  KeyEventResult _moveToContent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _refreshFocus.requestFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(settingsPreferencesProvider);
    // Do not construct the manager (which initializes its persisted queue)
    // until the encrypted master preference has finished loading. Otherwise
    // a disabled installation opened through a deep link can briefly expose
    // and start the Downloads surface using the constructor default.
    if (!preferences.loaded) {
      return const Scaffold(body: SizedBox.shrink());
    }
    if (!preferences.offlineDownloadsEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        GoRouter.maybeOf(context)?.go('/settings/accounts');
      });
      return const Scaffold(body: SizedBox.shrink());
    }
    final state = ref.watch(downloadManagerProvider);
    final season = ref.watch(seasonDownloadControllerProvider);
    final controller = ref.read(downloadManagerProvider.notifier);
    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: TopNavigationDestination.downloads,
      firstContentFocusNode: _refreshFocus,
      autofocusRail: widget.autofocusNavigation,
      onActiveDestinationPressed: () => _refresh(controller),
      builder: (context, layout) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!layout.usesPersistentNavigation)
            Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) => _moveToContent(event),
              child: MainNavigationBar(
                active: MainNavigationDestination.downloads,
                preferences: preferences,
                activeFocusNode: _classicNavigationFocus,
                onActivePressed: () => _refresh(controller),
              ),
            ),
          Expanded(
            child: Padding(
              padding: layout.usesSideNavigation
                  ? EdgeInsets.zero
                  : const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Downloads',
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            Text(
                              '${state.jobs.length} item${state.jobs.length == 1 ? '' : 's'}'
                              ' • ${_formatBytes(state.storageUsedBytes)} used',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      _ManagerButton(
                        key: const ValueKey('downloads-refresh'),
                        autofocus: true,
                        focusNode: _refreshFocus,
                        icon: Icons.refresh_rounded,
                        label: 'Refresh',
                        onLeftEdge: () {
                          if (_firstContentFocus.context != null) {
                            _firstContentFocus.requestFocus();
                          } else if (layout.usesPersistentNavigation) {
                            layout.focusRail();
                          } else {
                            _classicNavigationFocus.requestFocus();
                          }
                        },
                        onPressed: () => _refresh(controller),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (season.isRunning) ...[
                    _SeasonDownloadBanner(
                      state: season,
                      focusNode: _firstContentFocus,
                      onCancel: () => ref
                          .read(seasonDownloadControllerProvider.notifier)
                          .cancel(),
                      onLeftEdge: layout.usesPersistentNavigation
                          ? layout.focusRail
                          : _classicNavigationFocus.requestFocus,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (state.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.errorContainer.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(state.errorMessage!),
                        ),
                      ),
                    ),
                  Expanded(
                    child: state.loading && state.jobs.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : state.jobs.isEmpty
                        ? const _EmptyDownloads()
                        : ListView.separated(
                            key: const ValueKey('downloads-list'),
                            padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
                            itemCount: state.jobs.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 14),
                            itemBuilder: (context, index) => _DownloadJobCard(
                              job: state.jobs[index],
                              controller: controller,
                              firstActionFocusNode:
                                  index == 0 && !season.isRunning
                                  ? _firstContentFocus
                                  : null,
                              onLeftEdge: layout.usesPersistentNavigation
                                  ? layout.focusRail
                                  : _classicNavigationFocus.requestFocus,
                              onPlay: () => unawaited(
                                _openCompletedDownload(
                                  context,
                                  ref,
                                  state.jobs[index],
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.download_done_rounded,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'No offline episodes yet',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Long-press a torrent or web source, or choose Download season on a show.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _SeasonDownloadBanner extends StatelessWidget {
  const _SeasonDownloadBanner({
    required this.state,
    required this.onCancel,
    required this.onLeftEdge,
    this.focusNode,
  });

  final SeasonDownloadState state;
  final VoidCallback onCancel;
  final VoidCallback onLeftEdge;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final processed = state.processed.clamp(0, state.total);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.phase == SeasonDownloadPhase.preparing
                  ? 'Preparing season download…'
                  : 'Downloading season • $processed of ${state.total}',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: state.phase == SeasonDownloadPhase.preparing
                  ? null
                  : state.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(20),
            ),
            const SizedBox(height: 5),
            Text(
              '${state.queued} saved • ${state.skipped} already added'
              '${state.failed == 0 ? '' : ' • ${state.failed} unavailable'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
        final cancel = _ManagerButton(
          key: const ValueKey('downloads-season-cancel'),
          focusNode: focusNode,
          icon: Icons.cancel_outlined,
          label: 'Cancel season',
          onLeftEdge: onLeftEdge,
          onPressed: onCancel,
        );
        return Material(
          key: const ValueKey('downloads-season-progress'),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.video_library_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 13),
                          Expanded(child: details),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerLeft, child: cancel),
                    ],
                  )
                : Row(
                    children: [
                      Icon(
                        Icons.video_library_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 13),
                      Expanded(child: details),
                      const SizedBox(width: 16),
                      cancel,
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _DownloadJobCard extends StatelessWidget {
  const _DownloadJobCard({
    required this.job,
    required this.controller,
    required this.onPlay,
    required this.onLeftEdge,
    this.firstActionFocusNode,
  });

  final DownloadJob job;
  final DownloadManagerController controller;
  final VoidCallback onPlay;
  final VoidCallback onLeftEdge;
  final FocusNode? firstActionFocusNode;

  @override
  Widget build(BuildContext context) {
    final progress = job.progress;
    final colorScheme = Theme.of(context).colorScheme;
    final actions = <Widget>[];
    void addAction({
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
    }) {
      actions.add(
        _ManagerButton(
          icon: icon,
          label: label,
          focusNode: actions.isEmpty ? firstActionFocusNode : null,
          onLeftEdge: actions.isEmpty ? onLeftEdge : null,
          onPressed: onPressed,
        ),
      );
    }

    if (job.status == DownloadJobStatus.completed) {
      addAction(
        icon: Icons.play_arrow_rounded,
        label: 'Play',
        onPressed: onPlay,
      );
    }
    if (job.status.canPause) {
      addAction(
        icon: Icons.pause_rounded,
        label: 'Pause',
        onPressed: () => unawaited(controller.pause(job.id)),
      );
    }
    if (job.status == DownloadJobStatus.paused) {
      addAction(
        icon: Icons.play_arrow_rounded,
        label: 'Resume',
        onPressed: () => unawaited(controller.resume(job.id)),
      );
    }
    if (job.status == DownloadJobStatus.failed) {
      addAction(
        icon: Icons.replay_rounded,
        label: 'Retry',
        onPressed: () => unawaited(controller.retry(job.id)),
      );
    }
    if (!job.status.isTerminal && job.status != DownloadJobStatus.failed) {
      addAction(
        icon: Icons.cancel_outlined,
        label: 'Cancel',
        onPressed: () => unawaited(controller.cancel(job.id)),
      );
    }
    if (job.status == DownloadJobStatus.completed ||
        job.status == DownloadJobStatus.cancelled ||
        job.status == DownloadJobStatus.unsupported ||
        job.status == DownloadJobStatus.failed) {
      addAction(
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        onPressed: () => unawaited(controller.delete(job.id)),
      );
    }
    return Material(
      color: colorScheme.surfaceContainerHigh.withValues(alpha: .78),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_statusIcon(job.status), color: colorScheme.primary),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${job.seriesTitle} • Episode ${job.episode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          job.providerName ?? job.sourceLabel,
                          if (job.quality?.isNotEmpty == true) job.quality!,
                          if (job.audioLabel?.isNotEmpty == true)
                            job.audioLabel!,
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  _statusLabel(job.status),
                  style: TextStyle(
                    color: _statusColor(context, job.status),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            LinearProgressIndicator(
              value: progress ?? (job.status.isActive ? null : 0),
              minHeight: 7,
              borderRadius: BorderRadius.circular(20),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _progressLabel(job),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (job.speedBytesPerSecond > 0)
                  Text(
                    '${_formatBytes(job.speedBytesPerSecond)}/s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (job.errorMessage case final message?) ...[
              const SizedBox(height: 9),
              Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.error),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: actions),
          ],
        ),
      ),
    );
  }
}

Future<void> _openCompletedDownload(
  BuildContext context,
  WidgetRef ref,
  DownloadJob job,
) async {
  final asset = await ref
      .read(downloadedEpisodeSourceServiceProvider)
      .completedJob(job.id);
  if (!context.mounted) return;
  if (asset == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This downloaded episode is missing or incomplete.'),
      ),
    );
    return;
  }

  final episode = EpisodeReference(
    anilistMediaId: job.anilistMediaId,
    malMediaId: job.malMediaId,
    title: job.seriesTitle,
    episode: job.episode,
  );
  final launch = downloadedEpisodePlaybackLaunch(
    asset: asset,
    episode: episode,
  );
  final route = Uri(
    path: '/player',
    queryParameters: {
      'source': launch.stream.uri.toString(),
      'title': launch.stream.displayName,
      'anilistId': '${job.anilistMediaId}',
      if (job.malMediaId != null) 'malId': '${job.malMediaId}',
      'episode': '${job.episode}',
    },
  );
  context.push(route.toString(), extra: launch);
}

class _ManagerButton extends StatelessWidget {
  const _ManagerButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.onLeftEdge,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onLeftEdge;

  @override
  Widget build(BuildContext context) => TvFocusable(
    autofocus: autofocus,
    focusNode: focusNode,
    onKeyEvent: onLeftEdge == null
        ? null
        : (_, event) {
            if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
              return KeyEventResult.ignored;
            }
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              onLeftEdge!();
            }
            return KeyEventResult.handled;
          },
    onPressed: onPressed,
    focusScale: 1.025,
    borderRadius: BorderRadius.circular(13),
    child: Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 21),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    ),
  );
}

IconData _statusIcon(DownloadJobStatus status) => switch (status) {
  DownloadJobStatus.queued => Icons.schedule_rounded,
  DownloadJobStatus.resolving => Icons.manage_search_rounded,
  DownloadJobStatus.downloading => Icons.downloading_rounded,
  DownloadJobStatus.paused => Icons.pause_circle_outline_rounded,
  DownloadJobStatus.completed => Icons.download_done_rounded,
  DownloadJobStatus.failed => Icons.error_outline_rounded,
  DownloadJobStatus.cancelled => Icons.cancel_outlined,
  DownloadJobStatus.unsupported => Icons.block_rounded,
};

String _statusLabel(DownloadJobStatus status) => switch (status) {
  DownloadJobStatus.queued => 'QUEUED',
  DownloadJobStatus.resolving => 'PREPARING',
  DownloadJobStatus.downloading => 'DOWNLOADING',
  DownloadJobStatus.paused => 'PAUSED',
  DownloadJobStatus.completed => 'DOWNLOADED',
  DownloadJobStatus.failed => 'FAILED',
  DownloadJobStatus.cancelled => 'CANCELLED',
  DownloadJobStatus.unsupported => 'UNSUPPORTED',
};

Color _statusColor(BuildContext context, DownloadJobStatus status) =>
    switch (status) {
      DownloadJobStatus.completed => Colors.greenAccent,
      DownloadJobStatus.failed ||
      DownloadJobStatus.unsupported => Theme.of(context).colorScheme.error,
      DownloadJobStatus.cancelled => Theme.of(
        context,
      ).colorScheme.onSurfaceVariant,
      _ => Theme.of(context).colorScheme.primary,
    };

String _progressLabel(DownloadJob job) {
  final received = _formatBytes(job.receivedBytes);
  final expected = job.expectedBytes;
  if (expected == null) return received;
  final percent = ((job.progress ?? 0) * 100).toStringAsFixed(0);
  return '$received of ${_formatBytes(expected)} • $percent%';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} ${units[unit]}';
}
