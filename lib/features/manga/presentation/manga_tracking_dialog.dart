import 'dart:async';

import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/application/manga_tracking_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> showMangaTrackingDialog(
  BuildContext context,
  WidgetRef ref, {
  required String ownerKey,
  required String sourceId,
  required String publicationId,
  required String title,
}) => showDialog<void>(
  context: context,
  builder: (_) => MangaTrackingDialog(
    controller: ref.read(mangaTrackingControllerProvider),
    titleKey: MangaTrackingTitleKey(
      ownerKey: ownerKey,
      sourceId: sourceId,
      publicationId: publicationId,
    ),
    title: title,
  ),
);

/// A tracker is opt-in per title and per profile. Search never picks a match,
/// selecting a result only previews it, and confirming does not send progress.
class MangaTrackingDialog extends StatefulWidget {
  const MangaTrackingDialog({
    required this.controller,
    required this.titleKey,
    required this.title,
    super.key,
  });
  final MangaTrackingController controller;
  final MangaTrackingTitleKey titleKey;
  final String title;

  @override
  State<MangaTrackingDialog> createState() => _MangaTrackingDialogState();
}

class _MangaTrackingDialogState extends State<MangaTrackingDialog> {
  late final TextEditingController _query;
  final _searchFocus = FocusNode(debugLabel: 'manga-tracking-search');
  TrackingProvider _provider = TrackingProvider.anilist;
  List<MangaTrackingLink> _links = const [];
  List<MangaTrackingPending> _pending = const [];
  List<MangaTrackingSearchResult> _results = const [];
  MangaTrackingSearchResult? _selection;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(
      text: widget.title.length > 160
          ? widget.title.substring(0, 160)
          : widget.title,
    );
    unawaited(
      _run(() async {
        await _refresh();
        if (mounted && _links.isNotEmpty) {
          setState(() => _provider = _links.first.provider);
        }
      }),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final links = await widget.controller.currentLinks(widget.titleKey);
    final pending = await widget.controller.pendingFor(widget.titleKey);
    if (!mounted) return;
    setState(() {
      _links = links;
      _pending = pending;
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await operation();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is MangaTrackingException
            ? error.message
            : 'Manga tracking could not be updated. Try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _chooseProvider(TrackingProvider provider) {
    if (_busy || provider == _provider) return;
    setState(() {
      _provider = provider;
      _selection = null;
      _results = const [];
      _searched = false;
      _error = null;
      _notice = null;
    });
  }

  Future<void> _search() => _run(() async {
    setState(() {
      _selection = null;
      _results = const [];
      _searched = false;
    });
    final rows = await widget.controller.searchCatalog(_provider, _query.text);
    if (mounted) {
      setState(() {
        _results = rows;
        _searched = true;
      });
    }
  });

  Future<void> _confirm() => _run(() async {
    final selected = _selection;
    if (selected == null) return;
    await widget.controller.linkManga(
      widget.titleKey,
      selected,
      confirmed: true,
    );
    await _refresh();
    if (mounted) {
      setState(() {
        _selection = null;
        _results = const [];
        _searched = false;
        _notice = 'Manga linked. Future completed chapters can sync.';
      });
    }
  });

  Future<void> _unlink(TrackingProvider provider) => _run(() async {
    await widget.controller.unlink(widget.titleKey, provider);
    await _refresh();
    if (mounted) {
      setState(
        () => _notice =
            'Manga unlinked. Your tracker list entry was not removed.',
      );
    }
  });

  Future<void> _retry() => _run(() async {
    await widget.controller.retryPending(
      manual: true,
      title: widget.titleKey,
      provider: _provider,
    );
    await _refresh();
    if (mounted) {
      setState(
        () => _notice = _pending.isEmpty
            ? 'Manga tracking is up to date.'
            : 'Progress remains queued. Check the account or wait for the next retry.',
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final ui = TetoLocalizations.of(context);
    final theme = Theme.of(context);
    final link = _links.where((row) => row.provider == _provider).firstOrNull;
    final pending = _pending
        .where((row) => row.bindingId == link?.bindingId)
        .firstOrNull;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: FocusTraversalGroup(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ui.text('Manga tracking'),
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(widget.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(
                  ui.text(
                    'Choose the exact manga on AniList or MAL. Nothing syncs until you confirm a match.',
                  ),
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final provider in [
                      TrackingProvider.anilist,
                      TrackingProvider.myAnimeList,
                    ])
                      _action(
                        label: provider.displayName,
                        selected: _provider == provider,
                        autofocus: provider == TrackingProvider.anilist,
                        onPressed: () => _chooseProvider(provider),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (link != null) ...[
                  _card(
                    children: [
                      Text(
                        ui.text('Linked manga'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      _record(link.record),
                      Text(
                        ui.text('Tracker account {value1}', {
                          'value1': link.accountId,
                        }),
                      ),
                      if (pending != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          ui.text('Chapter {count} waiting to sync.', {
                            'count': pending.completedChapters,
                          }),
                        ),
                        Text(
                          ui.text(
                            pending.needsAttention
                                ? 'Needs attention'
                                : 'Retry scheduled',
                          ),
                        ),
                        if (pending.lastError != null)
                          Text(
                            ui.text(pending.lastError!),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _action(
                            label: ui.text('Unlink manga'),
                            onPressed: () => unawaited(_unlink(link.provider)),
                          ),
                          if (pending != null)
                            _action(
                              label: ui.text('Retry pending updates'),
                              onPressed: () => unawaited(_retry()),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ] else
                  Text(ui.text('Not linked to this tracker.')),
                const SizedBox(height: 12),
                IgnorePointer(
                  ignoring: _busy,
                  child: TvTextInput(
                    controller: _query,
                    focusNode: _searchFocus,
                    labelText: ui.text('Search manga title'),
                    maxLength: 160,
                    onSubmitted: (_) => unawaited(_search()),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _action(
                    label: ui.text('Search catalog'),
                    onPressed: () => unawaited(_search()),
                  ),
                ),
                if (_searched && _results.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(ui.text('No manga found. Try another title.')),
                ],
                if (_results.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    ui.text('Select a result to review'),
                    style: theme.textTheme.titleMedium,
                  ),
                  for (final result in _results)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _action(
                        label: result.title,
                        selected: _selection?.mediaId == result.mediaId,
                        onPressed: () => setState(() => _selection = result),
                        child: _record(result),
                      ),
                    ),
                ],
                if (_selection case final selected?) ...[
                  const SizedBox(height: 16),
                  _card(
                    children: [
                      Text(
                        ui.text('Confirm manga match'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _record(selected),
                      const SizedBox(height: 8),
                      Text(
                        ui.text(
                          'Confirm this is the same manga and edition before enabling chapter updates.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _action(
                        label: ui.text('Confirm and link manga'),
                        onPressed: () => unawaited(_confirm()),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  ui.text(
                    'Only future completed, whole-number chapters sync. Scores, volumes and list status stay unchanged.',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  ui.text(
                    'For specials, gaps, or numbering that restarts by volume, review your chapter count on the tracker.',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      ui.text(_error!),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(ui.text(_notice!))),
                ],
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: _action(
                    label: ui.text('Close'),
                    allowWhileBusy: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _record(MangaTrackingSearchResult record) {
    final ui = TetoLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(record.title, style: Theme.of(context).textTheme.titleMedium),
        Text(ui.text('Tracker ID {value1}', {'value1': record.mediaId})),
        if (record.format != null) Text(record.format!),
        Text(
          record.totalChapters == null
              ? ui.text('Chapter count unknown')
              : ui.text('{count} chapters', {'count': record.totalChapters!}),
        ),
        Text(
          record.url.toString(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _card({required List<Widget> children}) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  Widget _action({
    required String label,
    required VoidCallback onPressed,
    bool selected = false,
    bool autofocus = false,
    bool allowWhileBusy = false,
    Widget? child,
  }) => Builder(
    builder: (buttonContext) => Semantics(
      selected: selected,
      child: TvFocusable(
        autofocus: autofocus,
        focusScale: 1,
        enabled: !_busy || allowWhileBusy,
        onPressed: onPressed,
        onFocusChanged: (focused) {
          if (focused) {
            unawaited(
              Scrollable.ensureVisible(
                buttonContext,
                duration: const Duration(milliseconds: 150),
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              ),
            );
          }
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHigh,
          ),
          child:
              child ??
              Text(label, style: Theme.of(context).textTheme.titleMedium),
        ),
      ),
    ),
  );
}
