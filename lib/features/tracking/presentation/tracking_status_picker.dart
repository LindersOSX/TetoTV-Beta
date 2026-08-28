import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/material.dart';

class CatalogTrackingSelection {
  const CatalogTrackingSelection.status(this.status) : remove = false;
  const CatalogTrackingSelection.remove() : status = null, remove = true;

  final TrackingListStatus? status;
  final bool remove;
}

Future<CatalogTrackingSelection?> showTrackingStatusPicker(
  BuildContext context, {
  required String title,
  TrackingListStatus? current,
}) => showDialog<CatalogTrackingSelection>(
  context: context,
  barrierDismissible: true,
  builder: (context) => AlertDialog(
    backgroundColor: context.appPalette.surface,
    title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add or update this show on your connected AniList and MAL accounts.',
            style: TextStyle(color: context.appPalette.mutedText),
          ),
          const SizedBox(height: 14),
          TrackingStatusOptions(
            current: current,
            onSelected: (status) => Navigator.of(
              context,
            ).pop(CatalogTrackingSelection.status(status)),
          ),
          if (current != null) ...[
            const SizedBox(height: 14),
            TvFocusable(
              onPressed: () => Navigator.of(
                context,
              ).pop(const CatalogTrackingSelection.remove()),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                alignment: Alignment.center,
                color: const Color(0xFF4A1420),
                child: Row(
                  children: [
                    const Icon(Icons.remove_circle_outline_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Remove from ${current.displayName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Remove deletes the tracker list entry. Dropped keeps the show '
              'in your list as something you started and stopped.',
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ],
  ),
);

class TrackingStatusOptions extends StatelessWidget {
  const TrackingStatusOptions({
    required this.current,
    required this.onSelected,
    super.key,
  });

  final TrackingListStatus? current;
  final ValueChanged<TrackingListStatus> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 9,
    runSpacing: 9,
    children: [
      for (final status in TrackingListStatus.values)
        TvFocusable(
          autofocus:
              status == current ||
              (current == null && status == TrackingListStatus.planToWatch),
          onPressed: () => onSelected(status),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 126,
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            color: status == current
                ? context.appPalette.accent
                : context.appPalette.surfaceRaised,
            child: Text(
              status.displayName,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
    ],
  );
}
