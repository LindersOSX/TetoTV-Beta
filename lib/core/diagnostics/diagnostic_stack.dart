import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';

// Code locations are useful for matching a crash to a particular source line.
// Only compiled-in packages are recognized, and only within Dart stack frames.
// Arbitrary URIs, plugin-provided paths and free-text messages remain redacted.
final _codeLocation = RegExp(
  r'(?:package:(?:anime_tv|flutter|flutter_riverpod|riverpod|go_router|media_kit|media_kit_video|dio|sqflite|flutter_js|collection)/[A-Za-z0-9_./-]+\.dart|dart:[a-z_]+(?:/[A-Za-z0-9_./-]+\.dart)?):[0-9]+(?::[0-9]+)?',
);

String _redactFrame(String line) {
  if (!RegExp(r'^\s*#[0-9]+\s').hasMatch(line)) {
    return _boundLine(redactDiagnosticValue(line, maximum: 320));
  }
  final result = StringBuffer();
  var end = 0;
  for (final match in _codeLocation.allMatches(line)) {
    final location = match[0]!;
    if (location.contains('..')) continue;
    result.write(
      redactDiagnosticValue(line.substring(end, match.start), maximum: 320),
    );
    // Avoid URI syntax so a second redaction at the database/native/export
    // boundary does not erase the already-validated compiled-in code location.
    final parts = location.split(':');
    result.write('${parts[0]} ${parts[1]} line=${parts[2]}');
    if (parts.length > 3) result.write(' column=${parts[3]}');
    end = match.end;
  }
  result.write(redactDiagnosticValue(line.substring(end), maximum: 320));
  return _boundLine(result.toString());
}

String _boundLine(String value) {
  if (value.length <= 300) return value;
  var end = 280;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${value.substring(0, end)} [line truncated]';
}

/// Bounded, redacted trace with an explicit marker instead of silent clipping.
String redactDiagnosticStack(String value, {int maximum = 4000}) {
  if (maximum < 100) throw ArgumentError.value(maximum, 'maximum');
  final lines = stripDiagnosticControls(
    value,
  ).split(RegExp(r'[\r\n]+')).where((line) => line.isNotEmpty).toList();
  final retained = lines.take(50).map(_redactFrame).join('\n');
  const maximumBytes = 8000;
  if (retained.length <= maximum &&
      lines.length <= 50 &&
      _jsonBytes(retained) <= maximumBytes) {
    return retained;
  }
  const marker = '\n[stack truncated: report size limit]';
  final limit = maximum - marker.length;
  final byteLimit = maximumBytes - _jsonBytes(marker);
  final prefix = StringBuffer();
  var characters = 0;
  var bytes = 0;
  for (final rune in retained.runes) {
    final text = String.fromCharCode(rune);
    final size = _jsonBytes(text);
    if (characters + text.length > limit || bytes + size > byteLimit) break;
    prefix.write(text);
    characters += text.length;
    bytes += size;
  }
  return '$prefix$marker';
}

// Non-layout controls add no useful trace information and can expand sixfold
// during JSON encoding or split strings across privacy filters.
String stripDiagnosticControls(String value) =>
    value.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

int _jsonBytes(String value) => utf8.encode(jsonEncode(value)).length - 2;

/// Closed technical categories only: never FlutterErrorDetails.context, widget
/// labels, provider names or arbitrary library strings which can contain data.
String diagnosticErrorCategory(Object error, {String? frameworkLibrary}) {
  final type = switch (error.runtimeType.toString()) {
    'FlutterError' => 'flutter_error',
    'StateError' => 'state_error',
    'ArgumentError' => 'argument_error',
    'RangeError' || 'IndexError' => 'range_error',
    '_TypeError' || 'TypeError' => 'type_error',
    'NoSuchMethodError' => 'missing_method',
    'AssertionError' || '_AssertionError' => 'assertion',
    'DioException' => 'http_client',
    'SocketException' => 'socket',
    'TimeoutException' => 'timeout',
    'PlatformException' => 'platform',
    'OutOfMemoryError' => 'memory',
    _ => 'other',
  };
  final library = switch (frameworkLibrary) {
    'widgets library' => 'widgets',
    'rendering library' => 'rendering',
    'animation library' => 'animation',
    'scheduler library' => 'scheduler',
    'gestures library' => 'gestures',
    'services library' => 'services',
    'image resource service' => 'image',
    'painting library' => 'painting',
    _ => 'other',
  };
  return 'error_type=$type framework_area=$library';
}

/// Network transport failures surfaced by Flutter's image/request machinery
/// are recoverable request failures, not evidence that the Dart process died.
/// Keep them visible in explicit diagnostics as warnings while reserving
/// `fatal` for actual unhandled application faults.
String diagnosticSeverityForGlobalError(Object error) =>
    isRecoverableNetworkDiagnostic(error) ? 'warning' : 'fatal';

bool isRecoverableNetworkDiagnostic(Object error) {
  final message = stripDiagnosticControls(error.toString()).toLowerCase();
  return const [
    'failed host lookup',
    'no address associated with hostname',
    'temporary failure in name resolution',
    'name or service not known',
    'software caused connection abort',
    'connection reset by peer',
    'connection closed before full header',
    'network is unreachable',
    'no route to host',
  ].any(message.contains);
}
