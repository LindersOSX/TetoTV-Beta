import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/aniyomi/application/aniyomi_controller.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_repository_client.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('tetotv.test/aniyomi-controller');
const _productionChannel = MethodChannel('dev.animetv.anime_tv/aniyomi');
const _storageKey = 'aniyomi_experimental_repositories_v1';
const _storage = FlutterSecureStorage();
final _repo = Uri.parse('https://catalog.example/index.min.json');

Map<String, dynamic> _ok([Map<String, dynamic> data = const {}]) => {
  'ok': true,
  'data': data,
};
Matcher _failure(String code) =>
    throwsA(isA<AniyomiFailure>().having((error) => error.code, 'code', code));

AniyomiRepositoryExtension _extension(AniyomiMediaKind kind) =>
    AniyomiRepositoryExtension(
      kind: kind,
      packageName: 'org.example.fixture',
      name: 'Fixture',
      versionName: '1.4.1',
      versionCode: 1,
      extensionLib: '1.4',
      apkUri: Uri.parse('https://catalog.example/apk/fixture.apk'),
      iconUri: Uri.parse('https://catalog.example/icon/fixture.png'),
      language: 'en',
      isNsfw: false,
      isTorrent: false,
      sources: [],
    );

AniyomiRepositoryDocument _catalog(Uri uri, AniyomiMediaKind kind) =>
    AniyomiRepositoryDocument(
      kind: kind,
      repositoryUri: uri,
      format: AniyomiRepositoryFormat.legacyIndex,
      extensions: [_extension(kind)],
    );

class _Client extends AniyomiRepositoryClient {
  final catalogs = <(Uri, AniyomiMediaKind)>[];
  final inspections = <AniyomiRepositoryExtension>[];
  Future<AniyomiRepositoryDocument> Function(Uri, AniyomiMediaKind)? onCatalog;

  @override
  Future<AniyomiRepositoryDocument> catalog(
    Uri uri,
    AniyomiMediaKind kind, {
    required void Function() check,
  }) async {
    check();
    catalogs.add((uri, kind));
    return onCatalog == null
        ? _catalog(uri, kind)
        : await onCatalog!(uri, kind);
  }

  @override
  Future<Map<String, dynamic>> inspect(
    AniyomiRepositoryExtension extension,
    AniyomiGateway gateway,
  ) async {
    gateway.check(gateway.generation);
    inspections.add(extension);
    return {'inspectionId': 'fixture-inspection'};
  }
}

class _Controller extends AniyomiController {
  _Controller({
    required super.gateway,
    required super.client,
    super.mangaEnabled,
    super.diagnosticRecorder,
  }) : super(storage: _storage);

  AniyomiState get snapshot => state;
}

class _MutableAppUpdateController extends AppUpdateController {
  _MutableAppUpdateController(AppUpdateState initial)
    : super(
        _storage,
        _UnusedReleaseSource(),
        () async => initial.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = initial;
  }

  void replace(AppUpdateState next) => state = next;
}

class _UnusedReleaseSource extends AppReleaseSource {
  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) =>
      throw UnimplementedError();

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handle;
  late AniyomiGateway gateway;
  late _Client client;
  late _Controller controller;
  late List<Map<String, Object?>> diagnosticEvents;
  late bool mangaEnabled;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    calls = [];
    handle = (call) async => switch (call.method) {
      'status' => _ok({'available': true}),
      'list' => _ok({'extensions': []}),
      _ => _ok(),
    };
    for (final channel in [_channel, _productionChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return await handle(call);
      });
    }
    gateway = AniyomiGateway(channel: _channel, supportedPlatform: true);
    client = _Client();
    diagnosticEvents = [];
    mangaEnabled = true;
    controller = _Controller(
      gateway: gateway,
      client: client,
      mangaEnabled: () => mangaEnabled,
      diagnosticRecorder: (event) async => diagnosticEvents.add(event),
    );
  });

  tearDown(() async {
    if (controller.mounted) controller.dispose();
    gateway.dispose();
    client.dispose();
    await Future<void>.delayed(Duration.zero);
    for (final channel in [_channel, _productionChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'disabled controller has no native work or repository downloads',
    () async {
      await controller.initialize();
      expect(controller.snapshot.available, isFalse);
      await expectLater(
        controller.refreshApproved(),
        _failure('developer_access_revoked'),
      );
      await expectLater(
        controller.refreshCatalog(),
        _failure('developer_access_revoked'),
      );
      await expectLater(
        controller.addRepository('$_repo', AniyomiMediaKind.anime),
        _failure('developer_access_revoked'),
      );
      await expectLater(
        controller.approve('unapproved'),
        _failure('developer_access_revoked'),
      );
      await expectLater(
        controller.revoke('unapproved'),
        _failure('developer_access_revoked'),
      );
      expect(calls, isEmpty);
      expect(client.catalogs, isEmpty);
      expect(client.inspections, isEmpty);
      expect(await _storage.readAll(), isEmpty);
    },
  );

  test(
    'initialization loads only safe saved repositories without auto-refresh',
    () async {
      handle = (call) async => switch (call.method) {
        'status' => _ok({
          'available': true,
          'developerModeEnabled': true,
          'isolatedProcess': true,
          'runtime': 'experimental_http_subset',
          'runtimeRevision': 'aniyomi-fixture-2',
          'animeApiVersions': ['14', '16', '18', 'private-api-token'],
          'mangaApiVersions': ['1.4', '1.5', 'private-manga-token'],
          'minimumAndroidApi': 26,
          'maxConcurrentRequests': 3,
          'capabilities': {
            'currentHosterFlow': true,
            'lazyVideoResolution': true,
            'lazyHosterDeferral': true,
            'mangaImageRequestResolution': true,
            'opaqueMangaImageFetch': true,
            'ephemeralCookies': true,
            'redirects': true,
            'sourcePreferences': true,
            'javascriptEvaluation': false,
            'webView': false,
            'nativeLibraries': false,
            'privateCapability': 'private-capability-token',
          },
          'resultLimits': {
            'replyBytes': 163840,
            'httpBodyBytes': 4194304,
            'httpMetadataBytes': 16384,
            'sources': 32,
            'searchItems': 100,
            'episodesOrChapters': 2000,
            'targetedEpisodeCandidates': 64,
            'pages': 1000,
            'imageCapabilityCount': 4096,
            'imageCapabilityTtlSeconds': 7200,
            'imageBytes': 20 * 1024 * 1024,
            'imageConcurrentRequests': 3,
            'videos': 32,
            'tracksPerVideo': 16,
            'hosters': 64,
            'lazyHostersPerRequest': 8,
            'privateLimit': 999,
          },
          'universalCompatibility': false,
          'privateStatus': 'private-runtime-token',
        }),
        'list' => _ok({'extensions': []}),
        _ => _ok(),
      };
      FlutterSecureStorage.setMockInitialValues({
        _storageKey: jsonEncode([
          {'url': '$_repo', 'kind': 'anime'},
          {'url': '$_repo', 'kind': 'manga'},
          {'url': 'http://catalog.example/index.json', 'kind': 'anime'},
          {'url': 'https://127.0.0.1/index.json', 'kind': 'manga'},
          {'url': 'https://catalog.example/index.json', 'kind': 'unknown'},
          'not a repository',
        ]),
      });
      await gateway.configure(true);
      await Future.wait([controller.initialize(), controller.initialize()]);
      expect(controller.snapshot.available, isTrue);
      expect(controller.snapshot.repositories.map((repo) => repo.key), [
        'anime:$_repo',
        'manga:$_repo',
      ]);
      expect(client.catalogs, isEmpty);
      expect(client.inspections, isEmpty);
      expect(calls.map((call) => call.method), ['configure', 'status', 'list']);
      expect(
        diagnosticEvents.single,
        containsPair('runtime_revision', 'aniyomi-fixture-2'),
      );
      expect(diagnosticEvents.single, containsPair('worker_capacity', 3));
      expect(
        diagnosticEvents.single,
        containsPair('anime_api_versions', ['14', '16']),
      );
      expect(
        diagnosticEvents.single,
        containsPair('manga_api_versions', ['1.4', '1.5']),
      );
      expect(
        diagnosticEvents.single['capabilities'],
        containsPair('ephemeralCookies', true),
      );
      expect(
        diagnosticEvents.single,
        containsPair('supports_ephemeral_cookies', true),
      );
      expect(
        diagnosticEvents.single,
        containsPair('supports_lazy_hoster_deferral', true),
      );
      expect(
        diagnosticEvents.single,
        containsPair('supports_opaque_manga_image_fetch', true),
      );
      expect(
        diagnosticEvents.single,
        containsPair('supports_javascript_evaluation', false),
      );
      expect(diagnosticEvents.single['result_limits'], {
        'replyBytes': 163840,
        'httpBodyBytes': 4194304,
        'httpMetadataBytes': 16384,
        'sources': 32,
        'searchItems': 100,
        'episodesOrChapters': 2000,
        'targetedEpisodeCandidates': 64,
        'pages': 1000,
        'imageCapabilityCount': 4096,
        'imageCapabilityTtlSeconds': 7200,
        'imageBytes': 20 * 1024 * 1024,
        'imageConcurrentRequests': 3,
        'videos': 32,
        'tracksPerVideo': 16,
        'hosters': 64,
        'lazyHostersPerRequest': 8,
      });
      expect(
        jsonEncode(diagnosticEvents),
        isNot(contains('private-runtime-token')),
      );
      expect(
        jsonEncode(diagnosticEvents),
        isNot(contains('private-api-token')),
      );
      expect(
        jsonEncode(diagnosticEvents),
        isNot(contains('private-capability-token')),
      );
    },
  );

  test(
    'unavailable native runtime does not enumerate or download extensions',
    () async {
      handle = (call) async => _ok({'available': false});
      await gateway.configure(true);
      await controller.initialize();
      expect(controller.snapshot.available, isFalse);
      expect(calls.map((call) => call.method), ['configure', 'status']);
      expect(client.catalogs, isEmpty);
    },
  );

  test(
    'catalog success persists repositories in separate anime and manga namespaces',
    () async {
      await gateway.configure(true);
      await controller.addRepository('$_repo', AniyomiMediaKind.anime);
      await controller.addRepository('$_repo', AniyomiMediaKind.anime);
      await controller.addRepository('$_repo', AniyomiMediaKind.manga);
      expect(client.catalogs, [
        (_repo, AniyomiMediaKind.anime),
        (_repo, AniyomiMediaKind.manga),
      ]);
      expect(controller.snapshot.catalog.map((item) => item.identityKey), [
        'aniyomi:anime:org.example.fixture',
        'aniyomi:manga:org.example.fixture',
      ]);
      expect(jsonDecode((await _storage.read(key: _storageKey))!), [
        {'url': '$_repo', 'kind': 'anime'},
        {'url': '$_repo', 'kind': 'manga'},
      ]);
      expect(client.inspections, isEmpty);
      expect(calls.map((call) => call.method), ['configure']);
    },
  );

  test(
    'Manga opt-out preserves safe management and blocks Manga network work',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        _storageKey: jsonEncode([
          {'url': '$_repo', 'kind': 'anime'},
          {'url': '$_repo', 'kind': 'manga'},
        ]),
      });
      mangaEnabled = false;
      handle = (call) async {
        if (call.method == 'status') return _ok({'available': true});
        if (call.method == 'list') {
          return _ok({
            'extensions': [
              {
                'extensionId': 'aniyomi:anime:fixture',
                'packageName': 'org.example.anime',
                'kind': 'anime',
              },
              {
                'extensionId': 'aniyomi:manga:fixture',
                'packageName': 'org.example.manga',
                'kind': 'manga',
              },
            ],
          });
        }
        if (call.method == 'request') {
          return _ok({
            'sources': [
              {'id': '1', 'name': 'Anime only', 'lang': 'en'},
            ],
          });
        }
        return _ok();
      };
      await gateway.configure(true);
      await controller.initialize();

      expect(controller.snapshot.repositories.map((repo) => repo.kind), [
        AniyomiMediaKind.anime,
        AniyomiMediaKind.manga,
      ]);
      expect(controller.snapshot.approved, hasLength(2));
      expect(controller.sources.single.kind, AniyomiMediaKind.anime);
      expect(
        calls
            .where((call) => call.method == 'request')
            .map((call) => (call.arguments as Map)['extensionId']),
        everyElement('aniyomi:anime:fixture'),
      );

      await controller.refreshCatalog();
      expect(client.catalogs, [(_repo, AniyomiMediaKind.anime)]);
      expect(
        controller.snapshot.catalog.map((extension) => extension.kind),
        everyElement(AniyomiMediaKind.anime),
      );
      await expectLater(
        controller.addRepository('$_repo', AniyomiMediaKind.manga),
        _failure('manga_disabled'),
      );
      await expectLater(
        controller.inspect(_extension(AniyomiMediaKind.manga)),
        _failure('manga_disabled'),
      );
      await expectLater(
        controller.approve('manga-inspection'),
        _failure('inspection_expired'),
      );
      await expectLater(
        controller.retryDiscovery(
          'aniyomi:manga:fixture',
          kind: AniyomiMediaKind.manga,
        ),
        _failure('manga_disabled'),
      );
      expect(client.inspections, isEmpty);
      expect(calls.where((call) => call.method == 'approve'), isEmpty);

      final mangaRepository = controller.snapshot.repositories.singleWhere(
        (repository) => repository.kind == AniyomiMediaKind.manga,
      );
      await controller.removeRepository(mangaRepository);
      await controller.revoke('aniyomi:manga:fixture');
      expect(
        controller.snapshot.repositories.map((repository) => repository.kind),
        [AniyomiMediaKind.anime],
      );
      expect(calls.where((call) => call.method == 'revoke'), hasLength(1));
      expect(
        calls
            .where((call) => call.method == 'request')
            .map((call) => (call.arguments as Map)['extensionId']),
        everyElement('aniyomi:anime:fixture'),
      );
    },
  );

  test(
    'Manga inspection leases cannot be relabeled or reused after opt-out',
    () async {
      await gateway.configure(true);
      final inspected = await controller.inspect(
        _extension(AniyomiMediaKind.manga),
      );
      final inspectionId = inspected['inspectionId'] as String;

      mangaEnabled = false;
      controller.updateMangaAvailability(false);
      mangaEnabled = true;
      await expectLater(
        controller.approve(inspectionId),
        _failure('inspection_expired'),
      );
      expect(calls.where((call) => call.method == 'approve'), isEmpty);
    },
  );

  test('native approval cannot relabel a bound Manga inspection', () async {
    await gateway.configure(true);
    final inspected = await controller.inspect(
      _extension(AniyomiMediaKind.manga),
    );
    handle = (call) async => call.method == 'approve'
        ? _ok({
            'extensionId': 'aniyomi:anime:org.example.fixture',
            'kind': 'anime',
          })
        : _ok();

    await expectLater(
      controller.approve(inspected['inspectionId'] as String),
      _failure('identity_changed'),
    );
    expect(calls.where((call) => call.method == 'approve'), hasLength(1));
    expect(calls.where((call) => call.method == 'list'), isEmpty);
    expect(controller.sources, isEmpty);
  });

  test(
    'Manga opt-out during native approval prevents discovery and exposure',
    () async {
      await gateway.configure(true);
      final inspected = await controller.inspect(
        _extension(AniyomiMediaKind.manga),
      );
      final nativeApproval = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'approve') return await nativeApproval.future;
        if (call.method == 'list') return _ok({'extensions': []});
        return _ok();
      };

      final approval = controller.approve(inspected['inspectionId'] as String);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'approve'), hasLength(1));
      mangaEnabled = false;
      controller.updateMangaAvailability(false);
      nativeApproval.complete(
        _ok({
          'extensionId': 'aniyomi:manga:org.example.fixture',
          'kind': 'manga',
        }),
      );

      await expectLater(approval, _failure('manga_disabled'));
      expect(calls.where((call) => call.method == 'list'), isEmpty);
      expect(calls.where((call) => call.method == 'request'), isEmpty);
      expect(controller.sources, isEmpty);
      expect(controller.snapshot.readiness, isEmpty);
    },
  );

  test(
    'failed catalog leaves repository persistence and catalog untouched',
    () async {
      await gateway.configure(true);
      client.onCatalog = (_, _) async =>
          throw const AniyomiFailure('invalid_repository');
      await expectLater(
        controller.addRepository('$_repo', AniyomiMediaKind.anime),
        _failure('invalid_repository'),
      );
      expect(controller.snapshot.repositories, isEmpty);
      expect(controller.snapshot.catalog, isEmpty);
      expect(controller.snapshot.busy, isFalse);
      expect(await _storage.readAll(), isEmpty);
    },
  );

  test(
    'Developer Mode revocation discards a pending catalog before storage and state writes',
    () async {
      await gateway.configure(true);
      final pending = Completer<AniyomiRepositoryDocument>();
      client.onCatalog = (_, _) async => await pending.future;
      final checked = expectLater(
        controller.addRepository('$_repo', AniyomiMediaKind.anime),
        _failure('developer_access_revoked'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.busy, isTrue);
      await gateway.configure(false);
      pending.complete(_catalog(_repo, AniyomiMediaKind.anime));
      await checked;
      expect(controller.snapshot.repositories, isEmpty);
      expect(controller.snapshot.catalog, isEmpty);
      expect(controller.snapshot.busy, isFalse);
      expect(await _storage.readAll(), isEmpty);
    },
  );

  test(
    'disposing during initialization suppresses later list or source work',
    () async {
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'status') return await pending.future;
        return _ok();
      };
      await gateway.configure(true);
      final initialization = controller.initialize();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      pending.complete(_ok({'available': true}));
      await initialization;
      expect(calls.map((call) => call.method), ['configure', 'status']);
      expect(client.catalogs, isEmpty);
    },
  );

  test(
    'approved source discovery preserves exact 64-bit IDs and media kind',
    () async {
      handle = (call) async {
        if (call.method == 'list') {
          return _ok({
            'extensions': [
              {'extensionId': 'aniyomi:anime:fixture', 'kind': 'anime'},
              {'extensionId': 'aniyomi:manga:fixture', 'kind': 'manga'},
            ],
          });
        }
        if (call.method == 'request') {
          expect((call.arguments as Map)['operation'], 'sources');
          return _ok({
            'sources': [
              {
                'id': '9223372036854775807',
                'name': 'English fixture',
                'lang': 'en',
              },
              {'id': 9007199254740992, 'name': 'Invalid number ID'},
            ],
          });
        }
        return _ok();
      };
      await gateway.configure(true);
      expect(controller.animeProviderSnapshotGeneration, 0);
      await controller.refreshApproved();
      expect(controller.sources, hasLength(2));
      expect(controller.animeProviderSnapshotGeneration, 1);
      expect(
        controller.sources.map((source) => source.kind),
        AniyomiMediaKind.values,
      );
      expect(
        controller.sources.map((source) => source.id),
        everyElement('9223372036854775807'),
      );
      expect(
        controller.sources.map((source) => source.key).toSet(),
        hasLength(2),
      );
      expect(controller.sources.first.arguments('search'), {
        'operation': 'search',
        'extensionId': 'aniyomi:anime:fixture',
        'sourceId': '9223372036854775807',
      });
      final discoveryEvents = diagnosticEvents
          .where((event) => event['event'] == 'source_discovery')
          .toList();
      expect(discoveryEvents, hasLength(2));
      expect(
        discoveryEvents,
        everyElement(containsPair('extension_package', 'fixture')),
      );
      expect(client.catalogs, isEmpty);
      expect(client.inspections, isEmpty);
    },
  );

  test(
    'one incompatible approved extension does not hide another usable source',
    () async {
      handle = (call) async {
        if (call.method == 'list') {
          return _ok({
            'extensions': [
              {'extensionId': 'bad', 'kind': 'anime'},
              {'extensionId': 'good', 'kind': 'anime'},
            ],
          });
        }
        if (call.method == 'request') {
          if ((call.arguments as Map)['extensionId'] == 'bad') {
            return {'ok': false, 'error': 'unsupported_api'};
          }
          return _ok({
            'sources': [
              {'id': '1', 'name': 'Good', 'lang': 'en'},
            ],
          });
        }
        return _ok();
      };
      await gateway.configure(true);
      await controller.refreshApproved();
      expect(controller.sources.single.extensionId, 'good');
      expect(controller.snapshot.errors, ['extension_runtime_failed']);
      expect(
        controller.snapshot.readiness['bad']?.stage,
        AniyomiReadinessStage.failed,
      );
      expect(
        controller.snapshot.readiness['good']?.stage,
        AniyomiReadinessStage.ready,
      );
      expect(controller.snapshot.readiness['good']?.sourceCount, 1);
    },
  );

  test(
    'installed APK appears during discovery and retry recovers only failed APK',
    () async {
      final pending = Completer<Object?>();
      final requested = <String>[];
      var repaired = false;
      handle = (call) async {
        if (call.method == 'list') {
          return _ok({
            'extensions': [
              {
                'extensionId': 'broken',
                'packageName': 'private.package',
                'kind': 'anime',
                'apiVersion': '16',
                'versionName': '14.6',
                'versionCode': 46,
              },
              {'extensionId': 'ready', 'kind': 'anime'},
            ],
          });
        }
        if (call.method == 'request') {
          final id = (call.arguments as Map)['extensionId'] as String;
          requested.add(id);
          if (id == 'broken' && !repaired) return pending.future;
          return _ok({
            'sources': [
              {'id': '1', 'name': 'Fixture', 'lang': 'en'},
            ],
          });
        }
        return _ok();
      };
      await gateway.configure(true);
      final discovering = controller.refreshApproved();
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.approved, hasLength(2));
      expect(controller.snapshot.discovering, isTrue);
      expect(
        controller.snapshot.readiness['broken']?.stage,
        AniyomiReadinessStage.checking,
      );
      pending.complete({
        'ok': false,
        'error': 'unsupported_extension_abi',
        'stage': 'source_construct',
        'cause': 'method_missing',
        'message': 'private-token',
      });
      await discovering;
      expect(
        controller.snapshot.readiness['broken']?.failure?.cause,
        'method_missing',
      );
      expect(controller.sources.single.extensionId, 'ready');
      expect(controller.snapshot.discovering, isFalse);
      await controller.refreshCatalog();
      expect(
        requested,
        ['broken', 'ready'],
        reason: 'Catalog refresh must not pretend to retry runtime discovery.',
      );
      repaired = true;
      await controller.retryDiscovery('broken', kind: AniyomiMediaKind.anime);
      expect(requested, ['broken', 'ready', 'broken']);
      expect(controller.sources.map((s) => s.extensionId).toSet(), {
        'broken',
        'ready',
      });
      final recovered = controller.sources.singleWhere(
        (source) => source.extensionId == 'broken',
      );
      expect(recovered.apiVersion, '16');
      expect(recovered.extensionVersion, '14.6');
      expect(recovered.extensionVersionCode, 46);
      expect(
        controller.snapshot.readiness.values.every(
          (r) => r.stage == AniyomiReadinessStage.ready,
        ),
        isTrue,
      );
      expect(controller.snapshot.errors, isEmpty);
      expect(client.inspections, isEmpty);
      expect(client.catalogs, isEmpty);
      final serialized = jsonEncode(diagnosticEvents);
      for (final secret in [
        'private.package',
        'private-token',
        'broken',
        'ready.apk',
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
      final failureEvent = diagnosticEvents.singleWhere(
        (event) => event['reason_code'] == 'method_missing',
      );
      expect(failureEvent, containsPair('event', 'source_discovery'));
      expect(failureEvent, containsPair('kind', 'anime'));
      expect(failureEvent, containsPair('api_version', '16'));
      expect(failureEvent, containsPair('extension_version', '14.6'));
      expect(failureEvent, containsPair('extension_version_code', 46));
      expect(failureEvent['elapsed_ms'], isA<int>());
    },
  );

  test('an empty source list is installed but not ready', () async {
    handle = (call) async => call.method == 'list'
        ? _ok({
            'extensions': [
              {'extensionId': 'empty', 'kind': 'anime'},
            ],
          })
        : _ok({'sources': []});
    await gateway.configure(true);
    await controller.refreshApproved();
    expect(controller.snapshot.approved, hasLength(1));
    expect(controller.sources, isEmpty);
    expect(
      controller.snapshot.readiness['empty']?.stage,
      AniyomiReadinessStage.failed,
    );
    expect(controller.snapshot.readiness['empty']?.failure?.code, 'no_sources');
    await expectLater(
      controller.retryDiscovery('not-approved', kind: AniyomiMediaKind.anime),
      _failure('extension_not_approved'),
    );
  });

  test(
    'revocation during source discovery rejects stale sources and stops subsequent extensions',
    () async {
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'list') {
          return _ok({
            'extensions': [
              {'extensionId': 'one', 'kind': 'anime'},
              {'extensionId': 'two', 'kind': 'anime'},
            ],
          });
        }
        if (call.method == 'request') return await pending.future;
        return _ok();
      };
      await gateway.configure(true);
      final checked = expectLater(
        controller.refreshApproved(),
        _failure('developer_access_revoked'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'request'), hasLength(1));
      await gateway.configure(false);
      await gateway.configure(true);
      pending.complete(
        _ok({
          'sources': [
            {'id': '1', 'name': 'Stale', 'lang': 'en'},
          ],
        }),
      );
      await checked;
      expect(controller.sources, isEmpty);
      expect(controller.snapshot.approved, isEmpty);
      expect(calls.where((call) => call.method == 'request'), hasLength(1));
    },
  );

  test(
    'approval and revocation use explicit identities without implicit downloads',
    () async {
      await gateway.configure(true);
      await controller.inspect(_extension(AniyomiMediaKind.anime));
      handle = (call) async => call.method == 'approve'
          ? _ok({
              'extensionId': 'aniyomi:anime:org.example.fixture',
              'kind': 'anime',
            })
          : call.method == 'list'
          ? _ok({'extensions': []})
          : _ok();
      await controller.approve('fixture-inspection');
      await controller.revoke('aniyomi:anime:fixture');
      expect(calls.map((call) => call.method), [
        'configure',
        'approve',
        'list',
        'revoke',
        'list',
      ]);
      expect(calls[1].arguments, {'inspectionId': 'fixture-inspection'});
      expect(calls[3].arguments, {'extensionId': 'aniyomi:anime:fixture'});
      expect(client.catalogs, isEmpty);
      expect(client.inspections, hasLength(1));
    },
  );

  test(
    'repository removal clears the catalog but does not silently revoke approved code',
    () async {
      await gateway.configure(true);
      await controller.addRepository('$_repo', AniyomiMediaKind.anime);
      await controller.removeRepository(
        controller.snapshot.repositories.single,
      );
      expect(controller.snapshot.repositories, isEmpty);
      expect(controller.snapshot.catalog, isEmpty);
      expect(await _storage.read(key: _storageKey), '[]');
      expect(calls.map((call) => call.method), ['configure']);
    },
  );

  test(
    'provider gating preserves approvals while loading and revokes only explicit off',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final update = _MutableAppUpdateController(
        const AppUpdateState(loaded: false, developerMode: true),
      );
      final container = ProviderContainer(
        overrides: [appUpdateControllerProvider.overrideWith((_) => update)],
      );
      addTearDown(container.dispose);
      final productionGateway = container.read(aniyomiGatewayProvider);
      expect(container.read(aniyomiEnabledProvider), isFalse);
      expect(productionGateway.enabled, isFalse);
      await container.pump();
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, {
        'enabled': false,
        'revokeApprovals': false,
      });
      update.replace(const AppUpdateState(loaded: true, developerMode: true));
      await container.pump();
      expect(container.read(aniyomiEnabledProvider), isTrue);
      expect(productionGateway.enabled, isTrue);
      expect(calls.last.arguments, {'enabled': true, 'revokeApprovals': false});
      update.replace(const AppUpdateState(loaded: true, developerMode: false));
      expect(productionGateway.enabled, isFalse);
      await container.pump();
      expect(container.read(aniyomiEnabledProvider), isFalse);
      expect(calls.last.arguments, {'enabled': false, 'revokeApprovals': true});
      expect(calls.every((call) => call.method == 'configure'), isTrue);
    },
  );

  test('production loader gives cold discovery a bounded head start', () async {
    final pending = Completer<Object?>();
    handle = (call) async {
      if (call.method == 'status') return await pending.future;
      return _ok();
    };
    await gateway.configure(true);
    final update = _MutableAppUpdateController(
      const AppUpdateState(loaded: true, developerMode: true),
    );
    final container = ProviderContainer(
      overrides: [
        appUpdateControllerProvider.overrideWith((_) => update),
        aniyomiGatewayProvider.overrideWithValue(gateway),
        aniyomiControllerProvider.overrideWith((_) => controller),
      ],
    );
    addTearDown(container.dispose);
    final load = container.read(aniyomiWebProvidersLoaderProvider);
    final watch = Stopwatch()..start();
    expect(
      await Future.value(load()).timeout(const Duration(milliseconds: 240)),
      isEmpty,
    );
    expect(
      watch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 150)),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 240)));
    expect(pending.isCompleted, isFalse);
    pending.complete(_ok({'available': true}));
    await controller.initialize();
    expect(calls.map((call) => call.method), ['configure', 'status', 'list']);
  });

  test(
    'production loader returns the first source without waiting for a hung sibling',
    () async {
      final hungSource = Completer<Object?>();
      addTearDown(() {
        if (!hungSource.isCompleted) {
          hungSource.complete(_ok({'sources': []}));
        }
      });
      handle = (call) async {
        if (call.method == 'list') {
          return _ok({
            'extensions': [
              {'extensionId': 'aniyomi:anime:ready', 'kind': 'anime'},
              {'extensionId': 'aniyomi:anime:hung', 'kind': 'anime'},
            ],
          });
        }
        if (call.method == 'request') {
          final arguments = call.arguments as Map;
          if (arguments['extensionId'] == 'aniyomi:anime:hung') {
            return await hungSource.future;
          }
          return _ok({
            'sources': [
              {'id': '42', 'name': 'Ready source', 'lang': 'en'},
            ],
          });
        }
        return _ok({'available': true});
      };
      await gateway.configure(true);
      final update = _MutableAppUpdateController(
        const AppUpdateState(loaded: true, developerMode: true),
      );
      final container = ProviderContainer(
        overrides: [
          appUpdateControllerProvider.overrideWith((_) => update),
          aniyomiGatewayProvider.overrideWithValue(gateway),
          aniyomiControllerProvider.overrideWith((_) => controller),
        ],
      );
      addTearDown(container.dispose);

      final load = container.read(aniyomiWebProvidersLoaderProvider);
      final providers = await Future.value(
        load(),
      ).timeout(const Duration(milliseconds: 150));

      expect(providers, hasLength(1));
      expect(providers.single.id, 'aniyomi:anime:source:42');
      expect(hungSource.isCompleted, isFalse);
      hungSource.complete(_ok({'sources': []}));
      await controller.initialize();
    },
  );
}
