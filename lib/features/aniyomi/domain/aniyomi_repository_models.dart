/// Native-extension catalogs are separate from Seanime's script namespace.
enum AniyomiMediaKind { anime, manga }

enum AniyomiRepositoryFormat { legacyIndex, legacyMetadata, animeStore }

enum AniyomiRepositoryParseError {
  invalidDocument,
  unsafeResource,
  limitExceeded,
  unsupportedFormat,
  delegatedIndex,
}

final class AniyomiRepositoryParseException implements Exception {
  const AniyomiRepositoryParseException(this.code, this.message);

  final AniyomiRepositoryParseError code;
  final String message;

  @override
  String toString() => 'AniyomiRepositoryParseException: $message';
}

/// Informational repository claims, never proof of APK authenticity or consent.
final class AniyomiRepositoryMetadata {
  const AniyomiRepositoryMetadata({
    required this.name,
    required this.websiteUri,
    required this.signingKeyFingerprint,
    this.shortName,
  });

  final String name;
  final String? shortName;
  final Uri websiteUri;

  /// Unverified SHA-256 certificate fingerprint declared by the repository.
  /// The installer must verify the actual APK signature independently.
  final String signingKeyFingerprint;
}

final class AniyomiRepositorySource {
  const AniyomiRepositorySource({
    required this.kind,
    required this.id,
    required this.name,
    required this.language,
    this.homeUri,
  });

  final AniyomiMediaKind kind;

  /// Exact canonical signed-64-bit decimal; never pass through a double.
  final String id;
  final String name;
  final String language;
  final Uri? homeUri;

  String get identityKey => 'aniyomi:${kind.name}:source:$id';
}

/// A catalog entry is neither an installed extension nor a supported runtime.
final class AniyomiRepositoryExtension {
  AniyomiRepositoryExtension({
    required this.kind,
    required this.packageName,
    required this.name,
    required this.versionName,
    required this.versionCode,
    required this.extensionLib,
    required this.apkUri,
    required this.iconUri,
    required this.language,
    required this.isNsfw,
    required this.isTorrent,
    required List<AniyomiRepositorySource> sources,
  }) : sources = List.unmodifiable(sources);

  final AniyomiMediaKind kind;
  final String packageName;
  final String name;
  final String versionName;
  final int versionCode;

  /// Declared API version, not a guarantee that TetoTV can execute it.
  final String extensionLib;
  final Uri apkUri;
  final Uri iconUri;
  final String language;
  final bool isNsfw;
  final bool isTorrent;
  final List<AniyomiRepositorySource> sources;

  String get identityKey => 'aniyomi:${kind.name}:$packageName';
}

final class AniyomiRepositoryDocument {
  AniyomiRepositoryDocument({
    required this.kind,
    required this.repositoryUri,
    required this.format,
    required List<AniyomiRepositoryExtension> extensions,
    this.metadata,
    this.legacyIndexUri,
  }) : extensions = List.unmodifiable(extensions);

  final AniyomiMediaKind kind;
  final Uri repositoryUri;
  final AniyomiRepositoryFormat format;
  final AniyomiRepositoryMetadata? metadata;
  final List<AniyomiRepositoryExtension> extensions;

  /// Only supplied for a metadata-only legacy repo.json response. Fetching it
  /// is a separate caller-controlled operation, not parser network activity.
  final Uri? legacyIndexUri;

  bool get isMetadataOnly => format == AniyomiRepositoryFormat.legacyMetadata;
}
