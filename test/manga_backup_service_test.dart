import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/data/manga_backup_service.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const passphrase = 'correct horse manga library';
  const provider = 'example.manga';
  const protectedIdentity = 'private-title-identifier';
  final source =
      'extension.${hash.sha256.convert(utf8.encode(provider)).toString().substring(0, 40)}';
  final entryId =
      'publication.${hash.sha256.convert(utf8.encode('$provider\n$protectedIdentity')).toString().substring(0, 40)}';
  final chapterId = 'chapter.${'a' * 40}';
  final unsavedId = 'publication.${'b' * 40}';
  final unsavedChapter = 'chapter.${'b' * 40}';
  final unopenedChapter = 'chapter.${'c' * 40}';
  final now = DateTime.utc(2026, 9, 5);
  const secureStorage = FlutterSecureStorage();
  late Database database;
  late MangaStore store;
  late MangaBackupService service;
  late Map<String, String> identities;
  var failIdentityWrite = false;
  late String encrypted;
  late Map<String, dynamic> clearFixture;
  late Map<String, dynamic> envelopeFixture;
  late SecretKey fixtureKey;

  String identityKey(String owner, String source, String entry) =>
      '$owner/$source/$entry';
  MangaLibraryEntry library({String owner = 'profile'}) => MangaLibraryEntry(
    ownerKey: owner,
    sourceId: source,
    entryId: entryId,
    title: 'My private reading title',
    category: 'Favorites',
    status: MangaLibraryStatus.reading,
    metadata: const {
      'kind': 'seanime-manga-extension',
      'providerId': provider,
      'providerName': 'Example',
      'language': 'en',
      'year': 2024,
      'synonyms': ['A saved synonym'],
    },
    coverUri: Uri.parse('https://images.example/cover.webp'),
    updatedAt: now,
  );

  MangaReadingProgress historyProgress({
    String owner = 'profile',
    String? chapter,
    int page = 6,
    DateTime? updatedAt,
    bool bookmarked = false,
  }) => MangaReadingProgress(
    ownerKey: owner,
    sourceId: source,
    entryId: unsavedId,
    chapterId: chapter ?? unsavedChapter,
    pageIndex: page,
    pageOffset: 0,
    pageCount: 10,
    completed: false,
    bookmarked: bookmarked,
    updatedAt: updatedAt ?? now.subtract(const Duration(days: 1)),
  );

  Future<void> initialize() async {
    FlutterSecureStorage.setMockInitialValues({});
    identities = {};
    failIdentityWrite = false;
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: configureTetoTvDatabase,
        onCreate: (db, _) => createMangaTables(db),
        version: 1,
      ),
    );
    store = MangaStore(databaseProvider: () async => database);
    service = MangaBackupService(
      store: store,
      preferencesStorage: secureStorage,
      readIdentity:
          ({required ownerKey, required sourceId, required entryId}) async =>
              identities[identityKey(ownerKey, sourceId, entryId)],
      writeIdentity:
          ({
            required ownerKey,
            required sourceId,
            required entryId,
            required mangaId,
          }) async {
            final key = identityKey(ownerKey, sourceId, entryId);
            if (mangaId == null) {
              identities.remove(key);
            } else {
              identities[key] = mangaId;
            }
            if (failIdentityWrite && mangaId != null) {
              throw StateError('simulated protected storage failure');
            }
          },
    );
  }

  Future<void> seed() async {
    await store.upsertLibraryEntry(library());
    identities[identityKey('profile', source, entryId)] = protectedIdentity;
    await store.upsertProgress(
      MangaReadingProgress(
        ownerKey: 'profile',
        sourceId: source,
        entryId: entryId,
        chapterId: chapterId,
        chapterNumber: 1,
        pageIndex: 4,
        pageOffset: .2,
        pageCount: 24,
        completed: true,
        bookmarked: true,
        updatedAt: now,
      ),
    );
    await store.upsertProgress(
      MangaReadingProgress(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
        chapterId: unsavedChapter,
        pageIndex: 2,
        pageOffset: .4,
        pageCount: 10,
        completed: false,
        bookmarked: true,
        updatedAt: now,
      ),
    );
    await store.setChapterBookmark(
      ownerKey: 'profile',
      sourceId: source,
      entryId: unsavedId,
      chapterId: unopenedChapter,
      bookmarked: true,
      updatedAt: now.add(const Duration(hours: 1)),
    );
    // Neither another profile nor non-Seanime raw identities may leak.
    for (final owner in ['other-profile', 'profile']) {
      await store.upsertProgress(
        MangaReadingProgress(
          ownerKey: owner,
          sourceId: owner == 'profile' ? 'legacy-source' : source,
          entryId: 'private-out-of-scope-identity',
          chapterId: chapterId,
          pageIndex: 0,
          pageOffset: 0,
          completed: false,
          updatedAt: now,
        ),
      );
    }
    await store.replaceChapterSnapshot(
      ownerKey: 'profile',
      sourceId: source,
      entryId: entryId,
      chapters: [
        MangaChapterSnapshot(
          chapterId: chapterId,
          title: 'Chapter One',
          ordinal: 0,
          chapterNumber: 1,
        ),
      ],
      checkedAt: now,
    );
    await secureStorage.write(key: 'manga_reader_v1_mode', value: 'webtoon');
    await secureStorage.write(key: 'manga_reader_v1_preload', value: '3');
    await secureStorage.write(
      key: 'unrelated_account_token',
      value: 'private-account-credential',
    );
    final seriesKey =
        'manga_reader_series_v1_${hash.sha256.convert(utf8.encode(jsonEncode([source, entryId])))}';
    await secureStorage.write(
      key: seriesKey,
      value: jsonEncode({
        'enabled': true,
        'mode': 'paged',
        'direction': 'leftToRight',
        'spread': 'single',
        'fit': 'width',
      }),
    );
  }

  Future<String> alteredPayload(
    void Function(Map<String, dynamic>) edit,
  ) async {
    final payload =
        jsonDecode(jsonEncode(clearFixture)) as Map<String, dynamic>;
    edit(payload);
    final cipher = AesGcm.with256bits();
    final nonce = cipher.newNonce();
    final box = await cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: fixtureKey,
      nonce: nonce,
      aad: utf8.encode(
        'tetotv-manga-backup|1|AES-256-GCM|PBKDF2-HMAC-SHA256|600000',
      ),
    );
    return jsonEncode({
      ...envelopeFixture,
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
  }

  setUpAll(() async {
    await initialize();
    await seed();
    encrypted = await service.exportEncrypted(
      ownerKey: 'profile',
      passphrase: passphrase,
    );
    envelopeFixture = jsonDecode(encrypted) as Map<String, dynamic>;
    fixtureKey =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: MangaBackupService.derivationIterations,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(passphrase)),
          nonce: base64Decode(envelopeFixture['salt'] as String),
        );
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        base64Decode(envelopeFixture['ciphertext'] as String),
        nonce: base64Decode(envelopeFixture['nonce'] as String),
        mac: Mac(base64Decode(envelopeFixture['tag'] as String)),
      ),
      secretKey: fixtureKey,
      aad: utf8.encode(
        'tetotv-manga-backup|1|AES-256-GCM|PBKDF2-HMAC-SHA256|600000',
      ),
    );
    clearFixture = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    await database.close();
  });
  setUp(initialize);
  tearDown(() async {
    await database.close();
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'encrypted export has fixed strong KDF and no readable titles, identities, or unrelated secrets',
    () {
      expect(envelopeFixture['iterations'], 600000);
      for (final secret in [
        protectedIdentity,
        'My private reading title',
        'Favorites',
        source,
        entryId,
        'private-account-credential',
      ]) {
        expect(encrypted, isNot(contains(secret)));
      }
      final clear = jsonEncode(clearFixture);
      expect(clear, contains(protectedIdentity));
      for (final forbidden in [
        'https://',
        'cover.webp',
        'private-account-credential',
        'unrelated_account_token',
        'headers',
        'page_url',
        'download_jobs',
        'private-out-of-scope-identity',
        'other-profile',
      ]) {
        expect(clear, isNot(contains(forbidden)));
      }
    },
  );

  test(
    'preview is read-only, explicit confirmed import restores a working title and preferences into selected profile',
    () async {
      final preview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'new-profile',
        availableProviderIds: {provider},
      );
      expect(preview.newTitles, 1);
      expect(preview.conflictingTitles, 0);
      expect(preview.reconnectRequired, 0);
      expect(preview.preferenceChanges, 2);
      expect(preview.chapterRecords, 3);
      expect(preview.historyChapters, 2);
      expect(preview.conflictingHistoryChapters, 0);
      expect(await store.libraryEntries('new-profile'), isEmpty);
      await expectLater(
        service.confirmImport(preview, confirmed: false),
        throwsStateError,
      );
      final result = await service.confirmImport(preview, confirmed: true);
      expect(result.importedTitles, 1);
      expect(result.importedChapters, 3);
      expect(result.importedHistoryChapters, 2);
      final restored = (await store.libraryEntries('new-profile')).single;
      expect(restored.category, 'Favorites');
      expect(restored.status, MangaLibraryStatus.reading);
      expect(restored.coverUri, isNull);
      final progress = (await store.chapterProgressForEntry(
        ownerKey: 'new-profile',
        sourceId: source,
        entryId: entryId,
      )).single;
      expect(progress.pageIndex, 4);
      expect(progress.completed, isTrue);
      expect(progress.bookmarked, isTrue);
      expect(
        (await store.progress(
          ownerKey: 'new-profile',
          sourceId: source,
          entryId: entryId,
        ))!.chapterId,
        chapterId,
      );
      expect(
        identities[identityKey('new-profile', source, entryId)],
        protectedIdentity,
      );
      expect(await secureStorage.read(key: 'manga_reader_v1_mode'), 'webtoon');
      expect(await store.libraryEntries('profile'), isEmpty);
      expect(await store.libraryEntries('new-profile'), hasLength(1));
      final unsaved = await store.chapterProgressForEntry(
        ownerKey: 'new-profile',
        sourceId: source,
        entryId: unsavedId,
      );
      expect(unsaved, hasLength(2));
      expect(unsaved.every((row) => row.bookmarked), isTrue);
      expect(
        unsaved.firstWhere((row) => row.chapterId == unsavedChapter).pageIndex,
        2,
      );
      expect(
        (await store.progress(
          ownerKey: 'new-profile',
          sourceId: source,
          entryId: unsavedId,
        ))!.chapterId,
        unsavedChapter,
      );
      expect(identities.keys, hasLength(1));
    },
  );

  test(
    'wrong passphrase, modified ciphertext and malicious KDF envelopes cannot modify state',
    () async {
      await expectLater(
        service.previewImport(
          encrypted: encrypted,
          passphrase: 'incorrect password text',
          ownerKey: 'profile',
        ),
        throwsFormatException,
      );
      final cipher = base64Decode(envelopeFixture['ciphertext'] as String)
        ..[0] ^= 1;
      await expectLater(
        service.previewImport(
          encrypted: jsonEncode({
            ...envelopeFixture,
            'ciphertext': base64Encode(cipher),
          }),
          passphrase: passphrase,
          ownerKey: 'profile',
        ),
        throwsFormatException,
      );
      await expectLater(
        service.previewImport(
          encrypted: jsonEncode({...envelopeFixture, 'iterations': 999999999}),
          passphrase: passphrase,
          ownerKey: 'profile',
        ),
        throwsFormatException,
      );
      expect(await store.libraryEntries('profile'), isEmpty);
      expect(identities, isEmpty);
    },
  );

  test(
    'strict authenticated payload rejects unknown secret fields and invalid reading bounds',
    () async {
      final malicious = await alteredPayload(
        (data) => (data['titles'] as List).first['metadata']['headers'] = {
          'Authorization': 'secret',
        },
      );
      await expectLater(
        service.previewImport(
          encrypted: malicious,
          passphrase: passphrase,
          ownerKey: 'profile',
        ),
        throwsFormatException,
      );
      final invalid = await alteredPayload(
        (data) =>
            (data['titles'] as List).first['progress'][0]['pageIndex'] = 999,
      );
      await expectLater(
        service.previewImport(
          encrypted: invalid,
          passphrase: passphrase,
          ownerKey: 'profile',
        ),
        throwsFormatException,
      );
      expect(await store.libraryEntries('profile'), isEmpty);
    },
  );

  test(
    'conflict preview, keep-existing and stale confirmation protect newer local progress',
    () async {
      await seed();
      await store.upsertProgress(
        MangaReadingProgress(
          ownerKey: 'profile',
          sourceId: source,
          entryId: entryId,
          chapterId: chapterId,
          pageIndex: 15,
          pageOffset: .5,
          pageCount: 24,
          completed: false,
          updatedAt: now.add(const Duration(days: 1)),
        ),
      );
      final preview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      expect(preview.conflictingTitles, 1);
      expect(preview.reconnectRequired, 1);
      final kept = await service.confirmImport(
        preview,
        confirmed: true,
        conflictPolicy: MangaBackupConflictPolicy.keepExisting,
      );
      expect(kept.skippedTitles, 1);
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: source,
          entryId: entryId,
        ))!.pageIndex,
        15,
      );
      await store.setLibraryOrganization(
        ownerKey: 'profile',
        sourceId: source,
        entryId: entryId,
        category: 'Changed after preview',
        status: MangaLibraryStatus.onHold,
      );
      await expectLater(
        service.confirmImport(preview, confirmed: true),
        throwsStateError,
      );
    },
  );

  test(
    'protected-store write failure rolls back SQLite and compensates partial identity writes',
    () async {
      final preview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      failIdentityWrite = true;
      await expectLater(
        service.confirmImport(preview, confirmed: true),
        throwsStateError,
      );
      expect(await store.libraryEntries('profile'), isEmpty);
      expect(
        await store.chapterProgressForEntry(
          ownerKey: 'profile',
          sourceId: source,
          entryId: entryId,
        ),
        isEmpty,
      );
      expect(identities, isEmpty);
      expect(await secureStorage.read(key: 'manga_reader_v1_mode'), isNull);
      // History rows were written before the failing protected write, so this
      // proves they share the same SQL rollback as saved-library records.
      expect(await store.chapterHistoryForOwner('profile'), isEmpty);
      expect(await store.latestHistoryForOwner('profile'), isEmpty);
    },
  );

  test('export includes only hash-keyed unsaved history, with no overlaps', () {
    final rows = clearFixture['history'] as List;
    expect(rows, hasLength(2));
    expect(rows.where((row) => row['latest'] == true), hasLength(1));
    for (final row in rows) {
      expect((row as Map).keys.toSet(), {
        'sourceId',
        'entryId',
        'latest',
        'progress',
      });
      expect(row['sourceId'], source);
      expect(row['entryId'], unsavedId);
      expect(row['entryId'], isNot(entryId));
    }
  });

  test(
    'saved-library-only format remains readable without a history field',
    () async {
      final legacy = await alteredPayload((data) => data.remove('history'));
      final preview = await service.previewImport(
        encrypted: legacy,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      expect(preview.historyChapters, 0);
      expect(preview.chapterRecords, 1);
      await service.confirmImport(preview, confirmed: true);
      expect(await store.chapterHistoryForOwner('profile'), hasLength(1));
    },
  );

  test(
    'history-only restore creates no library entries or protected identities',
    () async {
      final historyOnly = await alteredPayload((data) {
        data['titles'] = [];
        data['preferences'] = {};
      });
      final preview = await service.previewImport(
        encrypted: historyOnly,
        passphrase: passphrase,
        ownerKey: 'chosen-profile',
      );
      expect(preview.titles, isEmpty);
      expect(preview.chapterRecords, 2);
      expect(preview.reconnectRequired, 0);
      final result = await service.confirmImport(preview, confirmed: true);
      expect(result.importedTitles, 0);
      expect(result.importedHistoryChapters, 2);
      expect(await store.libraryEntries('chosen-profile'), isEmpty);
      expect(
        await store.chapterHistoryForOwner('chosen-profile'),
        hasLength(2),
      );
      expect(await store.chapterHistoryForOwner('profile'), isEmpty);
      expect(identities, isEmpty);
      expect(await secureStorage.readAll(), isEmpty);
    },
  );

  test(
    'authenticated history rejects duplicates, overlaps, capabilities, and bounds',
    () async {
      final mutations = <void Function(Map<String, dynamic>)>[
        (data) => (data['history'] as List).add(data['history'][0]),
        (data) => data['history'][0]['entryId'] = entryId,
        (data) => data['history'][1]['latest'] = true,
        (data) => data['history'][0]['ownerKey'] = 'another-profile',
        (data) => data['history'][0]['entryId'] =
            'https://private.example/title?token=secret',
        (data) => data['history'][0]['progress']['headers'] = {
          'Authorization': 'secret',
        },
        (data) => data['history'][0]['progress']['pageIndex'] = 10,
        (data) => data['history'] = null,
        (data) => data['history'] = List<Object?>.filled(50001, null),
      ];
      for (final mutation in mutations) {
        final malformed = await alteredPayload(mutation);
        await expectLater(
          service.previewImport(
            encrypted: malformed,
            passphrase: passphrase,
            ownerKey: 'profile',
          ),
          throwsFormatException,
        );
      }
      expect(await store.chapterHistoryForOwner('profile'), isEmpty);
      expect(await store.libraryEntries('profile'), isEmpty);
      expect(identities, isEmpty);
    },
  );

  test(
    'history conflict policies preserve existing rows or merge strictly newer state',
    () async {
      await store.upsertProgress(historyProgress());
      final preview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      expect(preview.conflictingHistoryChapters, 1);
      final kept = await service.confirmImport(
        preview,
        confirmed: true,
        conflictPolicy: MangaBackupConflictPolicy.keepExisting,
      );
      expect(kept.importedHistoryChapters, 1); // New bookmarked chapter only.
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: source,
          entryId: unsavedId,
        ))!.pageIndex,
        6,
      );
      final mergePreview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      expect(mergePreview.conflictingHistoryChapters, 2);
      final merged = await service.confirmImport(mergePreview, confirmed: true);
      expect(merged.importedHistoryChapters, 1);
      final restored = await store.chapterProgress(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
        chapterId: unsavedChapter,
      );
      expect(restored!.pageIndex, 2);
      expect(restored.bookmarked, isTrue);

      await store.restoreChapterProgress(
        historyProgress(page: 9, updatedAt: now.add(const Duration(days: 1))),
        latest: true,
      );
      final newerPreview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      final skipped = await service.confirmImport(
        newerPreview,
        confirmed: true,
      );
      expect(skipped.importedHistoryChapters, 0);
      final newer = await store.chapterProgress(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
        chapterId: unsavedChapter,
      );
      expect(newer!.pageIndex, 9);
      expect(newer.bookmarked, isFalse); // An explicit newer clear wins.
    },
  );

  test('history merge cannot replace a newer title resume pointer', () async {
    final latestChapter = 'chapter.${'d' * 40}';
    await store.upsertProgress(
      historyProgress(
        chapter: latestChapter,
        updatedAt: now.add(const Duration(days: 1)),
      ),
    );
    final preview = await service.previewImport(
      encrypted: encrypted,
      passphrase: passphrase,
      ownerKey: 'profile',
    );
    await service.confirmImport(preview, confirmed: true);
    expect(
      (await store.progress(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
      ))!.chapterId,
      latestChapter,
    );
    expect(
      await store.chapterProgressForEntry(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
      ),
      hasLength(3),
    );
  });

  test(
    'history edits and clears invalidate an earlier import preview',
    () async {
      await store.upsertProgress(historyProgress());
      final preview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      await store.setChapterBookmark(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
        chapterId: unsavedChapter,
        bookmarked: true,
        updatedAt: now,
      );
      await expectLater(
        service.confirmImport(preview, confirmed: true),
        throwsStateError,
      );
      expect(await store.libraryEntries('profile'), isEmpty);
      final refreshed = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      await store.deleteProgress(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
      );
      await expectLater(
        service.confirmImport(refreshed, confirmed: true),
        throwsStateError,
      );
      expect(await store.chapterHistoryForOwner('profile'), isEmpty);
    },
  );

  test(
    'history rollback restores overwritten state and removes newly imported bookmarks',
    () async {
      await store.upsertProgress(historyProgress());
      final preview = await service.previewImport(
        encrypted: encrypted,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      failIdentityWrite = true;
      await expectLater(
        service.confirmImport(preview, confirmed: true),
        throwsStateError,
      );
      final rows = await store.chapterProgressForEntry(
        ownerKey: 'profile',
        sourceId: source,
        entryId: unsavedId,
      );
      expect(rows, hasLength(1));
      expect(rows.single.chapterId, unsavedChapter);
      expect(rows.single.pageIndex, 6);
      expect(rows.single.bookmarked, isFalse);
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: source,
          entryId: unsavedId,
        ))!.pageIndex,
        6,
      );
      expect(await store.libraryEntries('profile'), isEmpty);
      expect(identities, isEmpty);
    },
  );

  test(
    'large encrypted history below backup caps remains importable',
    () async {
      final large = await alteredPayload((data) {
        final template = data['history'][0] as Map;
        data['titles'] = [];
        data['preferences'] = {};
        data['history'] = [
          for (var index = 0; index < 250; index++)
            {
              ...template,
              'latest': index == 0,
              'progress': {
                ...template['progress'] as Map,
                'chapterId':
                    'chapter.${index.toRadixString(16).padLeft(40, '0')}',
              },
            },
        ];
      });
      expect(
        (jsonDecode(large)['ciphertext'] as String).length,
        greaterThan(65536),
      );
      final preview = await service.previewImport(
        encrypted: large,
        passphrase: passphrase,
        ownerKey: 'profile',
      );
      expect(preview.chapterRecords, 250);
      final result = await service.confirmImport(preview, confirmed: true);
      expect(result.importedHistoryChapters, 250);
      expect(await store.libraryEntries('profile'), isEmpty);
    },
  );

  test(
    'export rejects malformed Seanime history instead of leaking raw identities',
    () async {
      await store.upsertProgress(
        MangaReadingProgress(
          ownerKey: 'profile',
          sourceId: source,
          entryId: 'private-title?token=secret',
          chapterId: chapterId,
          pageIndex: 0,
          pageOffset: 0,
          completed: false,
          updatedAt: now,
        ),
      );
      await expectLater(
        service.exportEncrypted(ownerKey: 'profile', passphrase: passphrase),
        throwsFormatException,
      );
    },
  );

  test(
    'export rejects short passphrases and signed/page identities before encryption',
    () async {
      await expectLater(
        service.exportEncrypted(ownerKey: 'profile', passphrase: 'short'),
        throwsFormatException,
      );
      await seed();
      identities[identityKey('profile', source, entryId)] =
          'https://reader.example/pages/3.webp?token=secret';
      await expectLater(
        service.exportEncrypted(ownerKey: 'profile', passphrase: passphrase),
        throwsFormatException,
      );
    },
  );
}
