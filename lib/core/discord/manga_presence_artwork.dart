/// Only a public, header-free cover may be disclosed to Discord. This is a
/// lexical URL check, not a claim about DNS or a source's content. Never attach
/// cookies, page URLs, signed queries, or local-file capabilities to presence.
String? safeMangaPresenceArtworkUrl(String? value) {
  if (value == null) return null;
  if (_unsafeCharacters.hasMatch(value)) return null;
  final text = value.trim();
  if (text.isEmpty ||
      text.length > 300 ||
      RegExp(r'[\x00-\x20\x7f\\]').hasMatch(text) ||
      RegExp(
        r'%(?:0[0-9a-f]|1[0-9a-f]|20|5c|7f)',
        caseSensitive: false,
      ).hasMatch(text)) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port != 443) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final labels = host.split('.');
  if (host.length > 253 ||
      labels.length < 2 ||
      labels.any(
        (label) =>
            !RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(label),
      ) ||
      !RegExp(r'^(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})$').hasMatch(labels.last) ||
      labels.every(
        (label) => RegExp(r'^(?:[0-9]+|0x[0-9a-f]+)$').hasMatch(label),
      )) {
    return null;
  }
  final rawAuthority = RegExp(
    r'^https://([^/?#]+)',
    caseSensitive: false,
  ).firstMatch(text)?.group(1)?.toLowerCase();
  if (rawAuthority != host && rawAuthority != '$host:443') {
    return null;
  }
  try {
    final decoded = Uri.decodeComponent(uri.path);
    if (_unsafeCharacters.hasMatch(decoded) ||
        RegExp(r'\s', unicode: true).hasMatch(decoded) ||
        RegExp(
          r'%(?:0[0-9a-f]|1[0-9a-f]|7f|5c)',
          caseSensitive: false,
        ).hasMatch(decoded)) {
      return null;
    }
  } on FormatException {
    return null;
  }
  const reserved = [
    'localhost',
    'local',
    'lan',
    'internal',
    'home',
    'home.arpa',
    'localdomain',
    'test',
    'invalid',
    'example',
    'onion',
  ];
  if (reserved.any((suffix) => host == suffix || host.endsWith('.$suffix'))) {
    return null;
  }
  final canonical = uri
      .replace(scheme: 'https', host: host, port: 443)
      .toString();
  return canonical.length <= 300 ? canonical : null;
}

final _unsafeCharacters = RegExp(r'[\p{Cc}\p{Cf}\\]', unicode: true);
