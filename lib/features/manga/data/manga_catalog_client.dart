// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/manga/data/manga_parse_support.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/data/opds1_catalog_parser.dart';
import 'package:anime_tv/features/manga/data/opds2_catalog_parser.dart';
import 'package:anime_tv/features/manga/data/teto_manga_repository_parser.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/domain/repository_format.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const int maximumMangaCatalogResponseBytes = 2 * 1024 * 1024;

typedef MangaPublicTargetValidator = Future<void> Function(Uri uri);

sealed class MangaFetchedDocument {
  const MangaFetchedDocument({
    required this.requestedUri,
    required this.finalUri,
    required this.mediaType,
  });

  final Uri requestedUri;
  final Uri finalUri;
  final String? mediaType;
}

final class MangaFetchedFeed extends MangaFetchedDocument {
  const MangaFetchedFeed({
    required super.requestedUri,
    required super.finalUri,
    required super.mediaType,
    required this.feed,
  });

  final MangaCatalogFeed feed;
}

final class MangaFetchedRepository extends MangaFetchedDocument {
  const MangaFetchedRepository({
    required super.requestedUri,
    required super.finalUri,
    required super.mediaType,
    required this.repository,
  });

  final MangaRepositoryManifest repository;
}

class MangaSourceCredential {
  const MangaSourceCredential._({
    required this.kind,
    required this.secret,
    this.username,
    this.headerName,
  });

  factory MangaSourceCredential.basic({
    required String username,
    required String password,
  }) => MangaSourceCredential._(
    kind: MangaSourceAuthenticationKind.basic,
    username: username,
    secret: password,
  );

  factory MangaSourceCredential.bearer(String token) => MangaSourceCredential._(
    kind: MangaSourceAuthenticationKind.bearer,
    secret: token,
  );

  factory MangaSourceCredential.apiKey({
    required String headerName,
    required String value,
  }) => MangaSourceCredential._(
    kind: MangaSourceAuthenticationKind.apiKey,
    headerName: headerName,
    secret: value,
  );

  final MangaSourceAuthenticationKind kind;
  final String? username;
  final String? headerName;
  final String secret;
}

/// Keeps source secrets solely in Android/iOS protected storage.
///
/// The SQLite manga source row intentionally contains no authentication
/// column. Callers identify credentials by the same stable source id used by
/// the source row, but never receive a database-serializable representation.
class MangaSourceCredentialStore {
  const MangaSourceCredentialStore(this._storage);

  static const _prefix = 'manga_source_credential_v1_';
  static const _maximumCredentialCharacters = 8192;

  final FlutterSecureStorage _storage;

  Future<void> write(String sourceId, MangaSourceCredential credential) async {
    final safeId = _validatedSourceId(sourceId);
    final normalized = _validateCredential(credential);
    final payload = jsonEncode(<String, Object?>{
      'version': 1,
      'kind': normalized.kind.name,
      if (normalized.username != null) 'username': normalized.username,
      if (normalized.headerName != null) 'headerName': normalized.headerName,
      'secret': normalized.secret,
    });
    if (payload.length > _maximumCredentialCharacters) {
      throw const FormatException('Manga source credential is too large.');
    }
    await _storage.write(key: '$_prefix$safeId', value: payload);
  }

  Future<MangaSourceCredential?> read(String sourceId) async {
    final safeId = _validatedSourceId(sourceId);
    final payload = await _storage.read(key: '$_prefix$safeId');
    if (payload == null) return null;
    if (payload.isEmpty || payload.length > _maximumCredentialCharacters) {
      throw const FormatException('Stored manga source credential is invalid.');
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException('Stored manga source credential is invalid.');
    }
    final values = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw const FormatException(
          'Stored manga source credential is invalid.',
        );
      }
      values[entry.key as String] = entry.value;
    }
    if (values.length > 5 ||
        values.keys.any(
          (key) => !const <String>{
            'version',
            'kind',
            'username',
            'headerName',
            'secret',
          }.contains(key),
        ) ||
        values['version'] != 1) {
      throw const FormatException('Stored manga source credential is invalid.');
    }
    final secret = values['secret'];
    final kind = values['kind'];
    if (secret is! String || kind is! String) {
      throw const FormatException('Stored manga source credential is invalid.');
    }
    final credential = switch (kind) {
      'basic' => MangaSourceCredential.basic(
        username: values['username'] is String
            ? values['username']! as String
            : '',
        password: secret,
      ),
      'bearer' => MangaSourceCredential.bearer(secret),
      'apiKey' => MangaSourceCredential.apiKey(
        headerName: values['headerName'] is String
            ? values['headerName']! as String
            : '',
        value: secret,
      ),
      _ => throw const FormatException(
        'Stored manga source credential kind is invalid.',
      ),
    };
    return _validateCredential(credential);
  }

  Future<void> delete(String sourceId) =>
      _storage.delete(key: '$_prefix${_validatedSourceId(sourceId)}');

  Future<Map<String, String>> requestHeaders(String sourceId) async {
    final credential = await read(sourceId);
    if (credential == null) return const <String, String>{};
    return switch (credential.kind) {
      MangaSourceAuthenticationKind.basic => <String, String>{
        HttpHeaders.authorizationHeader:
            'Basic ${base64Encode(utf8.encode('${credential.username}:${credential.secret}'))}',
      },
      MangaSourceAuthenticationKind.bearer => <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${credential.secret}',
      },
      MangaSourceAuthenticationKind.apiKey => <String, String>{
        credential.headerName!: credential.secret,
      },
      MangaSourceAuthenticationKind.none => const <String, String>{},
    };
  }
}

class MangaCatalogClient {
  MangaCatalogClient({
    required MangaSourceCredentialStore credentials,
    Dio? dio,
    MangaPublicTargetValidator? validateTarget,
    this.connectTimeout = const Duration(seconds: 8),
    this.receiveTimeout = const Duration(seconds: 12),
    this.maximumResponseBytes = maximumMangaCatalogResponseBytes,
    this.maximumRedirects = 5,
    Opds1CatalogParser opds1Parser = const Opds1CatalogParser(),
    Opds2CatalogParser opds2Parser = const Opds2CatalogParser(),
    TetoMangaRepositoryParser repositoryParser =
        const TetoMangaRepositoryParser(),
  }) : _credentials = credentials,
       _validateTarget = validateTarget ?? _validatePublicTarget,
       _opds1Parser = opds1Parser,
       _opds2Parser = opds2Parser,
       _repositoryParser = repositoryParser,
       _dio =
           dio ??
           createPinnedPublicHttpsDio(
             BaseOptions(
               connectTimeout: connectTimeout,
               receiveTimeout: receiveTimeout,
               sendTimeout: connectTimeout,
               responseType: ResponseType.stream,
               followRedirects: false,
               persistentConnection: false,
               headers: const <String, Object>{
                 HttpHeaders.userAgentHeader: 'TetoTV/2 manga-catalog',
                 HttpHeaders.acceptHeader:
                     'application/opds+json, application/atom+xml, application/json;q=0.9',
               },
             ),
           ) {
    if (connectTimeout <= Duration.zero || receiveTimeout <= Duration.zero) {
      throw ArgumentError('Manga catalog timeouts must be positive.');
    }
    if (maximumResponseBytes < 1 ||
        maximumResponseBytes > maximumMangaCatalogResponseBytes) {
      throw ArgumentError.value(
        maximumResponseBytes,
        'maximumResponseBytes',
        'Must be between 1 byte and 2 MiB.',
      );
    }
    if (maximumRedirects < 0 || maximumRedirects > 8) {
      throw ArgumentError.value(maximumRedirects, 'maximumRedirects');
    }
    _dio.options.connectTimeout = connectTimeout;
    _dio.options.receiveTimeout = receiveTimeout;
    _dio.options.sendTimeout = connectTimeout;
  }

  final MangaSourceCredentialStore _credentials;
  final Dio _dio;
  final MangaPublicTargetValidator _validateTarget;
  final Opds1CatalogParser _opds1Parser;
  final Opds2CatalogParser _opds2Parser;
  final TetoMangaRepositoryParser _repositoryParser;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final int maximumResponseBytes;
  final int maximumRedirects;

  Future<MangaFetchedDocument> fetch(
    Uri uri, {
    String? sourceId,
    MangaSourceProtocol? protocolHint,
  }) async {
    final requestedUri = requireMangaPublicHttpsUri(
      uri.toString(),
      field: 'Manga source URL',
    );
    final compatibility = inspectExtensionRepositoryUri(requestedUri);
    if (compatibility.isRejected) {
      throw FormatException(compatibility.rejectionMessage!);
    }
    final headers = sourceId == null
        ? const <String, String>{}
        : await _credentials.requestHeaders(sourceId);
    final response = await _getText(requestedUri, headers: headers);
    return _parse(
      response.payload,
      requestedUri: requestedUri,
      finalUri: response.finalUri,
      mediaType: response.mediaType,
      protocolHint: protocolHint,
    );
  }

  Future<_MangaTextResponse> _getText(
    Uri uri, {
    required Map<String, String> headers,
  }) async {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      final compatibility = inspectExtensionRepositoryUri(current);
      if (compatibility.isRejected) {
        throw FormatException(compatibility.rejectionMessage!);
      }
      await _validateTarget(current).timeout(connectTimeout);
      final response = await _dio
          .get<ResponseBody>(
            current.toString(),
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              persistentConnection: false,
              headers: headers,
              validateStatus: (_) => true,
            ),
          )
          .timeout(connectTimeout + receiveTimeout);
      final status = response.statusCode ?? 0;
      if (_redirectStatuses.contains(status)) {
        if (redirects >= maximumRedirects) {
          throw const FormatException(
            'Manga source redirected too many times.',
          );
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.trim().isEmpty) {
          throw const FormatException('Manga source redirect has no location.');
        }
        await _cancelBody(response.data);
        final redirected = resolveMangaPublicHttpsReference(
          current,
          location,
          field: 'Manga source redirect',
        );
        if (headers.isNotEmpty && !_sameOrigin(uri, redirected)) {
          throw const FormatException(
            'Authenticated manga sources cannot redirect to another origin.',
          );
        }
        current = redirected;
        continue;
      }
      if (status < 200 || status >= 300) {
        await _cancelBody(response.data);
        throw MangaCatalogHttpException(status);
      }
      await _validateTarget(current).timeout(connectTimeout);
      final body = response.data;
      if (body == null) {
        throw const FormatException('Manga source returned an empty response.');
      }
      final declaredLength = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength > maximumResponseBytes) {
        await _cancelBody(body);
        throw const FormatException('Manga source response exceeds 2 MiB.');
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in body.stream.timeout(receiveTimeout)) {
        length += chunk.length;
        if (length > maximumResponseBytes) {
          throw const FormatException('Manga source response exceeds 2 MiB.');
        }
        bytes.add(chunk);
      }
      var payload = utf8.decode(bytes.takeBytes(), allowMalformed: false);
      if (payload.startsWith('\uFEFF')) payload = payload.substring(1);
      if (payload.trim().isEmpty) {
        throw const FormatException('Manga source returned an empty response.');
      }
      return _MangaTextResponse(
        finalUri: current,
        mediaType: _mediaType(
          response.headers.value(HttpHeaders.contentTypeHeader),
        ),
        payload: payload,
      );
    }
  }

  MangaFetchedDocument _parse(
    String payload, {
    required Uri requestedUri,
    required Uri finalUri,
    required String? mediaType,
    required MangaSourceProtocol? protocolHint,
  }) {
    if (protocolHint == MangaSourceProtocol.opds1) {
      return MangaFetchedFeed(
        requestedUri: requestedUri,
        finalUri: finalUri,
        mediaType: mediaType,
        feed: _opds1Parser.parse(payload, documentUri: finalUri),
      );
    }
    if (protocolHint == MangaSourceProtocol.opds2) {
      return MangaFetchedFeed(
        requestedUri: requestedUri,
        finalUri: finalUri,
        mediaType: mediaType,
        feed: _opds2Parser.parse(payload, documentUri: finalUri),
      );
    }

    final trimmed = payload.trimLeft();
    if (trimmed.startsWith('<') || mediaType == 'application/atom+xml') {
      return MangaFetchedFeed(
        requestedUri: requestedUri,
        finalUri: finalUri,
        mediaType: mediaType,
        feed: _opds1Parser.parse(payload, documentUri: finalUri),
      );
    }
    final decoded = decodeBoundedJson(
      payload,
      const MangaParseLimits(),
      format: 'Manga source',
    );
    final compatibility = inspectExtensionRepositoryJson(decoded);
    if (compatibility.isRejected) {
      throw FormatException(compatibility.rejectionMessage!);
    }
    final root = requiredStringMap(decoded, field: 'Manga source');
    if (root['format'] == MangaRepositoryManifest.format) {
      return MangaFetchedRepository(
        requestedUri: requestedUri,
        finalUri: finalUri,
        mediaType: mediaType,
        repository: _repositoryParser.parse(payload, documentUri: finalUri),
      );
    }
    return MangaFetchedFeed(
      requestedUri: requestedUri,
      finalUri: finalUri,
      mediaType: mediaType,
      feed: _opds2Parser.parse(payload, documentUri: finalUri),
    );
  }
}

class MangaCatalogHttpException implements Exception {
  const MangaCatalogHttpException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Manga catalog request failed (HTTP $statusCode).';
}

class _MangaTextResponse {
  const _MangaTextResponse({
    required this.finalUri,
    required this.mediaType,
    required this.payload,
  });

  final Uri finalUri;
  final String? mediaType;
  final String payload;
}

const Set<int> _redirectStatuses = <int>{301, 302, 303, 307, 308};
const Set<String> _blockedCredentialHeaders = <String>{
  'authorization',
  'cookie',
  'host',
  'origin',
  'referer',
  'proxy-authorization',
  'proxy-connection',
  'transfer-encoding',
};
final RegExp _sourceIdPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$',
);
final RegExp _headerNamePattern = RegExp(r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]+$");

Future<void> _validatePublicTarget(Uri uri) => validatePublicNetworkTarget(uri);

String _validatedSourceId(String value) {
  final normalized = value.trim();
  if (!_sourceIdPattern.hasMatch(normalized)) {
    throw const FormatException('Manga source id is invalid.');
  }
  return normalized;
}

MangaSourceCredential _validateCredential(MangaSourceCredential credential) {
  if (credential.kind == MangaSourceAuthenticationKind.none ||
      credential.secret.isEmpty ||
      credential.secret.length > 4096 ||
      credential.secret.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const FormatException('Manga source credential is invalid.');
  }
  if (credential.kind == MangaSourceAuthenticationKind.basic) {
    final username = credential.username;
    if (username == null ||
        username.isEmpty ||
        username.length > 512 ||
        username.contains(':') ||
        username.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const FormatException('Manga source username is invalid.');
    }
  }
  if (credential.kind == MangaSourceAuthenticationKind.apiKey) {
    final header = credential.headerName;
    if (header == null ||
        !_headerNamePattern.hasMatch(header) ||
        _blockedCredentialHeaders.contains(header.toLowerCase())) {
      throw const FormatException('Manga source API-key header is invalid.');
    }
  }
  return credential;
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme == second.scheme &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

Future<void> _cancelBody(ResponseBody? body) async {
  if (body == null) return;
  final subscription = body.stream.listen((_) {});
  await subscription.cancel();
}

String? _mediaType(String? contentType) {
  if (contentType == null) return null;
  final value = contentType.split(';').first.trim().toLowerCase();
  return value.isEmpty ? null : value;
}
