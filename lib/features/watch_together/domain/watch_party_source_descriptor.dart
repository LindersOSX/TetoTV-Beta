import 'dart:convert';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum WatchPartySourceClass { torrent, web }

enum WatchPartySourceAudio { dub, sub }

/// A one-way, capability-free hint that lets every viewer look for the same
/// source in their own locally discovered candidate list.
///
/// The preimage may contain a torrent hash or provider metadata, but only this
/// SHA-256 digest and coarse playback attributes are serialized. URLs, magnet
/// links, headers, account tokens, local paths, and video bytes never cross the
/// Watch Together boundary.
@immutable
class WatchPartySourceDescriptor {
  const WatchPartySourceDescriptor({
    required this.sourceClass,
    required this.fingerprint,
    required this.audio,
    this.qualityHeight,
  });

  static const int version = 1;

  final WatchPartySourceClass sourceClass;
  final String fingerprint;
  final WatchPartySourceAudio audio;
  final int? qualityHeight;

  /// Opaque identity for the complete descriptor, including its coarse audio
  /// and quality attributes. This is safe to place in local app routes and
  /// lets a same-episode source change invalidate an older player route.
  String get sourceKey => _digest(<String>[
    'tetotv-source-descriptor-v1',
    sourceClass.name,
    fingerprint,
    audio.name,
    '${qualityHeight ?? -1}',
  ]);

  factory WatchPartySourceDescriptor.forRelease(
    ReleaseCandidate release, {
    PlaybackAudioPreference? requestedAudio,
  }) {
    final descriptor = WatchPartySourceDescriptor.tryForRelease(
      release,
      requestedAudio: requestedAudio,
    );
    if (descriptor == null) {
      throw ArgumentError.value(
        release.infoHash,
        'release.infoHash',
        'A torrent source descriptor requires a valid BitTorrent info hash.',
      );
    }
    return descriptor;
  }

  static WatchPartySourceDescriptor? tryForRelease(
    ReleaseCandidate release, {
    PlaybackAudioPreference? requestedAudio,
  }) {
    final sourceClass = release.magnetUri.trim().isEmpty
        ? WatchPartySourceClass.web
        : WatchPartySourceClass.torrent;
    final fingerprint = tryWatchPartySourceFingerprint(release);
    if (fingerprint == null) return null;
    final multiAudio =
        release.audioIntent == ReleaseAudioIntent.multi ||
        releaseAdvertisesDualAudio(release);
    final audioPreference =
        requestedAudio ??
        releaseExplicitAudioPreference(release) ??
        (multiAudio
            ? null
            : release.isDubbed
            ? PlaybackAudioPreference.dub
            : PlaybackAudioPreference.sub);
    if (audioPreference == null) return null;
    return WatchPartySourceDescriptor(
      sourceClass: sourceClass,
      fingerprint: fingerprint,
      audio: audioPreference == PlaybackAudioPreference.dub
          ? WatchPartySourceAudio.dub
          : WatchPartySourceAudio.sub,
      qualityHeight: _releaseQualityHeight(release),
    );
  }

  bool matches(ReleaseCandidate release) =>
      sourceClass ==
          (release.magnetUri.trim().isEmpty
              ? WatchPartySourceClass.web
              : WatchPartySourceClass.torrent) &&
      fingerprint == tryWatchPartySourceFingerprint(release);

  Map<String, Object> toJson() => <String, Object>{
    'version': version,
    'class': sourceClass.name,
    'fingerprint': fingerprint,
    'audio': audio.name,
    'quality_height': ?qualityHeight,
  };

  static WatchPartySourceDescriptor? tryFromJson(Map<String, Object?> value) {
    const allowedKeys = <String>{
      'version',
      'class',
      'fingerprint',
      'audio',
      'quality_height',
    };
    if (value.keys.any((key) => !allowedKeys.contains(key)) ||
        value['version'] != version) {
      return null;
    }
    final sourceClass = switch (value['class']) {
      'torrent' => WatchPartySourceClass.torrent,
      'web' => WatchPartySourceClass.web,
      _ => null,
    };
    final audio = switch (value['audio']) {
      'dub' => WatchPartySourceAudio.dub,
      'sub' => WatchPartySourceAudio.sub,
      _ => null,
    };
    final fingerprint = value['fingerprint'];
    final rawQualityHeight = value['quality_height'];
    final qualityHeight = rawQualityHeight is int ? rawQualityHeight : null;
    if (sourceClass == null ||
        audio == null ||
        fingerprint is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        (rawQualityHeight != null &&
            (qualityHeight == null ||
                qualityHeight < 144 ||
                qualityHeight > 4320))) {
      return null;
    }
    return WatchPartySourceDescriptor(
      sourceClass: sourceClass,
      fingerprint: fingerprint,
      audio: audio,
      qualityHeight: qualityHeight,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WatchPartySourceDescriptor &&
      sourceClass == other.sourceClass &&
      fingerprint == other.fingerprint &&
      audio == other.audio &&
      qualityHeight == other.qualityHeight;

  @override
  int get hashCode =>
      Object.hash(sourceClass, fingerprint, audio, qualityHeight);
}

/// Stable across devices without exposing the source identity preimage.
String watchPartySourceFingerprint(ReleaseCandidate release) {
  final value = tryWatchPartySourceFingerprint(release);
  if (value == null) {
    throw ArgumentError.value(
      release.infoHash,
      'release.infoHash',
      'A torrent source fingerprint requires a valid BitTorrent info hash.',
    );
  }
  return value;
}

String? tryWatchPartySourceFingerprint(ReleaseCandidate release) {
  String normalized(String? value) =>
      value?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ') ?? '';

  final torrent = release.magnetUri.trim().isNotEmpty;
  final torrentIdentity = torrent ? _safeTorrentIdentity(release) : null;
  if (torrent && torrentIdentity == null) return null;
  final webVariant = torrent ? null : _safeWebVariantIdentity(release.infoHash);
  final webProvider = normalized(
    release.sourceId,
  ).replaceFirst(RegExp(r'^web:\s*'), '');
  final webProviderName = normalized(release.provider);
  final webReleaseName = normalized(release.releaseName);
  // Provider/title metadata by itself is not a unique stream identity. In
  // particular, an entirely blank candidate previously hashed a fixed vector
  // and collided with every other blank Web result. Production Web candidates
  // carry a query-free, one-way route hint in [infoHash]; if it is absent, fail
  // closed and let Watch Together synchronize without a source descriptor.
  if (!torrent &&
      (webVariant == null ||
          (webProvider.isEmpty && webProviderName.isEmpty) ||
          webReleaseName.isEmpty)) {
    return null;
  }
  final canonical = torrent
      ? <String>[
          'tetotv-source-v1',
          'torrent',
          torrentIdentity!,
          '${release.preferredFileIndex ?? -1}',
        ]
      : <String>[
          'tetotv-source-v1',
          'web',
          webProvider,
          webProviderName,
          webReleaseName,
          normalized(release.quality),
          release.audioIntent == ReleaseAudioIntent.unknown
              ? (release.isDubbed ? 'dub' : 'sub')
              : release.audioIntent.name,
          webVariant!,
        ];
  return _digest(canonical);
}

/// Builds the non-capability identity stored on a Web [ReleaseCandidate].
///
/// Query parameters, fragments, credentials, request headers, and subtitles
/// are never included. High-entropy path segments are also rejected because
/// some CDNs place bearer signatures in the path rather than in the query.
/// Returning `null` intentionally disables exact-source affinity for a URL
/// that cannot be reduced to a stable, non-sensitive route.
String? tryWatchPartyWebVariantIdentity(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'https' && scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.isEmpty ||
      segments.every((segment) => segment.isEmpty) ||
      segments.any(_looksLikePrivatePathCapability)) {
    return null;
  }
  final effectivePort = uri.hasPort
      ? uri.port
      : scheme == 'https'
      ? 443
      : 80;
  return _digest(<String>[
    'tetotv-web-route-v1',
    scheme,
    uri.host.toLowerCase(),
    '$effectivePort',
    // Uri.path is the encoded, case-preserving route. Query and fragment data
    // are deliberately absent, so independently signed URLs remain stable.
    uri.path,
  ]);
}

/// Stable Web pseudo-hash used by release ranking/deduplication and consumed
/// by [tryWatchPartySourceFingerprint]. No raw URL is retained.
String watchPartyWebReleaseIdentity({
  required String providerId,
  required Uri uri,
}) {
  final provider = providerId.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9._-]+'),
    '-',
  );
  final variant = tryWatchPartyWebVariantIdentity(uri);
  if (provider.isEmpty || variant == null) {
    // This fallback remains useful only for local list identity. It is not a
    // valid Watch Together variant and [_safeWebVariantIdentity] rejects it.
    return 'web:local:${uri.toString().hashCode.toUnsigned(32).toRadixString(16)}';
  }
  return 'web:$provider:$variant';
}

String? _safeWebVariantIdentity(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null) return null;
  return RegExp(
    r'^web:[a-z0-9._-]+:([a-f0-9]{64})$',
  ).firstMatch(normalized)?.group(1);
}

bool _looksLikePrivatePathCapability(String value) {
  // [Uri.pathSegments] is already decoded and may legitimately contain `%`.
  // Decoding a second time could throw for an otherwise valid media route.
  final decoded = value.trim();
  if (decoded.isEmpty) return false;
  if (decoded.length > 96) return true;
  final compact = decoded.replaceAll(RegExp(r'[-_]'), '');
  return compact.length >= 24 &&
      (RegExp(r'^[a-fA-F0-9]+$').hasMatch(compact) ||
          RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(compact));
}

String? _safeTorrentIdentity(ReleaseCandidate release) {
  String? normalize(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    final withoutPrefix = normalized.startsWith('urn:btih:')
        ? normalized.substring('urn:btih:'.length)
        : normalized;
    if (RegExp(r'^[a-f0-9]{40}$').hasMatch(withoutPrefix)) {
      return withoutPrefix;
    }
    if (RegExp(r'^[a-z2-7]{32}$').hasMatch(withoutPrefix)) {
      return _base32BtihToHex(withoutPrefix);
    }
    return null;
  }

  final direct = normalize(release.infoHash);
  if (direct != null) return direct;
  final magnet = Uri.tryParse(release.magnetUri);
  if (magnet == null || magnet.scheme.toLowerCase() != 'magnet') return null;
  for (final value in magnet.queryParametersAll['xt'] ?? const <String>[]) {
    final extracted = normalize(value);
    if (extracted != null) return extracted;
  }
  return null;
}

String? _base32BtihToHex(String value) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  var buffer = 0;
  var bits = 0;
  final bytes = <int>[];
  for (final unit in value.codeUnits) {
    final digit = alphabet.indexOf(String.fromCharCode(unit));
    if (digit < 0) return null;
    buffer = (buffer << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((buffer >> bits) & 0xff);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bytes.length != 20 || bits != 0) return null;
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _digest(List<String> canonical) =>
    sha256.convert(utf8.encode(canonical.join('\u001f'))).toString();

int? _releaseQualityHeight(ReleaseCandidate release) {
  final value = '${release.quality ?? ''} ${release.releaseName}'.toLowerCase();
  for (final candidate in <(RegExp, int)>[
    (RegExp(r'(?:4320|8k)'), 4320),
    (RegExp(r'(?:2160|4k|uhd)'), 2160),
    (RegExp(r'(?:1440|2k)'), 1440),
    (RegExp(r'(?:1080|full[ ._-]?hd)'), 1080),
    (RegExp(r'(?:720|\bhd\b)'), 720),
    (RegExp(r'576'), 576),
    (RegExp(r'480'), 480),
    (RegExp(r'360'), 360),
    (RegExp(r'240'), 240),
  ]) {
    if (candidate.$1.hasMatch(value)) return candidate.$2;
  }
  return null;
}
