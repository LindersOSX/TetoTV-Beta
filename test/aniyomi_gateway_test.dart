import 'dart:async';

import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('tetotv.test/aniyomi-gateway');
Map<String, dynamic> _ok([Map<String, dynamic> data = const {}]) => {
  'ok': true,
  'data': data,
};
Matcher _failure(String code) =>
    throwsA(isA<AniyomiFailure>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handle;

  setUp(() {
    calls = [];
    handle = (_) async => _ok();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return handle(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  AniyomiGateway gateway({
    bool platform = true,
    Duration timeout = const Duration(seconds: 1),
    AniyomiSchedulerDiagnostic? diagnostic,
  }) {
    final result = AniyomiGateway(
      channel: _channel,
      supportedPlatform: platform,
      requestTimeout: timeout,
      onSchedulerDiagnostic: diagnostic,
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'defaults disabled and neither calls nor requests dispatch native work',
    () async {
      final bridge = gateway();
      expect(bridge.enabled, isFalse);
      await expectLater(
        bridge.call('status'),
        _failure('developer_access_revoked'),
      );
      await expectLater(
        bridge.request({'operation': 'sources'}),
        _failure('developer_access_revoked'),
      );
      expect(calls, isEmpty);
    },
  );

  test('unsupported platform cannot enable or dispatch native work', () async {
    final bridge = gateway(platform: false);
    await bridge.configure(true);
    expect(bridge.enabled, isFalse);
    await expectLater(
      bridge.call('status'),
      _failure('developer_access_revoked'),
    );
    await expectLater(bridge.request({}), _failure('developer_access_revoked'));
    bridge.dispose();
    expect(calls, isEmpty);
  });

  test('manga image grants expose only a redacted in-memory loader', () async {
    const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final diagnostics = <Map<String, Object?>>[];
    handle = (call) async {
      if (call.method == 'request') {
        return _ok({
          'pages': [
            {'index': 0, 'imageCapability': token},
          ],
        });
      }
      if (call.method == 'fetchImage') {
        expect(call.arguments, {
          'extensionId': 'aniyomi:manga:eu.example.fixture',
          'capability': token,
        });
        return {
          'ok': true,
          'data': Uint8List.fromList([1, 2, 3]),
        };
      }
      return _ok({'maxConcurrentRequests': 1});
    };
    final bridge = gateway(diagnostic: diagnostics.add);
    await bridge.configure(true);
    final response = await bridge.request({
      'operation': 'pages',
      'extensionId': 'aniyomi:manga:eu.example.fixture',
      'sourceId': '1',
      'url': '/chapter',
    });
    final row = (response['pages'] as List).single as Map;
    expect(row.keys, containsAll(<String>['index', 'imageCapability']));
    expect(row, isNot(contains('url')));
    expect(row, isNot(contains('headers')));
    final capability = row['imageCapability'];
    expect(capability, isA<AniyomiImageCapability>());
    expect(capability.toString(), 'AniyomiImageCapability(<redacted>)');
    expect(await (capability as AniyomiImageCapability).load(), [1, 2, 3]);
    expect(diagnostics.toString(), isNot(contains(token)));
  });

  test('manga grant rejects any native URL or header side channel', () async {
    const token = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    handle = (call) async => call.method == 'request'
        ? _ok({
            'pages': [
              {
                'index': 0,
                'imageCapability': token,
                'url': 'https://private.example/page.jpg?secret=value',
                'headers': {'Cookie': 'private=value'},
              },
            ],
          })
        : _ok();
    final bridge = gateway();
    await bridge.configure(true);
    await expectLater(
      bridge.request({
        'operation': 'pages',
        'extensionId': 'aniyomi:manga:eu.example.fixture',
      }),
      _failure('invalid_or_revoked_extension_result'),
    );
  });

  test('disabling invalidates an already returned image capability', () async {
    const token = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
    handle = (call) async => call.method == 'request'
        ? _ok({
            'items': [
              {'url': '/series', 'title': 'Fixture', 'imageCapability': token},
            ],
            'hasNextPage': false,
          })
        : _ok();
    final bridge = gateway();
    await bridge.configure(true);
    final response = await bridge.request({
      'operation': 'search',
      'extensionId': 'aniyomi:manga:eu.example.fixture',
    });
    final capability =
        ((response['items'] as List).single as Map)['imageCapability']
            as AniyomiImageCapability;
    await bridge.configure(false, revokeApprovals: false);
    await expectLater(capability.load(), _failure('developer_access_revoked'));
    expect(calls.where((call) => call.method == 'fetchImage'), isEmpty);
  });

  test(
    'configuration keeps approvals while loading but explicit off revokes',
    () async {
      final bridge = gateway();
      await bridge.configure(false, revokeApprovals: false);
      expect(calls.single.arguments, {
        'enabled': false,
        'revokeApprovals': false,
      });
      await bridge.configure(true, revokeApprovals: false);
      expect(bridge.enabled, isTrue);
      await bridge.configure(false);
      expect(bridge.enabled, isFalse);
      expect(calls.last.arguments, {'enabled': false, 'revokeApprovals': true});
    },
  );

  test(
    'calls wait for configuration and discard revoked configuration generations',
    () async {
      final configuring = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'configure' &&
            (call.arguments as Map)['enabled'] == true) {
          return await configuring.future;
        }
        return _ok();
      };
      final bridge = gateway();
      final enabling = bridge.configure(true);
      final work = bridge.call('status');
      final checked = expectLater(work, _failure('developer_access_revoked'));
      await bridge.configure(false);
      expect(calls.where((call) => call.method == 'status'), isEmpty);
      configuring.complete(_ok());
      await enabling;
      await checked;
      expect(calls.where((call) => call.method == 'status'), isEmpty);
    },
  );

  test(
    'off invalidates synchronously and late native replies cannot resurrect data',
    () async {
      final started = Completer<void>();
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'status') {
          started.complete();
          return pending.future;
        }
        return _ok();
      };
      final bridge = gateway();
      await bridge.configure(true);
      final oldGeneration = bridge.generation;
      final work = bridge.call('status');
      final checked = expectLater(work, _failure('developer_access_revoked'));
      await started.future;
      final disabling = bridge.configure(false);
      expect(bridge.enabled, isFalse);
      expect(() => bridge.check(oldGeneration), throwsA(isA<AniyomiFailure>()));
      await disabling;
      await bridge.configure(true);
      pending.complete(_ok({'available': true, 'stale': true}));
      await checked;
      expect(bridge.enabled, isTrue);
    },
  );

  test(
    'off dispatches ahead of an active request and revoked queue never runs',
    () async {
      final started = Completer<void>();
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'request') {
          started.complete();
          return pending.future;
        }
        return _ok();
      };
      final bridge = gateway();
      await bridge.configure(true);
      final first = bridge.request({'operation': 'search'});
      final firstCheck = expectLater(
        first,
        _failure('developer_access_revoked'),
      );
      final second = bridge.request({'operation': 'episodes'});
      final secondCheck = expectLater(
        second,
        _failure('developer_access_revoked'),
      );
      await started.future;
      await bridge.configure(false);
      expect(calls.last.method, 'configure');
      expect((calls.last.arguments as Map)['enabled'], isFalse);
      pending.complete(_ok({'stale': true}));
      await Future.wait([firstCheck, secondCheck]);
      expect(calls.where((call) => call.method == 'request'), hasLength(1));
    },
  );

  test(
    'requests execute serially and failure does not poison the queue',
    () async {
      final firstStarted = Completer<void>();
      final pending = Completer<Object?>();
      var requests = 0;
      handle = (call) async {
        if (call.method != 'request') return _ok();
        requests++;
        if (requests == 1) {
          firstStarted.complete();
          return pending.future;
        }
        return _ok({'second': true});
      };
      final bridge = gateway();
      await bridge.configure(true);
      final first = bridge.request({});
      final firstCheck = expectLater(first, _failure('extension_failed'));
      final second = bridge.request({});
      await firstStarted.future;
      expect(requests, 1);
      pending.complete({'ok': false, 'error': 'extension_failed'});
      await firstCheck;
      expect(await second, {'second': true});
      expect(requests, 2);
    },
  );

  test(
    'native advertised capacity runs three providers and queues only overflow',
    () async {
      final responses = <int, Completer<Object?>>{};
      handle = (call) async {
        if (call.method == 'configure') {
          return _ok({'maxConcurrentRequests': 3});
        }
        if (call.method == 'request') {
          final id = (call.arguments as Map)['requestId'] as int;
          final response = Completer<Object?>();
          responses[id] = response;
          return response.future;
        }
        return _ok();
      };
      final bridge = gateway();
      await bridge.configure(true);

      final work = List.generate(
        4,
        (index) => bridge.request({'operation': 'search', 'query': '$index'}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(responses, hasLength(3));
      expect(responses.keys.toSet(), hasLength(3));

      final firstId = responses.keys.first;
      responses[firstId]!.complete(_ok({'index': 0}));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(responses, hasLength(4));
      for (final entry in responses.entries) {
        if (!entry.value.isCompleted) entry.value.complete(_ok());
      }
      await Future.wait(work);
    },
  );

  test(
    'targeted cancellation frees one slot without cancelling peer providers',
    () async {
      final responses = <int, Completer<Object?>>{};
      handle = (call) async {
        if (call.method == 'configure') {
          return _ok({'maxConcurrentRequests': 2});
        }
        if (call.method == 'request') {
          final id = (call.arguments as Map)['requestId'] as int;
          final response = Completer<Object?>();
          responses[id] = response;
          return response.future;
        }
        return _ok();
      };
      final bridge = gateway();
      await bridge.configure(true);
      final first = bridge.startRequest({'operation': 'search'});
      final second = bridge.startRequest({'operation': 'search'});
      final third = bridge.startRequest({'operation': 'search'});
      final firstCheck = expectLater(
        first.result,
        _failure('request_cancelled'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(responses, hasLength(2));
      final firstId = responses.keys.first;

      await first.cancel();
      await firstCheck;
      await Future<void>.delayed(Duration.zero);
      expect(responses, hasLength(3));
      final cancel = calls.singleWhere((call) => call.method == 'cancel');
      expect((cancel.arguments as Map)['requestId'], firstId);

      for (final entry in responses.entries) {
        if (!entry.value.isCompleted) entry.value.complete(_ok());
      }
      expect(await second.result, isEmpty);
      expect(await third.result, isEmpty);
    },
  );

  test(
    'scheduler diagnostics contain only fixed operational metadata',
    () async {
      final diagnostics = <Map<String, Object?>>[];
      handle = (call) async {
        if (call.method == 'configure') {
          return _ok({'maxConcurrentRequests': 3});
        }
        if (call.method == 'request') {
          return {
            'ok': false,
            'error': 'unsupported_extension_abi',
            'stage': 'source_construct',
            'cause': 'method_missing',
            'broker_failure': 'network',
            'broker_redirect_count': 2,
            'broker_response_size_bucket': '64to128k',
            'broker_status_class': '5xx',
            'message': 'secret-token https://private.example/path',
          };
        }
        return _ok();
      };
      final bridge = gateway(diagnostic: diagnostics.add);
      await bridge.configure(true);
      await expectLater(
        bridge.request({
          'operation': 'search',
          'extensionId': 'secret.extension',
          'sourceId': 'private-source',
          'query': 'private title',
          'url': 'https://private.example/path?token=secret',
        }),
        _failure('unsupported_extension_abi'),
      );
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, containsPair('operation', 'search'));
      expect(diagnostics.single, containsPair('extension_package', 'unknown'));
      expect(diagnostics.single, containsPair('worker_capacity', 3));
      expect(diagnostics.single, containsPair('outcome', 'failure'));
      expect(
        diagnostics.single,
        containsPair('code', 'unsupported_extension_abi'),
      );
      expect(diagnostics.single, containsPair('stage', 'source_construct'));
      expect(diagnostics.single, containsPair('reason_code', 'method_missing'));
      expect(diagnostics.single, containsPair('broker_failure', 'network'));
      expect(diagnostics.single, containsPair('broker_redirect_count', 2));
      expect(
        diagnostics.single,
        containsPair('broker_response_size_bucket', '64to128k'),
      );
      expect(diagnostics.single, containsPair('broker_status_class', '5xx'));
      final serialized = diagnostics.single.toString();
      expect(serialized, isNot(contains('secret.extension')));
      expect(serialized, isNot(contains('private-source')));
      expect(serialized, isNot(contains('private title')));
      expect(serialized, isNot(contains('private.example')));
      expect(serialized, isNot(contains('secret-token')));
    },
  );

  test(
    'forwards bounded operation timeout metadata to the native host',
    () async {
      final bridge = gateway();
      await bridge.configure(true);

      await bridge.request({
        'operation': 'search',
        'extensionId': 'aniyomi:anime:eu.example.fixture',
        'sourceId': '1',
        'query': 'Fixture',
        'timeoutMs': 8000,
      });

      final request = calls.singleWhere((call) => call.method == 'request');
      expect((request.arguments as Map)['timeoutMs'], 8000);
    },
  );

  test(
    'scheduler diagnostics identify only validated extension packages',
    () async {
      final diagnostics = <Map<String, Object?>>[];
      final bridge = gateway(diagnostic: diagnostics.add);
      await bridge.configure(true);

      await bridge.request({
        'operation': 'search',
        'extensionId': 'aniyomi:anime:eu.example.fixture',
        'sourceId': '1',
        'query': 'Private media title',
      });

      expect(diagnostics.single['extension_package'], 'eu.example.fixture');
      expect(
        diagnostics.single.toString(),
        isNot(contains('Private media title')),
      );
    },
  );

  test(
    'request timeout invokes native cancellation and ignores late success',
    () async {
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'request') return await pending.future;
        return _ok();
      };
      final bridge = gateway(timeout: const Duration(milliseconds: 150));
      await bridge.configure(true);
      await expectLater(
        bridge.request({'timeoutMs': 100}),
        _failure('request_deadline_exceeded'),
      );
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
      pending.complete(_ok({'stale': true}));
      await Future<void>.delayed(Duration.zero);
      expect(bridge.enabled, isTrue);
    },
  );

  test(
    'request handle awaits native cancel before dispatching the next request',
    () async {
      final firstStarted = Completer<void>();
      final firstResponse = Completer<Object?>();
      final cancelStarted = Completer<void>();
      final cancelResponse = Completer<Object?>();
      var requests = 0;
      handle = (call) async {
        if (call.method == 'cancel') {
          cancelStarted.complete();
          return cancelResponse.future;
        }
        if (call.method != 'request') return _ok();
        requests++;
        if (requests == 1) {
          firstStarted.complete();
          return firstResponse.future;
        }
        return _ok({'next': true});
      };
      final bridge = gateway();
      await bridge.configure(true);
      final first = bridge.startRequest({});
      final firstCheck = expectLater(
        first.result,
        _failure('request_cancelled'),
      );
      await firstStarted.future;

      final cancellation = first.cancel();
      await cancelStarted.future;
      final next = bridge.request({});
      firstResponse.complete({'ok': false, 'error': 'request_cancelled'});
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);

      cancelResponse.complete(_ok());
      await cancellation;
      await firstCheck;
      expect(await next, {'next': true});
      expect(requests, 2);
      expect(calls.map((call) => call.method), [
        'configure',
        'request',
        'cancel',
        'request',
      ]);
    },
  );

  test(
    'cancelling a queued handle neither cancels nor dispatches it',
    () async {
      final firstStarted = Completer<void>();
      final firstResponse = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'request') {
          firstStarted.complete();
          return firstResponse.future;
        }
        return _ok();
      };
      final bridge = gateway();
      await bridge.configure(true);
      final first = bridge.request({});
      await firstStarted.future;
      final queued = bridge.startRequest({});
      final queuedCheck = expectLater(
        queued.result,
        _failure('request_cancelled'),
      );

      await queued.cancel();
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      firstResponse.complete(_ok({'first': true}));
      expect(await first, {'first': true});
      await queuedCheck;
      expect(calls.where((call) => call.method == 'request'), hasLength(1));
    },
  );

  test(
    'queued request deadline starts when enqueued rather than when dispatched',
    () async {
      final firstStarted = Completer<void>();
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'request') {
          firstStarted.complete();
          return pending.future;
        }
        return _ok();
      };
      final bridge = gateway(timeout: const Duration(seconds: 1));
      await bridge.configure(true);
      final first = bridge.request({});
      final second = bridge.request({'timeoutMs': 100});
      final checked = expectLater(
        second,
        _failure('request_deadline_exceeded'),
      );
      await firstStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 130));
      pending.complete(_ok());
      await first;
      await checked;
      expect(calls.where((call) => call.method == 'request'), hasLength(1));
    },
  );

  testWidgets(
    'timed-out request cannot dispatch when stalled configuration later resolves',
    (tester) async {
      final configuring = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'configure' &&
            (call.arguments as Map)['enabled'] == true) {
          return await configuring.future;
        }
        return _ok();
      };
      final bridge = gateway();
      final configuration = bridge.configure(true);
      final checked = expectLater(
        bridge.request({'operation': 'sources', 'timeoutMs': 100}),
        _failure('request_deadline_exceeded'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      await checked;
      // The request never owned native work, so its timeout must not emit the
      // process-wide cancel signal while configuration is still pending.
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      expect(calls.where((call) => call.method == 'request'), isEmpty);
      configuring.complete(_ok());
      await tester.pump();
      await configuration;
      expect(calls.where((call) => call.method == 'request'), isEmpty);
    },
  );

  testWidgets('does not extend a requested budget below 100 milliseconds', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    handle = (call) async {
      if (call.method == 'request') return await pending.future;
      return _ok();
    };
    final bridge = gateway();
    await bridge.configure(true);
    var timedOut = false;
    final checked = expectLater(
      bridge.request({'timeoutMs': 20}),
      _failure('request_deadline_exceeded'),
    ).then((_) => timedOut = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));
    expect(timedOut, isTrue);
    await checked;
    expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    pending.complete(_ok());
    await tester.pump();
  });

  test(
    'queue has a fixed capacity and excess work never reaches Android',
    () async {
      final pending = Completer<Object?>();
      handle = (call) async {
        if (call.method == 'request') return await pending.future;
        return _ok();
      };
      final bridge = gateway();
      await bridge.configure(true);
      final work = List.generate(24, (_) => bridge.request({}));
      final checks = work
          .map(
            (item) => expectLater(item, _failure('developer_access_revoked')),
          )
          .toList();
      await expectLater(bridge.request({}), _failure('worker_busy'));
      await bridge.configure(false);
      pending.complete(_ok());
      await Future.wait(checks);
      expect(
        calls.where((call) => call.method == 'request').length,
        lessThanOrEqualTo(1),
      );
    },
  );

  test(
    'sanitizes provider/platform errors instead of leaking native messages',
    () async {
      final bridge = gateway();
      await bridge.configure(true);
      for (final response in [
        {'ok': false, 'error': 'secret=https://user:token@example.com'},
        {'ok': false, 'error': null},
        {'ok': false, 'error': 'UPPERCASE'},
        {'ok': false, 'error': 'private_token_looks_like_a_code'},
      ]) {
        handle = (_) async => response;
        await expectLater(bridge.call('status'), _failure('native_failure'));
      }
      handle = (_) async =>
          throw PlatformException(code: 'secret', message: 'private token');
      await expectLater(bridge.call('status'), _failure('native_failure'));
    },
  );

  test('keeps only allowlisted native stage and cause metadata', () async {
    final bridge = gateway();
    await bridge.configure(true);
    handle = (_) async => {
      'ok': false,
      'error': 'unsupported_extension_abi',
      'stage': 'source_construct',
      'cause': 'method_missing',
      'broker_failure': 'network',
      'broker_redirect_count': 3,
      'broker_response_size_bucket': '128to256k',
      'broker_status_class': '4xx',
      'message': 'secret-token https://private.example/path',
    };
    try {
      await bridge.request({'operation': 'sources'});
      fail('Expected the native failure.');
    } on AniyomiFailure catch (error) {
      expect(error.stage, 'source_construct');
      expect(error.cause, 'method_missing');
      expect(error.diagnosticFields, {
        'code': 'unsupported_extension_abi',
        'stage': 'source_construct',
        'reason_code': 'method_missing',
        'broker_failure': 'network',
        'broker_redirect_count': 3,
        'broker_response_size_bucket': '128to256k',
        'broker_status_class': '4xx',
      });
      expect(error.toString(), isNot(contains('secret-token')));
    }
    handle = (_) async => {
      'ok': false,
      'error': 'extension_execution_failed',
      'stage': 'secret-token',
      'cause': 'https://private.example',
      'broker_failure': 'private-network-token',
      'broker_redirect_count': 99,
      'broker_response_size_bucket': 'private-size-token',
      'broker_status_class': 'private-status-token',
    };
    try {
      await bridge.call('status');
      fail('Expected the native failure.');
    } on AniyomiFailure catch (error) {
      expect(error.stage, isNull);
      expect(error.cause, isNull);
      expect(error.diagnosticFields, {
        'code': 'extension_execution_failed',
        'stage': 'unknown',
        'reason_code': 'execution',
      });
    }
  });

  test('keeps privacy-safe result validation diagnostics', () async {
    final bridge = gateway();
    await bridge.configure(true);
    handle = (_) async => {
      'ok': false,
      'error': 'invalid_or_revoked_extension_result',
      'stage': 'result_validation',
      'cause': 'invalid_input',
      'message': 'provider URL and private parser details',
    };

    try {
      await bridge.request({'operation': 'search'});
      fail('Expected result validation to fail.');
    } on AniyomiFailure catch (error) {
      expect(error.diagnosticFields, {
        'code': 'invalid_or_revoked_extension_result',
        'stage': 'result_validation',
        'reason_code': 'invalid_input',
      });
      expect(error.toString(), isNot(contains('provider URL')));
    }
  });

  test('keeps the fixed hoster timeout failure classification', () async {
    final bridge = gateway();
    await bridge.configure(true);
    handle = (_) async => {
      'ok': false,
      'error': 'extension_hoster_timeout',
      'stage': 'source_videos',
      'cause': 'timeout',
    };
    try {
      await bridge.request({'operation': 'videos'});
      fail('Expected the hoster timeout failure.');
    } on AniyomiFailure catch (error) {
      expect(error.code, 'extension_hoster_timeout');
      expect(error.stage, 'source_videos');
      expect(error.cause, 'timeout');
    }
  });

  test(
    'keeps fixed ABI linkage categories without exposing native messages',
    () async {
      final bridge = gateway();
      await bridge.configure(true);
      for (final cause in [
        'verify_error',
        'incompatible_class_change',
        'illegal_access',
        'class_format',
        'native_linkage',
        'linkage',
      ]) {
        handle = (_) async => {
          'ok': false,
          'error': 'unsupported_extension_abi',
          'stage': 'class_load',
          'cause': cause,
          'message': 'secret-linkage-details',
        };
        try {
          await bridge.request({'operation': 'sources'});
          fail('Expected an ABI failure.');
        } on AniyomiFailure catch (error) {
          expect(error.code, 'unsupported_extension_abi');
          expect(error.cause, cause);
          expect(error.diagnosticFields, {
            'code': 'unsupported_extension_abi',
            'stage': 'class_load',
            'reason_code': cause,
          });
          expect(error.toString(), isNot(contains('secret-linkage-details')));
        }
      }
    },
  );

  test('configuration failure closes the gate', () async {
    handle = (_) async => {'ok': false, 'error': 'native_failure'};
    final bridge = gateway();
    await bridge.configure(true);
    expect(bridge.enabled, isFalse);
    await expectLater(
      bridge.call('status'),
      _failure('developer_access_revoked'),
    );
    expect(calls, hasLength(1));
  });

  test(
    'dispose revokes access, preserves approvals, and is idempotent',
    () async {
      final bridge = gateway();
      await bridge.configure(true);
      bridge.dispose();
      bridge.dispose();
      expect(bridge.enabled, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(2));
      expect(calls.last.arguments, {
        'enabled': false,
        'revokeApprovals': false,
      });
      await expectLater(
        bridge.call('status'),
        _failure('developer_access_revoked'),
      );
    },
  );
}
