import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

typedef PublicHostResolver =
    Future<List<InternetAddress>> Function(String host);
typedef CatalogHttpClientFactory = HttpClient Function();

abstract interface class PublicCatalogArtworkFetcher {
  Future<PublicCatalogArtwork> fetch(Uri uri);
}

class PublicCatalogArtworkException implements Exception {
  const PublicCatalogArtworkException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'PublicCatalogArtworkException($code, $message)';
}

/// A bounded, signature-checked public image which is safe to persist.
class PublicCatalogArtwork {
  const PublicCatalogArtwork._({
    required this.bytes,
    required this.mimeType,
    required this.fileExtension,
  });

  factory PublicCatalogArtwork.validate({
    required List<int> bytes,
    required String? contentType,
    int maxBytes = PublicCatalogArtworkClient.defaultMaxBytes,
  }) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const PublicCatalogArtworkException(
        'invalid_size',
        'Catalog artwork was empty or exceeded the size limit.',
      );
    }
    final normalizedType = contentType?.split(';').first.trim().toLowerCase();
    final detected = _detectImage(bytes);
    if (detected == null ||
        normalizedType == null ||
        !_mimeMatches(normalizedType, detected.$1)) {
      throw const PublicCatalogArtworkException(
        'invalid_content',
        'Catalog artwork did not match a supported image format.',
      );
    }
    return PublicCatalogArtwork._(
      bytes: Uint8List.fromList(bytes),
      mimeType: detected.$1,
      fileExtension: detected.$2,
    );
  }

  final Uint8List bytes;
  final String mimeType;
  final String fileExtension;
}

/// Fetches public catalog artwork without accepting caller headers, cookies,
/// credentials, private certificates, or non-HTTPS redirects.
class PublicCatalogArtworkClient implements PublicCatalogArtworkFetcher {
  PublicCatalogArtworkClient({
    PublicHostResolver? resolveHost,
    CatalogHttpClientFactory? createClient,
    this.maxBytes = defaultMaxBytes,
    this.maxRedirects = 3,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _resolveHost = resolveHost ?? InternetAddress.lookup,
       _createClient = createClient ?? HttpClient.new;

  static const int defaultMaxBytes = 8 * 1024 * 1024;

  final PublicHostResolver _resolveHost;
  final CatalogHttpClientFactory _createClient;
  final int maxBytes;
  final int maxRedirects;
  final Duration requestTimeout;

  @override
  Future<PublicCatalogArtwork> fetch(Uri uri) async {
    var current = uri;
    for (var redirectCount = 0; ; redirectCount += 1) {
      await validatePublicArtworkUri(current, resolveHost: _resolveHost);
      final client = _createClient()
        ..autoUncompress = false
        ..connectionTimeout = requestTimeout
        ..idleTimeout = requestTimeout
        ..userAgent = null;
      try {
        final request = await client.getUrl(current).timeout(requestTimeout);
        request.followRedirects = false;
        request.maxRedirects = 0;
        request.cookies.clear();
        final response = await request.close().timeout(requestTimeout);
        if (_isRedirect(response.statusCode)) {
          if (redirectCount >= maxRedirects) {
            throw const PublicCatalogArtworkException(
              'too_many_redirects',
              'Catalog artwork redirected too many times.',
            );
          }
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || location.trim().isEmpty) {
            throw const PublicCatalogArtworkException(
              'invalid_redirect',
              'Catalog artwork returned an invalid redirect.',
            );
          }
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw PublicCatalogArtworkException(
            'http_${response.statusCode}',
            'Catalog artwork returned HTTP ${response.statusCode}.',
          );
        }
        final contentEncoding = response.headers
            .value(HttpHeaders.contentEncodingHeader)
            ?.trim()
            .toLowerCase();
        if (contentEncoding != null &&
            contentEncoding.isNotEmpty &&
            contentEncoding != 'identity') {
          throw const PublicCatalogArtworkException(
            'encoded_response',
            'Compressed catalog artwork responses are not accepted.',
          );
        }
        final advertisedLength = response.contentLength;
        if (advertisedLength == 0 || advertisedLength > maxBytes) {
          throw const PublicCatalogArtworkException(
            'invalid_size',
            'Catalog artwork was empty or exceeded the size limit.',
          );
        }
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(requestTimeout)) {
          if (buffer.length + chunk.length > maxBytes) {
            throw const PublicCatalogArtworkException(
              'invalid_size',
              'Catalog artwork exceeded the size limit.',
            );
          }
          buffer.add(chunk);
        }
        return PublicCatalogArtwork.validate(
          bytes: buffer.takeBytes(),
          contentType: response.headers.contentType?.mimeType,
          maxBytes: maxBytes,
        );
      } on PublicCatalogArtworkException {
        rethrow;
      } on TimeoutException {
        throw const PublicCatalogArtworkException(
          'timeout',
          'Catalog artwork timed out.',
        );
      } on HandshakeException {
        throw const PublicCatalogArtworkException(
          'tls_error',
          'Catalog artwork failed TLS validation.',
        );
      } on SocketException {
        throw const PublicCatalogArtworkException(
          'network_error',
          'Catalog artwork could not be reached.',
        );
      } finally {
        client.close(force: true);
      }
    }
  }
}

Future<void> validatePublicArtworkUri(
  Uri uri, {
  PublicHostResolver? resolveHost,
}) async {
  validatePublicArtworkUriSyntax(uri);
  final host = uri.host.trim().toLowerCase();
  final literal = InternetAddress.tryParse(host);
  final addresses = literal == null
      ? await (resolveHost ?? InternetAddress.lookup)(host)
      : <InternetAddress>[literal];
  if (addresses.isEmpty || addresses.any((address) => !_isPublic(address))) {
    throw const PublicCatalogArtworkException(
      'private_host',
      'Catalog artwork resolved to a private or reserved address.',
    );
  }
}

/// Performs the credential/scheme/hostname checks without network access.
/// This is also used by the persistence service so injected test transports
/// cannot accidentally weaken the production URL boundary.
void validatePublicArtworkUriSyntax(Uri uri) {
  final host = uri.host.trim().toLowerCase();
  if (uri.scheme.toLowerCase() != 'https' ||
      !uri.isAbsolute ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      host.isEmpty ||
      uri.port != 443 ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      _containsCredentialQuery(uri)) {
    throw const PublicCatalogArtworkException(
      'unsafe_uri',
      'Catalog artwork must be a credential-free public HTTPS URL.',
    );
  }
}

bool _containsCredentialQuery(Uri uri) {
  const sensitiveNames = <String>{
    'access_token',
    'api_key',
    'apikey',
    'auth',
    'authorization',
    'credential',
    'key',
    'password',
    'secret',
    'sig',
    'signature',
    'token',
  };
  return uri.queryParameters.keys.any(
    (key) => sensitiveNames.contains(key.trim().toLowerCase()),
  );
}

bool _isPublic(InternetAddress address) {
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
    final a = raw[0];
    final b = raw[1];
    final c = raw[2];
    if (a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 0) ||
        (a == 192 && b == 168) ||
        (a == 198 && (b == 18 || b == 19)) ||
        (a == 198 && b == 51 && c == 100) ||
        (a == 203 && b == 0 && c == 113)) {
      return false;
    }
    return true;
  }
  if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
    final allZero = raw.every((byte) => byte == 0);
    final loopback = raw.take(15).every((byte) => byte == 0) && raw[15] == 1;
    final uniqueLocal = (raw[0] & 0xfe) == 0xfc;
    final linkLocal = raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80;
    final multicast = raw[0] == 0xff;
    final documentation =
        raw[0] == 0x20 && raw[1] == 0x01 && raw[2] == 0x0d && raw[3] == 0xb8;
    final ipv4Mapped =
        raw.take(10).every((byte) => byte == 0) &&
        raw[10] == 0xff &&
        raw[11] == 0xff;
    if (ipv4Mapped) {
      return _isPublic(InternetAddress.fromRawAddress(raw.sublist(12)));
    }
    return !allZero &&
        !loopback &&
        !uniqueLocal &&
        !linkLocal &&
        !multicast &&
        !documentation;
  }
  return false;
}

bool _isRedirect(int statusCode) =>
    statusCode == HttpStatus.movedPermanently ||
    statusCode == HttpStatus.found ||
    statusCode == HttpStatus.seeOther ||
    statusCode == HttpStatus.temporaryRedirect ||
    statusCode == HttpStatus.permanentRedirect;

(String, String)? _detectImage(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return ('image/png', 'png');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return ('image/jpeg', 'jpg');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return ('image/webp', 'webp');
  }
  if (bytes.length >= 6) {
    final signature = String.fromCharCodes(bytes.take(6));
    if (signature == 'GIF87a' || signature == 'GIF89a') {
      return ('image/gif', 'gif');
    }
  }
  return null;
}

bool _mimeMatches(String advertised, String detected) {
  if (advertised == detected) return true;
  return detected == 'image/jpeg' &&
      (advertised == 'image/jpg' || advertised == 'image/pjpeg');
}
