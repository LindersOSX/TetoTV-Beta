import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/features/manga/data/manga_parse_support.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef MangaBackupIdentityReader =
    Future<String?> Function({
      required String ownerKey,
      required String sourceId,
      required String entryId,
    });

/// Null means delete. The callback must throw on failure, not swallow it.
typedef MangaBackupIdentityWriter =
    Future<void> Function({
      required String ownerKey,
      required String sourceId,
      required String entryId,
      required String? mangaId,
    });

enum MangaBackupConflictPolicy { mergeNewer, keepExisting }

class MangaBackupTitlePreview {
  const MangaBackupTitlePreview({
    required this.title,
    required this.providerName,
    required this.alreadySaved,
    required this.requiresReconnect,
  });
  final String title;
  final String providerName;
  final bool alreadySaved;
  final bool requiresReconnect;
}

class MangaBackupImportPreview {
  MangaBackupImportPreview._({
    required this.ownerKey,
    required this.createdAt,
    required List<MangaBackupTitlePreview> titles,
    required this.preferenceChanges,
    required this.skippedLegacyTitles,
    required this.conflictingHistoryChapters,
    required List<_BackupTitle> data,
    required List<_BackupHistory> history,
    required Map<String, String> preferences,
    required this._fingerprint,
    required this._service,
  }) : titles = List.unmodifiable(titles),
       _data = List.unmodifiable(data),
       _history = List.unmodifiable(history),
       _preferences = Map.unmodifiable(preferences);
  final String ownerKey;
  final DateTime createdAt;
  final List<MangaBackupTitlePreview> titles;
  final int preferenceChanges;
  final int skippedLegacyTitles;

  /// Number of reading-state rows, not catalog chapter snapshots.
  int get chapterRecords =>
      _data.fold(0, (count, title) => count + title.progress.length) +
      historyChapters;
  int get historyChapters => _history.length;
  final int conflictingHistoryChapters;
  int get newTitles => titles.where((item) => !item.alreadySaved).length;
  int get conflictingTitles => titles.where((item) => item.alreadySaved).length;
  int get reconnectRequired =>
      titles.where((item) => item.requiresReconnect).length;
  final List<_BackupTitle> _data;
  final List<_BackupHistory> _history;
  final Map<String, String> _preferences;
  final String _fingerprint;
  final Object _service;
}

class MangaBackupImportResult {
  const MangaBackupImportResult({
    required this.importedTitles,
    required this.skippedTitles,
    required this.importedChapters,
    required this.reconnectRequired,
    this.importedHistoryChapters = 0,
  });
  final int importedTitles;
  final int skippedTitles;
  final int importedChapters;

  /// Included in [importedChapters], restored without creating library titles.
  final int importedHistoryChapters;
  final int reconnectRequired;
}

/// AES-GCM encrypted, bounded, user-initiated backup of Seanime library state.
/// Never exports the database, sources/URLs, credentials, downloaded files,
/// request headers, or arbitrary catalog metadata. Protected title identities
/// are encrypted and restored only after an explicit preview confirmation.
class MangaBackupService {
  MangaBackupService({
    required this.store,
    required this.readIdentity,
    required this.writeIdentity,
    FlutterSecureStorage? preferencesStorage,
  }) : _preferencesStorage = preferencesStorage ?? const FlutterSecureStorage();

  static const maximumPlaintextBytes = 8 * 1024 * 1024;
  static const maximumEnvelopeBytes = 12 * 1024 * 1024;
  static const derivationIterations = 600000;
  static const maximumChapterRecords = 50000;
  static const _format = 'tetotv-manga-backup';
  static const _aad =
      'tetotv-manga-backup|1|AES-256-GCM|PBKDF2-HMAC-SHA256|600000';
  final MangaStore store;
  final MangaBackupIdentityReader readIdentity;
  final MangaBackupIdentityWriter writeIdentity;
  final FlutterSecureStorage _preferencesStorage;
  final Object _serviceIdentity = Object();
  final _cipher = AesGcm.with256bits();

  Future<String> exportEncrypted({
    required String ownerKey,
    required String passphrase,
  }) async {
    _text(ownerKey, 128, 'profile');
    _passphrase(passphrase);
    final payload = await store.transaction((transaction) async {
      final entries = await transaction.libraryEntries(ownerKey, limit: 500);
      if (entries.length == 500) {
        throw StateError(
          'This backup supports fewer than 500 library titles. Export was not truncated.',
        );
      }
      final exported = <Map<String, Object?>>[];
      final exportedIds = <String>{};
      var chapterRecords = 0;
      var skipped = 0;
      for (final entry in entries) {
        if (entry.metadata['kind'] != 'seanime-manga-extension') {
          skipped++;
          continue;
        }
        final identity = await readIdentity(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        );
        final progress = await transaction.chapterProgressForEntry(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        );
        final snapshots = await transaction.chapterSnapshots(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        );
        final latest = await transaction.progress(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        );
        final rawSeries = await _preferencesStorage.read(
          key: _seriesPreferenceKey(entry.sourceId, entry.entryId),
        );
        final data = <String, Object?>{
          'sourceId': entry.sourceId,
          'entryId': entry.entryId,
          'title': entry.title,
          'metadata': _portableMetadata(entry.metadata),
          'category': entry.category,
          'status': entry.status.name,
          'updatedAt': entry.updatedAt.millisecondsSinceEpoch,
          'chapterCheckedAt': entry.chapterCheckedAt?.millisecondsSinceEpoch,
          'chapterUpdatedAt': entry.chapterUpdatedAt?.millisecondsSinceEpoch,
          'newChapterCount': entry.newChapterCount,
          'identity': identity,
          'seriesPreferences': rawSeries == null
              ? null
              : _seriesPreferences(jsonDecode(rawSeries)),
          'latestChapterId': latest?.chapterId,
          'progress': progress.map(_progressJson).toList(),
          'chapters': snapshots.map(_snapshotJson).toList(),
        };
        _parseTitle(data, ownerKey); // Strict outbound allowlist, too.
        exported.add(data);
        exportedIds.add(_titleKey(entry.sourceId, entry.entryId));
        chapterRecords += progress.length + snapshots.length;
      }
      final latestHistory = {
        for (final row in await transaction.latestHistoryForOwner(ownerKey))
          _titleKey(row.sourceId, row.entryId): row.chapterId,
      };
      final history = <Map<String, Object?>>[];
      for (final progress in await transaction.chapterHistoryForOwner(
        ownerKey,
      )) {
        final key = _titleKey(progress.sourceId, progress.entryId);
        if (exportedIds.contains(key) || !_isSeanimeHistory(progress)) continue;
        final row = <String, Object?>{
          'sourceId': progress.sourceId,
          'entryId': progress.entryId,
          'latest': latestHistory[key] == progress.chapterId,
          'progress': _progressJson(progress),
        };
        _parseHistory(row, ownerKey);
        history.add(row);
      }
      if (chapterRecords + history.length > maximumChapterRecords) {
        throw const FormatException('The backup has too many chapter records.');
      }
      return <String, Object?>{
        'version': 1,
        'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
        'identityPolicy': 'encrypted-seanime-identity',
        'skippedLegacyTitles': skipped,
        'preferences': await _readGlobalPreferences(),
        'titles': exported,
        'history': history,
      };
    });
    final encoded = jsonEncode(payload);
    final clear = utf8.encode(encoded);
    if (clear.length > maximumPlaintextBytes) {
      throw StateError('The library backup exceeds its safe size limit.');
    }
    // An exported file must also fit the import parser's structural limits.
    _decode(encoded, maximumPlaintextBytes);
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final nonce = _cipher.newNonce();
    final key = await _deriveKey(passphrase, salt);
    final box = await _cipher.encrypt(
      clear,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(_aad),
    );
    return jsonEncode({
      'format': _format,
      'version': 1,
      'cipher': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': derivationIterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
  }

  Future<MangaBackupImportPreview> previewImport({
    required String encrypted,
    required String passphrase,
    required String ownerKey,
    Set<String> availableProviderIds = const {},
  }) async {
    _text(ownerKey, 128, 'profile');
    _passphrase(passphrase);
    if (utf8.encode(encrypted).length > maximumEnvelopeBytes) {
      throw const FormatException('The backup is too large.');
    }
    final envelope = _map(_decode(encrypted, maximumEnvelopeBytes), 'envelope');
    _keys(envelope, {
      'format',
      'version',
      'cipher',
      'kdf',
      'iterations',
      'salt',
      'nonce',
      'ciphertext',
      'tag',
    });
    if (envelope['format'] != _format ||
        envelope['version'] != 1 ||
        envelope['cipher'] != 'AES-256-GCM' ||
        envelope['kdf'] != 'PBKDF2-HMAC-SHA256' ||
        envelope['iterations'] != derivationIterations) {
      throw const FormatException('Unsupported manga backup format.');
    }
    final salt = _bytes(envelope['salt'], 16, 'salt');
    final nonce = _bytes(envelope['nonce'], 12, 'nonce');
    final tag = _bytes(envelope['tag'], 16, 'tag');
    final ciphertext = _bytes(envelope['ciphertext'], null, 'ciphertext');
    if (ciphertext.length > maximumPlaintextBytes || ciphertext.isEmpty) {
      throw const FormatException('The backup payload size is invalid.');
    }
    final List<int> clear;
    try {
      clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: await _deriveKey(passphrase, salt),
        aad: utf8.encode(_aad),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException(
        'The passphrase is incorrect or the backup is damaged.',
      );
    }
    final payload = _map(
      _decode(utf8.decode(clear), maximumPlaintextBytes),
      'payload',
    );
    _keys(
      payload,
      {
        'version',
        'createdAt',
        'identityPolicy',
        'skippedLegacyTitles',
        'preferences',
        'titles',
        'history',
      },
      optional: {'history'},
    ); // Accept earlier saved-library-only backups.
    if (payload['version'] != 1 ||
        payload['identityPolicy'] != 'encrypted-seanime-identity') {
      throw const FormatException('Unsupported backup payload.');
    }
    final created = _date(payload['createdAt'], 'createdAt');
    final preferences = _globalPreferences(payload['preferences']);
    final titles = _list(
      payload['titles'],
      499,
      'titles',
    ).map((value) => _parseTitle(_map(value, 'title'), ownerKey)).toList();
    final ids = <String>{};
    var chapters = 0;
    for (final title in titles) {
      if (!ids.add(_titleKey(title.entry.sourceId, title.entry.entryId))) {
        throw const FormatException('Duplicate backup title.');
      }
      chapters += title.progress.length + title.chapters.length;
    }
    final history = _list(
      payload.containsKey('history') ? payload['history'] : const <Object?>[],
      maximumChapterRecords,
      'history',
    ).map((value) => _parseHistory(_map(value, 'history'), ownerKey)).toList();
    final historyIds = <String>{};
    final latestIds = <String>{};
    for (final item in history) {
      final row = item.progress;
      final titleKey = _titleKey(row.sourceId, row.entryId);
      if (ids.contains(titleKey) ||
          !historyIds.add(_progressKey(row)) ||
          (item.latest && !latestIds.add(titleKey))) {
        throw const FormatException('Duplicate or overlapping backup history.');
      }
    }
    if (chapters + history.length > maximumChapterRecords) {
      throw const FormatException('The backup has too many chapter records.');
    }
    return store.transaction((transaction) async {
      final visible = <MangaBackupTitlePreview>[];
      for (final title in titles) {
        final entry = title.entry;
        visible.add(
          MangaBackupTitlePreview(
            title: entry.title,
            providerName: entry.metadata['providerName'] as String,
            alreadySaved:
                await transaction.libraryEntry(
                  ownerKey: ownerKey,
                  sourceId: entry.sourceId,
                  entryId: entry.entryId,
                ) !=
                null,
            requiresReconnect:
                title.identity == null ||
                !availableProviderIds.contains(entry.metadata['providerId']),
          ),
        );
      }
      final currentPreferences = await _readGlobalPreferences();
      final currentHistory = {
        for (final row in await transaction.chapterHistoryForOwner(ownerKey))
          _progressKey(row),
      };
      return MangaBackupImportPreview._(
        ownerKey: ownerKey,
        createdAt: created,
        titles: visible,
        preferenceChanges: preferences.entries
            .where((entry) => currentPreferences[entry.key] != entry.value)
            .length,
        skippedLegacyTitles: _integer(
          payload['skippedLegacyTitles'],
          0,
          500,
          'skipped titles',
        ),
        data: titles,
        history: history,
        conflictingHistoryChapters: history
            .where(
              (item) => currentHistory.contains(_progressKey(item.progress)),
            )
            .length,
        preferences: preferences,
        fingerprint: await _fingerprint(
          transaction,
          ownerKey,
          titles,
          globalPreferences: currentPreferences,
        ),
        service: _serviceIdentity,
      );
    });
  }

  /// Merge never erases titles/chapters absent from the backup. A preview becomes
  /// invalid if local library/progress/protected state changes before confirm.
  /// SQLite rolls back atomically; protected writes are restored on any failure.
  Future<MangaBackupImportResult> confirmImport(
    MangaBackupImportPreview preview, {
    required bool confirmed,
    MangaBackupConflictPolicy conflictPolicy =
        MangaBackupConflictPolicy.mergeNewer,
  }) async {
    if (!confirmed || !identical(preview._service, _serviceIdentity)) {
      throw StateError(
        'Import requires an explicit confirmation of this preview.',
      );
    }
    final rollback = <Future<void> Function()>[];
    try {
      return await store.transaction((transaction) async {
        if (await _fingerprint(transaction, preview.ownerKey, preview._data) !=
            preview._fingerprint) {
          throw StateError(
            'Manga data changed. Preview the backup again before importing.',
          );
        }
        var imported = 0;
        var skipped = 0;
        var chapters = 0;
        var historyChapters = 0;
        // History-only restores never read protected identities or create
        // library titles. They are bound to the explicitly selected owner.
        for (final item in preview._history) {
          final progress = item.progress;
          final existing = await transaction.chapterProgress(
            ownerKey: preview.ownerKey,
            sourceId: progress.sourceId,
            entryId: progress.entryId,
            chapterId: progress.chapterId,
          );
          if (existing != null &&
              (conflictPolicy == MangaBackupConflictPolicy.keepExisting ||
                  !existing.updatedAt.isBefore(progress.updatedAt))) {
            continue;
          }
          final oldLatest = item.latest
              ? await transaction.progress(
                  ownerKey: preview.ownerKey,
                  sourceId: progress.sourceId,
                  entryId: progress.entryId,
                )
              : null;
          await transaction.restoreChapterProgress(
            progress,
            latest:
                item.latest &&
                (oldLatest == null ||
                    !oldLatest.updatedAt.isAfter(progress.updatedAt)),
          );
          historyChapters++;
          chapters++;
        }
        for (final title in preview._data) {
          final entry = title.entry;
          final old = await transaction.libraryEntry(
            ownerKey: preview.ownerKey,
            sourceId: entry.sourceId,
            entryId: entry.entryId,
          );
          if (old != null &&
              conflictPolicy == MangaBackupConflictPolicy.keepExisting) {
            skipped++;
            continue;
          }
          if (old == null || !old.updatedAt.isAfter(entry.updatedAt)) {
            await transaction.upsertLibraryEntry(entry);
          }
          final oldLatest = await transaction.progress(
            ownerKey: preview.ownerKey,
            sourceId: entry.sourceId,
            entryId: entry.entryId,
          );
          for (final progress in title.progress) {
            final existing = await transaction.chapterProgress(
              ownerKey: preview.ownerKey,
              sourceId: entry.sourceId,
              entryId: entry.entryId,
              chapterId: progress.chapterId,
            );
            if (existing != null &&
                !existing.updatedAt.isBefore(progress.updatedAt)) {
              continue;
            }
            await transaction.restoreChapterProgress(
              progress,
              latest:
                  progress.chapterId == title.latestChapterId &&
                  (oldLatest == null ||
                      !oldLatest.updatedAt.isAfter(progress.updatedAt)),
            );
            chapters++;
          }
          final existingSnapshots = {
            for (final chapter in await transaction.chapterSnapshots(
              ownerKey: preview.ownerKey,
              sourceId: entry.sourceId,
              entryId: entry.entryId,
            ))
              chapter.chapterId: chapter,
          };
          for (final chapter in title.chapters) {
            final existing = existingSnapshots[chapter.chapterId];
            if (existing?.lastSeenAt != null &&
                chapter.lastSeenAt != null &&
                !existing!.lastSeenAt!.isBefore(chapter.lastSeenAt!)) {
              continue;
            }
            await transaction.restoreChapterSnapshot(
              ownerKey: preview.ownerKey,
              sourceId: entry.sourceId,
              entryId: entry.entryId,
              chapter: chapter,
              fallbackTime: entry.updatedAt,
            );
          }
          final oldIdentity = await readIdentity(
            ownerKey: preview.ownerKey,
            sourceId: entry.sourceId,
            entryId: entry.entryId,
          );
          // Missing identity never erases an existing working connection.
          if (title.identity != null && oldIdentity == null) {
            rollback.add(
              () => writeIdentity(
                ownerKey: preview.ownerKey,
                sourceId: entry.sourceId,
                entryId: entry.entryId,
                mangaId: oldIdentity,
              ),
            );
            await writeIdentity(
              ownerKey: preview.ownerKey,
              sourceId: entry.sourceId,
              entryId: entry.entryId,
              mangaId: title.identity,
            );
          }
          if (title.seriesPreferences != null) {
            final key = _seriesPreferenceKey(entry.sourceId, entry.entryId);
            final oldValue = await _preferencesStorage.read(key: key);
            if (oldValue == null ||
                conflictPolicy == MangaBackupConflictPolicy.mergeNewer) {
              rollback.add(() => _writePreference(key, oldValue));
              await _writePreference(key, jsonEncode(title.seriesPreferences));
            }
          }
          imported++;
        }
        for (final value in preview._preferences.entries) {
          final key = 'manga_reader_v1_${value.key}';
          final old = await _preferencesStorage.read(key: key);
          if (old != null &&
              conflictPolicy == MangaBackupConflictPolicy.keepExisting) {
            continue;
          }
          if (old == value.value) continue;
          rollback.add(() => _writePreference(key, old));
          await _writePreference(key, value.value);
        }
        return MangaBackupImportResult(
          importedTitles: imported,
          skippedTitles: skipped,
          importedChapters: chapters,
          importedHistoryChapters: historyChapters,
          reconnectRequired: preview.reconnectRequired,
        );
      });
    } catch (error) {
      var failedRollback = false;
      for (final action in rollback.reversed) {
        try {
          await action();
        } catch (_) {
          failedRollback = true;
        }
      }
      if (failedRollback) {
        throw StateError(
          'Library import was rolled back, but protected settings could not be fully restored. Reconnect affected manga sources and check reader settings.',
        );
      }
      rethrow;
    }
  }

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: derivationIterations,
    bits: 256,
  ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);

  Future<void> _writePreference(String key, String? value) => value == null
      ? _preferencesStorage.delete(key: key)
      : _preferencesStorage.write(key: key, value: value);

  Future<Map<String, String>> _readGlobalPreferences() async {
    final result = <String, String>{};
    for (final key in _preferenceKeys) {
      final value = await _preferencesStorage.read(key: 'manga_reader_v1_$key');
      if (value != null) result[key] = value;
    }
    return _globalPreferences(result);
  }

  Future<String> _fingerprint(
    MangaStore transaction,
    String ownerKey,
    List<_BackupTitle> titles, {
    Map<String, String>? globalPreferences,
  }) async {
    final values = <Object?>[
      globalPreferences ?? await _readGlobalPreferences(),
      // Include unsaved-title history and resume pointers, with deterministic
      // ordering. A read/bookmark/clear after preview requires a fresh preview.
      for (final rows in [
        await transaction.chapterHistoryForOwner(ownerKey),
        await transaction.latestHistoryForOwner(ownerKey),
      ])
        rows
            .map((row) => [row.sourceId, row.entryId, _progressJson(row)])
            .toList(),
    ];
    for (final title in titles) {
      final entry = title.entry;
      final current = await transaction.libraryEntry(
        ownerKey: ownerKey,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
      );
      values.add(
        current == null
            ? null
            : [
                current.title,
                current.metadata,
                current.category,
                current.status.name,
                current.updatedAt.millisecondsSinceEpoch,
                current.chapterCheckedAt?.millisecondsSinceEpoch,
                current.chapterUpdatedAt?.millisecondsSinceEpoch,
                current.newChapterCount,
              ],
      );
      values.add(
        (await transaction.chapterProgressForEntry(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        )).map(_progressJson).toList(),
      );
      values.add(
        (await transaction.chapterSnapshots(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        )).map(_snapshotJson).toList(),
      );
      values.add(
        await readIdentity(
          ownerKey: ownerKey,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        ),
      );
      values.add(
        await _preferencesStorage.read(
          key: _seriesPreferenceKey(entry.sourceId, entry.entryId),
        ),
      );
    }
    return digest.sha256.convert(utf8.encode(jsonEncode(values))).toString();
  }
}

class _BackupTitle {
  const _BackupTitle({
    required this.entry,
    required this.progress,
    required this.chapters,
    this.identity,
    this.seriesPreferences,
    this.latestChapterId,
  });
  final MangaLibraryEntry entry;
  final List<MangaReadingProgress> progress;
  final List<MangaChapterSnapshot> chapters;
  final String? identity;
  final Map<String, Object?>? seriesPreferences;
  final String? latestChapterId;
}

class _BackupHistory {
  const _BackupHistory({required this.progress, required this.latest});
  final MangaReadingProgress progress;
  final bool latest;
}

String _titleKey(String sourceId, String entryId) => '$sourceId\n$entryId';
String _progressKey(MangaReadingProgress row) =>
    '${_titleKey(row.sourceId, row.entryId)}\n${row.chapterId}';

// Other legacy providers are out of scope. Malformed extension-backed rows
// fail the strict outbound parser instead of being silently dropped.
bool _isSeanimeHistory(MangaReadingProgress row) =>
    row.sourceId.startsWith('extension.');

_BackupHistory _parseHistory(Map<String, Object?> data, String owner) {
  _keys(data, {'sourceId', 'entryId', 'latest', 'progress'});
  return _BackupHistory(
    progress: _parseProgress(
      data['progress'],
      owner,
      _opaque(data['sourceId'], 'extension'),
      _opaque(data['entryId'], 'publication'),
    ),
    latest: _bool(data['latest']),
  );
}

MangaReadingProgress _parseProgress(
  Object? value,
  String owner,
  String source,
  String id,
) {
  final row = _map(value, 'progress');
  _keys(row, {
    'chapterId',
    'chapterNumber',
    'pageIndex',
    'pageOffset',
    'pageCount',
    'completed',
    'bookmarked',
    'updatedAt',
  });
  final count = row['pageCount'] == null
      ? null
      : _integer(row['pageCount'], 1, 1000, 'page count');
  final index = _integer(row['pageIndex'], 0, 999, 'page index');
  if (count != null && index >= count) {
    throw const FormatException('Invalid backup reading position.');
  }
  return MangaReadingProgress(
    ownerKey: owner,
    sourceId: source,
    entryId: id,
    chapterId: _opaque(row['chapterId'], 'chapter'),
    chapterNumber: _optionalNumber(row['chapterNumber']),
    pageIndex: index,
    pageOffset: _number(row['pageOffset'], 0, 1, 'page offset'),
    pageCount: count,
    completed: _bool(row['completed']),
    bookmarked: _bool(row['bookmarked']),
    updatedAt: _date(row['updatedAt'], 'progress date'),
  );
}

_BackupTitle _parseTitle(Map<String, Object?> data, String owner) {
  _keys(data, {
    'sourceId',
    'entryId',
    'title',
    'metadata',
    'category',
    'status',
    'updatedAt',
    'chapterCheckedAt',
    'chapterUpdatedAt',
    'newChapterCount',
    'identity',
    'seriesPreferences',
    'latestChapterId',
    'progress',
    'chapters',
  });
  final source = _opaque(data['sourceId'], 'extension');
  final id = _opaque(data['entryId'], 'publication');
  final metadata = _portableMetadata(
    _map(data['metadata'], 'metadata'),
    strict: true,
  );
  final entry = MangaLibraryEntry(
    ownerKey: owner,
    sourceId: source,
    entryId: id,
    title: _text(data['title'], 1024, 'title'),
    metadata: metadata,
    category: _text(data['category'], 80, 'category', allowEmpty: true),
    status: _status(data['status']),
    updatedAt: _date(data['updatedAt'], 'updatedAt'),
    chapterCheckedAt: _optionalDate(data['chapterCheckedAt']),
    chapterUpdatedAt: _optionalDate(data['chapterUpdatedAt']),
    newChapterCount: _integer(
      data['newChapterCount'],
      0,
      10000,
      'new chapters',
    ),
  );
  final progress = _list(
    data['progress'],
    10000,
    'progress',
  ).map((value) => _parseProgress(value, owner, source, id)).toList();
  final chapters = _list(data['chapters'], 10000, 'chapters').map((value) {
    final row = _map(value, 'chapter');
    _keys(row, {
      'chapterId',
      'title',
      'ordinal',
      'chapterNumber',
      'publishedAt',
      'firstSeenAt',
      'lastSeenAt',
      'available',
      'isNew',
    });
    return MangaChapterSnapshot(
      chapterId: _opaque(row['chapterId'], 'chapter'),
      title: _text(row['title'], 512, 'chapter title'),
      ordinal: _integer(row['ordinal'], 0, 99999, 'chapter ordinal'),
      chapterNumber: _optionalNumber(row['chapterNumber']),
      publishedAt: _optionalDate(row['publishedAt']),
      firstSeenAt: _optionalDate(row['firstSeenAt']),
      lastSeenAt: _optionalDate(row['lastSeenAt']),
      available: _bool(row['available']),
      isNew: _bool(row['isNew']),
    );
  }).toList();
  if (progress.map((item) => item.chapterId).toSet().length !=
          progress.length ||
      chapters.map((item) => item.chapterId).toSet().length !=
          chapters.length) {
    throw const FormatException('Duplicate backup chapters.');
  }
  final latest = data['latestChapterId'] == null
      ? null
      : _opaque(data['latestChapterId'], 'chapter');
  if (latest != null && !progress.any((item) => item.chapterId == latest)) {
    throw const FormatException(
      'The latest chapter is missing from backup history.',
    );
  }
  return _BackupTitle(
    entry: entry,
    progress: List.unmodifiable(progress),
    chapters: List.unmodifiable(chapters),
    identity: data['identity'] == null ? null : _identity(data['identity']),
    seriesPreferences: data['seriesPreferences'] == null
        ? null
        : _seriesPreferences(data['seriesPreferences']),
    latestChapterId: latest,
  );
}

Map<String, Object?> _portableMetadata(
  Map<String, Object?> input, {
  bool strict = false,
}) {
  const keys = {
    'kind',
    'providerId',
    'providerName',
    'language',
    'year',
    'synonyms',
  };
  if (strict) _keys(input, keys, optional: {'year', 'synonyms'});
  if (input['kind'] != 'seanime-manga-extension') {
    throw const FormatException(
      'Only Seanime manga-library entries are supported.',
    );
  }
  return Map.unmodifiable(<String, Object?>{
    'kind': 'seanime-manga-extension',
    'providerId': _text(input['providerId'], 256, 'provider id'),
    'providerName': _text(input['providerName'], 256, 'provider name'),
    'language': _text(input['language'], 64, 'language'),
    if (input['year'] != null) 'year': _integer(input['year'], 0, 9999, 'year'),
    if (input['synonyms'] != null)
      'synonyms': List.unmodifiable(
        _list(
          input['synonyms'],
          32,
          'synonyms',
        ).map((item) => _text(item, 1024, 'synonym')),
      ),
  });
}

Map<String, Object?> _progressJson(MangaReadingProgress value) => {
  'chapterId': value.chapterId,
  'chapterNumber': value.chapterNumber,
  'pageIndex': value.pageIndex,
  'pageOffset': value.pageOffset,
  'pageCount': value.pageCount,
  'completed': value.completed,
  'bookmarked': value.bookmarked,
  'updatedAt': value.updatedAt.millisecondsSinceEpoch,
};

Map<String, Object?> _snapshotJson(MangaChapterSnapshot value) => {
  'chapterId': value.chapterId,
  'title': value.title,
  'ordinal': value.ordinal,
  'chapterNumber': value.chapterNumber,
  'publishedAt': value.publishedAt?.millisecondsSinceEpoch,
  'firstSeenAt': value.firstSeenAt?.millisecondsSinceEpoch,
  'lastSeenAt': value.lastSeenAt?.millisecondsSinceEpoch,
  'available': value.available,
  'isNew': value.isNew,
};

String _seriesPreferenceKey(String source, String entry) =>
    'manga_reader_series_v1_${digest.sha256.convert(utf8.encode(jsonEncode([source, entry])))}';

const _preferenceEnums = <String, Set<String>>{
  'mode': {'paged', 'vertical', 'webtoon'},
  'direction': {'rightToLeft', 'leftToRight'},
  'spread': {'automatic', 'single', 'double'},
  'fit': {'contain', 'width', 'height'},
  'background': {'black', 'charcoal', 'white', 'sepia'},
  'tap_zone_layout': {'thirds', 'edges'},
};
const _preferenceNumbers = <String, double>{
  'gap': 40,
  'preload': 5,
  'side_padding': 80,
  'webtoon_gap': 40,
  'dim_amount': 0.7,
  'warmth': 1,
};
const _preferenceBooleans = {
  'cover_alone',
  'invert_spread',
  'tap_zones',
  'book_animation',
  'keep_awake',
  'discord_title',
  'grayscale',
  'invert_colors',
  'page_number',
  'double_tap_zoom',
  'invert_tap_zones',
};
final _preferenceKeys = {
  ..._preferenceEnums.keys,
  ..._preferenceNumbers.keys,
  ..._preferenceBooleans,
};

Map<String, String> _globalPreferences(Object? input) {
  final map = _map(input, 'reader preferences');
  if (map.keys.any((key) => !_preferenceKeys.contains(key))) {
    throw const FormatException('Unsupported reader preference.');
  }
  final result = <String, String>{};
  for (final entry in map.entries) {
    if (entry.value is! String) {
      throw const FormatException('Invalid reader preference.');
    }
    final value = entry.value! as String;
    if (_preferenceEnums.containsKey(entry.key)) {
      if (!_preferenceEnums[entry.key]!.contains(value)) {
        throw const FormatException('Invalid reader preference choice.');
      }
    } else if (_preferenceNumbers.containsKey(entry.key)) {
      final number = double.tryParse(value);
      if (number == null ||
          !number.isFinite ||
          number < 0 ||
          number > _preferenceNumbers[entry.key]! ||
          (entry.key == 'preload' && number != number.roundToDouble())) {
        throw const FormatException('Invalid reader preference range.');
      }
    } else if (value != 'true' && value != 'false') {
      throw const FormatException('Invalid reader preference toggle.');
    }
    result[entry.key] = value;
  }
  return Map.unmodifiable(result);
}

Map<String, Object?> _seriesPreferences(Object? input) {
  final map = _map(input, 'series preferences');
  _keys(map, {'enabled', 'mode', 'direction', 'spread', 'fit'});
  _bool(map['enabled']);
  for (final key in ['mode', 'direction', 'spread', 'fit']) {
    if (!_preferenceEnums[key]!.contains(map[key])) {
      throw const FormatException('Invalid series preference.');
    }
  }
  return Map.unmodifiable(map);
}

Object? _decode(String value, int maximum) => decodeBoundedJson(
  value,
  MangaParseLimits(
    maxPayloadCharacters: maximum,
    // The encrypted envelope contains one large base64 ciphertext string.
    // Payload strings get their narrower field-specific bounds after decoding.
    maxLongTextCharacters: maximum,
    maxNodes: 300000,
    maxDepth: 16,
  ),
  format: 'manga backup',
);
Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Invalid backup $field.');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, int maximum, String field) {
  if (value is! List || value.length > maximum) {
    throw FormatException('Invalid backup $field.');
  }
  return List<Object?>.from(value);
}

void _keys(
  Map<String, Object?> map,
  Set<String> allowed, {
  Set<String> optional = const {},
}) {
  if (map.keys.any((key) => !allowed.contains(key)) ||
      allowed.difference(optional).any((key) => !map.containsKey(key))) {
    throw const FormatException('Unexpected or missing backup fields.');
  }
}

String _text(
  Object? input,
  int maximum,
  String field, {
  bool allowEmpty = false,
}) {
  if (input is! String ||
      input.length > maximum ||
      input.trim() != input ||
      (!allowEmpty && input.isEmpty) ||
      RegExp(
        r'[\x00-\x1f\x7f]|(?:https?|file|data)\s*:|(?:authorization|bearer|password|access_token|api_key)\s*[:=]',
        caseSensitive: false,
      ).hasMatch(input)) {
    throw FormatException('Invalid or non-portable backup $field.');
  }
  return input;
}

String _opaque(Object? value, String prefix) {
  if (value is! String ||
      !RegExp('^$prefix\\.[0-9a-f]{40}\$').hasMatch(value)) {
    throw const FormatException('Invalid portable manga identity.');
  }
  return value;
}

String _identity(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 2048 ||
      value.trim() != value ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException('Invalid protected manga identity.');
  }
  if (value.contains('://')) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(
          r'/(?:pages?|downloads?|archives?)(?:/|$)|\.(?:zip|cbz|cbr|jpg|jpeg|png|webp)(?:$|/)',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
      throw const FormatException(
        'Request capabilities cannot be included in a manga backup.',
      );
    }
  } else if (RegExp(
    r'(?:bearer\s|token=|password=|signature=|[?&](?:key|auth)=)',
    caseSensitive: false,
  ).hasMatch(value)) {
    throw const FormatException(
      'Request capabilities cannot be included in a manga backup.',
    );
  }
  return value;
}

void _passphrase(String value) {
  if (value.trim().length < 12 || utf8.encode(value).length > 1024) {
    throw const FormatException(
      'Use a backup passphrase of at least 12 characters.',
    );
  }
}

List<int> _bytes(Object? value, int? exactLength, String field) {
  if (value is! String) throw FormatException('Invalid backup $field.');
  final bytes = base64Decode(value);
  if (exactLength != null && bytes.length != exactLength) {
    throw FormatException('Invalid backup $field length.');
  }
  return bytes;
}

int _integer(Object? value, int minimum, int maximum, String field) {
  if (value is! int || value < minimum || value > maximum) {
    throw FormatException('Invalid backup $field.');
  }
  return value;
}

double _number(Object? value, double minimum, double maximum, String field) {
  if (value is! num || !value.isFinite || value < minimum || value > maximum) {
    throw FormatException('Invalid backup $field.');
  }
  return value.toDouble();
}

double? _optionalNumber(Object? value) =>
    value == null ? null : _number(value, 0, 100000, 'chapter number');
bool _bool(Object? value) {
  if (value is! bool) throw const FormatException('Invalid backup boolean.');
  return value;
}

DateTime _date(Object? value, String field) =>
    DateTime.fromMillisecondsSinceEpoch(
      _integer(value, 0, 8640000000000000, field),
      isUtc: true,
    );
DateTime? _optionalDate(Object? value) =>
    value == null ? null : _date(value, 'timestamp');
MangaLibraryStatus _status(Object? value) {
  for (final status in MangaLibraryStatus.values) {
    if (status.name == value) return status;
  }
  throw const FormatException('Invalid backup library status.');
}
