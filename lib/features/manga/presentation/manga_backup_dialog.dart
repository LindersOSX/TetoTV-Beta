import 'dart:async';
import 'dart:math' as math;

import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/application/manga_series_preferences_controller.dart';
import 'package:anime_tv/features/manga/data/manga_backup_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class MangaBackupDocumentAccess {
  Future<String?> open();
  Future<bool> save(String encrypted, String suggestedName);
}

class AndroidMangaBackupDocumentAccess implements MangaBackupDocumentAccess {
  const AndroidMangaBackupDocumentAccess();
  @override
  Future<String?> open() => AndroidTvBridge.instance.importMangaBackup();
  @override
  Future<bool> save(String encrypted, String suggestedName) =>
      AndroidTvBridge.instance.exportMangaBackup(
        encryptedJson: encrypted,
        suggestedName: suggestedName,
      );
}

final mangaBackupDocumentAccessProvider = Provider<MangaBackupDocumentAccess>(
  (ref) => const AndroidMangaBackupDocumentAccess(),
);

final mangaBackupAvailableProvidersProvider = Provider<Set<String>>(
  (ref) => ref
      .watch(mangaExtensionControllerProvider)
      .providers
      .where((provider) => provider.enabled)
      .map((provider) => provider.manifest.id)
      .toSet(),
);

final mangaBackupServiceProvider = Provider<MangaBackupService>((ref) {
  final identities = ref.watch(mangaExtensionIdentityStoreProvider);
  return MangaBackupService(
    store: ref.watch(mangaStoreProvider),
    preferencesStorage: ref.watch(secureStorageProvider),
    readIdentity: identities.read,
    writeIdentity:
        ({
          required ownerKey,
          required sourceId,
          required entryId,
          required mangaId,
        }) => mangaId == null
        ? identities.delete(
            ownerKey: ownerKey,
            sourceId: sourceId,
            entryId: entryId,
          )
        : identities.write(
            ownerKey: ownerKey,
            sourceId: sourceId,
            entryId: entryId,
            mangaId: mangaId,
          ),
  );
});

Future<bool> showMangaBackupDialog(BuildContext context, WidgetRef ref) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MangaBackupDialog(
        service: ref.read(mangaBackupServiceProvider),
        documents: ref.read(mangaBackupDocumentAccessProvider),
      ),
    ) ??
    false;

/// The passphrase and encrypted input live only while this bounded dialog is
/// open. No clipboard export, plaintext temp file, filenames, or raw errors.
class MangaBackupDialog extends ConsumerStatefulWidget {
  const MangaBackupDialog({
    required this.service,
    required this.documents,
    super.key,
  });
  final MangaBackupService service;
  final MangaBackupDocumentAccess documents;
  @override
  ConsumerState<MangaBackupDialog> createState() => _MangaBackupDialogState();
}

class _MangaBackupDialogState extends ConsumerState<MangaBackupDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _scroll = ScrollController();
  final _passwordFocus = FocusNode(debugLabel: 'manga-backup-passphrase');
  final _actionFocus = FocusNode(debugLabel: 'manga-backup-action');
  bool _importing = false;
  bool _busy = false;
  String? _encrypted;
  String? _notice;
  bool _error = false;
  MangaBackupImportPreview? _preview;
  MangaBackupConflictPolicy _policy = MangaBackupConflictPolicy.mergeNewer;

  @override
  void dispose() {
    _encrypted = null;
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    _scroll.dispose();
    _passwordFocus.dispose();
    _actionFocus.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _error = false;
    });
    try {
      await operation();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _notice =
            error is PlatformException &&
                error.code == 'MANGA_BACKUP_UNSUPPORTED'
            ? 'Backup files are available on Android devices.'
            : error is StateError &&
                  error.message.contains('could not be fully restored')
            ? 'Import was rolled back. Reconnect affected sources and check reader settings before trying again.'
            : _importing
            ? 'Could not import this backup. Check the passphrase and file, then preview it again.'
            : 'Could not save the encrypted backup. Check the selected storage and try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _actionFocus.requestFocus();
      }
    }
  }

  bool _validPassword() {
    if (_password.text.trim().length < 12 || _password.text.length > 512) {
      setState(() {
        _error = true;
        _notice = 'Use a passphrase of at least 12 characters.';
      });
      _passwordFocus.requestFocus();
      return false;
    }
    if (!_importing && _password.text != _confirmation.text) {
      setState(() {
        _error = true;
        _notice = 'The passphrases do not match.';
      });
      return false;
    }
    return true;
  }

  void _changeMode(bool importing) {
    if (_busy || importing == _importing) return;
    setState(() {
      _importing = importing;
      _preview = null;
      _encrypted = null;
      _notice = null;
    });
    _password.clear();
    _confirmation.clear();
  }

  Future<void> _chooseFile() => _run(() async {
    final encrypted = await widget.documents.open();
    if (!mounted || encrypted == null) return;
    setState(() {
      _encrypted = encrypted;
      _preview = null;
      _notice = 'Encrypted backup selected. Enter its passphrase to preview.';
    });
  });

  Future<void> _export() async {
    if (!_validPassword()) return;
    await _run(() async {
      final owner = await ref.read(mangaOwnerKeyProvider.future);
      final encrypted = await widget.service.exportEncrypted(
        ownerKey: owner,
        passphrase: _password.text,
      );
      if (!mounted) return;
      final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      final saved = await widget.documents.save(
        encrypted,
        'TetoTV-Manga-Backup-$date.json',
      );
      if (!mounted) return;
      _password.clear();
      _confirmation.clear();
      setState(
        () => _notice = saved
            ? 'Encrypted backup saved. Keep its passphrase somewhere safe.'
            : 'Backup export cancelled.',
      );
    });
  }

  Future<void> _previewImport() async {
    if (_encrypted == null || !_validPassword()) return;
    await _run(() async {
      final owner = await ref.read(mangaOwnerKeyProvider.future);
      final providers = ref.read(mangaBackupAvailableProvidersProvider);
      final preview = await widget.service.previewImport(
        encrypted: _encrypted!,
        passphrase: _password.text,
        ownerKey: owner,
        availableProviderIds: providers,
      );
      if (!mounted) return;
      _password.clear();
      setState(() => _preview = preview);
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  Future<void> _confirmImport() => _run(() async {
    final preview = _preview;
    if (preview == null) return;
    if (await ref.read(mangaOwnerKeyProvider.future) != preview.ownerKey) {
      throw StateError('The selected profile changed.');
    }
    await widget.service.confirmImport(
      preview,
      confirmed: true,
      conflictPolicy: _policy,
    );
    if (!mounted) return;
    ref.invalidate(mangaReaderPreferencesProvider);
    ref.invalidate(mangaSeriesReaderPreferencesProvider);
    Navigator.of(context).pop(true);
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final palette = context.appPalette;
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        backgroundColor: palette.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 720,
            maxHeight: math.min(680, MediaQuery.sizeOf(context).height * .9),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, color: palette.accentBright),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.tr('Manga backup'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('manga-backup-close'),
                      autofocus: true,
                      tooltip: context.tr('Close'),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const LinearProgressIndicator(
                  key: ValueKey('manga-backup-busy'),
                  minHeight: 2,
                ),
              Flexible(
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          context.tr(
                            'Encrypted library, chapter progress, bookmarks, and reader settings. No account credentials or downloaded pages.',
                          ),
                          style: TextStyle(
                            color: palette.mutedText,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (preview == null) ...[
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              ChoiceChip(
                                key: const ValueKey('manga-backup-mode-export'),
                                label: Text(context.tr('Export backup')),
                                selected: !_importing,
                                onSelected: _busy
                                    ? null
                                    : (_) => _changeMode(false),
                              ),
                              ChoiceChip(
                                key: const ValueKey('manga-backup-mode-import'),
                                label: Text(context.tr('Import backup')),
                                selected: _importing,
                                onSelected: _busy
                                    ? null
                                    : (_) => _changeMode(true),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (_importing) ...[
                            OutlinedButton.icon(
                              key: const ValueKey('manga-backup-choose-file'),
                              onPressed: _busy ? null : _chooseFile,
                              icon: const Icon(Icons.folder_open_outlined),
                              label: Text(
                                context.tr(
                                  _encrypted == null
                                      ? 'Choose encrypted backup'
                                      : 'Choose another backup',
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          IgnorePointer(
                            ignoring: _busy,
                            child: ExcludeFocus(
                              excluding: _busy,
                              child: TvTextInput(
                                key: const ValueKey('manga-backup-password'),
                                controller: _password,
                                focusNode: _passwordFocus,
                                labelText: context.tr('Backup passphrase'),
                                helperText: context.tr(
                                  'At least 12 characters. This passphrase cannot be recovered.',
                                ),
                                obscureText: true,
                                maxLength: 512,
                                onChanged: (_) =>
                                    setState(() => _preview = null),
                              ),
                            ),
                          ),
                          if (!_importing) ...[
                            const SizedBox(height: 12),
                            IgnorePointer(
                              ignoring: _busy,
                              child: ExcludeFocus(
                                excluding: _busy,
                                child: TvTextInput(
                                  key: const ValueKey(
                                    'manga-backup-password-confirm',
                                  ),
                                  controller: _confirmation,
                                  labelText: context.tr('Confirm passphrase'),
                                  obscureText: true,
                                  maxLength: 512,
                                ),
                              ),
                            ),
                          ],
                        ] else ...[
                          Text(
                            context.tr('Review backup import'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            context.tr(
                              '{newCount} new titles · {conflictCount} existing titles · {settingsCount} reader settings',
                              {
                                'newCount': preview.newTitles,
                                'conflictCount': preview.conflictingTitles,
                                'settingsCount': preview.preferenceChanges,
                              },
                            ),
                          ),
                          if (preview.reconnectRequired > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                context.tr(
                                  '{count} titles need their manga extension enabled or source identity reselected.',
                                  {'count': preview.reconnectRequired},
                                ),
                              ),
                            ),
                          if (preview.skippedLegacyTitles > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                context.tr(
                                  '{count} older non-Seanime titles were not included in this backup.',
                                  {'count': preview.skippedLegacyTitles},
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              context.tr(
                                '{count} chapter records · {historyCount} from unsaved titles · {conflictCount} existing history records',
                                {
                                  'count': preview.chapterRecords,
                                  'historyCount': preview.historyChapters,
                                  'conflictCount':
                                      preview.conflictingHistoryChapters,
                                },
                              ),
                            ),
                          ),
                          if (preview.historyChapters > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                context.tr(
                                  'Unsaved history reconnects when you open the same title from the same extension. No library titles are added.',
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          for (final title in preview.titles.take(20))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '${title.title} — ${title.providerName}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (preview.titles.length > 20)
                            Text(
                              context.tr('And {count} more titles.', {
                                'count': preview.titles.length - 20,
                              }),
                            ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<MangaBackupConflictPolicy>(
                            key: const ValueKey('manga-backup-conflict-policy'),
                            initialValue: _policy,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: context.tr('Existing data'),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: MangaBackupConflictPolicy.mergeNewer,
                                child: Text(
                                  context.tr('Merge newer progress'),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              DropdownMenuItem(
                                value: MangaBackupConflictPolicy.keepExisting,
                                child: Text(
                                  context.tr('Keep existing data and settings'),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            onChanged: _busy
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _policy = value);
                                    }
                                  },
                          ),
                          const SizedBox(height: 12),
                          Text(
                            context.tr(
                              'Merge keeps newer chapter progress and restores backed-up reader settings. Nothing missing from the backup is deleted. Downloads are unchanged.',
                            ),
                            style: TextStyle(
                              color: palette.mutedText,
                              height: 1.4,
                            ),
                          ),
                        ],
                        if (_notice != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Text(
                              context.tr(_notice!),
                              key: const ValueKey('manga-backup-notice'),
                              style: TextStyle(
                                color: _error
                                    ? Theme.of(context).colorScheme.error
                                    : palette.accentBright,
                                height: 1.4,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OverflowBar(
                  spacing: 10,
                  overflowSpacing: 8,
                  children: [
                    if (preview != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _preview = null;
                                _encrypted = null;
                              }),
                        child: Text(context.tr('Choose another backup')),
                      ),
                    FilledButton(
                      key: const ValueKey('manga-backup-primary-action'),
                      focusNode: _actionFocus,
                      onPressed: _busy || (_importing && _encrypted == null)
                          ? null
                          : preview != null
                          ? _confirmImport
                          : _importing
                          ? _previewImport
                          : _export,
                      child: Text(
                        context.tr(
                          _busy
                              ? 'Please wait…'
                              : preview != null
                              ? 'Confirm import'
                              : _importing
                              ? 'Preview import'
                              : 'Save encrypted backup',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
