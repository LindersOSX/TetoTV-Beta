/// Process-local capability registry for app-pinned catalog artwork.
///
/// Widgets must not render arbitrary `file:` URLs originating in remote
/// metadata. Offline catalog storage registers a URI only after canonical path,
/// file-size, and image-signature verification.
class TrustedLocalArtworkRegistry {
  TrustedLocalArtworkRegistry._();

  static final instance = TrustedLocalArtworkRegistry._();

  final Set<String> _trusted = {};

  void register(Uri uri) {
    if (uri.scheme != 'file' || uri.hasQuery || uri.hasFragment) return;
    _trusted.add(_key(uri));
  }

  bool owns(Uri uri) =>
      uri.scheme == 'file' &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      _trusted.contains(_key(uri));

  void clearForTesting() => _trusted.clear();
}

String _key(Uri uri) => uri.normalizePath().toString();
