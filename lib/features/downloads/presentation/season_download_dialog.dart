import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:flutter/material.dart';

Future<SeasonDownloadSelection?> showSeasonDownloadDialog(
  BuildContext context, {
  required bool directTorrentAvailable,
}) {
  return showDialog<SeasonDownloadSelection>(
    context: context,
    builder: (_) =>
        _SeasonDownloadDialog(directTorrentAvailable: directTorrentAvailable),
  );
}

Future<bool> confirmDirectSeasonDownload(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('season-download-direct-warning'),
          title: Text(context.tr("Download without Debrid?")),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              context.tr(
                "Direct torrent downloads connect to peers. Your public IP address may be visible to them. This choice applies to the entire season.",
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('season-download-direct-cancel'),
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.tr("Cancel")),
            ),
            FilledButton(
              key: const ValueKey('season-download-direct-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.tr("Continue")),
            ),
          ],
        ),
      ) ??
      false;
}

class _SeasonDownloadDialog extends StatefulWidget {
  const _SeasonDownloadDialog({required this.directTorrentAvailable});

  final bool directTorrentAvailable;

  @override
  State<_SeasonDownloadDialog> createState() => _SeasonDownloadDialogState();
}

class _SeasonDownloadDialogState extends State<_SeasonDownloadDialog> {
  SeasonDownloadQuality _quality = SeasonDownloadQuality.best;
  SeasonDownloadSourcePolicy _source = SeasonDownloadSourcePolicy.automatic;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return AlertDialog(
      key: const ValueKey('season-download-dialog'),
      title: Text(context.tr("Download season")),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 560),
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ChoiceSection(
                    title: context.tr("Quality"),
                    children: [
                      for (final quality in SeasonDownloadQuality.values)
                        _SelectionTile(
                          key: ValueKey(
                            'season-download-quality-${quality.name}',
                          ),
                          label: context.tr(quality.displayName),
                          autofocus: quality == SeasonDownloadQuality.best,
                          selected: _quality == quality,
                          accent: palette.accentBright,
                          onPressed: () => setState(() => _quality = quality),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: _ChoiceSection(
                    title: context.tr("Source"),
                    children: [
                      for (final source in SeasonDownloadSourcePolicy.values)
                        _SelectionTile(
                          key: ValueKey(
                            'season-download-source-${source.name}',
                          ),
                          label: context.tr(source.displayName),
                          description:
                              source ==
                                      SeasonDownloadSourcePolicy
                                          .directTorrent &&
                                  !widget.directTorrentAvailable
                              ? context.tr(
                                  "Enable direct torrent streaming in Settings",
                                )
                              : context.tr(source.description),
                          selected: _source == source,
                          accent: palette.accentBright,
                          onPressed:
                              source ==
                                      SeasonDownloadSourcePolicy
                                          .directTorrent &&
                                  !widget.directTorrentAvailable
                              ? null
                              : () => setState(() => _source = source),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('season-download-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr("Cancel")),
        ),
        FilledButton.icon(
          key: const ValueKey('season-download-start'),
          onPressed: () => Navigator.pop(
            context,
            SeasonDownloadSelection(quality: _quality, sourcePolicy: _source),
          ),
          icon: const Icon(Icons.download_rounded),
          label: Text(context.tr("Add to Downloads")),
        ),
      ],
    );
  }
}

class _SelectionTile extends StatelessWidget {
  const _SelectionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onPressed,
    this.description,
    this.autofocus = false,
  });

  final String label;
  final String? description;
  final bool selected;
  final Color accent;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: OutlinedButton(
        autofocus: autofocus,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          side: BorderSide(
            color: selected ? accent : Colors.white.withValues(alpha: .16),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? accent : null,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (description != null)
                    Text(
                      description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceSection extends StatelessWidget {
  const _ChoiceSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        ...children,
      ],
    );
  }
}
