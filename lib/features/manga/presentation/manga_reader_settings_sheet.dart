import 'dart:async';
import 'dart:math' as math;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/application/manga_series_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A bounded settings surface with a persistent close action on phones and TVs.
class MangaReaderSettingsSheet extends ConsumerStatefulWidget {
  const MangaReaderSettingsSheet({
    required this.seriesKey,
    required this.seriesTitle,
    super.key,
  });

  final MangaReaderSeriesKey seriesKey;
  final String seriesTitle;

  @override
  ConsumerState<MangaReaderSettingsSheet> createState() =>
      _MangaReaderSettingsSheetState();
}

class _MangaReaderSettingsSheetState
    extends ConsumerState<MangaReaderSettingsSheet> {
  final _scrollController = ScrollController();
  bool _resetting = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Reset reader settings?'),
        content: const Text(
          'This restores reader settings for all manga and removes the saved '
          'layout for this manga. Saved layouts for other manga, downloads, '
          'and reading progress are kept.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep settings'),
          ),
          FilledButton(
            key: const ValueKey('manga-settings-confirm-reset'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset settings'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final controller = ref.read(mangaReaderPreferencesProvider.notifier);
    final seriesController = ref.read(
      mangaSeriesReaderPreferencesProvider(widget.seriesKey).notifier,
    );
    setState(() => _resetting = true);
    try {
      await Future.wait<void>([controller.reset(), seriesController.reset()]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Some settings could not be reset. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(
      mangaEffectiveReaderPreferencesProvider(widget.seriesKey),
    );
    final global = ref.watch(mangaReaderPreferencesProvider);
    final series = ref.watch(
      mangaSeriesReaderPreferencesProvider(widget.seriesKey),
    );
    final controller = ref.read(mangaReaderPreferencesProvider.notifier);
    final seriesController = ref.read(
      mangaSeriesReaderPreferencesProvider(widget.seriesKey).notifier,
    );
    final ready = global.loaded && series.loaded && !_resetting;
    final paged = prefs.mode == MangaReadingMode.paged;
    final webtoon = prefs.mode == MangaReadingMode.webtoon;
    final spreads = paged && prefs.spreadMode != MangaSpreadMode.single;
    final palette = context.appPalette;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 760,
        maxHeight: math.min(840, MediaQuery.sizeOf(context).height * .9),
      ),
      child: Material(
        color: palette.surface,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 10, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reader settings',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.seriesTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('manga-settings-close'),
                      tooltip: 'Close reader settings',
                      autofocus: true,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (!global.loaded || !series.loaded || _resetting)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    key: const ValueKey('manga-settings-scroll'),
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SettingsSection(
                          title: 'Reading layout',
                          icon: Icons.auto_stories_outlined,
                          help: 'Choose how pages flow and fit your screen.',
                          children: [
                            _SettingSwitch(
                              id: 'remember-layout',
                              label: 'Remember layout for this manga',
                              help: series.enabled
                                  ? 'Mode, direction, spread, and fit are saved '
                                        'only for this manga.'
                                  : 'Off: these four choices update your '
                                        'defaults for all manga.',
                              value: series.enabled,
                              onChanged: ready
                                  ? seriesController.setEnabled
                                  : null,
                            ),
                            const Divider(height: 20),
                            _SettingChoice<MangaReadingMode>(
                              id: 'mode',
                              label: 'Reading mode',
                              help:
                                  'Paged: turn sideways. Vertical: swipe up. '
                                  'Webtoon: one continuous strip.',
                              value: prefs.mode,
                              values: MangaReadingMode.values,
                              name: (value) => value.displayName,
                              onChanged: ready
                                  ? (series.enabled
                                        ? seriesController.setMode
                                        : controller.setMode)
                                  : null,
                            ),
                            _SettingChoice<MangaReadingDirection>(
                              id: 'direction',
                              label: 'Reading direction',
                              help: paged
                                  ? 'Sets page order and forward navigation.'
                                  : 'Sets forward/back tap and remote controls; '
                                        'scrolling stays vertical.',
                              value: prefs.direction,
                              values: MangaReadingDirection.values,
                              name: (value) => value.displayName,
                              onChanged: ready
                                  ? (series.enabled
                                        ? seriesController.setDirection
                                        : controller.setDirection)
                                  : null,
                            ),
                            _SettingChoice<MangaSpreadMode>(
                              id: 'spread',
                              label: 'Page spread',
                              help: paged
                                  ? 'Automatic adapts to your available space.'
                                  : 'Used in Paged mode.',
                              value: prefs.spreadMode,
                              values: MangaSpreadMode.values,
                              name: (value) => value.displayName,
                              onChanged: ready && paged
                                  ? (series.enabled
                                        ? seriesController.setSpreadMode
                                        : controller.setSpreadMode)
                                  : null,
                            ),
                            _SettingChoice<MangaPageFit>(
                              id: 'fit',
                              label: 'Page fit',
                              help: webtoon
                                  ? 'Webtoon pages always fit the strip width.'
                                  : 'Fit page shows the whole page without cropping.',
                              value: prefs.pageFit,
                              values: MangaPageFit.values,
                              name: (value) => value.displayName,
                              onChanged: ready && !webtoon
                                  ? (series.enabled
                                        ? seriesController.setPageFit
                                        : controller.setPageFit)
                                  : null,
                            ),
                          ],
                        ),
                        _SettingsSection(
                          title: 'Page appearance',
                          icon: Icons.palette_outlined,
                          help:
                              'Applies to all manga. Original images stay unchanged.',
                          children: [
                            _SettingChoice<MangaReaderBackground>(
                              id: 'background',
                              label: 'Background',
                              value: prefs.background,
                              values: MangaReaderBackground.values,
                              name: (value) => value.displayName,
                              onChanged: ready
                                  ? controller.setBackground
                                  : null,
                            ),
                            _SettingSlider(
                              id: 'side-padding',
                              label: 'Side margins',
                              help:
                                  'Adds breathing room on both sides of the page.',
                              value: prefs.sidePadding,
                              max: 80,
                              divisions: 16,
                              valueLabel: '${prefs.sidePadding.round()} px',
                              onChanged: ready
                                  ? controller.setSidePadding
                                  : null,
                            ),
                            _SettingSlider(
                              id: 'page-gap',
                              label: 'Page gap',
                              help: spreads
                                  ? 'Space between pages in a double-page spread.'
                                  : 'Used with Automatic or Double page in Paged mode.',
                              value: prefs.pageGap,
                              max: 40,
                              divisions: 8,
                              valueLabel: '${prefs.pageGap.round()} px',
                              onChanged: ready && spreads
                                  ? controller.setPageGap
                                  : null,
                            ),
                            _SettingSlider(
                              id: 'webtoon-gap',
                              label: 'Long-strip page gap',
                              help: webtoon
                                  ? 'Space between pages in the continuous strip.'
                                  : 'Used in Webtoon mode.',
                              value: prefs.webtoonGap,
                              max: 40,
                              divisions: 8,
                              valueLabel: '${prefs.webtoonGap.round()} px',
                              onChanged: ready && webtoon
                                  ? controller.setWebtoonGap
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'cover-alone',
                              label: 'Keep cover by itself',
                              help:
                                  'Starts double-page layouts with a single cover.',
                              value: prefs.coverStartsAlone,
                              onChanged: ready && spreads
                                  ? controller.setCoverStartsAlone
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'swap-spread',
                              label: 'Swap double-page sides',
                              help:
                                  'Reverses the two pages inside each spread.',
                              value: prefs.invertDoublePages,
                              onChanged: ready && spreads
                                  ? controller.setInvertDoublePages
                                  : null,
                            ),
                            const Divider(height: 20),
                            _SettingSlider(
                              id: 'dim',
                              label: 'Dim pages',
                              help:
                                  'Reduces page brightness, not your device brightness.',
                              value: prefs.dimAmount,
                              max: .7,
                              divisions: 14,
                              valueLabel: '${(prefs.dimAmount * 100).round()}%',
                              onChanged: ready ? controller.setDimAmount : null,
                            ),
                            _SettingSlider(
                              id: 'warmth',
                              label: 'Warmth',
                              help: 'Adds a warm tint to page images.',
                              value: prefs.warmth,
                              max: 1,
                              divisions: 20,
                              valueLabel: '${(prefs.warmth * 100).round()}%',
                              onChanged: ready ? controller.setWarmth : null,
                            ),
                            _SettingSwitch(
                              id: 'grayscale',
                              label: 'Grayscale',
                              help: 'View colored pages in black and white.',
                              value: prefs.grayscale,
                              onChanged: ready ? controller.setGrayscale : null,
                            ),
                            _SettingSwitch(
                              id: 'invert-colors',
                              label: 'Invert page colors',
                              help:
                                  'Reverses light and dark colors in page images.',
                              value: prefs.invertColors,
                              onChanged: ready
                                  ? controller.setInvertColors
                                  : null,
                            ),
                          ],
                        ),
                        _SettingsSection(
                          title: 'Controls & progress',
                          icon: Icons.touch_app_outlined,
                          help:
                              'Applies to all manga. Make navigation feel familiar.',
                          children: [
                            _SettingSwitch(
                              id: 'page-number',
                              label: 'Show page number',
                              help:
                                  'Keep a small page counter visible while reading.',
                              value: prefs.showPageNumber,
                              onChanged: ready
                                  ? controller.setShowPageNumber
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'double-tap-zoom',
                              label: 'Double-tap to zoom',
                              help:
                                  'Double-tap a page to zoom in or return to its normal size.',
                              value: prefs.doubleTapZoom,
                              onChanged: ready
                                  ? controller.setDoubleTapZoom
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'tap-zones',
                              label: 'Tap zones',
                              help:
                                  'Tap the sides to turn pages and the center for controls.',
                              value: prefs.tapZonesEnabled,
                              onChanged: ready
                                  ? controller.setTapZonesEnabled
                                  : null,
                            ),
                            _SettingChoice<MangaTapZoneLayout>(
                              id: 'tap-zone-layout',
                              label: 'Tap-zone layout',
                              help:
                                  'Thirds uses wider turn zones. Edges leaves more room for the center.',
                              value: prefs.tapZoneLayout,
                              values: MangaTapZoneLayout.values,
                              name: (value) => value.displayName,
                              onChanged: ready && prefs.tapZonesEnabled
                                  ? controller.setTapZoneLayout
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'invert-tap-zones',
                              label: 'Reverse tap zones',
                              help:
                                  'Swaps previous and next without changing reading direction.',
                              value: prefs.invertTapZones,
                              onChanged: ready && prefs.tapZonesEnabled
                                  ? controller.setInvertTapZones
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'book-animation',
                              label: 'Animate page turns',
                              help:
                                  'Smooth page changes, with a gentle book '
                                  'effect in Paged mode.',
                              value: prefs.bookAnimationEnabled,
                              onChanged: ready
                                  ? controller.setBookAnimationEnabled
                                  : null,
                            ),
                          ],
                        ),
                        _SettingsSection(
                          title: 'Performance & privacy',
                          icon: Icons.shield_outlined,
                          help: 'Applies to all manga.',
                          children: [
                            _SettingSlider(
                              id: 'preload',
                              label: 'Pages to preload',
                              help:
                                  'Loads nearby pages ahead of time. Lower values use less data and memory.',
                              value: prefs.preloadPages.toDouble(),
                              max: 5,
                              divisions: 5,
                              valueLabel: '${prefs.preloadPages}',
                              onChanged: ready
                                  ? (value) => controller.setPreloadPages(
                                      value.round(),
                                    )
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'keep-awake',
                              label: 'Keep screen awake',
                              help:
                                  'Prevents the display from sleeping while this reader is open.',
                              value: prefs.keepScreenAwake,
                              onChanged: ready
                                  ? controller.setKeepScreenAwake
                                  : null,
                            ),
                            _SettingSwitch(
                              id: 'discord-title',
                              label: 'Show manga title on Discord',
                              help:
                                  'When Discord sharing is connected, turn off to share only “Reading manga”.',
                              value: prefs.showDiscordTitle,
                              onChanged: ready
                                  ? controller.setShowDiscordTitle
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          key: const ValueKey('manga-settings-reset'),
                          onPressed: ready ? _confirmReset : null,
                          icon: const Icon(Icons.restart_alt_rounded),
                          label: const Text('Reset reader settings'),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Changes save automatically.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.mutedText),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.icon,
    required this.help,
    required this.children,
  });

  final String title;
  final IconData icon;
  final String help;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: palette.accentBright, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(help, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          Material(
            color: palette.surfaceRaised,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: palette.primaryText.withValues(alpha: .08),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingLabel extends StatelessWidget {
  const _SettingLabel({required this.label, this.help, this.enabled = true});

  final String label;
  final String? help;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: enabled
              ? context.appPalette.primaryText
              : context.appPalette.mutedText,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (help != null) ...[
        const SizedBox(height: 4),
        Text(
          help!,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.appPalette.mutedText,
            height: 1.35,
          ),
        ),
      ],
    ],
  );
}

class _SettingChoice<T> extends StatelessWidget {
  const _SettingChoice({
    required this.id,
    required this.label,
    required this.value,
    required this.values,
    required this.name,
    required this.onChanged,
    this.help,
  });

  final String id;
  final String label;
  final String? help;
  final T value;
  final List<T> values;
  final String Function(T) name;
  final Future<void> Function(T)? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final labelWidget = _SettingLabel(
          label: label,
          help: help,
          enabled: onChanged != null,
        );
        final choice = DecoratedBox(
          decoration: BoxDecoration(
            color: context.appPalette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: context.appPalette.accent.withValues(alpha: .25),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                key: ValueKey('manga-settings-$id'),
                value: value,
                isExpanded: true,
                borderRadius: BorderRadius.circular(12),
                dropdownColor: context.appPalette.surface,
                focusColor: context.appPalette.focusRing.withValues(alpha: .24),
                items: [
                  for (final item in values)
                    DropdownMenuItem(value: item, child: Text(name(item))),
                ],
                onChanged: onChanged == null
                    ? null
                    : (item) {
                        if (item != null) unawaited(onChanged!(item));
                      },
              ),
            ),
          ),
        );
        if (constraints.maxWidth >= 500) {
          return Row(
            children: [
              Expanded(child: labelWidget),
              const SizedBox(width: 20),
              SizedBox(width: 200, child: choice),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [labelWidget, const SizedBox(height: 10), choice],
        );
      },
    ),
  );
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.id,
    required this.label,
    required this.value,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
    this.help,
  });

  final String id;
  final String label;
  final String? help;
  final double value;
  final double max;
  final int divisions;
  final String valueLabel;
  final Future<void> Function(double)? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _SettingLabel(label: label, enabled: onChanged != null),
            ),
            const SizedBox(width: 8),
            Text(valueLabel, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
        if (help != null) ...[
          const SizedBox(height: 4),
          Text(
            help!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.appPalette.mutedText,
              height: 1.35,
            ),
          ),
        ],
        Slider(
          key: ValueKey('manga-settings-$id'),
          value: value.clamp(0, max),
          min: 0,
          max: max,
          divisions: divisions,
          label: valueLabel,
          semanticFormatterCallback: (_) => '$label: $valueLabel',
          onChanged: onChanged == null
              ? null
              : (value) => unawaited(onChanged!(value)),
        ),
      ],
    ),
  );
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.id,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String id;
  final String label;
  final String? help;
  final bool value;
  final Future<void> Function(bool)? onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    key: ValueKey('manga-settings-$id'),
    contentPadding: const EdgeInsets.symmetric(vertical: 5),
    title: _SettingLabel(label: label, help: help, enabled: onChanged != null),
    value: value,
    onChanged: onChanged == null
        ? null
        : (value) => unawaited(onChanged!(value)),
  );
}
