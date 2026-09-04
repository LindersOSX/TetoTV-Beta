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

/// Returns a canonical, origin-only value suitable for an HTTP `Origin`
/// header, or `null` when [value] is not a public HTTPS URL.
///
/// Origin headers never carry paths, queries, fragments, or user info. A
/// provider occasionally supplies a full page URL here; canonicalizing it to
/// its origin is safe and prevents path/query capabilities from being sent.
/// Keeping this rule in the URI policy prevents the reader and downloader from
/// gradually developing different handling for extension-supplied metadata.
String? canonicalMangaPageOriginHeader(Object? value) {
  final uri = _safeMangaPageHeaderUri(value);
  return uri?.origin;
}

/// Returns a canonical value suitable for an HTTP `Referer` header.
///
/// A same-origin request may retain the public HTTPS path/query because some
/// manga hosts use it for hotlink checks. Across an origin boundary only the
/// origin is retained, matching modern browser referrer behavior and ensuring
/// chapter capabilities in a path or query never reach another host.
String? canonicalMangaPageRefererHeader(
  Object? value, {
  bool originOnly = false,
}) {
  final uri = _safeMangaPageHeaderUri(value);
  if (uri == null) return null;
  return originOnly ? '${uri.origin}/' : uri.toString();
}

Uri? _safeMangaPageHeaderUri(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  final parsed = Uri.tryParse(normalized);
  if (parsed == null || parsed.hasFragment) return null;
  return safePublicHttpsUri(normalized);
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
