// ignore_for_file: prefer_initializing_formals

import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/data/web_playback_proxy.dart';

class ValidatedWebStream {
  const ValidatedWebStream({
    required this.uri,
    required this.headers,
    required this.contentType,
    this.subtitleUri,
    this.subtitleContentType,
    this.subtitleRejected = false,
    this.session,
  });

  final Uri uri;
  final Map<String, String> headers;
  final String contentType;
  final Uri? subtitleUri;
  final String? subtitleContentType;
  final bool subtitleRejected;
  final WebPlaybackSession? session;
}

typedef WebStreamPreflight =
    Future<ValidatedWebStream> Function(
      Uri uri,
      Map<String, String> headers, {
      Uri? subtitleUri,
    });

/// Prepares an engine-safe, app-owned loopback playback session.
///
/// Native engines receive only opaque loopback URLs. The proxy performs public
/// HTTPS validation, DNS pinning, redirect enforcement, manifest rewriting,
/// and credential scoping again for every actual upstream request.
class WebStreamValidator {
  const WebStreamValidator({WebPlaybackProxy? proxy}) : _proxy = proxy;

  final WebPlaybackProxy? _proxy;

  Future<ValidatedWebStream> validate(
    Uri uri,
    Map<String, String> headers, {
    Uri? subtitleUri,
  }) async {
    final proxy = _proxy ?? WebPlaybackProxy.instance;
    final retained = proxy.retainSessionForUri(uri);
    final session =
        retained ??
        await proxy.prepare(
          uri: uri,
          headers: sanitizeWebStreamHeaders(headers),
          subtitleUri: subtitleUri,
        );
    return ValidatedWebStream(
      uri: session.playbackUri,
      headers: const {},
      contentType: session.contentType,
      subtitleUri: session.subtitleUri,
      subtitleContentType: session.subtitleContentType,
      subtitleRejected: session.subtitleRejected,
      session: session,
    );
  }
}

Map<String, String> sanitizeWebStreamHeaders(
  Map<String, String> headers, {
  bool stripCredentials = false,
}) => sanitizeAddonHeaders(headers, stripCredentials: stripCredentials);

bool isPlayableWebResponse(Uri uri, String contentType, String sample) {
  final mime = contentType.toLowerCase().split(';').first.trim();
  final trimmedSample = sample.trimLeft();
  if (mime == 'text/html' ||
      trimmedSample.toLowerCase().startsWith('<!doctype html')) {
    return false;
  }
  if (mime.startsWith('video/') ||
      const {
        'application/vnd.apple.mpegurl',
        'application/x-mpegurl',
        'application/octet-stream',
      }.contains(mime)) {
    return true;
  }
  if (trimmedSample.startsWith('#EXTM3U')) {
    return true;
  }
  final path = uri.path.toLowerCase();
  return const [
    '.m3u8',
    '.mpd',
    '.mp4',
    '.mkv',
    '.webm',
    '.m4v',
    '.ts',
  ].any(path.endsWith);
}
