import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/localization/catalogs/manga_backup_strings.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_backup_service.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/presentation/manga_backup_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Documents implements MangaBackupDocumentAccess {
  String? selected;
  int opens = 0;
  final saved = <String>[];
  @override
  Future<String?> open() async {
    opens++;
    return selected;
  }

  @override
  Future<bool> save(String encrypted, String suggestedName) async {
    expect(suggestedName, endsWith('.json'));
    saved.add(encrypted);
    return true;
  }
}

class _Backup extends MangaBackupService {
  _Backup()
    : super(
        store: MangaStore(),
        readIdentity:
            ({required ownerKey, required sourceId, required entryId}) async =>
                null,
        writeIdentity:
            ({
              required ownerKey,
              required sourceId,
              required entryId,
              required mangaId,
            }) async {},
      );
  Completer<String>? pending;
  int exports = 0;
  int previews = 0;
  int imports = 0;
  MangaBackupImportPreview? resultPreview;
  @override
  Future<String> exportEncrypted({
    required String ownerKey,
    required String passphrase,
  }) async {
    expect(ownerKey, 'profile');
    expect(passphrase, 'a private manga password');
    exports++;
    return pending?.future ?? 'encrypted-backup-only';
  }

  @override
  Future<MangaBackupImportPreview> previewImport({
    required String encrypted,
    required String passphrase,
    required String ownerKey,
    Set<String> availableProviderIds = const {},
  }) async {
    previews++;
    if (resultPreview != null) return resultPreview!;
    throw const FormatException('private-server-url?token=NEVER-DISPLAY');
  }

  @override
  Future<MangaBackupImportResult> confirmImport(
    MangaBackupImportPreview preview, {
    required bool confirmed,
    MangaBackupConflictPolicy conflictPolicy =
        MangaBackupConflictPolicy.mergeNewer,
  }) async {
    expect(confirmed, isTrue);
    expect(preview, same(resultPreview));
    imports++;
    return const MangaBackupImportResult(
      importedTitles: 0,
      skippedTitles: 0,
      importedChapters: 1,
      importedHistoryChapters: 1,
      reconnectRequired: 0,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late MangaBackupImportPreview historyPreview;
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onCreate: (db, _) => createMangaTables(db),
        version: 1,
      ),
    );
    try {
      final store = MangaStore(databaseProvider: () async => database);
      await store.upsertProgress(
        MangaReadingProgress(
          ownerKey: 'profile',
          sourceId: 'extension.${'a' * 40}',
          entryId: 'publication.${'b' * 40}',
          chapterId: 'chapter.${'c' * 40}',
          pageIndex: 0,
          pageOffset: 0,
          bookmarked: true,
          completed: false,
          updatedAt: DateTime.utc(2026, 9, 5),
        ),
      );
      final service = MangaBackupService(
        store: store,
        readIdentity:
            ({required ownerKey, required sourceId, required entryId}) async =>
                null,
        writeIdentity:
            ({
              required ownerKey,
              required sourceId,
              required entryId,
              required mangaId,
            }) async {},
      );
      final encrypted = await service.exportEncrypted(
        ownerKey: 'profile',
        passphrase: 'a private manga password',
      );
      historyPreview = await service.previewImport(
        encrypted: encrypted,
        passphrase: 'a private manga password',
        ownerKey: 'profile',
      );
    } finally {
      await database.close();
    }
  });
  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    }),
  );
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));
  Future<void> show(
    WidgetTester tester,
    _Backup service,
    _Documents documents,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaOwnerKeyProvider.overrideWith((ref) async => 'profile'),
          mangaBackupAvailableProvidersProvider.overrideWithValue({}),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => MangaBackupDialog(
                      service: service,
                      documents: documents,
                    ),
                  ),
                  child: const Text('Open backup'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open backup'));
    await tester.pumpAndSettle();
  }

  void password(WidgetTester tester, {bool confirm = true}) {
    tester
            .widget<TvTextInput>(
              find.byKey(const ValueKey('manga-backup-password')),
            )
            .controller
            .text =
        'a private manga password';
    if (confirm) {
      tester
              .widget<TvTextInput>(
                find.byKey(const ValueKey('manga-backup-password-confirm')),
              )
              .controller
              .text =
          'a private manga password';
    }
  }

  for (final size in [const Size(960, 540), const Size(390, 844)]) {
    testWidgets('backup form fits $size and masks password fields', (
      tester,
    ) async {
      await show(tester, _Backup(), _Documents(), size);
      final fields = tester.widgetList<TvTextInput>(find.byType(TvTextInput));
      expect(fields, hasLength(2));
      expect(fields.every((field) => field.obscureText), isTrue);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(MangaBackupDialog), findsNothing);
    });

    testWidgets('history preview fits $size and imports only after confirmation', (
      tester,
    ) async {
      final service = _Backup()..resultPreview = historyPreview;
      final documents = _Documents()..selected = 'encrypted-history';
      await show(tester, service, documents, size);
      await tester.tap(find.byKey(const ValueKey('manga-backup-mode-import')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('manga-backup-choose-file')));
      await tester.pumpAndSettle();
      password(tester, confirm: false);
      await tester.tap(
        find.byKey(const ValueKey('manga-backup-primary-action')),
      );
      await tester.pumpAndSettle();
      expect(service.previews, 1);
      expect(service.imports, 0);
      expect(
        find.text(
          '1 chapter records · 1 from unsaved titles · 1 existing history records',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Unsaved history reconnects when you open the same title from the same extension. No library titles are added.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('manga-backup-primary-action')),
      );
      await tester.pumpAndSettle();
      expect(service.imports, 1);
      expect(find.byType(MangaBackupDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'backup translations cover every locale and preserve count placeholders',
    () {
      final keys = mangaBackupTranslations['es']!.keys.toSet();
      final placeholder = RegExp(r'\{[A-Za-z][A-Za-z0-9]*\}');
      for (final locale in ['es', 'pt', 'fr', 'hi', 'de']) {
        final translations = mangaBackupTranslations[locale]!;
        expect(translations.keys.toSet(), keys);
        for (final entry in translations.entries) {
          expect(entry.value.trim(), isNotEmpty);
          expect(
            placeholder
                .allMatches(entry.value)
                .map((match) => match.group(0))
                .toSet(),
            placeholder
                .allMatches(entry.key)
                .map((match) => match.group(0))
                .toSet(),
            reason: '$locale: ${entry.key}',
          );
        }
      }
    },
  );

  testWidgets(
    'passphrase validation performs no export and never displays input',
    (tester) async {
      final service = _Backup();
      final documents = _Documents();
      await show(tester, service, documents, const Size(960, 540));
      await tester.tap(
        find.byKey(const ValueKey('manga-backup-primary-action')),
      );
      await tester.pumpAndSettle();
      expect(service.exports, 0);
      password(tester);
      tester
              .widget<TvTextInput>(
                find.byKey(const ValueKey('manga-backup-password-confirm')),
              )
              .controller
              .text =
          'another private password';
      await tester.tap(
        find.byKey(const ValueKey('manga-backup-primary-action')),
      );
      await tester.pumpAndSettle();
      expect(service.exports, 0);
      expect(find.text('a private manga password'), findsNothing);
      expect(documents.saved, isEmpty);
    },
  );

  testWidgets(
    'busy export prevents duplicate actions and closing then saves encrypted file only',
    (tester) async {
      final service = _Backup()..pending = Completer<String>();
      final documents = _Documents();
      await show(tester, service, documents, const Size(700, 400));
      password(tester);
      await tester.tap(
        find.byKey(const ValueKey('manga-backup-primary-action')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byKey(const ValueKey('manga-backup-busy')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('manga-backup-close')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('manga-backup-primary-action')),
            )
            .onPressed,
        isNull,
      );
      service.pending!.complete('encrypted-backup-only');
      await tester.pumpAndSettle();
      expect(service.exports, 1);
      expect(documents.saved, ['encrypted-backup-only']);
      expect(
        tester
            .widget<TvTextInput>(
              find.byKey(const ValueKey('manga-backup-password')),
            )
            .controller
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled picker is harmless and import errors are privacy-safe',
    (tester) async {
      final service = _Backup();
      final documents = _Documents();
      await show(tester, service, documents, const Size(960, 540));
      await tester.tap(find.byKey(const ValueKey('manga-backup-mode-import')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('manga-backup-choose-file')));
      await tester.pumpAndSettle();
      expect(service.previews, 0);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('manga-backup-primary-action')),
            )
            .onPressed,
        isNull,
      );
      documents.selected = 'encrypted-backup-only';
      await tester.tap(find.byKey(const ValueKey('manga-backup-choose-file')));
      await tester.pumpAndSettle();
      password(tester, confirm: false);
      await tester.tap(
        find.byKey(const ValueKey('manga-backup-primary-action')),
      );
      await tester.pumpAndSettle();
      expect(service.previews, 1);
      expect(find.textContaining('NEVER-DISPLAY'), findsNothing);
      expect(find.textContaining('private-server-url'), findsNothing);
      expect(
        find.textContaining('Check the passphrase and file'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
