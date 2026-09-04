/// Repository families that can be identified without executing provider code.
///
/// TetoTV's Marketplace consumes Seanime-compatible JSON manifests. Mihon and
/// Tachiyomi stores distribute native Android extensions instead, so accepting
/// one as an ordinary Marketplace repository would leave a broken repository
/// row and could imply that TetoTV is able to execute its APKs.
enum ExtensionRepositoryFamily { seanimeMarketplace, mihonNative, unknown }

class ExtensionRepositoryInspection {
  const ExtensionRepositoryInspection(this.family, {this.rejectionMessage});

  final ExtensionRepositoryFamily family;
  final String? rejectionMessage;

  bool get isRejected => rejectionMessage != null;
}

const String mihonNativeRepositoryRejectionMessage =
    'That is a Mihon/Tachiyomi Android extension store. Its entries are native '
    'APK extensions, which TetoTV cannot safely run in its Seanime manga '
    'sandbox. Add a Seanime-compatible JSON Marketplace repository containing '
    'manga-provider extensions instead.';

/// Performs a conservative URI-only check before a repository is downloaded.
///
/// `.pb` is Mihon's protobuf store format. Query parameters do not affect the
/// classification because [Uri.path] excludes them. Other JSON filenames are
/// intentionally left unknown until their bounded payload can be inspected.
ExtensionRepositoryInspection inspectExtensionRepositoryUri(Uri uri) {
  final path = uri.path.toLowerCase();
  if (path.endsWith('.pb')) {
    return const ExtensionRepositoryInspection(
      ExtensionRepositoryFamily.mihonNative,
      rejectionMessage: mihonNativeRepositoryRejectionMessage,
    );
  }
  return const ExtensionRepositoryInspection(ExtensionRepositoryFamily.unknown);
}

/// Identifies Mihon/Tachiyomi JSON store descriptors and indexes after JSON
/// decoding but before they are interpreted as executable Marketplace data.
///
/// The checks require multiple format-specific fields to avoid rejecting an
/// unrelated repository merely because it happens to use a generic key such
/// as `extensions`, `name`, or `sources`.
ExtensionRepositoryInspection inspectExtensionRepositoryJson(Object? value) {
  if (_looksLikeMihonStore(value) || _looksLikeLegacyMihonIndex(value)) {
    return const ExtensionRepositoryInspection(
      ExtensionRepositoryFamily.mihonNative,
      rejectionMessage: mihonNativeRepositoryRejectionMessage,
    );
  }
  return const ExtensionRepositoryInspection(ExtensionRepositoryFamily.unknown);
}

bool _looksLikeMihonStore(Object? value) {
  if (value is! Map) return false;
  final map = _stringKeyed(value);

  // Current protobuf-v2 stores also publish a human-readable JSON form.
  final contact = map['contact'];
  final currentStore =
      map['signingKey'] is String &&
      map['badgeLabel'] is String &&
      contact is Map &&
      (map['extensionList'] is Map || map['extensionListUrl'] is String);
  if (currentStore) return true;

  // Legacy `repo.json` descriptors point at an index_v2 and bind it to the
  // repository signing fingerprint.
  final meta = map['meta'];
  if (map['index_v2'] is String && meta is Map) {
    final metadata = _stringKeyed(meta);
    return metadata['signingKeyFingerprint'] is String &&
        metadata['name'] is String;
  }
  return false;
}

bool _looksLikeLegacyMihonIndex(Object? value) {
  if (value is! List || value.isEmpty) return false;
  var inspected = 0;
  for (final item in value.take(4)) {
    if (item is! Map) return false;
    inspected++;
    final entry = _stringKeyed(item);
    if (entry['pkg'] is! String ||
        entry['apk'] is! String ||
        entry['code'] is! num ||
        entry['sources'] is! List) {
      return false;
    }
  }
  return inspected > 0;
}

Map<String, Object?> _stringKeyed(Map<dynamic, dynamic> value) =>
    <String, Object?>{
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
