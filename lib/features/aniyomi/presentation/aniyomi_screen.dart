import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/aniyomi/application/aniyomi_controller.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_catalog_filter.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_chapter_order.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_artwork.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_screen.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class AniyomiExperimentalGate extends ConsumerWidget {
  const AniyomiExperimentalGate({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aniyomiEnabledProvider)) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Text(
            context.tr(
              'Aniyomi experiments require Experimental options to be enabled.',
            ),
          ),
        ),
      );
    }
    return child;
  }
}

class AniyomiScreen extends ConsumerStatefulWidget {
  const AniyomiScreen({super.key});
  static const routePath = '/settings/aniyomi';
  @override
  ConsumerState<AniyomiScreen> createState() => _AniyomiScreenState();
}

class _AniyomiScreenState extends ConsumerState<AniyomiScreen> {
  final _catalogSearch = TextEditingController();
  int _catalogPage = 0;
  String? _catalogLanguage;
  @override
  void initState() {
    super.initState();
    _catalogSearch.addListener(
      () => setState(() {
        _filter = _catalogSearch.text.toLowerCase();
        _catalogPage = 0;
      }),
    );
  }

  @override
  void dispose() {
    _catalogSearch.dispose();
    super.dispose();
  }

  bool _working = false;
  String _filter = '';
  Future<void> _run(Future<void> Function() task) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await task();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'This extension could not complete the request. It may require an unsupported API, network feature, or repository format.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _add(AniyomiMediaKind kind) async {
    final input = TextEditingController();
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.tr('Add repository')),
          content: SizedBox(
            width: 620,
            child: TvTextInput(
              controller: input,
              autofocus: true,
              labelText: context.tr('HTTPS catalog links'),
              keyboardTitle: context.tr('Repository links'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('Add repository')),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) {
        await ref
            .read(aniyomiControllerProvider.notifier)
            .addRepository(input.text.trim(), kind);
      }
    } finally {
      input.dispose();
    }
  }

  Future<void> _install(AniyomiRepositoryExtension extension) async {
    final controller = ref.read(aniyomiControllerProvider.notifier);
    final access = controller.gateway.generation;
    final inspected = await controller.inspect(extension);
    if (!mounted) return;
    controller.gateway.check(access);
    final trusted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Trust this experimental extension?')),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  extension.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    'Extensions are third-party executable code. Install only ones you trust. Signature verification checks identity, not safety.',
                  ),
                ),
                const SizedBox(height: 12),
                Text(extension.packageName),
                Text(extension.versionName),
                const SizedBox(height: 12),
                Text(context.tr('Verified signer (SHA-256)')),
                SelectableText('${inspected['certificateSha256']}'),
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    'Changing or disabling Experimental options revokes execution approval. Seanime is unaffected.',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Trust and install')),
          ),
        ],
      ),
    );
    if (trusted != true || !mounted) return;
    controller.gateway.check(access);
    await controller.approve(inspected['inspectionId'] as String);
    if (!mounted) return;
    final readiness = ref
        .read(aniyomiControllerProvider)
        .readiness[extension.identityKey];
    if (readiness?.stage == AniyomiReadinessStage.failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Extension installed, but source discovery failed. Retry from Installed extensions.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _restore(Map<String, dynamic> installed) async {
    final controller = ref.read(aniyomiControllerProvider.notifier);
    // Explicit recovery only: no background downloads or automatic approvals.
    await controller.refreshCatalog();
    if (!mounted) return;
    final matches = ref
        .read(aniyomiControllerProvider)
        .catalog
        .where((entry) => entry.identityKey == installed['extensionId']);
    final extension =
        matches
            .where((entry) => entry.versionName == installed['versionName'])
            .firstOrNull ??
        matches.firstOrNull;
    if (extension == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'This extension is no longer in your repositories. Add its repository again to reinstall it.',
            ),
          ),
        ),
      );
      return;
    }
    // Reuse verification and the visible trust prompt. Native approval still
    // rejects signer changes and version downgrades against the saved identity.
    await _install(extension);
  }

  Future<void> _chooseLanguage(List<String> languages, String? selected) async {
    final choice = await showDialog<_CatalogLanguageSelection>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        backgroundColor: dialogContext.appPalette.surface,
        title: Text(dialogContext.tr('Filter extension language')),
        children: [
          for (final language in <String?>[null, ...languages])
            Semantics(
              selected: selected == language,
              child: TextButton(
                key: ValueKey('aniyomi-language-option-${language ?? 'any'}'),
                autofocus: selected == language,
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _CatalogLanguageSelection(language),
                ),
                child: Row(
                  children: [
                    Icon(
                      selected == language ? Icons.check : Icons.language,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _catalogLanguageLabel(dialogContext, language),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      _catalogLanguage = choice.language;
      _catalogPage = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aniyomiControllerProvider);
    final mangaEnabled = ref.watch(aniyomiMangaEnabledProvider);
    final controller = ref.read(aniyomiControllerProvider.notifier);
    final busy = _working || state.busy || state.discovering;
    final languages =
        aniyomiCatalogLanguages(state.catalog, mangaEnabled: mangaEnabled)
          ..sort((left, right) {
            final leftRank = left == 'unknown' ? 2 : (left == 'all' ? 1 : 0);
            final rightRank = right == 'unknown' ? 2 : (right == 'all' ? 1 : 0);
            if (leftRank != rightRank) return leftRank.compareTo(rightRank);
            return _catalogLanguageLabel(
              context,
              left,
            ).compareTo(_catalogLanguageLabel(context, right));
          });
    // Keep a selected language visible even if a repository refresh removes
    // its last result. The user can clear it instead of silently changing it.
    if (_catalogLanguage != null && !languages.contains(_catalogLanguage)) {
      languages.add(_catalogLanguage!);
    }
    final filteredCatalog = filterAniyomiCatalog(
      state.catalog,
      mangaEnabled: mangaEnabled,
      language: _catalogLanguage,
      query: _filter,
    );
    final catalogPage = _catalogPage.clamp(
      0,
      filteredCatalog.isEmpty ? 0 : (filteredCatalog.length - 1) ~/ 100,
    );
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Aniyomi • Experimental'))),
      body: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              context.tr(
                'Android 8 or newer. Anime APIs 14 and 16 and manga APIs 1.4–1.5 are supported. WebView, custom transports and native-player commands are not supported. No repositories are bundled.',
              ),
            ),
            const SizedBox(height: 16),
            if (!state.available)
              Text(context.tr('Waiting for a supported Android runtime.')),
            if (busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Action(
                  label: context.tr('Add anime repository'),
                  icon: Icons.video_library_outlined,
                  enabled: !busy && state.available,
                  autofocus: true,
                  onPressed: () => _run(() => _add(AniyomiMediaKind.anime)),
                ),
                if (mangaEnabled)
                  _Action(
                    label: context.tr('Add manga repository'),
                    icon: Icons.menu_book_outlined,
                    enabled: !busy && state.available,
                    onPressed: () => _run(() => _add(AniyomiMediaKind.manga)),
                  ),
                _Action(
                  label: context.tr('Refresh repositories'),
                  icon: Icons.refresh,
                  enabled: !busy && state.available,
                  onPressed: () => _run(controller.refreshCatalog),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text(
              context.tr('Repositories'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final repo in state.repositories)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _Action(
                  label:
                      '${repo.kind.name} • ${repo.uri.host} • ${context.tr('Remove')}',
                  icon: Icons.delete_outline,
                  enabled: !busy,
                  onPressed: () =>
                      _run(() => controller.removeRepository(repo)),
                ),
              ),
            const SizedBox(height: 22),
            Text(
              context.tr('Installed extensions'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final installed in state.approved)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _InstalledExtension(
                  installed: installed,
                  kind: _mediaKind(installed['kind']),
                  mangaEnabled: mangaEnabled,
                  readiness: state.readiness[installed['extensionId']],
                  busy: busy,
                  onRestore: () => _run(() => _restore(installed)),
                  onRetry: _mediaKind(installed['kind']) == null
                      ? null
                      : () => _run(
                          () => controller.retryDiscovery(
                            installed['extensionId'] as String,
                            kind: _mediaKind(installed['kind'])!,
                          ),
                        ),
                  onRevoke: () => _run(
                    () => controller.revoke(installed['extensionId'] as String),
                  ),
                ),
              ),
            if (state.errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  context.tr(
                    'Some repositories or extensions could not load. Refresh repositories or retry the failed extension. Unsupported extensions stay unavailable.',
                  ),
                ),
              ),
            if (mangaEnabled) ...[
              const SizedBox(height: 22),
              Text(
                context.tr('Browse'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                context.tr(
                  'Ready anime sources join the normal show source search. Ready manga sources open the existing reader below.',
                ),
              ),
              for (final source in state.sources.where(
                (s) => s.kind == AniyomiMediaKind.manga,
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _Action(
                    label: '${source.name} • ${source.language}',
                    icon: Icons.menu_book,
                    enabled: !busy,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AniyomiExperimentalGate(
                          child: _AniyomiMangaGate(
                            child: _MangaBrowser(source: source),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 22),
            Text(
              context.tr('Available extensions'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TvTextInput(
              controller: _catalogSearch,
              labelText: context.tr('Search extensions'),
              keyboardTitle: context.tr('Search extensions'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Action(
                  key: const ValueKey('aniyomi-language-filter'),
                  label: context.tr('Language: {value1}', {
                    'value1': _catalogLanguageLabel(context, _catalogLanguage),
                  }),
                  icon: Icons.language,
                  onPressed: () => _chooseLanguage(languages, _catalogLanguage),
                ),
                if (_catalogLanguage != null || _filter.isNotEmpty)
                  _Action(
                    key: const ValueKey('aniyomi-clear-filters'),
                    label: context.tr('Clear filters'),
                    icon: Icons.filter_alt_off_outlined,
                    onPressed: () {
                      _catalogSearch.clear();
                      setState(() {
                        _catalogLanguage = null;
                        _catalogPage = 0;
                      });
                    },
                  ),
              ],
            ),
            if (filteredCatalog.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(context.tr('No extensions match this filter')),
              ),
            for (final extension
                in filteredCatalog.skip(catalogPage * 100).take(100))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _Action(
                  label:
                      '${extension.name} • ${extension.language} • ${extension.versionName}',
                  icon: Icons.download,
                  enabled: !busy && !extension.isTorrent,
                  onPressed: () => _run(() => _install(extension)),
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                if (catalogPage > 0)
                  _Action(
                    label: context.tr('Previous'),
                    icon: Icons.chevron_left,
                    onPressed: () =>
                        setState(() => _catalogPage = catalogPage - 1),
                  ),
                if ((catalogPage + 1) * 100 < filteredCatalog.length)
                  _Action(
                    label: context.tr('Next'),
                    icon: Icons.chevron_right,
                    onPressed: () =>
                        setState(() => _catalogPage = catalogPage + 1),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogLanguageSelection {
  const _CatalogLanguageSelection(this.language);
  final String? language;
}

String _catalogLanguageLabel(BuildContext context, String? code) {
  if (code == null) return context.tr('All languages');
  if (code == 'all') return context.tr('Multilingual');
  if (code == 'unknown') return context.tr('Unknown');
  for (final language in AppLanguage.values) {
    if (language.code == code) return language.nativeName;
  }
  // Autonyms are intentionally independent of the current interface language.
  return const {
        'ar': 'العربية',
        'bn': 'বাংলা',
        'id': 'Bahasa Indonesia',
        'it': 'Italiano',
        'ja': '日本語',
        'ko': '한국어',
        'ml': 'മലയാളം',
        'mr': 'मराठी',
        'nl': 'Nederlands',
        'pl': 'Polski',
        'ru': 'Русский',
        'sr': 'Српски',
        'ta': 'தமிழ்',
        'te': 'తెలుగు',
        'th': 'ไทย',
        'tr': 'Türkçe',
        'uk': 'Українська',
        'vi': 'Tiếng Việt',
        'zh': '中文',
      }[code] ??
      code.toUpperCase();
}

class _InstalledExtension extends StatelessWidget {
  const _InstalledExtension({
    required this.installed,
    required this.kind,
    required this.mangaEnabled,
    required this.readiness,
    required this.busy,
    required this.onRetry,
    required this.onRevoke,
    required this.onRestore,
  });
  final Map<String, dynamic> installed;
  final AniyomiMediaKind? kind;
  final bool mangaEnabled;
  final AniyomiReadiness? readiness;
  final bool busy;
  final VoidCallback? onRetry;
  final VoidCallback onRevoke;
  final VoidCallback onRestore;
  @override
  Widget build(BuildContext context) {
    final stage = readiness?.stage ?? AniyomiReadinessStage.installed;
    final status = switch (stage) {
      AniyomiReadinessStage.installed => context.tr(
        'Installed • sources not checked',
      ),
      AniyomiReadinessStage.checking => context.tr(
        'Installed • checking sources…',
      ),
      AniyomiReadinessStage.ready => context.tr(
        readiness!.sourceCount == 1
            ? 'Ready • 1 source'
            : 'Ready • {count} sources',
        {'count': readiness!.sourceCount},
      ),
      AniyomiReadinessStage.failed => context.tr(
        'Installed • source discovery failed',
      ),
    };
    final failure = readiness?.failure;
    final missingSnapshot = failure?.code == 'snapshot_unavailable';
    final fields = failure?.diagnosticFields;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${installed['packageName'] ?? ''}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          missingSnapshot
              ? context.tr('Extension files missing • reinstall needed')
              : status,
        ),
        if (missingSnapshot)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.tr(
                'The extension files are no longer on this device. Reinstall to restore them; your existing approval will still be checked.',
              ),
            ),
          ),
        if (!mangaEnabled && kind == AniyomiMediaKind.manga)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(context.tr('Manga is disabled in Settings.')),
          ),
        if (fields != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.tr('Stage: {stage} • Reason: {reason}', {
                'stage': fields['stage'] as String,
                'reason': '${fields['code']} / ${fields['reason_code']}',
              }),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (onRetry != null &&
                !missingSnapshot &&
                (kind != AniyomiMediaKind.manga || mangaEnabled) &&
                (stage == AniyomiReadinessStage.failed ||
                    stage == AniyomiReadinessStage.installed))
              _Action(
                label: context.tr('Retry source discovery'),
                icon: Icons.refresh,
                enabled: !busy,
                onPressed: onRetry!,
              ),
            if (missingSnapshot &&
                (kind != AniyomiMediaKind.manga || mangaEnabled))
              _Action(
                label: context.tr('Reinstall extension'),
                icon: Icons.download,
                enabled: !busy,
                onPressed: onRestore,
              ),
            _Action(
              label: context.tr('Revoke approval'),
              icon: Icons.block,
              enabled: !busy,
              onPressed: onRevoke,
            ),
          ],
        ),
      ],
    );
  }
}

AniyomiMediaKind? _mediaKind(Object? value) =>
    AniyomiMediaKind.values.where((kind) => kind.name == value).firstOrNull;

class _AniyomiMangaGate extends ConsumerWidget {
  const _AniyomiMangaGate({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(aniyomiMangaEnabledProvider)) return child;
    return Scaffold(
      appBar: AppBar(),
      body: Center(child: Text(context.tr('Manga is disabled in Settings.'))),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.leading,
    this.enabled = true,
    this.autofocus = false,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Widget? leading;
  final bool enabled;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => TvFocusable(
    enabled: enabled,
    autofocus: autofocus,
    focusScale: 1,
    onPressed: onPressed,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.appPalette.mutedText.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading ?? Icon(icon),
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ],
      ),
    ),
  );
}

class _MangaBrowser extends ConsumerStatefulWidget {
  const _MangaBrowser({required this.source});
  final AniyomiRuntimeSource source;
  @override
  ConsumerState<_MangaBrowser> createState() => _MangaBrowserState();
}

class _MangaBrowserState extends ConsumerState<_MangaBrowser> {
  int _chapterPage = 0;
  final _query = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _title;
  int _page = 1;
  bool _hasNext = false;
  bool _busy = false;
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'This extension could not complete the request. It may require an unsupported API, network feature, or repository format.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search(int page) async {
    final gateway = ref.read(aniyomiGatewayProvider);
    final access = gateway.generation;
    _checkMangaAccess(gateway, access);
    final data = await gateway.request({
      ...widget.source.arguments('search'),
      'query': _query.text.trim(),
      'page': page,
    });
    _checkMangaAccess(gateway, access);
    if (!mounted) return;
    setState(() {
      _title = null;
      _items = aniyomiMaps(data['items']);
      _page = page;
      _hasNext = data['hasNextPage'] == true;
    });
  }

  Future<void> _chapters(Map<String, dynamic> title) async {
    final gateway = ref.read(aniyomiGatewayProvider);
    final access = gateway.generation;
    _checkMangaAccess(gateway, access);
    // Search results are intentionally partial in the Aniyomi contract. Load
    // canonical details before chapters so extensions that derive chapter
    // requests from a normalized title URL/status do not receive an incomplete
    // search DTO. This also supplies the reader with the best available cover.
    final detailData = await gateway.request({
      ...widget.source.arguments('details'),
      'url': title['url'],
      'title': title['title'],
    });
    _checkMangaAccess(gateway, access);
    final rawDetails = detailData['item'];
    if (rawDetails is! Map) throw const AniyomiFailure('invalid_result');
    final details = Map<String, dynamic>.from(rawDetails);
    if (details['url'] is! String || details['title'] is! String) {
      throw const AniyomiFailure('invalid_result');
    }
    final data = await gateway.request({
      ...widget.source.arguments('chapters'),
      'url': details['url'],
      'title': details['title'],
    });
    _checkMangaAccess(gateway, access);
    if (!mounted) return;
    setState(() {
      _title = details;
      _items = orderAniyomiChapters(aniyomiMaps(data['chapters']));
      _chapterPage = 0;
    });
  }

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

  void _checkMangaAccess(AniyomiGateway gateway, int access) {
    gateway.check(access);
    if (!ref.read(aniyomiMangaEnabledProvider)) {
      throw const AniyomiFailure('manga_disabled');
    }
  }

  Future<void> _read(Map<String, dynamic> chapter) async {
    final gateway = ref.read(aniyomiGatewayProvider);
    final access = gateway.generation;
    final ownerFuture = ref.read(mangaOwnerKeyProvider.future);
    final hub = ref.read(mangaHubControllerProvider.notifier);
    final owner = await ownerFuture;
    final title = _title!;
    final source = widget.source;
    final chapters = List<Map<String, dynamic>>.of(_items);
    final ordered = aniyomiChaptersHaveReliableOrder(chapters);
    // Bind all chapter callbacks to the opening profile and developer lease.
    void check() {
      _checkMangaAccess(gateway, access);
      if (!mounted ||
          !identical(ownerFuture, ref.read(mangaOwnerKeyProvider.future))) {
        throw const AniyomiFailure('developer_access_revoked');
      }
    }

    Future<MangaReaderRequest> load(Map<String, dynamic> selected) async {
      check();
      final data = await gateway.request({
        ...source.arguments('pages'),
        'url': selected['url'],
        'title': title['title'],
      });
      check();
      final rawPages = aniyomiMaps(data['pages']);
      if (rawPages.isEmpty || rawPages.length > 1000) {
        throw const AniyomiFailure('invalid_result');
      }
      final pages = <MangaReaderPage>[];
      for (final item in rawPages) {
        final capability = item['imageCapability'];
        if (capability is! AniyomiImageCapability) {
          throw const AniyomiFailure('invalid_result');
        }
        pages.add(
          MangaReaderPage(
            id: 'page.${pages.length}',
            index: pages.length,
            resource: _aniyomiImageResource(capability),
          ),
        );
      }
      final index = chapters.indexWhere((c) => c['url'] == selected['url']);
      final number = selected['number'];
      final request = MangaReaderRequest(
        ownerKey: owner,
        sourceId: 'aniyomi.${_digest(source.key)}',
        origin: MangaReaderOrigin.aniyomiExperimental,
        publicationId: _digest('${title['url']}'),
        chapterId: _digest('${selected['url']}'),
        seriesTitle: '${title['title']}',
        chapterTitle: '${selected['name']}',
        chapterNumber: number is num && number > 0 ? number.toDouble() : null,
        // Protected Aniyomi covers stay as runtime-only image capabilities;
        // they are never persisted or copied into Discord presence metadata.
        coverUri: null,
        pages: pages,
        resolvePreviousChapter: ordered && index > 0
            ? () => load(chapters[index - 1])
            : null,
        resolveNextChapter: ordered && index >= 0 && index + 1 < chapters.length
            ? () => load(chapters[index + 1])
            : null,
      );
      final resumed = await hub.applySavedProgress(request);
      check();
      return resumed;
    }

    final request = await load(chapter);
    check();
    if (!mounted) return;
    await context.push<void>(MangaReaderScreen.routePath, extra: request);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_title?['title'] as String? ?? widget.source.name),
    ),
    body: FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TvTextInput(
            controller: _query,
            labelText: context.tr('Search manga'),
            keyboardTitle: context.tr('Search manga'),
          ),
          const SizedBox(height: 12),
          _Action(
            label: context.tr('Search'),
            icon: Icons.search,
            enabled: !_busy,
            onPressed: () => _run(() => _search(1)),
          ),
          if (_busy) const LinearProgressIndicator(),
          for (final item
              in _items.skip(_title == null ? 0 : _chapterPage * 100).take(100))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Action(
                label: '${item[_title == null ? 'title' : 'name']}',
                icon: _title == null ? Icons.menu_book : Icons.auto_stories,
                leading: _title == null
                    ? _AniyomiMangaSearchCover(
                        capability:
                            item['imageCapability'] as AniyomiImageCapability?,
                      )
                    : null,
                enabled: !_busy,
                onPressed: () =>
                    _run(() => _title == null ? _chapters(item) : _read(item)),
              ),
            ),
          if (_title == null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Wrap(
                spacing: 16,
                children: [
                  if (_page > 1)
                    _Action(
                      label: context.tr('Previous'),
                      icon: Icons.chevron_left,
                      enabled: !_busy,
                      onPressed: () => _run(() => _search(_page - 1)),
                    ),
                  if (_hasNext)
                    _Action(
                      label: context.tr('Next'),
                      icon: Icons.chevron_right,
                      enabled: !_busy,
                      onPressed: () => _run(() => _search(_page + 1)),
                    ),
                ],
              ),
            ),
          if (_title != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Wrap(
                spacing: 12,
                children: [
                  if (_chapterPage > 0)
                    _Action(
                      label: context.tr('Previous'),
                      icon: Icons.chevron_left,
                      onPressed: () => setState(() => _chapterPage--),
                    ),
                  if ((_chapterPage + 1) * 100 < _items.length)
                    _Action(
                      label: context.tr('Next'),
                      icon: Icons.chevron_right,
                      onPressed: () => setState(() => _chapterPage++),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class _AniyomiMangaSearchCover extends StatelessWidget {
  const _AniyomiMangaSearchCover({required this.capability});

  final AniyomiImageCapability? capability;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('aniyomi-manga-search-cover'),
    width: 64,
    height: 88,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: MangaArtwork(
        uri: null,
        resource: capability == null
            ? null
            : _aniyomiImageResource(capability!, artwork: true),
        fit: BoxFit.contain,
        cacheWidth: 256,
      ),
    ),
  );
}

MangaOpaquePageResource _aniyomiImageResource(
  AniyomiImageCapability capability, {
  bool artwork = false,
}) => MangaOpaquePageResource(
  cacheIdentity: capability,
  allowPlatformArtworkTranscode: artwork,
  loadImage: () async {
    try {
      return await capability.load();
    } on AniyomiFailure catch (error) {
      throw MangaPageFetchException(switch (error.code) {
        'image_busy' => 'Too many manga images are loading. Try again shortly.',
        'image_capability_invalid' ||
        'image_request_cancelled_or_expired' ||
        'developer_access_revoked' =>
          'This manga image access expired. Return to the chapter list and reopen it.',
        'image_response_too_large' =>
          'This manga image is larger than the safe limit.',
        'image_not_supported' ||
        'image_malformed' => 'The manga page is not a supported image.',
        'image_dimensions_exceeded' =>
          'The manga page dimensions exceed the safe decode limit.',
        _ => 'This manga image could not be loaded. Try again.',
      }, reasonCode: error.code);
    }
  },
);
