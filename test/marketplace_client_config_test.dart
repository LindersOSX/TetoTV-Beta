import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('applies marketplace defaults to Seanime payload placeholders', () {
    const payload = '''
class Provider {
  baseUrl = "{{api}}";
  blobDomain = "{{blobDomain}}";
}
''';

    final configured = applyAddonConfigDefaults(payload, const {
      'api': 'https://api.provider.example',
      'blobDomain': 'https://media.provider.example',
    });

    expect(configured, contains('baseUrl = "https://api.provider.example"'));
    expect(
      configured,
      contains('blobDomain = "https://media.provider.example"'),
    );
    expect(configured, isNot(contains('{{')));
  });

  test('rejects configuration expansion beyond the addon payload limit', () {
    final payload =
        'class Provider {}\n${List.filled(100000, '{{api}}').join()}';

    expect(
      () => applyAddonConfigDefaults(payload, {
        'api': 'https://${List.filled(2040, 'a').join()}',
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'follows a safe manifest redirect and resolves its relative payload',
    () async {
      final adapter = _MarketplaceAdapter((request) {
        if (request.uri.host == 'catalog.example') {
          return _redirect('https://cdn.example/releases/v2/manifest.json');
        }
        if (request.uri.path.endsWith('/manifest.json')) {
          return _body({
            'id': 'redirect-provider',
            'name': 'Redirect provider',
            'type': 'onlinestream-provider',
            'language': 'javascript',
            'manifestURI': './manifest.json',
            'payloadURI': './provider.js',
          });
        }
        return ResponseBody.fromString('class Provider {}', 200);
      });
      final validated = <Uri>[];
      final client = _client(
        adapter,
        targetValidator: (uri) async => validated.add(uri),
      );

      final installed = await client.downloadAddon(_summary());

      expect(installed.payload, 'class Provider {}');
      expect(
        installed.manifest.payloadUri,
        Uri.parse('https://cdn.example/releases/v2/provider.js'),
      );
      expect(adapter.requests.map((request) => request.uri).toList(), [
        Uri.parse('https://catalog.example/latest/manifest.json'),
        Uri.parse('https://cdn.example/releases/v2/manifest.json'),
        Uri.parse('https://cdn.example/releases/v2/provider.js'),
      ]);
      expect(validated, hasLength(3));
      expect(
        adapter.requests.every((request) => !request.followRedirects),
        isTrue,
      );
    },
  );

  test(
    'resolves catalog entries from the final safe redirect location',
    () async {
      final adapter = _MarketplaceAdapter((request) {
        if (request.uri.host == 'catalog.example') {
          return _redirect('https://cdn.example/releases/v3/Main.json');
        }
        return _body([
          {
            'id': 'redirected-catalog-provider',
            'name': 'Redirected catalog provider',
            'type': 'onlinestream-provider',
            'language': 'javascript',
            'manifestURI': './manifest.json',
          },
        ]);
      });
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await database.execute('''
        CREATE TABLE marketplace_cache (
          repository_url TEXT PRIMARY KEY,
          payload_json TEXT NOT NULL,
          resource_base_url TEXT,
          fetched_at INTEGER NOT NULL
        )
      ''');
      final client = _client(
        adapter,
        store: AddonStore(TetoTvDatabase.forTesting(database)),
      );
      final repository = AddonRepository(
        url: 'https://catalog.example/latest/Main.json',
        updatedAt: DateTime.utc(2026, 9, 7),
      );

      final catalog = await client.catalog(repository);

      expect(catalog, hasLength(1));
      expect(catalog.single.repositoryUrl, repository.url);
      expect(
        catalog.single.manifestUri,
        Uri.parse('https://cdn.example/releases/v3/manifest.json'),
      );

      final cacheOnlyAdapter = _MarketplaceAdapter((_) {
        throw StateError('A cache hit must not access the network.');
      });
      final cachedClient = _client(
        cacheOnlyAdapter,
        store: AddonStore(TetoTvDatabase.forTesting(database)),
      );
      final cachedCatalog = await cachedClient.catalog(repository);

      expect(cacheOnlyAdapter.requests, isEmpty);
      expect(
        cachedCatalog.single.manifestUri,
        Uri.parse('https://cdn.example/releases/v3/manifest.json'),
      );
    },
  );

  test('rejects an HTTPS downgrade redirect before requesting it', () async {
    final adapter = _MarketplaceAdapter(
      (_) => _redirect('http://cdn.example/provider/manifest.json'),
    );
    final client = _client(adapter);

    await expectLater(
      client.manifest(_summary()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('public HTTPS'),
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('accepts a named implementation exported as global Provider', () async {
    final adapter = _MarketplaceAdapter((request) {
      if (request.uri.path.endsWith('manifest.json')) {
        return _body({
          'id': 'redirect-provider',
          'name': 'Redirect provider',
          'type': 'onlinestream-provider',
          'language': 'javascript',
          'manifestURI': './manifest.json',
          'payloadURI': './provider.js',
        });
      }
      return ResponseBody.fromString(
        'class ProviderImpl {}\nglobalThis.Provider = ProviderImpl;',
        200,
      );
    });
    final client = _client(adapter);

    final installed = await client.downloadAddon(_summary());

    expect(installed.payload, contains('globalThis.Provider'));
  });

  test('does not accept a fake Provider declaration in a comment', () async {
    final adapter = _MarketplaceAdapter((request) {
      if (request.uri.path.endsWith('manifest.json')) {
        return _body({
          'id': 'redirect-provider',
          'name': 'Redirect provider',
          'type': 'onlinestream-provider',
          'language': 'javascript',
          'manifestURI': './manifest.json',
          'payloadURI': './provider.js',
        });
      }
      return ResponseBody.fromString(
        '// class Provider {}\nconst nope = 1;',
        200,
      );
    });
    final client = _client(adapter);

    await expectLater(
      client.downloadAddon(_summary()),
      throwsA(isA<FormatException>()),
    );
  });
}

MarketplaceAddon _summary() => MarketplaceAddon(
  id: 'redirect-provider',
  name: 'Redirect provider',
  description: '',
  author: 'Tests',
  manifestUri: Uri.parse('https://catalog.example/latest/manifest.json'),
  repositoryUrl: 'https://catalog.example/marketplace.json',
  language: 'javascript',
  type: 'onlinestream-provider',
  locale: 'en',
);

MarketplaceClient _client(
  _MarketplaceAdapter adapter, {
  Future<void> Function(Uri uri)? targetValidator,
  AddonStore? store,
}) {
  final dio = Dio(BaseOptions(followRedirects: false));
  dio.httpClientAdapter = adapter;
  return MarketplaceClient(
    store ?? AddonStore(TetoTvDatabase.instance),
    dio: dio,
    targetValidator: targetValidator ?? (_) async {},
  );
}

ResponseBody _body(Object value) =>
    ResponseBody.fromString(jsonEncode(value), 200);

ResponseBody _redirect(String location) => ResponseBody.fromBytes(
  const [],
  302,
  headers: {
    'location': [location],
  },
);

class _MarketplaceAdapter implements HttpClientAdapter {
  _MarketplaceAdapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions request) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await respond(options);
  }

  @override
  void close({bool force = false}) {}
}
