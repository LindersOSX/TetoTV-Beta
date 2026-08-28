import 'dart:async';

import 'package:anime_tv/core/diagnostics/diagnostics_exporter.dart';
import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late Future<_DiagnosticsViewData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_DiagnosticsViewData> _load() async {
    final values = await Future.wait([
      AndroidTvBridge.instance.getDeviceProfile(refresh: true),
      AndroidTvBridge.instance.getAppVersion(),
      TetoTvDatabase.instance.diagnosticsSnapshot(),
      AndroidTvBridge.instance.getRecentLocalCrashSummaries().catchError(
        (_) => const LocalCrashSummaryHistory.empty(),
      ),
      AndroidTvBridge.instance.isTelevision(refresh: true),
    ]);
    return _DiagnosticsViewData(
      profile: values[0] as TvDeviceProfile,
      version: values[1] as AppVersionInfo,
      database: attachRecentCrashSummaries(
        values[2] as Map<String, Object?>,
        (values[3] as LocalCrashSummaryHistory).summaries,
        sourceDroppedOutsideWindow:
            (values[3] as LocalCrashSummaryHistory).droppedOutsideWindow,
        sourceDroppedForCapacity:
            (values[3] as LocalCrashSummaryHistory).droppedForCapacity,
      ),
      isTelevision: values[4] as bool,
    );
  }

  void _refresh() => setState(() => _data = _load());

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.appPalette.background,
    body: SafeArea(
      minimum: context.responsiveScreenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _DiagnosticsAction(
                label: 'Back',
                icon: Icons.arrow_back_rounded,
                autofocus: true,
                onPressed: context.pop,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Diagnostics',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              _DiagnosticsAction(
                label: 'Refresh',
                icon: Icons.refresh_rounded,
                onPressed: _refresh,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<_DiagnosticsViewData>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Diagnostics failed: ${snapshot.error}'),
                  );
                }
                final data = snapshot.data;
                if (data == null) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: context.appPalette.accentBright,
                    ),
                  );
                }
                return _DiagnosticsBody(data: data);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _DiagnosticsBody extends StatelessWidget {
  const _DiagnosticsBody({required this.data});

  final _DiagnosticsViewData data;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final events = (data.database['diagnosticEvents'] as List? ?? const [])
        .whereType<Map>()
        .toList(growable: false)
        .reversed
        .take(12);
    final hardwareCodecs =
        data.profile.codecs
            .where((codec) => codec.hardware)
            .map((codec) => codec.mime)
            .toSet()
            .toList()
          ..sort();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: palette.primaryText.withValues(alpha: .08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SUPPORT REPORT',
                style: TextStyle(
                  color: palette.accentBright,
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'A complete bounded dump of device capabilities, player health, performance timings, provider health, and the preceding 48 hours of persisted app events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, URLs, file paths, and network addresses are removed before it leaves the TV.',
                style: TextStyle(color: palette.mutedText),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  _SendDiagnosticsAction(data: data),
                  _DiagnosticsAction(
                    label: 'Copy full report',
                    icon: Icons.copy_rounded,
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _reportText(data)),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Full redacted report copied.'),
                        ),
                      );
                    },
                  ),
                  _DiagnosticsAction(
                    label: 'Export full report',
                    icon: Icons.file_download_outlined,
                    onPressed: () async {
                      final file = await const DiagnosticsExporter().export();
                      await Clipboard.setData(ClipboardData(text: file.path));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Saved report: ${file.path}')),
                      );
                    },
                  ),
                  _DiagnosticsAction(
                    label: 'Device calibration',
                    icon: Icons.tune_rounded,
                    onPressed: () => context.push('/settings/device-setup'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _DiagnosticCard(
              title: 'APP',
              value: 'TetoTV ${data.version.name}',
              detail: 'Build ${data.version.code}',
              icon: Icons.tv_rounded,
            ),
            _DiagnosticCard(
              title: 'DEVICE',
              value: '${data.profile.manufacturer} ${data.profile.model}',
              detail:
                  'Android ${data.profile.sdk} • ${data.profile.abis.join(', ')}',
              icon: Icons.devices_rounded,
            ),
            _DiagnosticCard(
              title: 'DISPLAY',
              value: data.profile.hasHdr ? 'HDR available' : 'SDR display',
              detail: '${data.profile.displayModes.length} display mode(s)',
              icon: Icons.monitor_rounded,
            ),
            _DiagnosticCard(
              title: 'VIDEO DECODERS',
              value: '${hardwareCodecs.length} hardware format(s)',
              detail: hardwareCodecs.isEmpty
                  ? 'No hardware decoders reported'
                  : hardwareCodecs.join(', '),
              icon: Icons.video_settings_rounded,
            ),
          ],
        ),
        const SizedBox(height: 14),
        PlaybackSessionDiagnosticsPanel(diagnostics: data.database),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'RECENT REDACTED EVENTS',
                style: TextStyle(
                  color: palette.accentBright,
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 8),
              if (events.isEmpty)
                Text(
                  'No recent playback or provider failures.',
                  style: TextStyle(color: palette.mutedText),
                )
              else
                for (final event in events) ...[
                  Text(
                    '${event['severity'] ?? 'info'} • ${event['component'] ?? 'event'} • ${event['timestamp'] ?? ''}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${event['message'] ?? ''}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.mutedText, fontSize: 10),
                  ),
                  const Divider(height: 14),
                ],
            ],
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}

/// TV-friendly playback session comparison rendered from the same bounded,
/// redacted data included in explicit support reports.
class PlaybackSessionDiagnosticsPanel extends StatelessWidget {
  const PlaybackSessionDiagnosticsPanel({required this.diagnostics, super.key});

  final Map<String, Object?> diagnostics;

  @override
  Widget build(BuildContext context) {
    final derived = diagnostics['playbackSessions'] is List
        ? diagnostics
        : derivePlaybackSessionDiagnostics(diagnostics['diagnosticEvents']);
    final sessions = (derived['playbackSessions'] as List? ?? const [])
        .whereType<Map>()
        .take(4)
        .toList(growable: false);
    final comparison = derived['playbackSessionComparison'] as Map? ?? const {};
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.primaryText.withValues(alpha: .08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PLAYBACK SESSION TIMELINES',
            style: TextStyle(
              color: palette.accentBright,
              fontWeight: FontWeight.w900,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Privacy-safe stages correlate source selection, stream opening, decoder choice, fallback attempts, and the final result. Media names, addresses, URLs, filenames, headers, and server IDs are never shown.',
            style: TextStyle(color: palette.mutedText, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Text(
            'WORKING VS FAILED PLAYBACK',
            style: TextStyle(
              color: palette.primaryText,
              fontWeight: FontWeight.w900,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 8),
          if (comparison['available'] != true)
            Text(
              'A completed working session and a failed session are needed before TetoTV can compare them.',
              style: TextStyle(color: palette.mutedText, fontSize: 11),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth >= 680
                    ? (constraints.maxWidth - 10) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: _PlaybackComparisonCard(
                        title: 'WORKING SESSION',
                        value: comparison['working'] as Map,
                        successful: true,
                      ),
                    ),
                    SizedBox(
                      width: cardWidth,
                      child: _PlaybackComparisonCard(
                        title: 'FAILED SESSION',
                        value: comparison['failed'] as Map,
                        successful: false,
                      ),
                    ),
                  ],
                );
              },
            ),
          const SizedBox(height: 14),
          if (sessions.isEmpty)
            Text(
              'No correlated playback sessions have been recorded yet.',
              style: TextStyle(color: palette.mutedText, fontSize: 11),
            )
          else
            for (var index = 0; index < sessions.length; index++) ...[
              _PlaybackTimelineCard(index: index + 1, session: sessions[index]),
              if (index + 1 < sessions.length) const SizedBox(height: 9),
            ],
        ],
      ),
    );
  }
}

class _PlaybackComparisonCard extends StatelessWidget {
  const _PlaybackComparisonCard({
    required this.title,
    required this.value,
    required this.successful,
  });

  final String title;
  final Map value;
  final bool successful;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final accent = successful
        ? const Color(0xFF62D394)
        : const Color(0xFFFF6B78);
    return Semantics(
      label: '$title ${_outcomeLabel(value['finalOutcome'])}',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: palette.selectableSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: .72)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  successful
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 7),
                Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              '${_sourceKindLabel(value['sourceKind'])} • ${_decoderLabel(value['decoder'])}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
            ),
            const SizedBox(height: 3),
            Text(
              'Codec ${_technicalLabel(value['codec'])}${value['decoderName'] == null || value['decoderName'] == 'unknown' ? '' : ' • ${_technicalLabel(value['decoderName'])}'} • ${value['fallbackAttempts'] ?? 0} fallback attempt(s) • ${value['observedStageCount'] ?? 0}/5 stages observed',
              style: TextStyle(color: palette.mutedText, fontSize: 10),
            ),
            const SizedBox(height: 3),
            Text(
              '${_outcomeLabel(value['finalOutcome'])} • ${_timestampLabel(value['lastEventAt'])}',
              style: TextStyle(color: palette.mutedText, fontSize: 10),
            ),
            if (value['finalReasonCode'] != null) ...[
              const SizedBox(height: 3),
              Text(
                'Reason: ${_technicalLabel(value['finalReasonCode'])}',
                style: TextStyle(color: palette.mutedText, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlaybackTimelineCard extends StatelessWidget {
  const _PlaybackTimelineCard({required this.index, required this.session});

  final int index;
  final Map session;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final timeline = (session['timeline'] as List? ?? const [])
        .whereType<Map>()
        .toList(growable: false);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SESSION $index • ${_outcomeLabel(session['finalOutcome'])} • ${_timestampLabel(session['startedAt'])}',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10),
          ),
          const SizedBox(height: 8),
          for (var eventIndex = 0; eventIndex < timeline.length; eventIndex++)
            _PlaybackTimelineRow(
              event: timeline[eventIndex],
              last: eventIndex + 1 == timeline.length,
            ),
        ],
      ),
    );
  }
}

class _PlaybackTimelineRow extends StatelessWidget {
  const _PlaybackTimelineRow({required this.event, required this.last});

  final Map event;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final stage = event['stage']?.toString() ?? 'event';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                Icon(
                  _stageIcon(stage),
                  size: 16,
                  color: _stageColor(context, stage, event['status']),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: palette.primaryText.withValues(alpha: .16),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 8),
              child: Text(
                _timelineEventLabel(event),
                style: TextStyle(color: palette.mutedText, fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _timelineEventLabel(Map event) {
  final stage = switch (event['stage']) {
    'source_selected' => 'Source selected',
    'stream_opened' => 'Stream open',
    'decoder_selected' => 'Decoder selected',
    'fallback_attempted' => 'Fallback attempted',
    'final_outcome' => 'Final outcome',
    _ => 'Playback event',
  };
  final details = <String>[
    if (event['sourceKind'] != null) _sourceKindLabel(event['sourceKind']),
    if (event['decoder'] != null) _decoderLabel(event['decoder']),
    if (event['codec'] != null) 'codec ${_technicalLabel(event['codec'])}',
    if (event['decoderName'] != null)
      'backend ${_technicalLabel(event['decoderName'])}',
    if (event['fallbackKind'] != null)
      '${_technicalLabel(event['fallbackKind'])} fallback',
    if (event['reasonCode'] != null) _technicalLabel(event['reasonCode']),
    if (event['status'] != null) _outcomeLabel(event['status']),
  ];
  return details.isEmpty ? stage : '$stage • ${details.join(' • ')}';
}

IconData _stageIcon(String stage) => switch (stage) {
  'source_selected' => Icons.video_library_outlined,
  'stream_opened' => Icons.play_circle_outline_rounded,
  'decoder_selected' => Icons.memory_rounded,
  'fallback_attempted' => Icons.swap_horiz_rounded,
  'final_outcome' => Icons.flag_outlined,
  _ => Icons.circle_outlined,
};

Color _stageColor(BuildContext context, String stage, Object? status) {
  if (status == 'failed' || status == 'open_failed') {
    return const Color(0xFFFF6B78);
  }
  if (stage == 'fallback_attempted') return const Color(0xFFFFB85C);
  if (status == 'working' || status == 'completed') {
    return const Color(0xFF62D394);
  }
  return context.appPalette.accentBright;
}

String _sourceKindLabel(Object? value) => switch (value) {
  'torrent' => 'Torrent / Debrid',
  'web' => 'Web stream',
  'plex' => 'Plex',
  'jellyfin' => 'Jellyfin',
  'local' => 'On-device media',
  'private_library' => 'Private library',
  _ => 'Unknown source type',
};

String _decoderLabel(Object? value) => switch (value) {
  'hardware_adaptive' => 'Hardware adaptive',
  'hardware_direct' => 'Hardware direct',
  'software_compatibility' => 'Software compatibility',
  _ => 'Unknown decoder',
};

String _outcomeLabel(Object? value) => switch (value) {
  'selected' => 'Selected',
  'selected_automatically' => 'Selected automatically',
  'selected_by_user' => 'Selected by user',
  'opened' => 'Opened',
  'open_failed' => 'Open failed',
  'attempted' => 'Attempted',
  'working' => 'Working',
  'completed' => 'Completed',
  'failed' => 'Failed',
  'exited_after_start' => 'Exited after playback started',
  'exited_before_start' => 'Exited before playback started',
  'in_progress' => 'In progress',
  _ => _technicalLabel(value),
};

String _technicalLabel(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return 'Unknown';
  return text
      .split('_')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _timestampLabel(Object? value) {
  final timestamp = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (timestamp == null) return 'time unavailable';
  final hour = timestamp.hour % 12 == 0 ? 12 : timestamp.hour % 12;
  final minute = timestamp.minute.toString().padLeft(2, '0');
  final period = timestamp.hour >= 12 ? 'PM' : 'AM';
  return '${timestamp.month}/${timestamp.day} $hour:$minute $period';
}

class _SendDiagnosticsAction extends StatefulWidget {
  const _SendDiagnosticsAction({required this.data});

  final _DiagnosticsViewData data;

  @override
  State<_SendDiagnosticsAction> createState() => _SendDiagnosticsActionState();
}

class _SendDiagnosticsActionState extends State<_SendDiagnosticsAction> {
  bool _sending = false;

  Future<void> _send() async {
    if (_sending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send diagnostic report?'),
        content: const Text(
          'This posts the complete bounded, redacted technical dump shown in Diagnostics to TetoTV’s private Discord support channel. It includes the app build, device capabilities, player and provider health, performance timings, and the preceding 48 hours of persisted events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, file paths, and network addresses are excluded.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Send report'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _sending = true);
    try {
      final data = widget.data;
      final report = ExplicitDiagnosticsReport.fromSnapshot(
        version: data.version,
        profile: data.profile,
        isTelevision: data.isTelevision,
        diagnostics: data.database,
      );
      final acknowledgement = await ExplicitDiagnosticsReportClient().send(
        report,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            acknowledgement.duplicate
                ? 'Diagnostic report was already received. Reference: ${acknowledgement.reference}'
                : 'Diagnostic report sent. Reference: ${acknowledgement.reference}',
          ),
        ),
      );
    } on DiagnosticsShareException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The diagnostic report could not be sent. Try again shortly.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => _DiagnosticsAction(
    label: _sending ? 'Sending…' : 'Send to support',
    icon: _sending ? Icons.hourglass_top_rounded : Icons.send_rounded,
    primary: true,
    onPressed: _send,
  );
}

String _reportText(_DiagnosticsViewData data) => buildRedactedDiagnosticsText(
  version: data.version,
  profile: data.profile,
  isTelevision: data.isTelevision,
  diagnostics: data.database,
  generatedAt: DateTime.now().toUtc(),
);

class _DiagnosticCard extends StatelessWidget {
  const _DiagnosticCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 285,
    height: 112,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: context.appPalette.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: context.appPalette.primaryText.withValues(alpha: .07),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: context.appPalette.accentBright),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: context.appPalette.mutedText,
                  fontSize: 9,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.appPalette.mutedText,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _DiagnosticsAction extends StatelessWidget {
  const _DiagnosticsAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final foreground = primary
        ? contrastForeground(palette.accent)
        : palette.primaryText;
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 41,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: primary ? palette.accent : palette.selectableSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.primaryText.withValues(alpha: .1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsViewData {
  const _DiagnosticsViewData({
    required this.profile,
    required this.version,
    required this.database,
    required this.isTelevision,
  });

  final TvDeviceProfile profile;
  final AppVersionInfo version;
  final Map<String, Object?> database;
  final bool isTelevision;
}
