import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_repository_client.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativeChannel = MethodChannel('tetotv.test/aniyomi-repository-client');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
final _fingerprint = 'a' * 64;
final _uri = Uri.parse('https://catalog.example/repo/index.min.json');
Matcher _failure(String code) =>
    throwsA(isA<AniyomiFailure>().having((e) => e.code, 'code', code));

Map<String, Object?> _legacy() => {
  'name': 'Example',
  'pkg': 'com.example.extension',
  'apk': 'example.apk',
  'lang': 'en',
  'code': 1,
  'version': '14.1',
  'nsfw': 0,
  'sources': [],
};
ResponseBody _json(Object? value) =>
    ResponseBody.fromString(jsonEncode(value), 200);
ResponseBody _redirect(String location) => ResponseBody.fromBytes(
  [],
  302,
  headers: {
    'location': [location],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions options) respond;
  final requests = <RequestOptions>[];
  bool closed = false;
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
  void close({bool force = false}) {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory cache;
  late List<MethodCall> nativeCalls;
  late Future<Object?> Function(MethodCall) nativeResponse;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp(
      'tetotv-aniyomi-client-test-',
    );
    nativeCalls = [];
    nativeResponse = (_) async => {'ok': true, 'data': <String, dynamic>{}};
    messenger.setMockMethodCallHandler(_pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return cache.path;
      throw PlatformException(code: 'unexpected_test_path_method');
    });
    messenger.setMockMethodCallHandler(_nativeChannel, (call) async {
      nativeCalls.add(call);
      return await nativeResponse(call);
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(_nativeChannel, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    // Only this test-created empty directory; never recursively remove cache.
    expect(await cache.list().toList(), isEmpty);
    await cache.delete();
  });

  AniyomiRepositoryClient client(_Adapter adapter) {
    final dio = Dio(
      BaseOptions(
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );
    dio.httpClientAdapter = adapter;
    final result = AniyomiRepositoryClient(dio: dio);
    addTearDown(result.dispose);
    return result;
  }

  Future<AniyomiGateway> enabledGateway() async {
    final result = AniyomiGateway(
      channel: _nativeChannel,
      supportedPlatform: true,
    );
    addTearDown(result.dispose);
    await result.configure(true);
    return result;
  }

  AniyomiRepositoryExtension extension() => AniyomiRepositoryExtension(
    kind: AniyomiMediaKind.anime,
    packageName: 'com.example.extension',
    name: 'Example',
    versionName: '14.1',
    versionCode: 1,
    extensionLib: '14',
    apkUri: Uri.parse('https://download.example/example.apk'),
    iconUri: Uri.parse('https://download.example/icon.png'),
    language: 'en',
    isNsfw: false,
    isTorrent: false,
    sources: [],
  );

  Map<String, dynamic> inspection(AniyomiRepositoryExtension item) => {
    'extensionId': item.identityKey,
    'packageName': item.packageName,
    'kind': item.kind.name,
    'versionCode': item.versionCode,
    'versionName': item.versionName,
    'inspectionId': 'fixture-inspection',
    'certificateSha256': _fingerprint,
  };

  test(
    'catalog uses fake transport only and never downloads or installs APKs',
    () async {
      final adapter = _Adapter((_) => _json([_legacy()]));
      final result = await client(
        adapter,
      ).catalog(_uri, AniyomiMediaKind.anime, check: () {});
      expect(result.extensions.single.packageName, 'com.example.extension');
      expect(adapter.requests.single.uri, _uri);
      expect(adapter.requests.single.followRedirects, isFalse);
      expect(
        adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(nativeCalls, isEmpty);
    },
  );

  test(
    'public HTTPS redirect changes the base used for relative APK resources',
    () async {
      final adapter = _Adapter(
        (options) => options.uri.host == 'catalog.example'
            ? _redirect('https://cdn.example/new/index.min.json')
            : _json([_legacy()]),
      );
      final result = await client(
        adapter,
      ).catalog(_uri, AniyomiMediaKind.anime, check: () {});
      expect(
        result.repositoryUri.toString(),
        'https://cdn.example/new/index.min.json',
      );
      expect(
        result.extensions.single.apkUri.toString(),
        'https://cdn.example/new/apk/example.apk',
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'metadata redirect resolves its follow-up index at the final location',
    () async {
      final adapter = _Adapter((options) {
        if (options.uri.host == 'catalog.example') {
          return _redirect('https://cdn.example/new/repo.json');
        }
        if (options.uri.path.endsWith('repo.json')) {
          return _json({
            'meta': {
              'name': 'Example repo',
              'shortName': 'Ex',
              'website': 'https://catalog.example',
              'signingKeyFingerprint': _fingerprint,
            },
          });
        }
        return _json([_legacy()]);
      });
      final result = await client(adapter).catalog(
        Uri.parse('https://catalog.example/repo.json'),
        AniyomiMediaKind.anime,
        check: () {},
      );
      expect(adapter.requests.map((request) => request.uri.toString()), [
        'https://catalog.example/repo.json',
        'https://cdn.example/new/repo.json',
        'https://cdn.example/new/index.min.json',
      ]);
      expect(result.isMetadataOnly, isFalse);
      expect(nativeCalls, isEmpty);
    },
  );

  test(
    'rejects private, insecure and credential-bearing initial URLs before transport',
    () async {
      final adapter = _Adapter((_) => _json([]));
      final repository = client(adapter);
      for (final url in [
        'http://catalog.example/index.json',
        'https://127.0.0.1/index.json',
        'https://[::1]/index.json',
        'https://user:pass@catalog.example/index.json',
      ]) {
        await expectLater(
          repository.catalog(
            Uri.parse(url),
            AniyomiMediaKind.anime,
            check: () {},
          ),
          _failure('unsafe_resource'),
        );
      }
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'revalidates every redirect without following unsafe locations',
    () async {
      for (final target in [
        'http://cdn.example/index.json',
        'https://192.168.1.1/index.json',
        'file:///data/private',
        'https://user:password@cdn.example/index.json',
        'https://cdn.example/index.json#fragment',
      ]) {
        final adapter = _Adapter((_) => _redirect(target));
        await expectLater(
          client(adapter).catalog(_uri, AniyomiMediaKind.anime, check: () {}),
          _failure('unsafe_resource'),
        );
        expect(adapter.requests, hasLength(1), reason: target);
      }
    },
  );

  test(
    'redirect loop is bounded and invalid redirect status does not become a catalog',
    () async {
      final loop = _Adapter((_) => _redirect('/loop.json'));
      await expectLater(
        client(loop).catalog(_uri, AniyomiMediaKind.anime, check: () {}),
        _failure('redirect_limit_exceeded'),
      );
      expect(loop.requests, hasLength(5));
      final invalid = _Adapter((_) => ResponseBody.fromString('', 304));
      await expectLater(
        client(invalid).catalog(_uri, AniyomiMediaKind.anime, check: () {}),
        _failure('download_failed'),
      );
    },
  );

  test('catalog streaming size limit stops oversized fake bytes', () async {
    final adapter = _Adapter(
      (_) => ResponseBody.fromBytes(Uint8List(4 * 1024 * 1024 + 1), 200),
    );
    await expectLater(
      client(adapter).catalog(_uri, AniyomiMediaKind.anime, check: () {}),
      _failure('download_limit_exceeded'),
    );
    expect(nativeCalls, isEmpty);
  });

  test(
    'revocation checkpoint stops a response before parse or metadata follow-up',
    () async {
      var enabled = true;
      final adapter = _Adapter((_) {
        enabled = false;
        return _json([]);
      });
      await expectLater(
        client(adapter).catalog(
          _uri,
          AniyomiMediaKind.anime,
          check: () {
            if (!enabled) {
              throw const AniyomiFailure('developer_access_revoked');
            }
          },
        ),
        _failure('developer_access_revoked'),
      );
      expect(adapter.requests, hasLength(1));
      expect(nativeCalls, isEmpty);
    },
  );

  test('disabled inspection does not start a fake APK request', () async {
    final adapter = _Adapter((_) => ResponseBody.fromBytes([1, 2, 3], 200));
    final bridge = AniyomiGateway(
      channel: _nativeChannel,
      supportedPlatform: true,
    );
    addTearDown(bridge.dispose);
    await expectLater(
      client(adapter).inspect(extension(), bridge),
      _failure('developer_access_revoked'),
    );
    expect(adapter.requests, isEmpty);
    expect(nativeCalls, isEmpty);
  });

  test(
    'inspection sends only temporary fixture bytes and removes them afterwards',
    () async {
      final item = extension();
      final bridge = await enabledGateway();
      String? temporaryPath;
      nativeResponse = (call) async {
        if (call.method != 'inspect') return {'ok': true, 'data': {}};
        temporaryPath = (call.arguments as Map)['path'] as String;
        expect(temporaryPath, startsWith(cache.path));
        expect(await File(temporaryPath!).readAsBytes(), [1, 2, 3, 4]);
        return {'ok': true, 'data': inspection(item)};
      };
      final adapter = _Adapter(
        (_) => ResponseBody.fromBytes([1, 2, 3, 4], 200),
      );
      final result = await client(adapter).inspect(item, bridge);
      expect(result['certificateSha256'], _fingerprint);
      expect(await File(temporaryPath!).exists(), isFalse);
      expect(nativeCalls.map((call) => call.method), ['configure', 'inspect']);
    },
  );

  test(
    'manifest mismatch and malformed certificate identity reject native inspection',
    () async {
      final item = extension();
      final bridge = await enabledGateway();
      final repository = client(
        _Adapter((_) => ResponseBody.fromBytes([1, 2, 3, 4], 200)),
      );
      for (final change in <Map<String, dynamic>>[
        {'extensionId': 'wrong'},
        {'packageName': 'com.other'},
        {'kind': 'manga'},
        {'versionCode': 2},
        {'versionName': '14.2'},
        {'inspectionId': null},
        {'certificateSha256': 'not-a-certificate'},
        {'certificateSha256': 'f' * 63},
      ]) {
        nativeResponse = (call) async => call.method == 'inspect'
            ? {'ok': true, 'data': inspection(item)..addAll(change)}
            : {'ok': true, 'data': {}};
        await expectLater(
          repository.inspect(item, bridge),
          _failure('catalog_apk_mismatch'),
          reason: '$change',
        );
        expect(await cache.list().toList(), isEmpty);
      }
      expect(nativeCalls.where((call) => call.method == 'approve'), isEmpty);
    },
  );

  test(
    'native signature failure is propagated without approving or retaining fixture files',
    () async {
      final bridge = await enabledGateway();
      nativeResponse = (call) async => call.method == 'inspect'
          ? {'ok': false, 'error': 'apk_signature_invalid_or_multisigner'}
          : {'ok': true, 'data': {}};
      final repository = client(
        _Adapter((_) => ResponseBody.fromBytes([1, 2, 3], 200)),
      );
      await expectLater(
        repository.inspect(extension(), bridge),
        _failure('apk_signature_invalid_or_multisigner'),
      );
      expect(await cache.list().toList(), isEmpty);
      expect(nativeCalls.where((call) => call.method == 'approve'), isEmpty);
    },
  );

  test(
    'revocation during native inspection discards success and cleans fixture files',
    () async {
      final item = extension();
      final bridge = await enabledGateway();
      final started = Completer<void>();
      final pending = Completer<Object?>();
      nativeResponse = (call) async {
        if (call.method == 'inspect') {
          started.complete();
          return await pending.future;
        }
        return {'ok': true, 'data': {}};
      };
      final work = client(
        _Adapter((_) => ResponseBody.fromBytes([1, 2, 3], 200)),
      ).inspect(item, bridge);
      final checked = expectLater(work, _failure('developer_access_revoked'));
      await started.future;
      await bridge.configure(false);
      pending.complete({'ok': true, 'data': inspection(item)});
      await checked;
      expect(await cache.list().toList(), isEmpty);
    },
  );

  test(
    'APK byte limit rejects oversized fake payload before temporary files or inspection',
    () async {
      final bridge = await enabledGateway();
      final adapter = _Adapter(
        (_) => ResponseBody.fromBytes(Uint8List(32 * 1024 * 1024 + 1), 200),
      );
      await expectLater(
        client(adapter).inspect(extension(), bridge),
        _failure('download_limit_exceeded'),
      );
      expect(nativeCalls.where((call) => call.method == 'inspect'), isEmpty);
      expect(await cache.list().toList(), isEmpty);
    },
  );
}
