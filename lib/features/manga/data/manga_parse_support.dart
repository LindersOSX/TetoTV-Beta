import 'dart:convert';

class MangaParseLimits {
  const MangaParseLimits({
    this.maxPayloadCharacters = 2 * 1024 * 1024,
    this.maxNodes = 20000,
    this.maxDepth = 32,
    this.maxEntries = 512,
    this.maxLinks = 4096,
    this.maxSources = 128,
    this.maxContributorsPerPublication = 64,
    this.maxListItemsPerField = 128,
    this.maxShortTextCharacters = 512,
    this.maxLongTextCharacters = 65536,
  });

  final int maxPayloadCharacters;
  final int maxNodes;
  final int maxDepth;
  final int maxEntries;
  final int maxLinks;
  final int maxSources;
  final int maxContributorsPerPublication;
  final int maxListItemsPerField;
  final int maxShortTextCharacters;
  final int maxLongTextCharacters;
}

void requireBoundedPayload(
  String payload,
  MangaParseLimits limits, {
  required String format,
}) {
  if (payload.isEmpty) {
    throw FormatException('$format document is empty.');
  }
  if (payload.length > limits.maxPayloadCharacters) {
    throw FormatException('$format document exceeds the size limit.');
  }
}

Object? decodeBoundedJson(
  String payload,
  MangaParseLimits limits, {
  required String format,
}) {
  requireBoundedPayload(payload, limits, format: format);
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException catch (error) {
    throw FormatException('Invalid $format JSON: ${error.message}');
  }
  var nodes = 0;

  void visit(Object? value, int depth) {
    if (depth > limits.maxDepth) {
      throw FormatException('$format document is nested too deeply.');
    }
    nodes += 1;
    if (nodes > limits.maxNodes) {
      throw FormatException('$format document has too many values.');
    }
    if (value is String && value.length > limits.maxLongTextCharacters) {
      throw FormatException('$format document contains an oversized string.');
    }
    if (value is List<Object?>) {
      for (final item in value) {
        visit(item, depth + 1);
      }
    } else if (value is Map<String, Object?>) {
      for (final entry in value.entries) {
        if (entry.key.length > limits.maxShortTextCharacters) {
          throw FormatException('$format document contains an oversized key.');
        }
        visit(entry.value, depth + 1);
      }
    } else if (value is Map) {
      throw FormatException('$format objects must use string keys.');
    }
  }

  visit(decoded, 0);
  return decoded;
}

String requiredText(
  Object? value, {
  required String field,
  required int maxCharacters,
}) {
  final text = optionalText(value, field: field, maxCharacters: maxCharacters);
  if (text == null) throw FormatException('$field is required.');
  return text;
}

String? optionalText(
  Object? value, {
  required String field,
  required int maxCharacters,
}) {
  if (value == null) return null;
  if (value is! String) throw FormatException('$field must be a string.');
  final text = value.trim();
  if (text.isEmpty) return null;
  if (text.length > maxCharacters) {
    throw FormatException('$field exceeds the length limit.');
  }
  return text;
}

DateTime? optionalDateTime(Object? value, {required String field}) {
  final text = optionalText(value, field: field, maxCharacters: 128);
  if (text == null) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) throw FormatException('$field is not a valid date.');
  return parsed;
}

Map<String, Object?> requiredStringMap(Object? value, {required String field}) {
  if (value is! Map) throw FormatException('$field must be an object.');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$field must use string keys.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> optionalObjectList(
  Object? value, {
  required String field,
  required int maximum,
  bool allowSingle = false,
}) {
  if (value == null) return const <Object?>[];
  if (allowSingle && value is! List) return <Object?>[value];
  if (value is! List) throw FormatException('$field must be an array.');
  if (value.length > maximum) {
    throw FormatException('$field contains too many items.');
  }
  return List<Object?>.unmodifiable(value);
}

void requireOnlyKeys(
  Map<String, Object?> value,
  Set<String> allowed, {
  required String field,
}) {
  final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException(
      '$field contains unsupported key "${unknown.first}".',
    );
  }
}
