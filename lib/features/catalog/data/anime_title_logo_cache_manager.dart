import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

const _maximumArtworkBytes = 4 * 1024 * 1024;
const _maximumRedirects = 3;
const _maximumDownloadAttempts = 3;

/// Dedicated cache for title logos whose transport rejects private-network
/// DNS answers, untrusted redirects, and oversized payloads.
final BaseCacheManager animeTitleLogoCacheManager = CacheManager(
  Config(
    // V3 discards V2 entries created while Android's custom connection
    // factory was incompatible with the artwork CDN transport.
    'animeTitleLogosV3',
    stalePeriod: const Duration(days: 14),
    maxNrOfCacheObjects: 100,
    fileService: _SafeArtworkFileService(),
  ),
);

class _SafeArtworkFileService extends FileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    var current = Uri.parse(url);
    for (var redirectCount = 0; ; redirectCount += 1) {
      if (!isSafeAnimeTitleLogoUri(current)) {
        throw HttpException('Untrusted title-logo URL.', uri: current);
      }
      late final List<InternetAddress> addresses;
      try {
        addresses = await InternetAddress.lookup(
          current.host,
        ).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _recordArtworkDiagnostic('failed', reason: 'dns_timeout');
        rethrow;
      } on SocketException {
        _recordArtworkDiagnostic('failed', reason: 'dns_failed');
        rethrow;
      }
      if (orderPublicArtworkAddresses(addresses) == null) {
        _recordArtworkDiagnostic('failed', reason: 'non_public_dns');
        throw HttpException(
          'Title-logo host did not resolve publicly.',
          uri: current,
        );
      }
      Uri? redirectTarget;
      Object? lastFailure;
      StackTrace? lastFailureStack;
      for (var attempt = 0; attempt < _maximumDownloadAttempts; attempt += 1) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 6)
          ..idleTimeout = const Duration(seconds: 8)
          ..autoUncompress = false
          ..findProxy = (_) => 'DIRECT';

        try {
          final request = await client.getUrl(current);
          request.followRedirects = false;
          request.maxRedirects = 0;
          request.headers.set(
            HttpHeaders.acceptHeader,
            'image/png,image/webp,image/jpeg',
          );
          for (final entry
              in headers?.entries ?? const <MapEntry<String, String>>[]) {
            final name = entry.key.toLowerCase();
            if (name == HttpHeaders.ifNoneMatchHeader ||
                name == HttpHeaders.ifModifiedSinceHeader) {
              request.headers.set(entry.key, entry.value);
            }
          }
          final response = await request.close();
          if (response.isRedirect) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            await response.drain<void>();
            client.close(force: true);
            if (location == null || redirectCount >= _maximumRedirects) {
              throw const _ArtworkPolicyException(
                'Invalid title-logo redirect.',
              );
            }
            redirectTarget = current.resolve(location);
            break;
          }
          if (isTransientArtworkStatus(response.statusCode)) {
            await response.drain<void>();
            throw HttpException(
              'Temporary title-logo response (${response.statusCode}).',
              uri: current,
            );
          }
          final contentType = response.headers.contentType;
          if (response.statusCode != HttpStatus.notModified &&
              (contentType == null || contentType.primaryType != 'image')) {
            await response.drain<void>();
            throw const _ArtworkPolicyException(
              'Title-logo response was not an image.',
            );
          }
          final declaredContentLength = response.contentLength;
          if (declaredContentLength > _maximumArtworkBytes) {
            await response.drain<void>();
            throw const _ArtworkPolicyException(
              'Title-logo response was too large.',
            );
          }
          final bytes = await _readBoundedArtwork(response);
          if (!hasCompleteArtworkLength(
            declaredBytes: declaredContentLength,
            receivedBytes: bytes.length,
          )) {
            throw HttpException(
              'Title-logo response ended before it was complete.',
              uri: current,
            );
          }
          final result = _SafeArtworkResponse(
            bytes: bytes,
            statusCode: response.statusCode,
            eTag: response.headers.value(HttpHeaders.etagHeader),
            contentType: contentType,
          );
          _recordArtworkDiagnostic('success');
          client.close();
          return result;
        } on _ArtworkPolicyException catch (error) {
          client.close(force: true);
          _recordArtworkDiagnostic('failed', reason: 'policy');
          throw HttpException(error.message, uri: current);
        } catch (error, stackTrace) {
          client.close(force: true);
          lastFailure = error;
          lastFailureStack = stackTrace;
          if (attempt + 1 >= _maximumDownloadAttempts) {
            _recordArtworkDiagnostic(
              'failed',
              reason: _safeArtworkFailureReason(error),
            );
            Error.throwWithStackTrace(error, stackTrace);
          }
        }
      }
      if (redirectTarget != null) {
        current = redirectTarget;
        continue;
      }
      if (lastFailure != null && lastFailureStack != null) {
        Error.throwWithStackTrace(lastFailure, lastFailureStack);
      }
      throw HttpException('Title-logo download failed.', uri: current);
    }
  }
}

String _safeArtworkFailureReason(Object error) => switch (error) {
  TimeoutException() => 'timeout',
  HandshakeException() => 'tls',
  SocketException() => 'socket',
  HttpException() => 'http_or_transport',
  _ => 'unexpected',
};

void _recordArtworkDiagnostic(String outcome, {String? reason}) {
  unawaited(
    TetoTvDatabase.instance.recordDiagnosticEvent(
      category: 'title-logo',
      message: 'Title logo artwork download',
      details: {'stage': 'artwork', 'outcome': outcome, 'reason': ?reason},
    ),
  );
}

class _SafeArtworkResponse implements FileServiceResponse {
  const _SafeArtworkResponse({
    required this._bytes,
    required this.statusCode,
    required this.eTag,
    required this._contentType,
  });

  final Uint8List _bytes;
  final ContentType? _contentType;

  @override
  Stream<List<int>> get content => Stream<List<int>>.value(_bytes);

  @override
  int get contentLength => _bytes.length;

  @override
  final String? eTag;

  @override
  String get fileExtension {
    final subtype = _contentType?.subType.toLowerCase();
    return switch (subtype) {
      'jpeg' => '.jpg',
      'png' => '.png',
      'webp' => '.webp',
      _ => '',
    };
  }

  @override
  final int statusCode;

  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 7));
}

class _ArtworkPolicyException implements Exception {
  const _ArtworkPolicyException(this.message);

  final String message;
}

Future<Uint8List> _readBoundedArtwork(HttpClientResponse response) async {
  final bytes = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in response) {
    received += chunk.length;
    if (received > _maximumArtworkBytes) {
      throw const _ArtworkPolicyException('Title-logo response was too large.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// Returns a deterministic address order only when every resolved address is
/// globally routable. The production request keeps the approved hostname so
/// Android can perform compatible TLS/SNI negotiation with the artwork CDN.
List<InternetAddress>? orderPublicArtworkAddresses(
  List<InternetAddress> addresses,
) {
  if (addresses.isEmpty ||
      addresses.any((address) => !isPublicArtworkAddress(address))) {
    return null;
  }
  final unique = <String, InternetAddress>{};
  for (final address in addresses) {
    unique['${address.type.name}:${address.address}'] = address;
  }
  final ordered = unique.values.toList(growable: false)
    ..sort((left, right) {
      final leftScore = left.type == InternetAddressType.IPv4 ? 0 : 1;
      final rightScore = right.type == InternetAddressType.IPv4 ? 0 : 1;
      return leftScore.compareTo(rightScore);
    });
  return ordered;
}

bool isTransientArtworkStatus(int statusCode) =>
    statusCode == HttpStatus.requestTimeout ||
    statusCode == 425 ||
    statusCode == HttpStatus.tooManyRequests ||
    statusCode >= HttpStatus.internalServerError;

bool hasCompleteArtworkLength({
  required int declaredBytes,
  required int receivedBytes,
}) => declaredBytes < 0 || declaredBytes == receivedBytes;

/// Only globally routable addresses are eligible for title-logo connections.
///
/// The subsequent request still uses the validated, exact allowlisted HTTPS
/// hostname so Android's HttpClient can negotiate CDN TLS correctly. Redirects
/// are disabled and every redirect target is independently revalidated.
bool isPublicArtworkAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    final first = bytes[0];
    final second = bytes[1];
    if (first == 0 || first == 10 || first == 127 || first >= 224) return false;
    if (first == 100 && second >= 64 && second <= 127) return false;
    if (first == 169 && second == 254) return false;
    if (first == 172 && second >= 16 && second <= 31) return false;
    if (first == 192 && (second == 0 || second == 168)) return false;
    if (first == 198 && (second == 18 || second == 19)) return false;
    if (first == 198 && second == 51 && bytes[2] == 100) return false;
    if (first == 203 && second == 0 && bytes[2] == 113) return false;
    return true;
  }
  if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
    return false;
  }
  // Accept only global-unicast IPv6 and exclude the documentation prefix.
  if ((bytes[0] & 0xe0) != 0x20) return false;
  if (bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8) {
    return false;
  }
  return true;
}
