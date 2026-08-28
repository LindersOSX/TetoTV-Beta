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

  final String? status;

  @override
  Widget build(BuildContext context) {
    final label = animeAiringStatusLabel(status);
    if (label == null) return const SizedBox.shrink();
    final airing = label == 'AIRING';
    final unreleased = label == 'UNRELEASED';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: airing
            ? const Color(0xF21A7A45)
            : unreleased
            ? const Color(0xF2591120)
            : const Color(0xF21B1B1B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: .22)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          maxLines: 1,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: .45,
            height: 1,
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
              _PosterBadge(text: '$value', color: const Color(0xFF59111F)),
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
