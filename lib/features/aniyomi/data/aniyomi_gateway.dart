// The public channel parameter is intentionally injectable for bridge tests.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Fixed errors only: native/provider exceptions can contain credentials.
class AniyomiFailure implements Exception {
  const AniyomiFailure(
    this.code, {
    this.stage,
    this.cause,
    this.brokerFailure,
    this.brokerRedirectCount,
    this.brokerResponseSizeBucket,
    this.brokerStatusClass,
    this.brokerReason,
  });
  final String code;
  final String? stage;
  final String? cause;
  final String? brokerFailure;
  final int? brokerRedirectCount;
  final String? brokerResponseSizeBucket;
  final String? brokerStatusClass;
  final String? brokerReason;
  factory AniyomiFailure.fromNative(Map<dynamic, dynamic>? raw) =>
      AniyomiFailure(
        _nativeErrorCodes.contains(raw?['error'])
            ? raw!['error'] as String
            : 'native_failure',
        stage: _nativeStages.contains(raw?['stage'])
            ? raw!['stage'] as String
            : null,
        cause: _nativeCauses.contains(raw?['cause'])
            ? raw!['cause'] as String
            : null,
        brokerFailure: _nativeBrokerFailures.contains(raw?['broker_failure'])
            ? raw!['broker_failure'] as String
            : null,
        brokerRedirectCount:
            raw?['broker_redirect_count'] is int &&
                (raw!['broker_redirect_count'] as int) >= 0 &&
                (raw['broker_redirect_count'] as int) <= 3
            ? raw['broker_redirect_count'] as int
            : null,
        brokerResponseSizeBucket:
            _nativeBrokerResponseSizeBuckets.contains(
              raw?['broker_response_size_bucket'],
            )
            ? raw!['broker_response_size_bucket'] as String
            : null,
        brokerStatusClass:
            _nativeBrokerStatusClasses.contains(raw?['broker_status_class'])
            ? raw!['broker_status_class'] as String
            : null,
        brokerReason: _nativeBrokerReasons.contains(raw?['broker_reason'])
            ? raw!['broker_reason'] as String
            : null,
      );
  Map<String, Object?> get brokerDiagnosticFields => {
    if (_nativeBrokerFailures.contains(brokerFailure))
      'broker_failure': brokerFailure,
    if (brokerRedirectCount case final count? when count >= 0 && count <= 3)
      'broker_redirect_count': count,
    if (_nativeBrokerResponseSizeBuckets.contains(brokerResponseSizeBucket))
      'broker_response_size_bucket': brokerResponseSizeBucket,
    if (_nativeBrokerStatusClasses.contains(brokerStatusClass))
      'broker_status_class': brokerStatusClass,
    if (_nativeBrokerReasons.contains(brokerReason))
      'broker_reason': brokerReason,
  };
  Map<String, Object?> get diagnosticFields => {
    'code': _nativeErrorCodes.contains(code) ? code : 'native_failure',
    'stage': _nativeStages.contains(stage) ? stage : 'unknown',
    'reason_code': _nativeCauses.contains(cause) ? cause : 'execution',
    ...brokerDiagnosticFields,
  };
  @override
  String toString() => 'AniyomiFailure($code)';
}

const _nativeBrokerReasons = {
  'client_configuration',
  'client_websocket',
  'client_chain',
  'client_network_interceptor',
  'client_proxy',
  'client_cache',
  'credential_header',
  'request_method',
  'request_headers',
  'request_body',
  'transport_mutation',
  'direct_network',
  'request_envelope',
  'http_method_unsupported',
  'get_body_unsupported',
  'http_request_too_large',
  'http_headers_too_large',
  'http_header_not_permitted',
  'unsupported_http_field',
  'http_request_limit',
  'invalid_http_option',
  'http_redirect_unsupported',
  'http_redirect_limit',
  'http_response_too_large',
};

/// One scheduled native request and the only cancellation capability that may
/// stop it. Every dispatched request receives an opaque scheduling ID so its
/// cancellation cannot affect another provider request.
final class AniyomiRequestHandle {
  AniyomiRequestHandle({
    required this.result,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  final Future<Map<String, dynamic>> result;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

const _nativeStages = {
  'dex_load',
  'runtime_setup',
  'class_load',
  'source_construct',
  'source_factory',
  'source_describe',
  'source_select',
  'source_operation',
  'source_search',
  'source_details',
  'source_seasons',
  'source_episodes',
  'source_chapters',
  'source_hosters',
  'source_videos',
  'source_pages',
  'source_image_url',
  'result_validation',
  'unknown',
};
const _nativeCauses = {
  'class_missing',
  'method_missing',
  'field_missing',
  'abstract_method',
  'class_initialization',
  'linkage',
  'verify_error',
  'incompatible_class_change',
  'illegal_access',
  'class_format',
  'native_linkage',
  'unsupported_capability',
  'security_denied',
  'invalid_input',
  'io',
  'timeout',
  'execution',
};
const _nativeErrorCodes = {
  'native_failure',
  'android_required',
  'disabled',
  'developer_access_revoked',
  'android_26_required',
  'developer_mode_or_android_version_required',
  'invalid_import_file',
  'extension_limit_reached',
  'unsupported_anime_api',
  'unsupported_manga_api',
  'apk_signature_invalid_or_multisigner',
  'extension_feature_missing',
  'extension_class_invalid',
  'native_code_unsupported',
  'unsupported_dex_layout',
  'inspection_expired',
  'identity_changed',
  'signer_change_requires_revocation',
  'version_downgrade',
  'extension_not_approved',
  'approved_identity_changed',
  'snapshot_unavailable',
  'apk_inspection_failed',
  'approval_failed',
  'worker_busy',
  'invalid_request',
  'request_deadline_exceeded',
  'worker_unavailable',
  'worker_terminated',
  'worker_start_failed',
  'worker_disconnected',
  'worker_binding_died',
  'worker_bind_failed',
  'extension_not_approved_or_changed',
  'request_cancelled',
  'host_closed',
  'invalid_or_revoked_extension_result',
  'unsupported_extension_capability',
  'extension_local_proxy_required',
  'unsupported_extension_abi',
  'extension_execution_failed',
  'extension_hoster_timeout',
  'extension_result_too_large',
  'extension_failed',
  'unsupported_api',
  'no_sources',
  'image_capability_invalid',
  'image_busy',
  'image_response_too_large',
  'image_redirect_limit',
  'image_http_failure',
  'image_empty',
  'image_not_supported',
  'image_malformed',
  'image_dimensions_exceeded',
  'private_network_blocked',
  'private_host_blocked',
  'public_https_required',
  'https_port_not_allowed',
  'invalid_https_url',
  'invalid_https_host',
  'image_request_cancelled_or_expired',
  'image_fetch_failed',
};
const _nativeBrokerFailures = {'policy', 'network', 'unsupported', 'invalid'};
const _nativeBrokerResponseSizeBuckets = {
  'none',
  'lt64k',
  '64to128k',
  '128to256k',
  'over256k',
};
const _nativeBrokerStatusClasses = {'none', '1xx', '2xx', '3xx', '4xx', '5xx'};
const _diagnosticOperations = {
  'sources',
  'search',
  'details',
  'seasons',
  'chapters',
  'episodes',
  'pages',
  'videos',
};

typedef AniyomiSchedulerDiagnostic = void Function(Map<String, Object?> fields);

/// In-memory authority to fetch one native-owned Aniyomi manga image.
///
/// The URL, provider headers and cookie jar are deliberately unavailable to
/// Dart. Even debug rendering redacts the random native token.
final class AniyomiImageCapability {
  AniyomiImageCapability._({
    required AniyomiGateway gateway,
    required String extensionId,
    required String token,
    required int generation,
  }) : _gateway = gateway,
       _extensionId = extensionId,
       _token = token,
       _generation = generation;

  final AniyomiGateway _gateway;
  final String _extensionId;
  final String _token;
  final int _generation;

  Future<Uint8List> load() => _gateway._loadImage(this);

  @override
  String toString() => 'AniyomiImageCapability(<redacted>)';
}

/// This bridge never loads APK code into Flutter or the main Android process.
/// The native service owns verification, isolation, consent and deadlines.
class AniyomiGateway {
  AniyomiGateway({
    MethodChannel channel = const MethodChannel('dev.animetv.anime_tv/aniyomi'),
    bool? supportedPlatform,
    this.requestTimeout = const Duration(seconds: 10),
    this.onSchedulerDiagnostic,
  }) : _channel = channel,
       supportedPlatform =
           supportedPlatform ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool supportedPlatform;
  final Duration requestTimeout;
  final AniyomiSchedulerDiagnostic? onSchedulerDiagnostic;
  bool _enabled = false;
  bool _closed = false;
  int _generation = 0;
  int _nextRequestId = 0;
  int _maxConcurrentRequests = 1;
  Future<void> _configuration = Future.value();
  final List<_AniyomiQueuedRequest> _waiting = [];
  final Map<int, _AniyomiQueuedRequest> _running = {};
  int _queued = 0;
  int get generation => _generation;
  bool get enabled => _enabled && !_closed && supportedPlatform;

  void check(int generation) {
    if (!enabled || generation != _generation) {
      throw const AniyomiFailure('developer_access_revoked');
    }
  }

  Future<void> configure(bool enabled, {bool revokeApprovals = true}) {
    if (_closed) return Future.value();
    _enabled = enabled && supportedPlatform;
    _generation++;
    final access = _generation;
    if (!supportedPlatform) return Future.value();
    // Not queued behind worker requests: opt-out must interrupt immediately.
    _configuration =
        _invoke('configure', {
              'enabled': _enabled,
              'revokeApprovals': revokeApprovals,
            })
            .then<void>((data) {
              if (access != _generation) return;
              _maxConcurrentRequests = _nativeConcurrency(data);
              _pumpQueue();
            })
            .catchError((Object _) {
              if (access == _generation) _enabled = false;
            });
    return _configuration;
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final access = _generation;
    check(access);
    await _configuration;
    check(access);
    final result = await _invoke(method, arguments);
    check(access);
    return result;
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> arguments) =>
      startRequest(arguments).result;

  AniyomiRequestHandle startRequest(Map<String, dynamic> arguments) {
    if (_queued >= 24) {
      _emitImmediateFailure(arguments, 'worker_busy');
      return AniyomiRequestHandle(
        result: Future.error(const AniyomiFailure('worker_busy')),
        cancel: () async {},
      );
    }
    final access = _generation;
    final requestedMs = arguments['timeoutMs'];
    final budget = Duration(
      milliseconds: requestedMs is int
          ? requestedMs.clamp(1, requestTimeout.inMilliseconds)
          : requestTimeout.inMilliseconds,
    );
    final watch = Stopwatch()..start();
    final work = _AniyomiQueuedRequest(
      id: _allocateRequestId(),
      access: access,
      arguments: Map<String, dynamic>.from(arguments),
      budget: budget,
      watch: watch,
    );
    _queued++;
    _waiting.add(work);
    _pumpQueue();
    return AniyomiRequestHandle(
      result: work.result.future,
      cancel: () => _cancelRequest(work),
    );
  }

  int _nativeConcurrency(Map<String, dynamic> data) {
    final raw = data['maxConcurrentRequests'];
    return raw is int && raw >= 1 && raw <= 3 ? raw : 1;
  }

  int _allocateRequestId() {
    do {
      _nextRequestId = _nextRequestId >= 0x7fffffff ? 1 : _nextRequestId + 1;
    } while (_running.containsKey(_nextRequestId) ||
        _waiting.any((work) => work.id == _nextRequestId));
    return _nextRequestId;
  }

  void _pumpQueue() {
    while (_running.length < _maxConcurrentRequests && _waiting.isNotEmpty) {
      final work = _waiting.removeAt(0);
      if (work.finished) continue;
      work.running = true;
      _running[work.id] = work;
      unawaited(_runRequest(work));
    }
  }

  Future<void> _runRequest(_AniyomiQueuedRequest work) async {
    Map<String, dynamic>? value;
    Object? failure;
    StackTrace? failureStack;
    try {
      check(work.access);
      final configurationRemaining = work.budget - work.watch.elapsed;
      if (configurationRemaining <= Duration.zero) {
        throw const AniyomiFailure('request_deadline_exceeded');
      }
      await Future.any<void>([
        _configuration,
        work.cancelSignal.future,
      ]).timeout(configurationRemaining);
      if (work.cancelled) {
        throw const AniyomiFailure('request_cancelled');
      }
      check(work.access);
      final remaining = work.budget - work.watch.elapsed;
      if (remaining <= Duration.zero) {
        throw const AniyomiFailure('request_deadline_exceeded');
      }

      work.nativeActive = true;
      work.executionStarted = work.watch.elapsed;
      final nativeArguments = Map<String, dynamic>.from(work.arguments)
        ..['requestId'] = work.id;
      final result = await Future.any<Map<String, dynamic>>([
        _invoke('request', nativeArguments),
        work.cancelSignal.future.then<Map<String, dynamic>>(
          (_) => throw const AniyomiFailure('request_cancelled'),
        ),
      ]).timeout(remaining);
      // A response and cancellation can cross in the platform channel. Keep
      // this slot until the targeted cancel RPC has been acknowledged.
      if (work.cancelled) {
        await work.nativeCancellation;
        throw const AniyomiFailure('request_cancelled');
      }
      check(work.access);
      value = _materializeImageCapabilities(result, work);
    } on TimeoutException {
      work.cancelled = true;
      await _cancelActive(work);
      failure = const AniyomiFailure('request_deadline_exceeded');
      failureStack = StackTrace.current;
    } catch (error, stack) {
      if (work.cancelled) {
        await work.nativeCancellation;
        failure = const AniyomiFailure('request_cancelled');
        failureStack = StackTrace.current;
      } else {
        failure = error;
        failureStack = stack;
      }
    } finally {
      _finishRequest(
        work,
        value: value,
        failure: failure,
        failureStack: failureStack,
      );
    }
  }

  void _finishRequest(
    _AniyomiQueuedRequest work, {
    Map<String, dynamic>? value,
    Object? failure,
    StackTrace? failureStack,
  }) {
    if (work.finished) return;
    _waiting.remove(work);
    if (identical(_running[work.id], work)) _running.remove(work.id);
    work.nativeActive = false;
    work.running = false;
    work.finished = true;
    _queued--;
    if (!work.done.isCompleted) work.done.complete();
    _emitDiagnostic(work, failure);
    if (failure != null) {
      work.result.completeError(failure, failureStack ?? StackTrace.current);
    } else {
      work.result.complete(value!);
    }
    _pumpQueue();
  }

  void _emitImmediateFailure(Map<String, dynamic> arguments, String code) {
    final callback = onSchedulerDiagnostic;
    if (callback == null) return;
    final operation = arguments['operation'];
    try {
      callback({
        'operation': _diagnosticOperations.contains(operation)
            ? operation as String
            : 'unknown',
        'extension_package': _diagnosticExtensionPackage(arguments),
        'queued_count': _waiting.length,
        'active_count': _running.length,
        'worker_capacity': _maxConcurrentRequests,
        'queue_wait_ms': 0,
        'execution_ms': 0,
        'total_ms': 0,
        'outcome': 'rejected',
        'code': code,
        'stage': 'unknown',
        'reason_code': 'execution',
      });
    } catch (_) {
      // Diagnostics must never affect provider execution.
    }
  }

  void _emitDiagnostic(_AniyomiQueuedRequest work, Object? failure) {
    final callback = onSchedulerDiagnostic;
    if (callback == null) return;
    final total = work.watch.elapsed;
    final executionStart = work.executionStarted;
    final error = failure is AniyomiFailure ? failure : null;
    final outcome = switch (error?.code) {
      null when failure == null => 'success',
      'request_cancelled' => 'cancelled',
      'request_deadline_exceeded' => 'timeout',
      'developer_access_revoked' => 'revoked',
      _ => 'failure',
    };
    try {
      callback({
        'operation': work.operation,
        'extension_package': _diagnosticExtensionPackage(work.arguments),
        'queued_count': _waiting.length,
        'active_count': _running.length,
        'worker_capacity': _maxConcurrentRequests,
        'queue_wait_ms': (executionStart ?? total).inMilliseconds,
        'execution_ms': executionStart == null
            ? 0
            : (total - executionStart).inMilliseconds,
        'total_ms': total.inMilliseconds,
        'outcome': outcome,
        'code':
            error?.diagnosticFields['code'] ??
            (failure == null ? 'none' : 'native_failure'),
        'stage': error?.diagnosticFields['stage'] ?? 'unknown',
        'reason_code': error?.diagnosticFields['reason_code'] ?? 'execution',
        ...?error?.brokerDiagnosticFields,
      });
    } catch (_) {
      // Diagnostics must never affect provider execution.
    }
  }

  Future<void> _cancelRequest(_AniyomiQueuedRequest work) async {
    if (work.finished) return;
    if (work.cancelled) {
      await work.nativeCancellation;
      if (work.running) await work.done.future;
      return;
    }
    work.cancelled = true;
    if (!work.running) {
      _finishRequest(
        work,
        failure: const AniyomiFailure('request_cancelled'),
        failureStack: StackTrace.current,
      );
      return;
    }
    if (!work.nativeActive || !identical(_running[work.id], work)) {
      if (!work.cancelSignal.isCompleted) work.cancelSignal.complete();
      await work.done.future;
      return;
    }
    await _cancelActive(work);
    await work.done.future;
  }

  Future<void> _cancelActive(_AniyomiQueuedRequest work) {
    final existing = work.nativeCancellation;
    if (existing != null) return existing;
    if (!work.nativeActive || !identical(_running[work.id], work)) {
      if (!work.cancelSignal.isCompleted) work.cancelSignal.complete();
      return Future.value();
    }
    final cancellation = _cancelNative(work.id).whenComplete(() {
      if (!work.cancelSignal.isCompleted) work.cancelSignal.complete();
    });
    work.nativeCancellation = cancellation;
    return cancellation;
  }

  Future<void> _cancelNative(int requestId) async {
    try {
      await _invoke('cancel', {'requestId': requestId});
    } catch (_) {
      /* Native deadline is the final backstop. */
    }
  }

  Future<Map<String, dynamic>> _invoke(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(method, args);
      if (raw?['ok'] != true) {
        throw AniyomiFailure.fromNative(raw);
      }
      final data = raw?['data'];
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on PlatformException {
      throw const AniyomiFailure('native_failure');
    } on MissingPluginException {
      throw const AniyomiFailure('android_required');
    }
  }

  Map<String, dynamic> _materializeImageCapabilities(
    Map<String, dynamic> result,
    _AniyomiQueuedRequest work,
  ) {
    final extensionId = work.arguments['extensionId'];
    final operation = work.arguments['operation'];
    if (extensionId is! String ||
        !extensionId.startsWith('aniyomi:manga:') ||
        !const {'search', 'details', 'pages'}.contains(operation)) {
      return result;
    }

    Map<String, dynamic> materializeRow(Object? raw, {required bool page}) {
      if (raw is! Map) {
        throw const AniyomiFailure('invalid_or_revoked_extension_result');
      }
      final row = Map<String, dynamic>.from(raw);
      // Native manga image DTOs must never retain transport details alongside
      // a grant. Fail closed if an older or compromised host does so.
      if (row.containsKey(page ? 'url' : 'thumbnailUrl') ||
          row.containsKey(page ? 'headers' : 'thumbnailHeaders')) {
        throw const AniyomiFailure('invalid_or_revoked_extension_result');
      }
      final token = row['imageCapability'];
      if (token == null && !page) return row;
      if (token is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
        throw const AniyomiFailure('invalid_or_revoked_extension_result');
      }
      row['imageCapability'] = AniyomiImageCapability._(
        gateway: this,
        extensionId: extensionId,
        token: token,
        generation: work.access,
      );
      return row;
    }

    final copy = Map<String, dynamic>.from(result);
    if (operation == 'pages' || operation == 'search') {
      final key = operation == 'pages' ? 'pages' : 'items';
      final rows = copy[key];
      if (rows is! List || rows.length > (operation == 'pages' ? 1000 : 100)) {
        throw const AniyomiFailure('invalid_or_revoked_extension_result');
      }
      copy[key] = rows
          .map((row) => materializeRow(row, page: operation == 'pages'))
          .toList(growable: false);
    } else {
      copy['item'] = materializeRow(copy['item'], page: false);
    }
    return copy;
  }

  Future<Uint8List> _loadImage(AniyomiImageCapability capability) async {
    if (!identical(capability._gateway, this)) {
      throw const AniyomiFailure('image_capability_invalid');
    }
    check(capability._generation);
    await _configuration;
    check(capability._generation);
    try {
      final raw = await _channel.invokeMethod<Object?>('fetchImage', {
        'extensionId': capability._extensionId,
        'capability': capability._token,
      });
      if (raw is! Map || raw['ok'] != true) {
        throw AniyomiFailure.fromNative(raw is Map ? raw : null);
      }
      final bytes = raw['data'];
      if (bytes is! Uint8List ||
          bytes.isEmpty ||
          bytes.length > maximumAniyomiImageBytes) {
        throw const AniyomiFailure('image_response_too_large');
      }
      check(capability._generation);
      return bytes;
    } on PlatformException {
      throw const AniyomiFailure('native_failure');
    } on MissingPluginException {
      throw const AniyomiFailure('android_required');
    }
  }

  void dispose() {
    if (_closed) return;
    _enabled = false;
    _generation++;
    _closed = true;
    if (supportedPlatform) {
      unawaited(
        _invoke('configure', {
          'enabled': false,
          'revokeApprovals': false,
        }).catchError((Object _) => <String, dynamic>{}),
      );
    }
  }
}

const int maximumAniyomiImageBytes = 20 * 1024 * 1024;

String _diagnosticExtensionPackage(Map<String, dynamic> arguments) {
  final identity = arguments['extensionId'];
  if (identity is! String) return 'unknown';
  return RegExp(
        r'^aniyomi:(?:anime|manga):([A-Za-z][A-Za-z0-9_.]{0,159})$',
      ).firstMatch(identity)?.group(1) ??
      'unknown';
}

final class _AniyomiQueuedRequest {
  _AniyomiQueuedRequest({
    required this.id,
    required this.access,
    required this.arguments,
    required this.budget,
    required this.watch,
  });

  final int id;
  final int access;
  final Map<String, dynamic> arguments;
  String get operation {
    final value = arguments['operation'];
    return _diagnosticOperations.contains(value) ? value as String : 'unknown';
  }

  final Duration budget;
  final Stopwatch watch;
  Duration? executionStarted;
  final Completer<Map<String, dynamic>> result =
      Completer<Map<String, dynamic>>();
  final Completer<void> cancelSignal = Completer<void>();
  final Completer<void> done = Completer<void>();
  bool running = false;
  bool nativeActive = false;
  bool cancelled = false;
  bool finished = false;
  Future<void>? nativeCancellation;
}
