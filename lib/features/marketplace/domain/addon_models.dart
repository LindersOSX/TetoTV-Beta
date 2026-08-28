import 'dart:convert';
import 'dart:io';

/// Stable identity used for add-on ownership, persistence, and updates.
///
/// Seanime repositories in the wild occasionally change only the ASCII
/// casing of an ID between the catalog and manifest. IDs are restricted to
/// ASCII letters, numbers, dots, underscores, and hyphens, so lower-casing is
/// deterministic and does not broaden the accepted identifier grammar.
String marketplaceAddonIdentityKey(String id) => id.trim().toLowerCase();

bool marketplaceAddonIdsMatch(String left, String right) =>
    marketplaceAddonIdentityKey(left) == marketplaceAddonIdentityKey(right);

/// Stable catalog sort choices exposed by the Marketplace screen.
enum MarketplaceCatalogSort { name, language }

/// Returns the normalized content-language code declared by an add-on.
///
/// Both common Seanime catalog formats use `lang`, while some manifests use
/// `locale`. [MarketplaceAddon.tryParse] stores either spelling in [locale].
/// Grouping regional variants by their primary language keeps entries such as
/// `en`, `en-US`, and `en_GB` under one useful TV filter.
String marketplaceCatalogLanguageCode(MarketplaceAddon addon) {
  final raw = addon.locale.trim().toLowerCase().replaceAll('_', '-');
  if (raw.isEmpty || raw == 'unknown') return 'unknown';
  final primary = raw.split('-').first;
  return RegExp(r'^[a-z]{2,3}$').hasMatch(primary) ? primary : raw;
}

/// Unique declared catalog languages in deterministic display order.
List<String> marketplaceCatalogLanguages(Iterable<MarketplaceAddon> addons) {
  final languages = addons
      .map(marketplaceCatalogLanguageCode)
      .toSet()
      .toList(growable: false);
  languages.sort((left, right) {
    if (left == 'unknown') return right == 'unknown' ? 0 : 1;
    if (right == 'unknown') return -1;
    return marketplaceCatalogLanguageLabel(
      left,
    ).compareTo(marketplaceCatalogLanguageLabel(right));
  });
  return languages;
}

/// Filters and sorts a catalog without mutating the controller-owned list.
///
/// The implementation is O(n log n), so repositories with hundreds of
/// installable providers remain inexpensive to browse and re-sort locally.
List<MarketplaceAddon> filterAndSortMarketplaceCatalog(
  Iterable<MarketplaceAddon> addons, {
  String? languageCode,
  MarketplaceCatalogSort sort = MarketplaceCatalogSort.name,
}) {
  final selected = languageCode?.trim().toLowerCase();
  final result = addons
      .where(
        (addon) =>
            selected == null ||
            selected.isEmpty ||
            marketplaceCatalogLanguageCode(addon) == selected,
      )
      .toList(growable: false);
  int compareName(MarketplaceAddon left, MarketplaceAddon right) {
    final byName = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    return byName != 0 ? byName : left.id.compareTo(right.id);
  }

  result.sort((left, right) {
    if (sort == MarketplaceCatalogSort.language) {
      final byLanguage =
          marketplaceCatalogLanguageLabel(
            marketplaceCatalogLanguageCode(left),
          ).compareTo(
            marketplaceCatalogLanguageLabel(
              marketplaceCatalogLanguageCode(right),
            ),
          );
      if (byLanguage != 0) return byLanguage;
    }
    return compareName(left, right);
  });
  return result;
}

/// Human-readable labels for language codes commonly used by Seanime repos.
/// Unknown future codes remain usable and display in uppercase.
String marketplaceCatalogLanguageLabel(String code) =>
    switch (code.trim().toLowerCase()) {
      'ar' => 'Arabic',
      'de' => 'German',
      'en' => 'English',
      'es' => 'Spanish',
      'fr' => 'French',
      'hi' => 'Hindi',
      'id' => 'Indonesian',
      'it' => 'Italian',
      'ja' => 'Japanese',
      'ko' => 'Korean',
      'nl' => 'Dutch',
      'pl' => 'Polish',
      'pt' => 'Portuguese',
      'ru' => 'Russian',
      'th' => 'Thai',
      'tr' => 'Turkish',
      'uk' => 'Ukrainian',
      'vi' => 'Vietnamese',
      'zh' => 'Chinese',
      'unknown' || '' => 'Unknown',
      final value => value.toUpperCase(),
    };

class AddonRepository {
  const AddonRepository({
    required this.url,
    this.enabled = true,
    this.isDefault = false,
    required this.updatedAt,
  });

  final String url;
  final bool enabled;
  final bool isDefault;
  final DateTime updatedAt;

  AddonRepository copyWith({bool? enabled, DateTime? updatedAt}) =>
      AddonRepository(
        url: url,
        enabled: enabled ?? this.enabled,
        isDefault: isDefault,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class BulkSourceAddResult {
  const BulkSourceAddResult({
    required this.added,
    required this.duplicates,
    required this.rejected,
  });

  final int added;
  final int duplicates;
  final List<String> rejected;

  int get rejectedCount => rejected.length;

  String get summary {
    final parts = <String>['Added $added'];
    if (duplicates > 0) parts.add('$duplicates already saved');
    if (rejectedCount > 0) parts.add('$rejectedCount rejected');
    return '${parts.join(' • ')}.';
  }
}

/// Accepts URLs pasted one-per-line or separated by ordinary whitespace.
/// URLs containing spaces must already be percent encoded, as required by URI
/// syntax. The bound prevents an accidental clipboard dump from creating an
/// unbounded validation queue.
List<String> splitSourceUrlInput(String value) => value
    .split(RegExp(r'\s+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .take(64)
    .toList(growable: false);

class MarketplaceAddon {
  const MarketplaceAddon({
    required this.id,
    required this.name,
    required this.description,
    required this.author,
    required this.manifestUri,
    required this.repositoryUrl,
    required this.language,
    required this.type,
    required this.locale,
    this.version,
    this.iconUri,
    this.payloadUri,
    this.inlinePayload,
    this.userConfigDefaults = const {},
    this.reportedWorking,
    this.reportedBroken = false,
    this.isDeprecated = false,
    this.lastWorkingVersion,
  });

  final String id;
  final String name;
  final String description;
  final String author;
  final Uri manifestUri;
  final String repositoryUrl;
  final String language;
  final String type;
  final String locale;
  final String? version;
  final Uri? iconUri;
  final Uri? payloadUri;
  final String? inlinePayload;
  final Map<String, String> userConfigDefaults;

  /// Optional community-catalog metadata. This is advisory only: executable
  /// compatibility is still validated from the separately downloaded
  /// manifest and payload.
  final bool? reportedWorking;
  final bool reportedBroken;
  final bool isDeprecated;
  final String? lastWorkingVersion;

  bool get isOnlineStreamProvider => type == 'onlinestream-provider';
  bool get isJavascript => language.toLowerCase() == 'javascript';
  bool get isTypescript => language.toLowerCase() == 'typescript';
  bool get isCompatible =>
      isOnlineStreamProvider && (isJavascript || isTypescript);

  MarketplaceAddon mergeManifest(MarketplaceAddon manifest) => MarketplaceAddon(
    id: id,
    name: manifest.name.isEmpty ? name : manifest.name,
    description: manifest.description.isEmpty
        ? description
        : manifest.description,
    author: manifest.author == 'Unknown' ? author : manifest.author,
    manifestUri: manifestUri,
    repositoryUrl: repositoryUrl,
    language: manifest.language.isEmpty ? language : manifest.language,
    type: manifest.type.isEmpty ? type : manifest.type,
    locale: manifest.locale == 'unknown' ? locale : manifest.locale,
    version: manifest.version ?? version,
    iconUri: manifest.iconUri ?? iconUri,
    payloadUri: manifest.payloadUri ?? payloadUri,
    inlinePayload: manifest.inlinePayload ?? inlinePayload,
    userConfigDefaults: manifest.userConfigDefaults.isEmpty
        ? userConfigDefaults
        : manifest.userConfigDefaults,
    reportedWorking: manifest.reportedWorking ?? reportedWorking,
    reportedBroken: reportedBroken || manifest.reportedBroken,
    isDeprecated: isDeprecated || manifest.isDeprecated,
    lastWorkingVersion: manifest.lastWorkingVersion ?? lastWorkingVersion,
  );

  MarketplaceAddon withCatalogStatus({
    bool? reportedWorking,
    bool? reportedBroken,
    bool? isDeprecated,
    String? lastWorkingVersion,
  }) => MarketplaceAddon(
    id: id,
    name: name,
    description: description,
    author: author,
    manifestUri: manifestUri,
    repositoryUrl: repositoryUrl,
    language: language,
    type: type,
    locale: locale,
    version: version,
    iconUri: iconUri,
    payloadUri: payloadUri,
    inlinePayload: inlinePayload,
    userConfigDefaults: userConfigDefaults,
    reportedWorking: reportedWorking ?? this.reportedWorking,
    reportedBroken: reportedBroken ?? this.reportedBroken,
    isDeprecated: isDeprecated ?? this.isDeprecated,
    lastWorkingVersion: lastWorkingVersion ?? this.lastWorkingVersion,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'author': author,
    'manifestURI': manifestUri.toString(),
    'repositoryURL': repositoryUrl,
    'language': language,
    'type': type,
    'lang': locale,
    'version': version,
    'icon': iconUri?.toString(),
    'payloadURI': payloadUri?.toString(),
    if (reportedWorking != null) 'workingTag': reportedWorking,
    if (reportedBroken) 'brokenTag': true,
    if (isDeprecated) 'deprecatedTag': true,
    if (lastWorkingVersion != null) 'lastWorkingVersion': lastWorkingVersion,
    if (userConfigDefaults.isNotEmpty)
      'userConfig': {
        'fields': [
          for (final entry in userConfigDefaults.entries)
            {'name': entry.key, 'default': entry.value},
        ],
      },
  };

  static MarketplaceAddon? tryParse(
    Object? value, {
    required String repositoryUrl,
    Uri? resourceBaseUri,
  }) {
    if (value is! Map) return null;
    final json = value.map((key, value) => MapEntry('$key', value));
    final id = _clean(
      _firstValue(json, const ['id', 'extensionId', 'identifier']),
      80,
    );
    final name = _clean(_firstValue(json, const ['name', 'title']), 120);
    final manifest = _safeMarketplaceResourceUri(
      _firstValue(json, const [
        'manifestURI',
        'manifestUri',
        'manifestURL',
        'manifestUrl',
        'manifest',
      ]),
      repositoryUrl: repositoryUrl,
      resourceBaseUri: resourceBaseUri,
    );
    if (id == null ||
        name == null ||
        manifest == null ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) {
      return null;
    }
    return MarketplaceAddon(
      id: id,
      name: name,
      description: _clean(json['description'], 600) ?? '',
      author: _clean(json['author'], 120) ?? 'Unknown',
      manifestUri: manifest,
      repositoryUrl: repositoryUrl,
      language: _normalizedAddonLanguage(
        _firstValue(json, const ['language', 'runtime']),
      ),
      type: _normalizedAddonType(_firstValue(json, const ['type', 'kind'])),
      locale:
          (_clean(_firstValue(json, const ['lang', 'locale']), 12) ?? 'unknown')
              .toLowerCase(),
      version: _clean(json['version'], 32),
      iconUri: _safeMarketplaceResourceUri(
        json['icon'],
        repositoryUrl: repositoryUrl,
        resourceBaseUri: resourceBaseUri,
      ),
      payloadUri: _safeMarketplaceResourceUri(
        _firstValue(json, const [
          'payloadURI',
          'payloadUri',
          'payloadURL',
          'payloadUrl',
          'sourceURI',
          'sourceUri',
          'sourceURL',
          'sourceUrl',
          'scriptURI',
          'scriptUri',
          'scriptURL',
          'scriptUrl',
        ]),
        repositoryUrl: repositoryUrl,
        resourceBaseUri: resourceBaseUri,
      ),
      inlinePayload: _cleanPayload(json['payload']),
      userConfigDefaults: _userConfigDefaults(json['userConfig']),
      reportedWorking: _optionalBool(
        _firstValue(json, const ['workingTag', 'isWorking', 'working']),
      ),
      reportedBroken:
          _optionalBool(
            _firstValue(json, const ['brokenTag', 'isBroken', 'broken']),
          ) ??
          false,
      isDeprecated:
          _optionalBool(
            _firstValue(json, const [
              'deprecatedTag',
              'isDeprecated',
              'deprecated',
            ]),
          ) ??
          false,
      lastWorkingVersion: _clean(json['lastWorkingVersion'], 32),
    );
  }
}

Uri? _safeMarketplaceResourceUri(
  Object? value, {
  required String repositoryUrl,
  Uri? resourceBaseUri,
}) {
  if (value is! String || value.trim().isEmpty || value.length > 2048) {
    return null;
  }
  final raw = Uri.tryParse(value.trim());
  if (raw == null) return null;
  if (raw.hasScheme || raw.hasAuthority) {
    return safePublicHttpsUri(raw.toString());
  }
  final base = resourceBaseUri ?? safePublicHttpsUri(repositoryUrl);
  if (base == null) return null;
  return safePublicHttpsUri(base.resolveUri(raw).toString());
}

Object? _firstValue(Map<String, Object?> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value != null) return value;
  }
  return null;
}

bool? _optionalBool(Object? value) => switch (value) {
  final bool result => result,
  final num result =>
    result == 1
        ? true
        : result == 0
        ? false
        : null,
  final String result => switch (result.trim().toLowerCase()) {
    'true' || 'yes' || '1' => true,
    'false' || 'no' || '0' => false,
    _ => null,
  },
  _ => null,
};

String _normalizedAddonLanguage(Object? value) {
  final language = (_clean(value, 24) ?? '').toLowerCase();
  return switch (language) {
    'js' => 'javascript',
    'ts' => 'typescript',
    _ => language,
  };
}

String _normalizedAddonType(Object? value) {
  final type = (_clean(value, 48) ?? '').toLowerCase();
  final compact = type.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return switch (compact) {
    'onlinestreamprovider' || 'animestreamprovider' => 'onlinestream-provider',
    _ => type,
  };
}

Map<String, String> _userConfigDefaults(Object? value) {
  if (value is! Map || value['fields'] is! List) return const {};
  final result = <String, String>{};
  for (final raw in (value['fields'] as List).take(32)) {
    if (raw is! Map) continue;
    final name = _clean(raw['name'], 80);
    final defaultValue = _clean(raw['default'], 2048);
    if (name != null &&
        defaultValue != null &&
        RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
      result[name] = defaultValue;
    }
  }
  return Map.unmodifiable(result);
}

String? _cleanPayload(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  if (utf8.encode(value).length > 768 * 1024) return null;
  return value;
}

class InstalledStreamingAddon {
  const InstalledStreamingAddon({
    required this.manifest,
    required this.payload,
    required this.enabled,
    required this.installedAt,
    required this.updatedAt,
  });

  final MarketplaceAddon manifest;
  final String payload;
  final bool enabled;
  final DateTime installedAt;
  final DateTime updatedAt;

  InstalledStreamingAddon copyWith({bool? enabled}) => InstalledStreamingAddon(
    manifest: manifest,
    payload: payload,
    enabled: enabled ?? this.enabled,
    installedAt: installedAt,
    updatedAt: updatedAt,
  );

  factory InstalledStreamingAddon.fromRow(Map<String, Object?> row) {
    final raw = jsonDecode(row['manifest_json']! as String);
    final manifest = MarketplaceAddon.tryParse(
      raw,
      repositoryUrl: row['repository_url']! as String,
    );
    if (manifest == null) throw const FormatException('Invalid addon manifest');
    return InstalledStreamingAddon(
      manifest: manifest,
      payload: row['payload']! as String,
      enabled: row['enabled'] == 1,
      installedAt: DateTime.fromMillisecondsSinceEpoch(
        row['installed_at']! as int,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
    );
  }
}

enum WebStreamAudioCapability {
  unknown,
  sub,
  dub,
  subAndDub;

  bool get supportsSub =>
      this == WebStreamAudioCapability.sub ||
      this == WebStreamAudioCapability.subAndDub;

  bool get supportsDub =>
      this == WebStreamAudioCapability.dub ||
      this == WebStreamAudioCapability.subAndDub;

  String get pickerLabel => switch (this) {
    WebStreamAudioCapability.unknown => 'AUDIO UNKNOWN',
    WebStreamAudioCapability.sub => 'SUB',
    WebStreamAudioCapability.dub => 'DUB',
    // Multi-audio remains visible in both picker filters. The filter used to
    // launch it determines MPV's initial Japanese or English track.
    WebStreamAudioCapability.subAndDub => 'SUB / DUB',
  };
}

WebStreamAudioCapability mergeWebStreamAudioCapabilities(
  WebStreamAudioCapability left,
  WebStreamAudioCapability right,
) {
  final supportsSub = left.supportsSub || right.supportsSub;
  final supportsDub = left.supportsDub || right.supportsDub;
  if (supportsSub && supportsDub) return WebStreamAudioCapability.subAndDub;
  if (supportsDub) return WebStreamAudioCapability.dub;
  if (supportsSub) return WebStreamAudioCapability.sub;
  return WebStreamAudioCapability.unknown;
}

WebStreamAudioCapability webStreamAudioCapabilityFromWire(Object? value) {
  final support = _webStreamAudioSupportFromWire(value);
  if (support & _webStreamSubAudioSupport != 0 &&
      support & _webStreamDubAudioSupport != 0) {
    return WebStreamAudioCapability.subAndDub;
  }
  if (support & _webStreamDubAudioSupport != 0) {
    return WebStreamAudioCapability.dub;
  }
  if (support & _webStreamSubAudioSupport != 0) {
    return WebStreamAudioCapability.sub;
  }
  return WebStreamAudioCapability.unknown;
}

const _webStreamSubAudioSupport = 1;
const _webStreamDubAudioSupport = 2;

/// Normalizes the small collection of shapes used by community providers.
///
/// Seanime extensions commonly report a scalar (`both`, `dub`, `sub`), but
/// some expose audio-language arrays or track objects instead. Keeping this
/// normalization at the add-on boundary prevents typed picker filtering from
/// treating a known dual-audio result as unknown. Only audio-related keys are
/// traversed, so an English subtitle label is not mistaken for English audio.
int _webStreamAudioSupportFromWire(
  Object? value, {
  int depth = 0,
  bool insideAudioTrack = false,
}) {
  if (value == null || depth > 4) return 0;
  if (value is WebStreamAudioCapability) {
    return (value.supportsSub ? _webStreamSubAudioSupport : 0) |
        (value.supportsDub ? _webStreamDubAudioSupport : 0);
  }
  if (value is Iterable) {
    var support = 0;
    for (final item in value.take(32)) {
      support |= _webStreamAudioSupportFromWire(
        item,
        depth: depth + 1,
        insideAudioTrack: insideAudioTrack,
      );
    }
    return support;
  }
  if (value is Map) {
    var support = 0;
    var visited = 0;
    for (final entry in value.entries) {
      if (++visited > 32) break;
      final key = entry.key.toString().trim().toLowerCase().replaceAll(
        RegExp(r'[^a-z]+'),
        '',
      );
      final enabled = switch (entry.value) {
        true => true,
        1 => true,
        final String item => const {
          'true',
          'yes',
          '1',
        }.contains(item.trim().toLowerCase()),
        _ => false,
      };
      if (enabled) {
        if (const {
          'both',
          'dualaudio',
          'multiaudio',
          'subanddub',
          'supportssubanddub',
        }.contains(key)) {
          support |= _webStreamSubAudioSupport | _webStreamDubAudioSupport;
        } else if (const {
          'sub',
          'subbed',
          'supportssub',
          'hassub',
          'japaneseaudio',
          'originalaudio',
        }.contains(key)) {
          support |= _webStreamSubAudioSupport;
        } else if (const {
          'dub',
          'dubbed',
          'supportsdub',
          'hasdub',
          'englishaudio',
          'hasenglishaudio',
        }.contains(key)) {
          support |= _webStreamDubAudioSupport;
        }
      }
      final audioTrackCollection = const {
        'audiotracks',
        'audiostreams',
      }.contains(key);
      final audioMetadata = const {
        'audiocapability',
        'audiomode',
        'languagemode',
        'audiolanguage',
        'audiolanguages',
        'availableaudiolanguages',
        'subordub',
      }.contains(key);
      final audioTrackField =
          insideAudioTrack &&
          const {'language', 'lang', 'label', 'name', 'items'}.contains(key);
      if (audioTrackCollection || audioMetadata || audioTrackField) {
        support |= _webStreamAudioSupportFromWire(
          entry.value,
          depth: depth + 1,
          insideAudioTrack: insideAudioTrack || audioTrackCollection,
        );
      }
    }
    return support;
  }
  if (value is! String) return 0;

  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (normalized.isEmpty) return 0;
  final compact = normalized.replaceAll(' ', '');
  if (const {
        'both',
        'subdub',
        'dubsub',
        'dualaudio',
        'multiaudio',
        'subanddub',
        'dubandsub',
      }.contains(compact) ||
      compact.contains('dualaudio') ||
      compact.contains('multiaudio') ||
      compact.contains('subanddub') ||
      compact.contains('dubandsub')) {
    return _webStreamSubAudioSupport | _webStreamDubAudioSupport;
  }

  final words = normalized.split(RegExp(r'\s+')).toSet();
  var support = 0;
  if (words.intersection(const {
    'sub',
    'subbed',
    'subtitle',
    'subtitles',
    'subtitled',
  }).isNotEmpty) {
    support |= _webStreamSubAudioSupport;
  }
  if (words.intersection(const {'dub', 'dubbed'}).isNotEmpty) {
    support |= _webStreamDubAudioSupport;
  }

  final subtitleContext = words.intersection(const {
    'subtitle',
    'subtitles',
    'caption',
    'captions',
  }).isNotEmpty;
  final hasEnglish = words.intersection(const {
    'en',
    'eng',
    'english',
  }).isNotEmpty;
  final hasJapanese = words.intersection(const {
    'ja',
    'jp',
    'jpn',
    'japanese',
  }).isNotEmpty;
  if (!subtitleContext && hasEnglish) support |= _webStreamDubAudioSupport;
  if (!subtitleContext && hasJapanese) support |= _webStreamSubAudioSupport;
  return support;
}

class WebStreamResult {
  const WebStreamResult({
    required this.providerId,
    required this.providerName,
    required this.title,
    required this.uri,
    this.quality,
    this.headers = const {},
    this.subtitleUri,
    this.subtitleLanguage,
    this.isDubbed = false,
    this.audioCapability,
    this.matchedEpisodeNumber,
    this.matchedSeasonNumber,
    this.matchedSeriesTitle,
  });

  final String providerId;
  final String providerName;
  final String title;
  final Uri uri;
  final String? quality;
  final Map<String, String> headers;
  final Uri? subtitleUri;
  final String? subtitleLanguage;

  /// Legacy provider hint retained for extension compatibility.
  ///
  /// New adapters should set [audioCapability]. A null capability preserves
  /// the historical mapping for older providers; an explicitly unknown
  /// capability is never guessed to be Sub or Dub.
  final bool isDubbed;
  final WebStreamAudioCapability? audioCapability;

  /// Bounded public identity selected by the provider before extraction.
  /// These fields contain no URL, server ID, filename, or credential.
  final int? matchedEpisodeNumber;
  final int? matchedSeasonNumber;
  final String? matchedSeriesTitle;

  WebStreamAudioCapability get effectiveAudioCapability =>
      audioCapability ??
      (isDubbed
          ? WebStreamAudioCapability.dub
          : WebStreamAudioCapability.unknown);

  bool get supportsSubAudio => effectiveAudioCapability.supportsSub;
  bool get supportsDubAudio => effectiveAudioCapability.supportsDub;
  bool get hasKnownAudioCapability =>
      effectiveAudioCapability != WebStreamAudioCapability.unknown;

  WebStreamResult withAudioCapability(WebStreamAudioCapability capability) =>
      WebStreamResult(
        providerId: providerId,
        providerName: providerName,
        title: title,
        uri: uri,
        quality: quality,
        headers: headers,
        subtitleUri: subtitleUri,
        subtitleLanguage: subtitleLanguage,
        isDubbed: capability.supportsDub,
        audioCapability: capability,
        matchedEpisodeNumber: matchedEpisodeNumber,
        matchedSeasonNumber: matchedSeasonNumber,
        matchedSeriesTitle: matchedSeriesTitle,
      );
}

String webStreamProviderIdentity(WebStreamResult stream) {
  final id = stream.providerId.trim().toLowerCase();
  if (id.isNotEmpty) return id;
  final name = stream.providerName.trim().toLowerCase();
  return name.isEmpty ? 'unknown' : name;
}

enum WebProviderFailureStatus { noMatch, advisory, unavailable, paused, failed }

class WebProviderFailure {
  const WebProviderFailure({
    required this.providerName,
    required this.message,
    this.status = WebProviderFailureStatus.failed,
    this.providerId,
    this.providerVersion,
    this.repositoryHost,
    this.executableHost,
    this.stage,
    this.reason,
  });

  final String providerName;
  final String message;
  final WebProviderFailureStatus status;
  final String? providerId;
  final String? providerVersion;
  final String? repositoryHost;
  final String? executableHost;
  final String? stage;
  final String? reason;
}

class WebStreamAggregation {
  const WebStreamAggregation({
    this.streams = const [],
    this.failures = const [],
  });

  final List<WebStreamResult> streams;
  final List<WebProviderFailure> failures;
}

Uri? safePublicHttpsUri(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty ||
      host == 'localhost' ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      _literalAddressIsNonPublic(host)) {
    return null;
  }
  return uri.removeFragment();
}

typedef PublicHostLookup = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> resolvePublicNetworkTarget(
  Uri uri, {
  PublicHostLookup? lookup,
}) async {
  if (safePublicHttpsUri(uri.toString()) == null) {
    throw const FormatException('Only public HTTPS resources are allowed.');
  }
  final addresses = await (lookup ?? InternetAddress.lookup)(
    uri.host,
  ).timeout(const Duration(seconds: 4));
  if (addresses.isEmpty || addresses.any(_isNonPublicAddress)) {
    throw const FormatException(
      'The resource host does not resolve to a public address.',
    );
  }
  return List<InternetAddress>.unmodifiable(addresses);
}

Future<void> validatePublicNetworkTarget(
  Uri uri, {
  PublicHostLookup? lookup,
}) async {
  await resolvePublicNetworkTarget(uri, lookup: lookup);
}

/// Creates an HTTPS client whose socket is connected to the exact public IP
/// address that was validated for the request. This closes the DNS-rebinding
/// gap between a preflight lookup and the operating system's later connect.
///
/// TLS still authenticates [Uri.host] (including SNI); certificates are never
/// accepted for the pinned IP address and no bad-certificate callback is used.
HttpClient createPinnedPublicHttpsClient({PublicHostLookup? lookup}) {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost != null || proxyPort != null) {
      throw const FormatException(
        'Network proxies are not permitted for addon resources.',
      );
    }
    final addresses = await resolvePublicNetworkTarget(uri, lookup: lookup);
    ConnectionTask<Socket>? activeTask;
    Socket? connectedSocket;
    var cancelled = false;
    final secureSocket = () async {
      Object? lastError;
      StackTrace? lastStack;
      for (final address in addresses) {
        if (cancelled) {
          throw const SocketException('Connection attempt was cancelled.');
        }
        try {
          activeTask = await Socket.startConnect(address, uri.port);
          final socket = await activeTask!.socket;
          connectedSocket = socket;
          if (cancelled) {
            socket.destroy();
            throw const SocketException('Connection attempt was cancelled.');
          }
          return await SecureSocket.secure(
            socket,
            host: uri.host,
            supportedProtocols: const ['http/1.1'],
          );
        } catch (error, stackTrace) {
          connectedSocket?.destroy();
          connectedSocket = null;
          if (cancelled) rethrow;
          lastError = error;
          lastStack = stackTrace;
        }
      }
      Error.throwWithStackTrace(
        lastError ?? const SocketException('No public address was available.'),
        lastStack ?? StackTrace.current,
      );
    }();
    return ConnectionTask.fromSocket<Socket>(secureSocket, () {
      cancelled = true;
      activeTask?.cancel();
      connectedSocket?.destroy();
    });
  };
  return client;
}

bool _literalAddressIsNonPublic(String host) {
  final address = InternetAddress.tryParse(host);
  return address != null && _isNonPublicAddress(address);
}

bool _isNonPublicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _isNonPublicIpv4(bytes);
  }
  if (bytes.length != 16) return true;

  // IPv4-mapped IPv6 (::ffff:a.b.c.d) must be checked using the embedded
  // IPv4 address. Otherwise loopback/RFC1918 literals can bypass IPv4 guards.
  final isIpv4Mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (isIpv4Mapped) return _isNonPublicIpv4(bytes.sublist(12));

  final isUnspecified = bytes.every((byte) => byte == 0);
  final isLoopback =
      bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  final isIpv4Compatible = bytes.take(12).every((byte) => byte == 0);
  final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc; // fc00::/7
  final isLinkLocal =
      bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80; // fe80::/10
  final isSiteLocal =
      bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0; // fec0::/10
  final isMulticast = bytes[0] == 0xff; // ff00::/8
  final isDocumentation =
      bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8; // 2001:db8::/32
  final isNat64WellKnown =
      bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      bytes.sublist(4, 12).every((byte) => byte == 0);
  final nat64MapsNonPublic =
      isNat64WellKnown && _isNonPublicIpv4(bytes.sublist(12));
  final isNat64LocalUse =
      bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      bytes[4] == 0x00 &&
      bytes[5] == 0x01; // 64:ff9b:1::/48 (RFC 8215 local-use translation)
  final is6to4 = bytes[0] == 0x20 && bytes[1] == 0x02;
  final sixToFourMapsNonPublic =
      is6to4 && _isNonPublicIpv4(bytes.sublist(2, 6));
  return isUnspecified ||
      isLoopback ||
      isIpv4Compatible ||
      isUniqueLocal ||
      isLinkLocal ||
      isSiteLocal ||
      isMulticast ||
      isDocumentation ||
      nat64MapsNonPublic ||
      isNat64LocalUse ||
      sixToFourMapsNonPublic;
}

bool _isNonPublicIpv4(List<int> bytes) {
  if (bytes.length != 4) return true;
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  return first == 0 || // current network / unspecified
      first == 10 || // RFC1918
      (first == 100 && second >= 64 && second <= 127) || // CGNAT
      first == 127 || // loopback
      (first == 169 && second == 254) || // link-local
      (first == 172 && second >= 16 && second <= 31) || // RFC1918
      (first == 192 && second == 0 && third == 0) || // IETF assignments
      (first == 192 && second == 0 && third == 2) || // documentation
      (first == 192 && second == 88 && third == 99) || // deprecated 6to4
      (first == 192 && second == 168) || // RFC1918
      (first == 198 && (second == 18 || second == 19)) || // benchmarking
      (first == 198 && second == 51 && third == 100) || // documentation
      (first == 203 && second == 0 && third == 113) || // documentation
      first >= 224; // multicast, reserved, limited broadcast
}

String? _clean(Object? value, int maximum) {
  if (value is! String) return null;
  final cleaned = value.replaceAll(RegExp(r'[\x00-\x1F]'), ' ').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= maximum ? cleaned : cleaned.substring(0, maximum);
}
