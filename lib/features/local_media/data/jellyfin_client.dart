import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:dio/dio.dart';

const _maxJellyfinResponseBytes = 4 * 1024 * 1024;
const _maxJellyfinImageBytes = 8 * 1024 * 1024;

/// Codecs which commonly require licensed passthrough or a decoder that is
/// absent from Android MPV builds. Jellyfin can safely convert these tracks to
/// AAC without changing the private server boundary.
bool jellyfinAudioNeedsCompatibilityTranscode(String? value) {
  final codec = value?.trim().toLowerCase().replaceAll('_', '-');
  return const {
    'truehd',
    'mlp',
    'dts',
    'dca',
    'dts-hd',
    'dts-hd-ma',
    'dtshd',
    'dtshd-ma',
  }.contains(codec);
}

Uri? normalizeJellyfinServerUri(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;
  final withScheme = raw.contains('://') ? raw : 'http://$raw';
  final parsed = Uri.tryParse(withScheme);
  if (parsed == null ||
      !const {'http', 'https'}.contains(parsed.scheme.toLowerCase()) ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      parsed.port <= 0 ||
      parsed.port > 65535) {
    return null;
  }
  if (parsed.scheme.toLowerCase() == 'http' &&
      !isPrivateJellyfinHost(parsed.host)) {
    return null;
  }
  final path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
  return parsed.replace(
    scheme: parsed.scheme.toLowerCase(),
    host: parsed.host.toLowerCase(),
    path: path,
    query: null,
    fragment: null,
  );
}

bool isPrivateJellyfinHost(String input) {
  final host = input.trim().toLowerCase();
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  final bytes = address.rawAddress;
  if (address.isMulticast || bytes.every((byte) => byte == 0)) return false;
  if (address.isLoopback || address.isLinkLocal) {
    return true;
  }
  if (bytes.length == 4) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 10 ||
        first == 127 ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }
  return bytes.isNotEmpty &&
      ((bytes[0] & 0xfe) == 0xfc ||
          (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80));
}

class JellyfinClient {
  JellyfinClient([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 10),
              followRedirects: false,
              maxRedirects: 0,
              responseType: ResponseType.json,
              validateStatus: (status) => status != null && status < 500,
            ),
          );

  final Dio _dio;

  Future<JellyfinServerInfo> publicInfo(Uri baseUri) async {
    final response = await _request(
      baseUri.resolve('${_basePath(baseUri)}/System/Info/Public'),
    );
    final data = _map(response);
    return JellyfinServerInfo(
      name: _bounded(data['ServerName'], 1, 200) ?? 'Jellyfin',
      version: _bounded(data['Version'], 1, 80) ?? 'unknown',
      id: _bounded(data['Id'], 1, 160) ?? '',
    );
  }

  Future<JellyfinConnection> authenticate({
    required Uri baseUri,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final cleanUsername = username.trim();
    if (cleanUsername.isEmpty || cleanUsername.length > 200) {
      throw const JellyfinException('Enter a valid Jellyfin username.');
    }
    final server = await publicInfo(baseUri);
    final response = await _request(
      baseUri.resolve('${_basePath(baseUri)}/Users/AuthenticateByName'),
      method: 'POST',
      data: {'Username': cleanUsername, 'Pw': password},
      headers: {'Authorization': _authorization(deviceId: deviceId)},
    );
    final data = _map(response);
    final token = _bounded(data['AccessToken'], 16, 4096);
    final user = _map(data['User']);
    final userId = _bounded(user['Id'], 8, 160);
    final returnedUsername = _bounded(user['Name'], 1, 200) ?? cleanUsername;
    if (token == null || userId == null) {
      throw const JellyfinException(
        'Jellyfin did not return a usable account session.',
      );
    }
    return JellyfinConnection(
      baseUri: baseUri,
      serverName: server.name,
      serverVersion: server.version,
      userId: userId,
      username: returnedUsername,
      accessToken: token,
      deviceId: deviceId,
    );
  }

  Future<JellyfinLibraryPage> items(
    JellyfinConnection connection, {
    String? parentId,
    int startIndex = 0,
  }) async {
    final response = await _request(
      connection.baseUri.resolve('${_basePath(connection.baseUri)}/Items'),
      queryParameters: {
        'userId': connection.userId,
        if (parentId?.isNotEmpty == true) 'parentId': parentId,
        'sortBy': 'SortName',
        'sortOrder': 'Ascending',
        'includeItemTypes':
            'CollectionFolder,Folder,Series,Season,BoxSet,Movie,Episode,Video',
        // Some Jellyfin versions do not expand nested stream metadata merely
        // because MediaSources was requested. Ask for MediaStreams explicitly
        // so codec/bit-depth/subtitle compatibility decisions cannot silently
        // degrade to unknown values.
        'fields':
            'Overview,MediaSources,MediaStreams,PrimaryImageAspectRatio,'
            'ProviderIds,UserData',
        'enableImages': true,
        'enableTotalRecordCount': true,
        'startIndex': startIndex.clamp(0, 1 << 31),
        'limit': 100,
      },
      headers: _sessionHeaders(connection),
    );
    final data = _map(response);
    return _parseItemPage(data, startIndex: startIndex);
  }

  Future<List<JellyfinMediaItem>> search(
    JellyfinConnection connection,
    String query, {
    int limit = 60,
  }) async {
    final term = query.trim();
    if (term.length < 2 || term.length > 200) {
      throw const JellyfinException(
        'Enter at least two characters to search Jellyfin.',
      );
    }
    final response = await _request(
      connection.baseUri.resolve('${_basePath(connection.baseUri)}/Items'),
      queryParameters: {
        'userId': connection.userId,
        'searchTerm': term,
        'recursive': true,
        'sortBy': 'SortName',
        'sortOrder': 'Ascending',
        'includeItemTypes': 'Series,Season,Movie,Episode,Video',
        'fields':
            'Overview,MediaSources,MediaStreams,PrimaryImageAspectRatio,'
            'ProviderIds,UserData',
        'enableImages': true,
        'enableTotalRecordCount': true,
        'startIndex': 0,
        'limit': limit.clamp(1, 100),
      },
      headers: _sessionHeaders(connection),
    );
    return _parseItemPage(_map(response), startIndex: 0).items;
  }

  Future<void> reportPlaybackStarted(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String playSessionId,
    required Duration position,
    JellyfinPlayMethod playMethod = JellyfinPlayMethod.directPlay,
  }) => _reportPlayback(
    connection,
    item,
    endpoint: 'Playing',
    playSessionId: playSessionId,
    position: position,
    paused: false,
    playMethod: playMethod,
  );

  Future<void> reportPlaybackProgress(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String playSessionId,
    required Duration position,
    bool paused = false,
    JellyfinPlayMethod playMethod = JellyfinPlayMethod.directPlay,
  }) => _reportPlayback(
    connection,
    item,
    endpoint: 'Playing/Progress',
    playSessionId: playSessionId,
    position: position,
    paused: paused,
    playMethod: playMethod,
  );

  Future<void> reportPlaybackStopped(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String playSessionId,
    required Duration position,
    JellyfinPlayMethod playMethod = JellyfinPlayMethod.directPlay,
  }) => _reportPlayback(
    connection,
    item,
    endpoint: 'Playing/Stopped',
    playSessionId: playSessionId,
    position: position,
    paused: true,
    playMethod: playMethod,
  );

  Future<void> _reportPlayback(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String endpoint,
    required String playSessionId,
    required Duration position,
    required bool paused,
    required JellyfinPlayMethod playMethod,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(playSessionId)) {
      throw const JellyfinException('The local playback session is invalid.');
    }
    await _request(
      connection.baseUri.resolve(
        '${_basePath(connection.baseUri)}/Sessions/$endpoint',
      ),
      method: 'POST',
      data: {
        'ItemId': item.id,
        'PlaySessionId': playSessionId,
        'PositionTicks': position.inMicroseconds.clamp(0, 1 << 49) * 10,
        'IsPaused': paused,
        'PlayMethod': playMethod.serverValue,
        'EventName': paused ? 'Pause' : 'TimeUpdate',
      },
      headers: {
        ..._sessionHeaders(connection),
        'Content-Type': 'application/json',
      },
      expectedStatuses: const {200, 204},
      allowEmptyBody: true,
    );
  }

  JellyfinLibraryPage _parseItemPage(
    Map<Object?, Object?> data, {
    required int startIndex,
  }) {
    final rawItems = data['Items'] is List ? data['Items'] as List : const [];
    final parsed = <JellyfinMediaItem>[];
    for (final value in rawItems.whereType<Map>()) {
      final item = value.cast<Object?, Object?>();
      final id = _bounded(item['Id'], 8, 160);
      final name = _bounded(item['Name'], 1, 500);
      final type = _bounded(item['Type'], 1, 80);
      if (id == null || !_safeServerId(id) || name == null || type == null) {
        continue;
      }
      final imageTags = _map(item['ImageTags']);
      final userData = _map(item['UserData']);
      final mediaSources = item['MediaSources'] is List
          ? item['MediaSources'] as List
          : const [];
      final sourceMaps = mediaSources.whereType<Map>();
      final firstSource = sourceMaps.isEmpty ? null : sourceMaps.first;
      final source = firstSource?.cast<Object?, Object?>();
      final mediaStreams = source?['MediaStreams'] is List
          ? source!['MediaStreams'] as List
          : item['MediaStreams'] is List
          ? item['MediaStreams'] as List
          : const [];
      Map<Object?, Object?>? videoStream;
      Map<Object?, Object?>? audioStream;
      final audioStreams = <JellyfinAudioStream>[];
      final subtitleStreams = <JellyfinSubtitleStream>[];
      for (final value in mediaStreams.whereType<Map>()) {
        final stream = value.cast<Object?, Object?>();
        final type = _bounded(stream['Type'], 1, 40)?.toLowerCase();
        if (type == 'video' && videoStream == null) videoStream = stream;
        if (type == 'audio') {
          audioStream ??= stream;
          final index = _integer(stream['Index']);
          if (index != null &&
              index >= 0 &&
              index <= 10000 &&
              audioStreams.length < 32) {
            audioStreams.add(
              JellyfinAudioStream(
                index: index,
                language: _bounded(stream['Language'], 1, 40),
                isDefault: stream['IsDefault'] == true,
              ),
            );
          }
        }
        if (type == 'subtitle' && stream['IsTextSubtitleStream'] == true) {
          final index = _integer(stream['Index']);
          if (index != null && index >= 0 && index <= 10000) {
            subtitleStreams.add(
              JellyfinSubtitleStream(
                index: index,
                label:
                    _bounded(stream['DisplayTitle'], 1, 300) ??
                    _bounded(stream['Language'], 1, 40) ??
                    'Subtitles',
                language: _bounded(stream['Language'], 1, 40),
                isDefault: stream['IsDefault'] == true,
                isForced: stream['IsForced'] == true,
              ),
            );
          }
        }
      }
      parsed.add(
        JellyfinMediaItem(
          id: id,
          name: name,
          type: type,
          seriesName: _bounded(item['SeriesName'], 1, 500),
          productionYear: _integer(item['ProductionYear']),
          seasonNumber: _integer(item['ParentIndexNumber']),
          episodeNumber: _integer(item['IndexNumber']),
          runTimeTicks: _integer(item['RunTimeTicks']),
          primaryImageTag: _bounded(imageTags['Primary'], 1, 300),
          mediaSourceId: firstSource == null
              ? null
              : _bounded(firstSource['Id'], 1, 300),
          container: firstSource == null
              ? _bounded(item['Container'], 1, 80)
              : _bounded(firstSource['Container'], 1, 80),
          videoCodec: _bounded(videoStream?['Codec'], 1, 80),
          videoBitDepth: _integer(videoStream?['BitDepth']),
          videoWidth: _integer(videoStream?['Width']),
          videoHeight: _integer(videoStream?['Height']),
          audioCodec: _bounded(audioStream?['Codec'], 1, 80),
          supportsDirectPlay: source?['SupportsDirectPlay'] is bool
              ? source!['SupportsDirectPlay'] as bool
              : null,
          audioStreams: List.unmodifiable(audioStreams),
          subtitleStreams: List.unmodifiable(subtitleStreams),
          overview: _bounded(item['Overview'], 1, 4000),
          playbackPositionTicks: _integer(userData['PlaybackPositionTicks']),
          played: userData['Played'] == true,
          providerIds: _publicAnimeProviderIds(item['ProviderIds']),
        ),
      );
    }
    final minimumTotal = startIndex.clamp(0, 1 << 31) + parsed.length;
    final reportedTotal = _integer(data['TotalRecordCount']) ?? minimumTotal;
    return JellyfinLibraryPage(
      items: List.unmodifiable(parsed),
      // A stale or malformed total must not hide items already returned by
      // the server, and an absurd value must not leak into the UI.
      totalCount: reportedTotal.clamp(minimumTotal, 1 << 31),
      // Advance by the raw server page, not just the valid parsed rows. A
      // malformed item must not make the next request repeat the same record.
      nextStartIndex: startIndex.clamp(0, 1 << 31) + rawItems.length,
    );
  }

  static Map<String, String> _publicAnimeProviderIds(Object? raw) {
    if (raw is! Map || raw.length > 40) return const {};
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString().trim();
      final value = entry.value?.toString().trim();
      if (key == null ||
          value == null ||
          key.isEmpty ||
          key.length > 40 ||
          value.isEmpty ||
          value.length > 80 ||
          !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(key) ||
          !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
        continue;
      }
      final normalizedKey = key.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      final canonicalKey = switch (normalizedKey) {
        'anilist' || 'anilistid' => 'anilist',
        'myanimelist' || 'myanimelistid' || 'mal' => 'myanimelist',
        'tmdb' || 'themoviedb' => 'tmdb',
        'tvdb' || 'thetvdb' => 'tvdb',
        'imdb' => 'imdb',
        _ => null,
      };
      if (canonicalKey == null) continue;
      final normalizedValue = value.toLowerCase();
      final valid = canonicalKey == 'imdb'
          ? RegExp(r'^tt\d{7,10}$').hasMatch(normalizedValue)
          : RegExp(r'^\d{1,12}$').hasMatch(normalizedValue) &&
                int.tryParse(normalizedValue) != null &&
                int.parse(normalizedValue) > 0;
      if (valid) result[canonicalKey] = normalizedValue;
    }
    return result.isEmpty ? const {} : Map.unmodifiable(result);
  }

  Uri streamUri(JellyfinConnection connection, JellyfinMediaItem item) {
    final path = '${_basePath(connection.baseUri)}/Videos/${item.id}/stream';
    return connection.baseUri
        .resolve(path)
        .replace(
          queryParameters: {
            'static': 'true',
            'deviceId': connection.deviceId,
            if (item.mediaSourceId?.isNotEmpty == true)
              'mediaSourceId': item.mediaSourceId!,
            if (item.container?.isNotEmpty == true)
              'container': item.container!,
          },
        );
  }

  /// Selects direct play for ordinary compatible files and a conservative
  /// H.264/AAC HLS transcode for formats which commonly produce audio over a
  /// black video surface on Android TV. In particular, the affected Jellyfin
  /// samples are AV1 Main 10-bit in Matroska: valid files, but not reliably
  /// renderable by every decoder which merely advertises AV1 support.
  JellyfinPlaybackPlan playbackPlan(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String playSessionId,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
  }) => _playbackPlan(
    connection,
    item,
    playSessionId: playSessionId,
    preferredSubtitleLanguage: preferredSubtitleLanguage,
    requestedAudio: requestedAudio,
  );

  /// Forces the viewer's own Jellyfin server to provide a conservative
  /// H.264/AAC HLS stream after MPV rejects direct playback at startup.
  JellyfinPlaybackPlan compatibilityPlaybackPlan(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String playSessionId,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
  }) => _playbackPlan(
    connection,
    item,
    playSessionId: playSessionId,
    preferredSubtitleLanguage: preferredSubtitleLanguage,
    requestedAudio: requestedAudio,
    forceCompatibility: true,
  );

  JellyfinPlaybackPlan _playbackPlan(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required String playSessionId,
    required String preferredSubtitleLanguage,
    required PlaybackAudioPreference? requestedAudio,
    bool forceCompatibility = false,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(playSessionId)) {
      throw const JellyfinException('The local playback session is invalid.');
    }
    final codec = item.videoCodec?.trim().toLowerCase();
    final audioCodec = item.audioCodec?.trim().toLowerCase();
    final bitDepth = item.videoBitDepth ?? 8;
    final needsCompatibilityTranscode =
        forceCompatibility ||
        item.supportsDirectPlay == false ||
        codec == 'av1' ||
        codec == 'av01' ||
        ((codec == 'h264' || codec == 'avc') && bitDepth > 8) ||
        bitDepth > 10 ||
        jellyfinAudioNeedsCompatibilityTranscode(audioCodec);
    final headers = Map<String, String>.unmodifiable(
      _sessionHeaders(connection),
    );
    if (!needsCompatibilityTranscode) {
      return JellyfinPlaybackPlan(
        uri: streamUri(connection, item),
        headers: headers,
        method: JellyfinPlayMethod.directPlay,
        playSessionId: playSessionId,
        mediaContentType: _containerContentType(item.container),
      );
    }

    final path =
        '${_basePath(connection.baseUri)}/Videos/${item.id}/master.m3u8';
    final externalSubtitleTracks =
        List<JellyfinPlaybackSubtitleTrack>.unmodifiable(
          _rankedSubtitles(item.subtitleStreams, preferredSubtitleLanguage).map(
            (subtitle) {
              final uri = _subtitleStreamUri(
                connection,
                item,
                streamIndex: subtitle.index,
              );
              return uri == null
                  ? null
                  : JellyfinPlaybackSubtitleTrack(
                      uri: uri,
                      label: subtitle.label,
                      language: subtitle.language,
                      contentType: 'text/vtt',
                    );
            },
          ).whereType<JellyfinPlaybackSubtitleTrack>(),
        );
    final audioStream = _preferredAudioStream(
      item.audioStreams,
      requestedAudio,
    );
    final uri = connection.baseUri
        .resolve(path)
        .replace(
          queryParameters: {
            'DeviceId': connection.deviceId,
            if (item.mediaSourceId?.isNotEmpty == true)
              'MediaSourceId': item.mediaSourceId!,
            'PlaySessionId': playSessionId,
            'VideoCodec': 'h264',
            'AudioCodec': 'aac',
            if (audioStream != null)
              'AudioStreamIndex': audioStream.index.toString(),
            'MaxStreamingBitrate': '20000000',
            'TranscodingProtocol': 'hls',
            'SegmentContainer': 'ts',
            'RequireAvc': 'true',
            // Jellyfin's HLS subtitle manifest URLs contain an ApiKey query
            // parameter. Keep the manifest token-free and attach a bounded
            // text-track list separately with the same-origin auth header.
            'EnableSubtitlesInManifest': 'false',
          },
        );
    return JellyfinPlaybackPlan(
      uri: uri,
      headers: headers,
      method: JellyfinPlayMethod.transcode,
      playSessionId: playSessionId,
      mediaContentType: 'application/x-mpegURL',
      externalSubtitleTracks: externalSubtitleTracks,
    );
  }

  JellyfinAudioStream? _preferredAudioStream(
    List<JellyfinAudioStream> streams,
    PlaybackAudioPreference? requestedAudio,
  ) {
    if (streams.isEmpty) return null;
    final preferredLanguage = requestedAudio?.audioLanguage;
    if (preferredLanguage != null) {
      final matching = streams
          .where(
            (stream) =>
                _canonicalJellyfinLanguage(stream.language) ==
                preferredLanguage,
          )
          .toList(growable: false);
      if (matching.isNotEmpty) return _stableAudioChoice(matching);
    }
    final defaults = streams
        .where((stream) => stream.isDefault)
        .toList(growable: false);
    return _stableAudioChoice(defaults.isEmpty ? streams : defaults);
  }

  JellyfinAudioStream _stableAudioChoice(List<JellyfinAudioStream> streams) {
    final ranked = streams.toList(growable: false)
      ..sort((left, right) {
        final byDefault = (right.isDefault ? 1 : 0).compareTo(
          left.isDefault ? 1 : 0,
        );
        return byDefault != 0 ? byDefault : left.index.compareTo(right.index);
      });
    return ranked.first;
  }

  List<JellyfinSubtitleStream> _rankedSubtitles(
    List<JellyfinSubtitleStream> streams,
    String preferredLanguage,
  ) {
    final preferred = _canonicalSubtitleLanguage(preferredLanguage) ?? 'eng';
    final ranked = streams.toList(growable: false);
    ranked.sort((left, right) {
      int score(JellyfinSubtitleStream stream) {
        var value = 0;
        final language = _canonicalSubtitleLanguage(stream.language);
        if (language != null && language == preferred) {
          value += 100;
        }
        if (stream.isDefault) value += 20;
        if (stream.isForced) value += 5;
        return value;
      }

      final byScore = score(right).compareTo(score(left));
      if (byScore != 0) return byScore;
      return left.index.compareTo(right.index);
    });
    return List.unmodifiable(ranked.take(32));
  }

  Uri? _subtitleStreamUri(
    JellyfinConnection connection,
    JellyfinMediaItem item, {
    required int streamIndex,
  }) {
    final mediaSourceId = item.mediaSourceId;
    if (mediaSourceId == null || mediaSourceId.trim().isEmpty) {
      return null;
    }
    final path = [
      ..._basePath(
        connection.baseUri,
      ).split('/').where((part) => part.isNotEmpty),
      'Videos',
      item.id,
      mediaSourceId,
      'Subtitles',
      '$streamIndex',
      '0',
      'Stream.vtt',
    ];
    return connection.baseUri.resolve(
      '/${path.map(Uri.encodeComponent).join('/')}',
    );
  }

  Uri? imageUri(JellyfinConnection connection, JellyfinMediaItem item) {
    if (item.primaryImageTag == null) return null;
    final path =
        '${_basePath(connection.baseUri)}/Items/${item.id}/Images/Primary';
    return connection.baseUri
        .resolve(path)
        .replace(
          queryParameters: {
            'maxWidth': '480',
            'quality': '85',
            'tag': item.primaryImageTag!,
          },
        );
  }

  Map<String, String> playbackHeaders(JellyfinConnection connection) =>
      _sessionHeaders(connection);

  /// Loads authenticated artwork without allowing a redirect to carry the
  /// Jellyfin session header to another origin.
  Future<Uint8List> imageBytes(JellyfinConnection connection, Uri uri) async {
    final baseUri = normalizeJellyfinServerUri(connection.baseUri.toString());
    if (baseUri == null ||
        !_sameOrigin(baseUri, uri) ||
        !_isUnderBasePath(baseUri.path, uri.path)) {
      throw const JellyfinException(
        'Jellyfin returned an external image resource.',
      );
    }
    try {
      final response = await _dio.requestUri<ResponseBody>(
        uri,
        options: Options(
          method: 'GET',
          headers: _sessionHeaders(connection),
          followRedirects: false,
          maxRedirects: 0,
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        _closeResponseBody(response.data);
        throw const JellyfinException('Jellyfin redirected an image request.');
      }
      if (status != 200) {
        _closeResponseBody(response.data);
        throw const JellyfinException('Jellyfin image could not be loaded.');
      }
      final declared = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declared != null && declared > _maxJellyfinImageBytes) {
        _closeResponseBody(response.data);
        throw const JellyfinException('Jellyfin returned an oversized image.');
      }
      final body = response.data;
      if (body == null) {
        throw const JellyfinException('Jellyfin returned an empty image.');
      }
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in body.stream) {
          if (bytes.length + chunk.length > _maxJellyfinImageBytes) {
            throw const JellyfinException(
              'Jellyfin returned an oversized image.',
            );
          }
          bytes.add(chunk);
        }
      } finally {
        _closeResponseBody(body);
      }
      final result = bytes.takeBytes();
      if (result.isEmpty) {
        throw const JellyfinException('Jellyfin returned an empty image.');
      }
      return result;
    } on JellyfinException {
      rethrow;
    } on DioException catch (error) {
      final responseBody = error.response?.data;
      if (responseBody is ResponseBody) _closeResponseBody(responseBody);
      throw const JellyfinException('Jellyfin image could not be loaded.');
    }
  }

  Future<void> logout(JellyfinConnection connection) async {
    await _request(
      connection.baseUri.resolve(
        '${_basePath(connection.baseUri)}/Sessions/Logout',
      ),
      method: 'POST',
      headers: _sessionHeaders(connection),
      expectedStatuses: const {200, 204},
    );
  }

  Future<Object?> _request(
    Uri uri, {
    String method = 'GET',
    Object? data,
    Map<String, Object?>? queryParameters,
    Map<String, String>? headers,
    Set<int> expectedStatuses = const {200},
    bool allowEmptyBody = false,
  }) async {
    try {
      final requestUri = queryParameters == null
          ? uri
          : uri.replace(
              queryParameters: {
                for (final entry in queryParameters.entries)
                  if (entry.value != null) entry.key: entry.value.toString(),
              },
            );
      final response = await _dio.requestUri<ResponseBody>(
        requestUri,
        data: data,
        options: Options(
          method: method,
          headers: headers,
          followRedirects: false,
          maxRedirects: 0,
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        _closeResponseBody(response.data);
        throw const JellyfinException(
          'Jellyfin rejected the username, password, or saved session.',
        );
      }
      if (status >= 300 && status < 400) {
        _closeResponseBody(response.data);
        throw const JellyfinException(
          'Jellyfin redirected the request. Enter the server’s final address.',
        );
      }
      if (!expectedStatuses.contains(status)) {
        _closeResponseBody(response.data);
        throw JellyfinException('Jellyfin returned HTTP $status.');
      }
      if (status == 204) {
        _closeResponseBody(response.data);
        return null;
      }
      final contentLength = response.headers.value(Headers.contentLengthHeader);
      if ((int.tryParse(contentLength ?? '') ?? 0) >
          _maxJellyfinResponseBytes) {
        _closeResponseBody(response.data);
        throw const JellyfinException('Jellyfin returned too much data.');
      }
      final body = response.data;
      if (body == null) {
        if (allowEmptyBody) return null;
        throw const JellyfinException('Jellyfin returned an empty response.');
      }
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in body.stream) {
          if (bytes.length + chunk.length > _maxJellyfinResponseBytes) {
            throw const JellyfinException('Jellyfin returned too much data.');
          }
          bytes.add(chunk);
        }
      } finally {
        _closeResponseBody(body);
      }
      try {
        final value = bytes.takeBytes();
        if (value.isEmpty && allowEmptyBody) return null;
        return jsonDecode(utf8.decode(value));
      } on FormatException {
        throw const JellyfinException('Jellyfin returned invalid data.');
      }
    } on JellyfinException {
      rethrow;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const JellyfinException(
          'Jellyfin rejected the username, password, or saved session.',
        );
      }
      throw const JellyfinException(
        'TetoTV could not reach that Jellyfin server.',
      );
    }
  }

  Map<String, String> _sessionHeaders(JellyfinConnection connection) => {
    'Authorization': _authorization(
      deviceId: connection.deviceId,
      token: connection.accessToken,
    ),
  };

  String _authorization({required String deviceId, String? token}) {
    String quote(String value) => value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(RegExp(r'[\r\n]'), '');
    return [
      'MediaBrowser Client="TetoTV"',
      'Device="Android TV"',
      'DeviceId="${quote(deviceId)}"',
      'Version="1.0.0"',
      if (token != null) 'Token="${quote(token)}"',
    ].join(', ');
  }

  static String _basePath(Uri baseUri) =>
      baseUri.path.replaceFirst(RegExp(r'/+$'), '');

  static Map<Object?, Object?> _map(Object? value) => value is Map
      ? value.cast<Object?, Object?>()
      : const <Object?, Object?>{};

  static String? _bounded(Object? value, int min, int max) {
    final text = value is String ? value.trim() : '';
    return text.length >= min && text.length <= max ? text : null;
  }

  static int? _integer(Object? value) => switch (value) {
    num number => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };
}

String? _containerContentType(String? container) =>
    switch (container?.trim().toLowerCase()) {
      'mkv' || 'matroska' => 'video/x-matroska',
      'mp4' || 'm4v' => 'video/mp4',
      'webm' => 'video/webm',
      'ts' || 'mpegts' => 'video/mp2t',
      _ => null,
    };

String? _canonicalJellyfinLanguage(String? value) {
  final normalized = value?.trim().toLowerCase().split(RegExp('[-_]')).first;
  return switch (normalized) {
    'en' || 'eng' => 'eng',
    'ja' || 'jpn' || 'jp' => 'jpn',
    'es' || 'spa' => 'spa',
    'fr' || 'fra' || 'fre' => 'fra',
    'de' || 'deu' || 'ger' => 'deu',
    'it' || 'ita' => 'ita',
    'pt' || 'por' => 'por',
    'ko' || 'kor' => 'kor',
    'zh' || 'zho' || 'chi' => 'zho',
    final language? when language.isNotEmpty => language,
    _ => null,
  };
}

String? _canonicalSubtitleLanguage(String? value) =>
    _canonicalJellyfinLanguage(value);

// Dio exposes streaming response bodies publicly but keeps their close hook
// internal. Rejected and size-limited responses must release the socket now.
// ignore: invalid_use_of_internal_member
void _closeResponseBody(ResponseBody? body) => body?.close();

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

bool _isUnderBasePath(String basePath, String path) {
  final base = basePath.replaceFirst(RegExp(r'/+$'), '');
  return base.isEmpty || path == base || path.startsWith('$base/');
}

bool _safeServerId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{8,160}$').hasMatch(value);
