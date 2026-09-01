import 'package:anime_tv/features/marketplace/domain/addon_models.dart';

const int _maximumMangaUriCharacters = 2048;

Uri requireMangaPublicHttpsUri(Object? value, {required String field}) {
  final uri = safePublicHttpsUri(value);
  if (uri == null) {
    throw FormatException('$field must be a credential-free public HTTPS URL.');
  }
  return uri;
}

/// Applies the stricter boundary required for URLs written to local storage.
///
/// Public catalog links may legitimately be short-lived signed capabilities,
/// but persisting them would put credentials in SQLite and can retain access
/// beyond the browsing session. Runtime requests may still use those links;
/// saved library/catalog paths must omit them.
Uri requireMangaPersistablePublicHttpsUri(
  Object? value, {
  required String field,
}) {
  final uri = requireMangaPublicHttpsUri(value, field: field);
  for (final key in uri.queryParametersAll.keys) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (_isCredentialQueryKey(normalized)) {
      throw FormatException(
        '$field must keep credentials in protected storage, not its URL.',
      );
    }
  }
  return uri;
}

Uri resolveMangaPublicHttpsReference(
  Uri documentUri,
  Object? value, {
  required String field,
}) {
  final safeBase = requireMangaPublicHttpsUri(
    documentUri.toString(),
    field: 'Document URL',
  );
  if (value is! String) throw FormatException('$field must be a URL string.');
  final reference = value.trim();
  if (reference.isEmpty || reference.length > _maximumMangaUriCharacters) {
    throw FormatException('$field is empty or too long.');
  }
  if (reference.contains('\\') ||
      reference.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw FormatException('$field contains unsafe URL characters.');
  }
  final parsedReference = Uri.tryParse(reference);
  if (parsedReference == null) throw FormatException('$field is not a URL.');
  final resolved = safeBase.resolveUri(parsedReference);
  return requireMangaPublicHttpsUri(resolved.toString(), field: field);
}

bool _isCredentialQueryKey(String normalized) {
  if (_credentialQueryKeys.contains(normalized)) return true;
  return normalized.endsWith('token') ||
      normalized.endsWith('apikey') ||
      normalized.endsWith('signature') ||
      normalized.endsWith('credential') ||
      normalized.endsWith('password') ||
      normalized.endsWith('secret');
}

const Set<String> _credentialQueryKeys = <String>{
  'accessid',
  'auth',
  'authorization',
  'bearer',
  'key',
  'keypairid',
  'policy',
  'sig',
};
