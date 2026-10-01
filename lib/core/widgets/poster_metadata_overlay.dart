import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

String? animeAiringStatusLabel(String? status) {
  final normalized = status
      ?.trim()
      .toUpperCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  return switch (normalized) {
    'RELEASING' || 'CURRENTLY_AIRING' || 'AIRING' => 'AIRING',
    'FINISHED' || 'FINISHED_AIRING' => 'FINISHED',
    'NOT_YET_RELEASED' ||
    'NOT_YET_AIRED' ||
    'UPCOMING' ||
    'UNRELEASED' ||
    'NOT_RELEASED' ||
    'TBA' => 'UNRELEASED',
    _ => null,
  };
}

class PosterAiringStatusBadge extends StatelessWidget {
  const PosterAiringStatusBadge({required this.status, super.key});

  // 15% larger than the previous compact badges, without returning to the
  // original oversized version.
  static const _sizeFactor = .67 * 1.15;

  final String? status;

  @override
  Widget build(BuildContext context) {
    final label = animeAiringStatusLabel(status);
    if (label == null) return const SizedBox.shrink();
    final (displayLabel, icon, background) = switch (label) {
      'AIRING' => ('Airing', Icons.sensors_rounded, const Color(0xF215964F)),
      'UNRELEASED' => (
        'Unreleased',
        Icons.schedule_rounded,
        const Color(0xF2A0364D),
      ),
      _ => ('Finished', Icons.check_rounded, const Color(0xF222272D)),
    };
    final localizedLabel = context.tr(displayLabel);
    return Semantics(
      label: localizedLabel,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8 * _sizeFactor),
              border: Border.all(
                color: Colors.white.withValues(alpha: .1),
                width: _sizeFactor,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 5 * _sizeFactor,
                vertical: 3 * _sizeFactor,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .16),
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox.square(
                      dimension: 16 * _sizeFactor,
                      child: Icon(
                        icon,
                        size: 12 * _sizeFactor,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4 * _sizeFactor),
                  Flexible(
                    child: Text(
                      localizedLabel,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9 * _sizeFactor,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PosterMetadataOverlay extends StatelessWidget {
  const PosterMetadataOverlay({
    this.score,
    this.releaseYear,
    this.durationMinutes,
    super.key,
  });

  final double? score;
  final int? releaseYear;
  final int? durationMinutes;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xC9000000),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: .14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (score case final value?)
              _PosterBadge(
                text: '★${value.toStringAsFixed(1)}',
                color: context.appPalette.accent,
              ),
            if (releaseYear case final value?) ...[
              const SizedBox(width: 3),
              _PosterBadge(text: '$value', color: context.appPalette.accent),
            ],
            if (durationMinutes case final value?) ...[
              const SizedBox(width: 3),
              _PosterBadge(text: '${value}m', color: const Color(0xFF202020)),
            ],
          ],
        ),
      ),
    );
  }
}

class _PosterBadge extends StatelessWidget {
  const _PosterBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 8,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
