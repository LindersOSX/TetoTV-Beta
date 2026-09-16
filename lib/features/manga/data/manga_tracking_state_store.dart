import 'dart:convert';

import 'package:anime_tv/features/manga/domain/manga_tracking_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const mangaTrackingStateStorageKey = 'manga_tracking_links_outbox_v1';

class MangaTrackingSnapshot {
  MangaTrackingSnapshot({
    Iterable<MangaTrackingLink> links = const [],
    Iterable<MangaTrackingPending> pending = const [],
  }) : links = List.unmodifiable(links),
       pending = List.unmodifiable(pending);
  final List<MangaTrackingLink> links;
  final List<MangaTrackingPending> pending;
}

abstract interface class MangaTrackingStateStore {
  Future<MangaTrackingSnapshot> read();
  Future<void> write(MangaTrackingSnapshot snapshot);
}

/// One encrypted value commits link generations and their outbox together.
/// It contains no tokens, signed source URLs, page URLs, or request headers.
class SecureMangaTrackingStateStore implements MangaTrackingStateStore {
  const SecureMangaTrackingStateStore(this.storage);
  final FlutterSecureStorage storage;
  static const maximumEntries = 500;
  static const maximumEncodedBytes = 1024 * 1024;

  @override
  Future<MangaTrackingSnapshot> read() async {
    try {
      final encoded = await storage.read(key: mangaTrackingStateStorageKey);
      if (encoded == null || encoded.isEmpty) return MangaTrackingSnapshot();
      if (encoded.length > maximumEncodedBytes ||
          utf8.encode(encoded).length > maximumEncodedBytes) {
        throw const FormatException();
      }
      final root = jsonDecode(encoded);
      if (root is! Map ||
          root['version'] != 1 ||
          root['links'] is! List ||
          root['pending'] is! List ||
          (root['links'] as List).length > maximumEntries ||
          (root['pending'] as List).length > maximumEntries) {
        throw const FormatException();
      }
      final links = (root['links'] as List)
          .map(
            (row) => MangaTrackingLink.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
      final ids = links.map((link) => link.bindingId).toSet();
      if (ids.length != links.length) throw const FormatException();
      final pending = (root['pending'] as List)
          .map(
            (row) => MangaTrackingPending.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
      if (pending.any((row) => !ids.contains(row.bindingId)) ||
          pending.map((row) => row.bindingId).toSet().length !=
              pending.length) {
        throw const FormatException();
      }
      return MangaTrackingSnapshot(links: links, pending: pending);
    } catch (_) {
      // Never silently erase an unreadable outbox or attach it to another owner.
      throw const MangaTrackingException(
        'Saved manga tracking could not be read. No tracker changes were sent.',
      );
    }
  }

  @override
  Future<void> write(MangaTrackingSnapshot snapshot) async {
    if (snapshot.links.length > maximumEntries ||
        snapshot.pending.length > maximumEntries) {
      throw const MangaTrackingException(
        'The manga tracking queue is full. Retry pending updates or unlink unused titles.',
      );
    }
    final encoded = jsonEncode({
      'version': 1,
      'links': snapshot.links.map((link) => link.toJson()).toList(),
      'pending': snapshot.pending.map((item) => item.toJson()).toList(),
    });
    if (utf8.encode(encoded).length > maximumEncodedBytes) {
      throw const MangaTrackingException(
        'The manga tracking queue is full. Retry pending updates or unlink unused titles.',
      );
    }
    try {
      await storage.write(key: mangaTrackingStateStorageKey, value: encoded);
    } catch (_) {
      throw const MangaTrackingException(
        'Manga tracking could not be saved securely. Free device storage and try again.',
      );
    }
  }
}
