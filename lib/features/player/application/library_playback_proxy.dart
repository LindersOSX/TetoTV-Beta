import 'dart:async';
import 'dart:io';

import 'package:anime_tv/features/marketplace/data/web_playback_proxy.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

/// Converts an authenticated private-library request into an opaque loopback
/// capability before libmpv sees it.
///
/// The proxy follows and rewrites only resources on the exact user-configured
/// server origin. Authorization, X-Plex-Token, and other private headers never
/// enter libmpv and cannot cross a redirect or HLS reference boundary.
class LibraryPlaybackProxy {
  const LibraryPlaybackProxy({
    this.limits = const WebPlaybackProxyLimits(),
    this.hopFetcher,
  });

  final WebPlaybackProxyLimits limits;

  /// Test seam. Production uses a redirect-disabled [HttpClient] for every hop.
  final WebProxyHopFetcher? hopFetcher;

  Future<LibraryPlaybackRequest> protect(LibraryPlaybackRequest request) async {
    if (request.isContentUri || request.headers.isEmpty) return request;

    final origin = privateLibraryPlaybackOrigin(request.source);
    final proxy = WebPlaybackProxy(
      limits: limits,
      upstream: SameOriginLibraryProxyUpstream(
        origin: origin,
        limits: limits,
        hopFetcher: hopFetcher,
      ),
      referenceResolver: (base, reference) =>
          resolveSameOriginLibraryReference(origin, base, reference),
    );
    WebPlaybackSession? session;
    try {
      final legacySubtitle = Uri.tryParse(request.externalSubtitle ?? '');
      final subtitleUris = <Uri>[
        ...request.externalSubtitleTracks.map((track) => track.uri),
        if (legacySubtitle != null &&
            legacySubtitle.hasScheme &&
            !request.externalSubtitleTracks.any(
              (track) => track.uri == legacySubtitle,
            ))
          legacySubtitle,
      ];
      session = await proxy.prepare(
        uri: request.source,
        headers: request.headers,
        subtitleUris: subtitleUris,
      );
      final subtitles = <Uri, WebPlaybackSubtitle>{
        for (final subtitle in session.subtitles) subtitle.sourceUri: subtitle,
      };
      final protectedTracks = <LibraryExternalSubtitleTrack>[
        for (final track in request.externalSubtitleTracks)
          if (subtitles[track.uri] case final protected?)
            LibraryExternalSubtitleTrack(
              uri: protected.playbackUri,
              label: track.label,
              language: track.language,
              contentType: protected.contentType,
            ),
      ];
      final protectedLegacy = legacySubtitle == null
          ? null
          : subtitles[legacySubtitle];
      final lease = _OwnedLibraryProxyLease(proxy, session);
      session = null;
      try {
        return LibraryPlaybackRequest(
          source: lease.playbackUri,
          title: request.title,
          releaseName: request.releaseName,
          streamLabel: request.streamLabel,
          sourceProviderId: request.sourceProviderId,
          sourceProviderName: request.sourceProviderName,
          checkpointKey: request.checkpointKey,
          timelineIdentity: request.timelineIdentity,
          headers: const {},
          artworkUrl: request.artworkUrl,
          externalSubtitle: protectedLegacy?.playbackUri.toString(),
          externalSubtitleTracks: protectedTracks,
          mediaContentType: _preferContentType(
            lease.contentType,
            request.mediaContentType,
          ),
          subtitleContentType:
              protectedLegacy?.contentType ?? request.subtitleContentType,
          initialPosition: request.initialPosition,
          requestedAudio: request.requestedAudio,
          onStarted: request.onStarted,
          onProgress: request.onProgress,
          onFinished: request.onFinished,
          playbackLease: lease,
          isCompatibilityStream: request.isCompatibilityStream,
          watchPartyDisplayTitle: request.watchPartyDisplayTitle,
          watchPartyIdentity: request.watchPartyIdentity,
        );
      } catch (_) {
        await lease.close();
        rethrow;
      }
    } catch (_) {
      await session?.close();
      await proxy.close();
      rethrow;
    }
  }
}

class _OwnedLibraryProxyLease implements PlaybackResourceLease {
  _OwnedLibraryProxyLease(this._proxy, this._session)
    : playbackUri = _session.playbackUri,
      contentType = _session.contentType;

  final WebPlaybackProxy _proxy;
  final WebPlaybackSession _session;
  final Uri playbackUri;
  final String contentType;
  bool _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _session.close();
    } finally {
      await _proxy.close();
    }
  }
}

/// Redirect-disabled upstream used only for a user's authenticated media
/// server. Unlike the public add-on upstream it permits numeric LAN HTTP, but
/// it never permits a request, redirect, or HLS resource to change origin.
class SameOriginLibraryProxyUpstream extends PinnedPublicWebProxyUpstream {
  SameOriginLibraryProxyUpstream({
    required Uri origin,
    super.limits = const WebPlaybackProxyLimits(),
    this.hopFetcher,
  }) : origin = privateLibraryPlaybackOrigin(origin);

  final Uri origin;
  final WebProxyHopFetcher? hopFetcher;

  @override
  Future<void> validateTarget(Uri uri) async {
    _requireSameOriginLibraryUri(origin, uri);
  }

  @override
  Future<WebProxyUpstreamResponse> fetch(
    Uri initialUri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? range,
    String? ifRange,
  }) async {
    if (method != 'GET' && method != 'HEAD') {
      throw const FormatException('The proxy supports only GET and HEAD.');
    }
    var target = initialUri;
    final sanitized = sanitizeWebStreamHeaders(headers);
    for (var redirect = 0; redirect <= limits.maximumRedirects; redirect++) {
      await validateTarget(target);
      final response = await (hopFetcher ?? _fetchHop)(
        WebProxyUpstreamRequest(
          uri: target,
          method: method,
          headers: sanitized,
          range: range,
          ifRange: ifRange,
        ),
      );
      if (response.uri != target) {
        await response.close();
        throw const FormatException(
          'A single media-server hop returned an unexpected target.',
        );
      }
      if (!_isRedirect(response.statusCode)) return response;
      final location = response.header(HttpHeaders.locationHeader);
      await response.close();
      if (location == null || redirect == limits.maximumRedirects) {
        throw const FormatException(
          'The media server exceeded the redirect limit.',
        );
      }
      final redirected = target.resolve(location);
      _requireSameOriginLibraryUri(origin, redirected);
      target = redirected;
    }
    throw const FormatException('The media-server resource could not open.');
  }

  Future<WebProxyUpstreamResponse> _fetchHop(
    WebProxyUpstreamRequest request,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = limits.upstreamConnectTimeout
      ..idleTimeout = limits.upstreamIdleTimeout;
    try {
      final outgoing = request.method == 'HEAD'
          ? await client
                .headUrl(request.uri)
                .timeout(limits.upstreamHeaderTimeout)
          : await client
                .getUrl(request.uri)
                .timeout(limits.upstreamHeaderTimeout);
      outgoing.followRedirects = false;
      outgoing.headers.set(HttpHeaders.acceptHeader, '*/*');
      for (final entry in request.headers.entries) {
        outgoing.headers.set(entry.key, entry.value);
      }
      if (request.range != null) {
        outgoing.headers.set(HttpHeaders.rangeHeader, request.range!);
      }
      if (request.ifRange != null) {
        outgoing.headers.set(HttpHeaders.ifRangeHeader, request.ifRange!);
      }
      final incoming = await outgoing.close().timeout(
        limits.upstreamHeaderTimeout,
      );
      final responseHeaders = <String, List<String>>{};
      incoming.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = List.unmodifiable(values);
      });
      return WebProxyUpstreamResponse(
        statusCode: incoming.statusCode,
        uri: request.uri,
        requestHeaders: Map.unmodifiable(request.headers),
        headers: Map.unmodifiable(responseHeaders),
        body: incoming.timeout(limits.upstreamIdleTimeout),
        onClose: () => client.close(force: true),
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

Uri privateLibraryPlaybackOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (!const {'http', 'https'}.contains(scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (scheme == 'http' && !_isPrivateLibraryHttpHost(uri.host))) {
    throw const FormatException(
      'Authenticated library playback requires HTTPS or numeric private-network HTTP.',
    );
  }
  return uri.replace(
    scheme: scheme,
    host: uri.host.toLowerCase(),
    path: '/',
    query: null,
    fragment: null,
  );
}

Uri resolveSameOriginLibraryReference(
  Uri origin,
  Uri base,
  String rawReference,
) {
  final value = rawReference.trim();
  if (value.isEmpty ||
      value.length > 4096 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      value.contains(r'{$')) {
    throw const FormatException('The media manifest contains an unsafe URI.');
  }
  _requireSameOriginLibraryUri(origin, base);
  final resolved = base.resolve(value);
  _requireSameOriginLibraryUri(origin, resolved);
  return resolved;
}

void _requireSameOriginLibraryUri(Uri origin, Uri uri) {
  if (!_sameOrigin(origin, uri) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    throw const FormatException(
      'Authenticated media resources must stay on the configured server origin.',
    );
  }
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

bool _isPrivateLibraryHttpHost(String value) {
  final host = value.trim().toLowerCase();
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  if (address == null ||
      address.isMulticast ||
      address.rawAddress.every((byte) => byte == 0)) {
    return false;
  }
  if (address.isLoopback || address.isLinkLocal) return true;
  var bytes = address.rawAddress;
  if (_isIpv4MappedIpv6(bytes)) bytes = bytes.sublist(12);
  if (bytes.length == 4) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 10 ||
        first == 127 ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }
  return bytes.length == 16 &&
      ((bytes[0] & 0xfe) == 0xfc ||
          (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80));
}

bool _isIpv4MappedIpv6(List<int> bytes) =>
    bytes.length == 16 &&
    bytes.take(10).every((byte) => byte == 0) &&
    bytes[10] == 0xff &&
    bytes[11] == 0xff;

bool _isRedirect(int status) => const {
  HttpStatus.movedPermanently,
  HttpStatus.found,
  HttpStatus.seeOther,
  HttpStatus.temporaryRedirect,
  HttpStatus.permanentRedirect,
}.contains(status);

String? _preferContentType(String proxied, String? declared) {
  final normalized = proxied.trim();
  if (normalized.isEmpty || normalized == 'application/octet-stream') {
    return declared;
  }
  return normalized;
}
