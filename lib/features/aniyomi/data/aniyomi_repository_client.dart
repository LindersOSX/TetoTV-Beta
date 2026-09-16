import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_repository_parser.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// No seed catalogs, automatic updates, cookies or shared account headers.
class AniyomiRepositoryClient {
  AniyomiRepositoryClient({Dio? dio})
    : _dio =
          dio ??
          createPinnedPublicHttpsDio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              followRedirects: false,
              validateStatus: (code) =>
                  code != null && code >= 200 && code < 400,
              headers: {'User-Agent': 'TetoTV/1 experimental-extensions'},
            ),
          );
  final Dio _dio;

  Future<AniyomiRepositoryDocument> catalog(
    Uri uri,
    AniyomiMediaKind kind, {
    required void Function() check,
  }) async {
    final bytes = await _read(uri, 4 * 1024 * 1024, check);
    check();
    var doc = parseAniyomiRepository(
      utf8.decode(bytes.$2),
      repositoryUri: bytes.$1,
      kind: kind,
    );
    if (doc.isMetadataOnly) {
      final index = doc.legacyIndexUri!;
      final content = await _read(index, 4 * 1024 * 1024, check);
      check();
      doc = parseAniyomiRepository(
        utf8.decode(content.$2),
        repositoryUri: content.$1,
        kind: kind,
      );
      if (doc.isMetadataOnly) throw const AniyomiFailure('invalid_repository');
    }
    return doc;
  }

  Future<Map<String, dynamic>> inspect(
    AniyomiRepositoryExtension extension,
    AniyomiGateway gateway,
  ) async {
    final access = gateway.generation;
    void check() => gateway.check(access);
    check();
    final bytes = await _read(extension.apkUri, 32 * 1024 * 1024, check);
    check();
    final cache = await getTemporaryDirectory();
    check();
    final dir = await cache.createTemp('aniyomi-inspect-');
    final file = File('${dir.path}${Platform.pathSeparator}extension.apk');
    try {
      await file.writeAsBytes(bytes.$2, flush: true);
      check();
      final inspected = await gateway.call('inspect', {
        'path': file.path,
        'kind': extension.kind.name,
      });
      check();
      // Catalog claims must match the independently verified Android manifest.
      if (inspected['extensionId'] != extension.identityKey ||
          inspected['packageName'] != extension.packageName ||
          inspected['kind'] != extension.kind.name ||
          inspected['versionCode'] != extension.versionCode ||
          inspected['versionName'] != extension.versionName ||
          inspected['inspectionId'] is! String ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch('${inspected['certificateSha256']}')) {
        throw const AniyomiFailure('catalog_apk_mismatch');
      }
      return inspected;
    } finally {
      // Only this exact newly created temporary file and directory, not a
      // repository path or a recursive cache deletion.
      if (await file.exists()) await file.delete();
      if (await dir.exists()) await dir.delete();
    }
  }

  Future<(Uri, Uint8List)> _read(
    Uri initial,
    int limit,
    void Function() check,
  ) async {
    var uri = initial;
    final watch = Stopwatch()..start();
    for (var redirects = 0; redirects <= 4; redirects++) {
      check();
      if (safePublicHttpsUri(uri.toString()) == null || uri.hasFragment) {
        throw const AniyomiFailure('unsafe_resource');
      }
      final token = CancelToken();
      try {
        final response = await _dio.getUri<ResponseBody>(
          uri,
          options: Options(responseType: ResponseType.stream),
          cancelToken: token,
        );
        check();
        final body = response.data;
        if (body == null) throw const AniyomiFailure('download_failed');
        if (response.statusCode != 200) {
          token.cancel();
          final location = response.headers.value('location');
          if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
              location == null) {
            throw const AniyomiFailure('download_failed');
          }
          uri = uri.resolve(location);
          continue;
        }
        final bytes = BytesBuilder(copy: false);
        final declaredLength = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (declaredLength != null && declaredLength > limit) {
          throw const AniyomiFailure('download_limit_exceeded');
        }
        await for (final chunk in body.stream.timeout(
          const Duration(seconds: 12),
        )) {
          check();
          if (watch.elapsed > const Duration(seconds: 60) ||
              bytes.length + chunk.length > limit) {
            throw const AniyomiFailure('download_limit_exceeded');
          }
          bytes.add(chunk);
        }
        check();
        return (uri, bytes.takeBytes());
      } finally {
        token.cancel();
      }
    }
    throw const AniyomiFailure('redirect_limit_exceeded');
  }

  void dispose() => _dio.close(force: true);
}
