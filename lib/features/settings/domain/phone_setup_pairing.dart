import 'dart:convert';

import 'package:anime_tv/features/discord/domain/discord_minimum_age_confirmation.dart';

enum PhoneSetupPairingStatus {
  pending,
  bound,
  submitted,
  completed,
  failed,
  expired,
}

class PhoneSetupKeyMaterial {
  const PhoneSetupKeyMaterial({
    required this.privateD,
    required this.publicX,
    required this.publicY,
  });

  final List<int> privateD;
  final List<int> publicX;
  final List<int> publicY;

  String get encodedPublicKey =>
      _base64UrlNoPadding([0x04, ...publicX, ...publicY]);

  Map<String, Object?> toJson() => {
    'd': _base64UrlNoPadding(privateD),
    'x': _base64UrlNoPadding(publicX),
    'y': _base64UrlNoPadding(publicY),
  };

  static PhoneSetupKeyMaterial fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('The saved phone-setup key is invalid.');
    }
    final d = _decodeFixed(value['d'], 32);
    final x = _decodeFixed(value['x'], 32);
    final y = _decodeFixed(value['y'], 32);
    return PhoneSetupKeyMaterial(privateD: d, publicX: x, publicY: y);
  }
}

class PhoneSetupPairingSession {
  const PhoneSetupPairingSession({
    required this.pairingId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.codeExpiresAt,
    required this.expiresAt,
    required this.pollInterval,
    required this.keyMaterial,
    required this.deviceKeyFingerprint,
    required this.confirmationCode,
  });

  final String pairingId;
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Uri verificationUriComplete;
  final DateTime codeExpiresAt;
  final DateTime expiresAt;
  final Duration pollInterval;
  final PhoneSetupKeyMaterial keyMaterial;
  final String deviceKeyFingerprint;
  final String confirmationCode;

  Map<String, Object?> toJson() => {
    'version': 1,
    'pairing_id': pairingId,
    'device_code': deviceCode,
    'user_code': userCode,
    'verification_uri': verificationUri.toString(),
    'verification_uri_complete': verificationUriComplete.toString(),
    'code_expires_at': codeExpiresAt.toUtc().toIso8601String(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'interval_seconds': pollInterval.inSeconds,
    'key': keyMaterial.toJson(),
    'device_key_fingerprint': deviceKeyFingerprint,
    'confirmation_code': confirmationCode,
  };
}

class PhoneSetupEncryptedSubmission {
  const PhoneSetupEncryptedSubmission({
    required this.browserPublicKey,
    required this.nonce,
    required this.ciphertext,
  });

  final List<int> browserPublicKey;
  final List<int> nonce;
  final List<int> ciphertext;
}

class PhoneSetupPollResult {
  const PhoneSetupPollResult({
    required this.status,
    required this.revision,
    this.envelope,
  });

  final PhoneSetupPairingStatus status;
  final int revision;
  final PhoneSetupEncryptedSubmission? envelope;
}

class PhoneSetupPreferences {
  const PhoneSetupPreferences({
    this.preferredAudio,
    this.titleLanguage,
    this.useBuiltInKeyboard,
    this.autoSkipIntros,
    this.autoSkipOutros,
    this.homeLayout,
    this.interfaceMode,
    this.showHero,
    this.showPosterMetadata,
    this.showMyList,
    this.showDiscover,
    this.showCalendar,
    this.showWatchParty,
    this.showDownloads,
    this.anonymousCrashReporting,
    this.anonymousUsageCount,
    this.trackingProvider,
    this.debridProvider,
    this.linkDiscord,
  });

  final String? preferredAudio;
  final String? titleLanguage;
  final bool? useBuiltInKeyboard;
  final bool? autoSkipIntros;
  final bool? autoSkipOutros;
  final String? homeLayout;
  final String? interfaceMode;
  final bool? showHero;
  final bool? showPosterMetadata;
  final bool? showMyList;
  final bool? showDiscover;
  final bool? showCalendar;
  final bool? showWatchParty;
  final bool? showDownloads;
  final bool? anonymousCrashReporting;
  final bool? anonymousUsageCount;
  final String? trackingProvider;
  final String? debridProvider;
  final bool? linkDiscord;

  int get choiceCount => <Object?>[
    preferredAudio,
    titleLanguage,
    useBuiltInKeyboard,
    autoSkipIntros,
    autoSkipOutros,
    homeLayout,
    interfaceMode,
    showHero,
    showPosterMetadata,
    showMyList,
    showDiscover,
    showCalendar,
    showWatchParty,
    showDownloads,
    anonymousCrashReporting,
    anonymousUsageCount,
    trackingProvider,
    debridProvider,
    linkDiscord,
  ].where((value) => value != null).length;
}

class PhoneSetupCredentials {
  const PhoneSetupCredentials({
    this.trackingToken,
    this.debridCredential,
    this.tracking,
    this.debrid,
    this.discord,
  });

  /// Legacy protocol-v1 tracker token.
  final String? trackingToken;

  /// Legacy protocol-v1 debrid token/API key.
  final String? debridCredential;

  /// Complete protocol-v2 tracker credentials.
  final PhoneSetupTrackingCredentials? tracking;

  /// Provider-specific protocol-v2 debrid credentials.
  final PhoneSetupDebridCredentials? debrid;

  /// Complete protocol-v3 Discord OAuth credentials and eligibility marker.
  final PhoneSetupDiscordCredentials? discord;

  bool get hasTrackingToken =>
      (trackingToken?.isNotEmpty ?? false) || tracking != null;
  bool get hasDebridCredential =>
      (debridCredential?.isNotEmpty ?? false) || debrid != null;
  bool get hasDiscordCredential => discord != null;
}

class PhoneSetupTrackingCredentials {
  const PhoneSetupTrackingCredentials({
    required this.provider,
    required this.accessToken,
    this.refreshToken,
    this.tokenType,
    this.expiresAt,
  });

  final String provider;
  final String accessToken;
  final String? refreshToken;
  final String? tokenType;
  final DateTime? expiresAt;
}

class PhoneSetupDebridCredentials {
  const PhoneSetupDebridCredentials({
    required this.provider,
    this.accessToken,
    this.apiKey,
    this.refreshToken,
    this.clientId,
    this.clientSecret,
    this.expiresAt,
  });

  final String provider;
  final String? accessToken;
  final String? apiKey;
  final String? refreshToken;
  final String? clientId;
  final String? clientSecret;
  final DateTime? expiresAt;

  String get validationCredential => accessToken ?? apiKey!;
}

class PhoneSetupDiscordCredentials {
  const PhoneSetupDiscordCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresAt,
    required this.scopes,
    required this.minimumAgeConfirmation,
  });

  final String accessToken;
  final String refreshToken;
  final int tokenType;
  final DateTime expiresAt;
  final List<String> scopes;
  final DiscordMinimumAgeConfirmation minimumAgeConfirmation;
}

class PhoneSetupBundle {
  const PhoneSetupBundle({
    this.protocolVersion = 1,
    required this.preferences,
    required this.repositoryUrls,
    required this.manifestUrls,
    required this.credentials,
  });

  final int protocolVersion;
  final PhoneSetupPreferences preferences;
  final List<String> repositoryUrls;
  final List<String> manifestUrls;
  final PhoneSetupCredentials credentials;

  static PhoneSetupBundle parse(List<int> cleartext) {
    if (cleartext.isEmpty || cleartext.length > 64 * 1024) {
      throw const FormatException('The phone setup is empty or too large.');
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(cleartext, allowMalformed: false));
    } catch (_) {
      throw const FormatException('The phone setup could not be decoded.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The phone setup version is not supported.');
    }
    final versionValue = decoded['version'];
    if (versionValue is! int ||
        (versionValue != 1 && versionValue != 2 && versionValue != 3)) {
      throw const FormatException('The phone setup version is not supported.');
    }
    final protocolVersion = versionValue;
    const rootKeys = {'version', 'preferences', 'sources', 'credentials'};
    if (decoded.keys.any((key) => !rootKeys.contains(key))) {
      throw const FormatException('The phone setup contains unknown fields.');
    }
    final preferences = _stringMap(decoded['preferences'], 'preferences');
    final sources = _stringMap(decoded['sources'], 'sources');
    final credentials = _stringMap(decoded['credentials'], 'credentials');

    const preferenceKeys = {
      'preferred_audio',
      'title_language',
      'built_in_keyboard',
      'auto_skip_intros',
      'auto_skip_outros',
      'home_layout',
      'interface_mode',
      'show_hero',
      'show_poster_metadata',
      'show_my_list',
      'discover',
      'calendar',
      'watch_party',
      'downloads',
      'anonymous_crash',
      'anonymous_usage',
      'tracking_provider',
      'debrid_provider',
      'link_discord',
    };
    if (preferences.keys.any((key) => !preferenceKeys.contains(key))) {
      throw const FormatException(
        'The phone setup contains an unknown preference.',
      );
    }
    const sourceKeys = {'repository_urls', 'manifest_urls'};
    if (sources.keys.any((key) => !sourceKeys.contains(key))) {
      throw const FormatException('The phone setup contains unknown sources.');
    }
    final credentialKeys = protocolVersion == 1
        ? const {'tracking_token', 'debrid_credential'}
        : const {'tracking', 'debrid', 'discord'};
    if (credentials.keys.any((key) => !credentialKeys.contains(key))) {
      throw const FormatException(
        'The phone setup contains unknown credentials.',
      );
    }

    final parsedPreferences = PhoneSetupPreferences(
      preferredAudio: _enumValue(preferences['preferred_audio'], const {
        'dub',
        'sub',
      }),
      titleLanguage: _enumValue(preferences['title_language'], const {
        'english',
        'romaji',
      }),
      useBuiltInKeyboard: _nullableBool(preferences['built_in_keyboard']),
      autoSkipIntros: _nullableBool(preferences['auto_skip_intros']),
      autoSkipOutros: _nullableBool(preferences['auto_skip_outros']),
      homeLayout: _enumValue(preferences['home_layout'], const {
        'cinematic',
        'compact',
      }),
      interfaceMode: _enumValue(preferences['interface_mode'], const {
        'automatic',
        'television',
        'phone',
      }),
      showHero: _nullableBool(preferences['show_hero']),
      showPosterMetadata: _nullableBool(preferences['show_poster_metadata']),
      showMyList: _nullableBool(preferences['show_my_list']),
      showDiscover: _nullableBool(preferences['discover']),
      showCalendar: _nullableBool(preferences['calendar']),
      showWatchParty: _nullableBool(preferences['watch_party']),
      showDownloads: _nullableBool(preferences['downloads']),
      anonymousCrashReporting: _nullableBool(preferences['anonymous_crash']),
      anonymousUsageCount: _nullableBool(preferences['anonymous_usage']),
      trackingProvider: _enumValue(preferences['tracking_provider'], const {
        'anilist',
        'myanimelist',
      }),
      debridProvider: _enumValue(preferences['debrid_provider'], const {
        'realdebrid',
        'torbox',
        'alldebrid',
        'premiumize',
      }),
      linkDiscord: _nullableBool(preferences['link_discord']),
    );
    final repositories = _stringList(
      sources['repository_urls'],
      maximumItems: 8,
      field: 'Marketplace repository',
    );
    final manifests = _stringList(
      sources['manifest_urls'],
      maximumItems: 8,
      field: 'Torrent manifest',
    );
    final parsedCredentials = protocolVersion == 1
        ? _parseLegacyCredentials(credentials, parsedPreferences)
        : _parseStructuredCredentials(
            credentials,
            parsedPreferences,
            requireDiscordConfirmation: protocolVersion >= 3,
          );
    return PhoneSetupBundle(
      protocolVersion: protocolVersion,
      preferences: parsedPreferences,
      repositoryUrls: repositories,
      manifestUrls: manifests,
      credentials: parsedCredentials,
    );
  }
}

PhoneSetupCredentials _parseLegacyCredentials(
  Map<String, dynamic> credentials,
  PhoneSetupPreferences preferences,
) {
  final trackingToken = _credential(credentials['tracking_token']);
  final debridCredential = _credential(credentials['debrid_credential']);
  if (trackingToken != null && preferences.trackingProvider == null) {
    throw const FormatException(
      'A tracker token requires a selected tracker provider.',
    );
  }
  if (debridCredential != null && preferences.debridProvider == null) {
    throw const FormatException(
      'A debrid credential requires a selected debrid provider.',
    );
  }
  return PhoneSetupCredentials(
    trackingToken: trackingToken,
    debridCredential: debridCredential,
  );
}

PhoneSetupCredentials _parseStructuredCredentials(
  Map<String, dynamic> credentials,
  PhoneSetupPreferences preferences, {
  required bool requireDiscordConfirmation,
}) {
  final tracking = _parseTrackingCredentials(credentials['tracking']);
  final debrid = _parseDebridCredentials(credentials['debrid']);
  final discord = _parseDiscordCredentials(
    credentials['discord'],
    requireConfirmation: requireDiscordConfirmation,
  );
  if (tracking != null &&
      preferences.trackingProvider != null &&
      preferences.trackingProvider != tracking.provider) {
    throw const FormatException(
      'The tracker account does not match the selected tracker provider.',
    );
  }
  if (debrid != null &&
      preferences.debridProvider != null &&
      preferences.debridProvider != debrid.provider) {
    throw const FormatException(
      'The debrid account does not match the selected debrid provider.',
    );
  }
  return PhoneSetupCredentials(
    tracking: tracking,
    debrid: debrid,
    discord: discord,
  );
}

PhoneSetupTrackingCredentials? _parseTrackingCredentials(Object? value) {
  if (value == null) return null;
  final data = _stringMap(value, 'tracker credentials');
  const keys = {
    'provider',
    'access_token',
    'refresh_token',
    'token_type',
    'expires_at',
  };
  _rejectUnknownKeys(data, keys, 'tracker credentials');
  final provider = _requiredEnum(data['provider'], const {
    'anilist',
    'myanimelist',
  }, 'tracker provider');
  final accessToken = _requiredCredential(data['access_token']);
  final refreshToken = _credential(data['refresh_token']);
  final tokenType = _shortText(data['token_type'], maximum: 64);
  final expiresAt = _epochSeconds(data['expires_at']);
  if (provider == 'anilist' && refreshToken != null) {
    throw const FormatException(
      'AniList phone setup does not accept a refresh token.',
    );
  }
  if (provider == 'myanimelist' &&
      (refreshToken == null || expiresAt == null)) {
    throw const FormatException(
      'MyAnimeList phone setup requires refresh and expiry metadata.',
    );
  }
  return PhoneSetupTrackingCredentials(
    provider: provider,
    accessToken: accessToken,
    refreshToken: refreshToken,
    tokenType: tokenType,
    expiresAt: expiresAt,
  );
}

PhoneSetupDebridCredentials? _parseDebridCredentials(Object? value) {
  if (value == null) return null;
  final data = _stringMap(value, 'debrid credentials');
  const keys = {
    'provider',
    'access_token',
    'api_key',
    'refresh_token',
    'client_id',
    'client_secret',
    'expires_at',
  };
  _rejectUnknownKeys(data, keys, 'debrid credentials');
  final provider = _requiredEnum(data['provider'], const {
    'realdebrid',
    'torbox',
    'alldebrid',
    'premiumize',
  }, 'debrid provider');
  final accessToken = _credential(data['access_token']);
  final apiKey = _credential(data['api_key']);
  final refreshToken = _credential(data['refresh_token']);
  final clientId = _credential(data['client_id']);
  final clientSecret = _credential(data['client_secret']);
  final expiresAt = _epochSeconds(data['expires_at']);
  if (provider == 'realdebrid') {
    if (accessToken == null ||
        refreshToken == null ||
        clientId == null ||
        clientSecret == null ||
        apiKey != null) {
      throw const FormatException(
        'Real-Debrid phone setup requires complete OAuth credentials.',
      );
    }
  } else if (apiKey == null ||
      accessToken != null ||
      refreshToken != null ||
      clientId != null ||
      clientSecret != null ||
      expiresAt != null) {
    throw const FormatException('This debrid provider requires one API key.');
  }
  return PhoneSetupDebridCredentials(
    provider: provider,
    accessToken: accessToken,
    apiKey: apiKey,
    refreshToken: refreshToken,
    clientId: clientId,
    clientSecret: clientSecret,
    expiresAt: expiresAt,
  );
}

PhoneSetupDiscordCredentials? _parseDiscordCredentials(
  Object? value, {
  required bool requireConfirmation,
}) {
  if (value == null) return null;
  if (!requireConfirmation) {
    throw const FormatException(
      'Discord phone setup requires protocol version 3 and a minimum-age confirmation.',
    );
  }
  final data = _stringMap(value, 'Discord credentials');
  const keys = {
    'access_token',
    'refresh_token',
    'token_type',
    'expires_at',
    'scopes',
    'minimum_age_confirmation',
  };
  _rejectUnknownKeys(data, keys, 'Discord credentials');
  final tokenType = data['token_type'];
  if (tokenType is! int || tokenType != 1) {
    throw const FormatException('The Discord token type is invalid.');
  }
  final scopes = _scopeList(data['scopes']);
  if (!scopes.contains('openid') ||
      !scopes.contains('sdk.social_layer_presence')) {
    throw const FormatException('The Discord authorization scope is invalid.');
  }
  return PhoneSetupDiscordCredentials(
    accessToken: _requiredCredential(data['access_token']),
    refreshToken: _requiredCredential(data['refresh_token']),
    tokenType: tokenType,
    expiresAt:
        _epochSeconds(data['expires_at']) ??
        (throw const FormatException('The Discord token expiry is invalid.')),
    scopes: scopes,
    minimumAgeConfirmation: DiscordMinimumAgeConfirmation.parseExact(
      data['minimum_age_confirmation'],
    ),
  );
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

List<int> _decodeFixed(Object? value, int length) {
  if (value is! String || value.isEmpty || value.length > 256) {
    throw const FormatException('A phone-setup key component is invalid.');
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (bytes.length != length) throw const FormatException();
    return List<int>.unmodifiable(bytes);
  } catch (_) {
    throw const FormatException('A phone-setup key component is invalid.');
  }
}

Map<String, dynamic> _stringMap(Object? value, String label) {
  if (value == null) return <String, dynamic>{};
  if (value is! Map) {
    throw FormatException('The phone setup $label section is invalid.');
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('The phone setup $label section is invalid.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? _enumValue(Object? value, Set<String> allowed) {
  if (value == null) return null;
  if (value is! String || !allowed.contains(value)) {
    throw const FormatException('A phone-setup choice is invalid.');
  }
  return value;
}

bool? _nullableBool(Object? value) {
  if (value == null) return null;
  if (value is! bool) {
    throw const FormatException('A phone-setup toggle is invalid.');
  }
  return value;
}

List<String> _stringList(
  Object? value, {
  required int maximumItems,
  required String field,
}) {
  if (value == null) return const [];
  if (value is! List || value.length > maximumItems) {
    throw FormatException('$field entries are invalid.');
  }
  final result = <String>[];
  final seen = <String>{};
  for (final item in value) {
    if (item is! String || item.isEmpty || item.length > 2048) {
      throw FormatException('A $field entry is invalid.');
    }
    if (seen.add(item)) result.add(item);
  }
  return List<String>.unmodifiable(result);
}

String? _credential(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String) {
    throw const FormatException('An account credential is invalid.');
  }
  final normalized = value.trim();
  if (normalized.length < 4 || normalized.length > 4096) {
    throw const FormatException('An account credential is invalid.');
  }
  if (value.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    throw const FormatException('An account credential is invalid.');
  }
  return normalized;
}

String _requiredCredential(Object? value) =>
    _credential(value) ??
    (throw const FormatException('An account credential is missing.'));

String _requiredEnum(Object? value, Set<String> allowed, String label) {
  final parsed = _enumValue(value, allowed);
  if (parsed == null) throw FormatException('The $label is missing.');
  return parsed;
}

void _rejectUnknownKeys(
  Map<String, dynamic> value,
  Set<String> allowed,
  String label,
) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw FormatException('The phone setup contains unknown $label fields.');
  }
}

String? _shortText(Object? value, {required int maximum}) {
  if (value == null || value == '') return null;
  if (value is! String) {
    throw const FormatException('Account metadata is invalid.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      normalized.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw const FormatException('Account metadata is invalid.');
  }
  return normalized;
}

DateTime? _epochSeconds(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 946684800 || value > 4102444800) {
    throw const FormatException('An account token expiry is invalid.');
  }
  return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
}

List<String> _scopeList(Object? value) {
  if (value is! List || value.isEmpty || value.length > 16) {
    throw const FormatException('The Discord authorization scope is invalid.');
  }
  final scopes = <String>[];
  final seen = <String>{};
  for (final item in value) {
    final scope = _shortText(item, maximum: 128);
    if (scope == null || !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(scope)) {
      throw const FormatException(
        'The Discord authorization scope is invalid.',
      );
    }
    if (seen.add(scope)) scopes.add(scope);
  }
  return List<String>.unmodifiable(scopes);
}

List<int> decodeSetupBase64Url(
  Object? value, {
  required int minimum,
  required int maximum,
  required String label,
}) {
  // [minimum] and [maximum] describe decoded bytes. Base64url expands its
  // input, so applying those limits to the encoded string rejects every
  // correctly sized P-256 key and AES-GCM nonce before they can be decoded.
  final maximumEncodedLength = ((maximum + 2) ~/ 3) * 4;
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumEncodedLength) {
    throw FormatException('The encrypted $label is invalid.');
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (bytes.length < minimum || bytes.length > maximum) {
      throw const FormatException();
    }
    return List<int>.unmodifiable(bytes);
  } catch (_) {
    throw FormatException('The encrypted $label is invalid.');
  }
}
