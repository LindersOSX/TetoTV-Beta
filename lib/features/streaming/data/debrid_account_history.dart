import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_models.dart';
import 'package:anime_tv/features/streaming/data/premiumize_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';

/// An explicitly selectable account file. The provider link and credentials
/// stay inside its opener; neither is used as a display or diagnostic label.
class DebridAccountVideoFile {
  const DebridAccountVideoFile({
    required this.id,
    required this.name,
    required this.size,
    required Future<StreamReady> Function() open,
    // Keep the callback private so opening always passes the URL check below.
    // ignore: prefer_initializing_formals
  }) : _open = open;

  final String id;
  final String name;
  final int size;
  final Future<StreamReady> Function() _open;

  Future<StreamReady> open() async {
    final stream = await _open();
    final uri = stream.uri;
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      await stream.playbackLease?.close();
      throw StateError('The service did not return a secure playback link.');
    }
    return stream;
  }
}

/// Account-owned items, not the provider's global instant-availability cache.
class DebridAccountHistoryItem {
  const DebridAccountHistoryItem({
    required this.id,
    required this.name,
    required this.service,
    required this.ready,
    this.hash,
  });

  final String id;
  final String name;
  final DebridService service;
  final bool ready;
  final String? hash;

  /// Account lists do not supply audio metadata. Only explicit filename
  /// markers may place an item in a Sub or Dub tab; ambiguous names stay in All.
  ReleaseAudioIntent get audioIntent {
    final normalized = name.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      ' ',
    );
    if (RegExp(r'\b(?:dual|multi) audio\b').hasMatch(normalized)) {
      return ReleaseAudioIntent.multi;
    }
    final dub = RegExp(
      r'\b(?:dub|dubbed|english audio|eng audio)\b',
    ).hasMatch(normalized);
    final sub = RegExp(
      r'\b(?:sub|subbed|subtitled|jpn|japanese|original audio)\b',
    ).hasMatch(normalized);
    if (dub && sub) return ReleaseAudioIntent.multi;
    if (dub) return ReleaseAudioIntent.dub;
    if (sub) return ReleaseAudioIntent.sub;
    return ReleaseAudioIntent.unknown;
  }

  ReleaseCandidate get release => ReleaseCandidate(
    infoHash: hash ?? '${service.slug}:$id',
    magnetUri: '',
    releaseName: name,
    seeders: 0,
    sourceId: 'account:${service.slug}',
    provider: service.displayName,
    audioIntent: audioIntent,
    isDubbed:
        audioIntent == ReleaseAudioIntent.dub ||
        audioIntent == ReleaseAudioIntent.multi,
  );
}

class DebridAccountHistory {
  const DebridAccountHistory({this.dioFactory});

  final Dio Function(DebridService service, String token)? dioFactory;

  /// Manual browsing is intentionally independent of catalog episode identity.
  /// Only files already available in this account are offered, and each opener
  /// retains the provider's exact file ID/link even after display sorting.
  Future<List<DebridAccountVideoFile>> videoFiles(
    DebridAccountHistoryItem item,
    String token,
  ) async {
    if (!item.ready) {
      throw StateError('This account download is not ready to watch yet.');
    }
    final files = <DebridAccountVideoFile>[];
    final dio = dioFactory?.call(item.service, token);
    switch (item.service) {
      case DebridService.realDebrid:
        final client = RealDebridClient(token: token, dio: dio);
        final torrent = await client.torrentInfo(item.id);
        if (!torrent.isDownloaded) {
          throw StateError('This download is no longer ready.');
        }
        final selected = torrent.files.where((file) => file.selected).toList();
        // Preserve link ordering before filtering or sorting. A single link
        // must never be guessed to represent any of several video files.
        final linkedFiles = selected.length == torrent.links.length
            ? selected
            : torrent.files.length == torrent.links.length
            ? torrent.files
            : null;
        if (linkedFiles == null) {
          throw StateError('The service did not identify the available files.');
        }
        for (var index = 0; index < linkedFiles.length; index++) {
          final file = linkedFiles[index];
          if (!file.isPlayable) continue;
          final link = torrent.links[index];
          files.add(
            DebridAccountVideoFile(
              id: '${file.id}',
              name: file.path,
              size: file.bytes,
              open: () async => StreamReady(
                uri: (await client.unrestrict(link)).download,
                displayName: file.path,
                debridService: item.service,
              ),
            ),
          );
        }
      case DebridService.torBox:
        final client = TorBoxClient(token: token, dio: dio);
        final id = int.parse(item.id);
        final torrent = await client.torrentInfo(id);
        if (!torrent.isReady) {
          throw StateError('This download is no longer ready.');
        }
        for (final file in torrent.files.where((file) => file.isPlayable)) {
          files.add(
            DebridAccountVideoFile(
              id: '${file.id}',
              name: file.name,
              size: file.size,
              open: () async => StreamReady(
                uri: await client.requestDownloadLink(
                  torrentId: id,
                  fileId: file.id,
                ),
                displayName: file.name,
                debridService: item.service,
              ),
            ),
          );
        }
      case DebridService.allDebrid:
        final client = AllDebridClient(token: token, dio: dio);
        final id = int.parse(item.id);
        if (!(await client.magnetStatus(id)).isReady) {
          throw StateError('This download is no longer ready.');
        }
        for (final file in (await client.magnetFiles(
          id,
        )).where((file) => file.isPlayable)) {
          files.add(
            DebridAccountVideoFile(
              id: '${files.length}',
              name: file.name,
              size: file.size,
              open: () async => StreamReady(
                uri: await client.unlock(file.link),
                displayName: file.name,
                debridService: item.service,
              ),
            ),
          );
        }
      case DebridService.premiumize:
        final client = PremiumizeClient(token: token, dio: dio);
        for (final file in (await _premiumizeFiles(
          client,
          item,
        )).where((file) => file.isPlayable)) {
          files.add(
            DebridAccountVideoFile(
              id: file.id ?? '${files.length}',
              name: file.name,
              size: file.size,
              open: () async => StreamReady(
                uri: file.link,
                displayName: file.name,
                debridService: item.service,
              ),
            ),
          );
        }
    }
    files.sort((a, b) => _compareFileNames(a.name, b.name));
    return List.unmodifiable(files);
  }

  static int _compareFileNames(String a, String b) {
    final parts = RegExp(r'\d+|\D+');
    final left = parts.allMatches(a.toLowerCase()).toList();
    final right = parts.allMatches(b.toLowerCase()).toList();
    for (var index = 0; index < left.length && index < right.length; index++) {
      final l = left[index].group(0)!;
      final r = right[index].group(0)!;
      final ln = int.tryParse(l);
      final rn = int.tryParse(r);
      final comparison = ln != null && rn != null
          ? ln.compareTo(rn)
          : l.compareTo(r);
      if (comparison != 0) return comparison;
    }
    final comparison = left.length.compareTo(right.length);
    return comparison != 0 ? comparison : a.compareTo(b);
  }

  Future<List<PremiumizeFile>> _premiumizeFiles(
    PremiumizeClient client,
    DebridAccountHistoryItem item,
  ) async {
    final transfer = (await client.transfers())
        .where((value) => value.id == item.id)
        .firstOrNull;
    if (transfer == null || !transfer.isReady) {
      throw StateError('This download is no longer ready.');
    }
    final files = <PremiumizeFile>[];
    if (transfer.fileId case final id?) {
      files.add(await client.itemDetails(id));
    } else if (transfer.folderId case final id?) {
      // Bound nested account folders, including cyclic provider responses.
      final pendingFolders = <String>[id];
      final seenFolders = <String>{};
      while (pendingFolders.isNotEmpty &&
          seenFolders.length < 24 &&
          files.length < 500) {
        final folderId = pendingFolders.removeAt(0);
        if (!seenFolders.add(folderId)) continue;
        for (final entry in await client.folderContents(folderId)) {
          if (entry.isFolder) {
            pendingFolders.add(entry.id);
          } else if (entry.link != null) {
            files.add(
              PremiumizeFile(
                id: entry.id,
                name: entry.name,
                size: entry.size,
                link: entry.link!,
              ),
            );
          }
          if (files.length >= 500) break;
        }
      }
    }
    return files;
  }

  Future<List<DebridAccountHistoryItem>> listAll(
    DebridService service,
    String token, {
    CancelToken? cancelToken,
  }) => _list(service, token, cancelToken: cancelToken, full: true);

  Future<List<DebridAccountHistoryItem>> list(
    DebridService service,
    String token, {
    CancelToken? cancelToken,
  }) => _list(service, token, cancelToken: cancelToken, full: false);

  Future<List<DebridAccountHistoryItem>> _list(
    DebridService service,
    String token, {
    CancelToken? cancelToken,
    required bool full,
  }) async {
    switch (service) {
      case DebridService.realDebrid:
        final client = RealDebridClient(token: token);
        final items = full
            ? await _allPages(
                5000,
                (offset) => client.accountTorrents(
                  limit: 5000,
                  offset: offset,
                  cancelToken: cancelToken,
                ),
              )
            : await client.accountTorrents(cancelToken: cancelToken);
        return [
          for (final item in items)
            DebridAccountHistoryItem(
              id: item.id,
              name: item.filename,
              service: service,
              ready: item.isDownloaded,
              hash: item.hash,
            ),
        ];
      case DebridService.torBox:
        final client = TorBoxClient(token: token);
        final items = full
            ? await _allPages(
                1000,
                (offset) => client.accountTorrents(
                  limit: 1000,
                  offset: offset,
                  cancelToken: cancelToken,
                ),
              )
            : await client.accountTorrents(cancelToken: cancelToken);
        return [
          for (final item in items)
            DebridAccountHistoryItem(
              id: '${item.id}',
              name: item.name,
              service: service,
              // The list endpoint may omit file details; the item endpoint
              // verifies those before playback.
              ready: item.downloadFinished || item.cached,
              hash: item.hash,
            ),
        ];
      case DebridService.allDebrid:
        final items = await AllDebridClient(
          token: token,
        ).accountMagnets(cancelToken: cancelToken);
        return [
          for (final item in full ? items : items.take(100))
            DebridAccountHistoryItem(
              id: '${item.id}',
              name: item.filename ?? 'AllDebrid magnet',
              service: service,
              ready: item.isReady,
              hash: item.hash,
            ),
        ];
      case DebridService.premiumize:
        final items = await PremiumizeClient(
          token: token,
        ).transfers(cancelToken: cancelToken);
        return [
          for (final item in full ? items : items.take(100))
            DebridAccountHistoryItem(
              id: item.id,
              name: item.name,
              service: service,
              ready: item.isReady,
            ),
        ];
    }
  }

  Future<List<T>> _allPages<T>(
    int pageSize,
    Future<List<T>> Function(int offset) fetch,
  ) async {
    final items = <T>[];
    // Bound pathological provider responses while still covering large
    // libraries; neither endpoint should return a full repeated page forever.
    for (var page = 0; page < 20; page++) {
      final batch = await fetch(items.length);
      items.addAll(batch);
      if (batch.length < pageSize) break;
    }
    return items;
  }

  /// Reuse the service's existing episode-file selectors; never choose the
  /// first video in a season pack merely because it was downloaded already.
  Future<StreamReady> resolve(
    DebridAccountHistoryItem item,
    String token,
    EpisodeReference episode,
  ) async {
    if (!item.ready) {
      throw StateError('This account download is not ready to watch yet.');
    }
    final season = catalogSeasonNumber(episode);
    final absolute = absoluteEpisodeNumber(episode);
    final special = episodeReferenceIsSpecial(episode);
    final movie = episodeReferenceIsMovie(episode);
    final requireScheme = episodeReferenceHasUnresolvedSequelNumbering(episode);
    late final StreamReady ready;
    switch (item.service) {
      case DebridService.realDebrid:
        final client = RealDebridClient(token: token);
        final torrent = await client.torrentInfo(item.id);
        if (!torrent.isDownloaded) {
          throw StateError('This download is no longer ready.');
        }
        final file = selectEpisodeFile(
          torrent.files,
          episode.episode,
          requestedSeason: season,
          requestedAbsoluteEpisode: absolute,
          requestedSpecial: special,
          requestedMovie: movie,
          containerLabel: item.name,
          requireNumberingSchemeEvidence: requireScheme,
        );
        final link = selectEpisodeDownloadLink(
          torrent,
          episode.episode,
          requestedSeason: season,
          requestedAbsoluteEpisode: absolute,
          requestedSpecial: special,
          requestedMovie: movie,
          containerLabel: item.name,
          requireNumberingSchemeEvidence: requireScheme,
        );
        final unrestricted = await client.unrestrict(link);
        ready = StreamReady(
          uri: unrestricted.download,
          displayName: file.path.split(RegExp(r'[/\\]')).last,
          debridService: item.service,
        );
      case DebridService.torBox:
        final client = TorBoxClient(token: token);
        final id = int.parse(item.id);
        final torrent = await client.torrentInfo(id);
        if (!torrent.isReady) {
          throw StateError('This download is no longer ready.');
        }
        final file = selectTorBoxEpisodeFile(
          torrent.files,
          episode.episode,
          requestedSeason: season,
          requestedAbsoluteEpisode: absolute,
          requestedSpecial: special,
          requestedMovie: movie,
          containerLabel: item.name,
          requireNumberingSchemeEvidence: requireScheme,
        );
        ready = StreamReady(
          uri: await client.requestDownloadLink(torrentId: id, fileId: file.id),
          displayName: file.name,
          debridService: item.service,
        );
      case DebridService.allDebrid:
        final client = AllDebridClient(token: token);
        final id = int.parse(item.id);
        final status = await client.magnetStatus(id);
        if (!status.isReady) {
          throw StateError('This download is no longer ready.');
        }
        final file = selectAllDebridEpisodeFile(
          await client.magnetFiles(id),
          episode.episode,
          requestedSeason: season,
          requestedAbsoluteEpisode: absolute,
          requestedSpecial: special,
          requestedMovie: movie,
          containerLabel: item.name,
          requireNumberingSchemeEvidence: requireScheme,
        );
        ready = StreamReady(
          uri: await client.unlock(file.link),
          displayName: file.name,
          debridService: item.service,
        );
      case DebridService.premiumize:
        final client = PremiumizeClient(token: token);
        final files = await _premiumizeFiles(client, item);
        final file = selectPremiumizeEpisodeFile(
          files,
          episode.episode,
          requestedSeason: season,
          requestedAbsoluteEpisode: absolute,
          requestedSpecial: special,
          requestedMovie: movie,
          containerLabel: item.name,
          requireNumberingSchemeEvidence: requireScheme,
        );
        ready = StreamReady(
          uri: file.link,
          displayName: file.name,
          debridService: item.service,
        );
    }
    verifyPlaybackEpisodeIdentity(
      episode: episode,
      stream: ready,
      release: item.release,
    );
    return ready;
  }
}
