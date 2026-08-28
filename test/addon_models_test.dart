import 'dart:io';

import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts a compatible JavaScript stream provider', () {
    final addon = MarketplaceAddon.tryParse({
      'id': 'provider.test',
      'name': 'Provider Test',
      'description': 'A provider',
      'author': 'Tester',
      'manifestURI': 'https://example.com/manifest.json',
      'payloadURI': 'https://example.com/provider.js',
      'type': 'onlinestream-provider',
      'language': 'javascript',
      'lang': 'en',
    }, repositoryUrl: 'https://example.com/marketplace.json');

    expect(addon, isNotNull);
    expect(addon!.isCompatible, isTrue);
    expect(addon.payloadUri.toString(), 'https://example.com/provider.js');
  });

  test('catalog language normalization groups regional locale variants', () {
    MarketplaceAddon addon(String id, String name, String locale) =>
        MarketplaceAddon(
          id: id,
          name: name,
          description: '',
          author: 'Test',
          manifestUri: Uri.parse('https://example.com/$id/manifest.json'),
          repositoryUrl: 'https://example.com/marketplace.json',
          language: 'javascript',
          type: 'onlinestream-provider',
          locale: locale,
        );

    final catalog = <MarketplaceAddon>[
      for (var index = 0; index < 120; index++)
        addon('english-$index', 'English $index', 'en-US'),
      for (var index = 0; index < 90; index++)
        addon('spanish-$index', 'Spanish $index', 'es'),
      addon('unknown', 'Unknown', 'unknown'),
    ];

    expect(marketplaceCatalogLanguages(catalog), ['en', 'es', 'unknown']);
    expect(
      filterAndSortMarketplaceCatalog(catalog, languageCode: 'en'),
      hasLength(120),
    );
    expect(marketplaceCatalogLanguageLabel('en'), 'English');
    expect(marketplaceCatalogLanguageLabel('tl'), 'TL');
  });

  test('rejects private, insecure, and malformed repository resources', () {
    expect(safePublicHttpsUri('http://example.com/catalog.json'), isNull);
    expect(safePublicHttpsUri('https://127.0.0.1/catalog.json'), isNull);
    expect(safePublicHttpsUri('https://10.0.0.1/catalog.json'), isNull);
    expect(safePublicHttpsUri('https://192.168.1.20/catalog.json'), isNull);
    expect(
      safePublicHttpsUri('https://user:password@example.com/catalog.json'),
      isNull,
    );
    expect(
      MarketplaceAddon.tryParse({
        'id': '../bad',
        'name': 'Bad',
        'manifestURI': 'https://example.com/manifest.json',
      }, repositoryUrl: 'https://example.com/catalog.json'),
      isNull,
    );
  });

  test('pinned client rejects a DNS public-to-private rebind', () async {
    var lookups = 0;
    Future<List<InternetAddress>> rebindingLookup(String _) async {
      lookups += 1;
      return [InternetAddress(lookups == 1 ? '93.184.216.34' : '127.0.0.1')];
    }

    final uri = Uri.parse('https://rebinding.example/catalog.json');
    await validatePublicNetworkTarget(uri, lookup: rebindingLookup);
    final client = createPinnedPublicHttpsClient(lookup: rebindingLookup);
    addTearDown(() => client.close(force: true));

    await expectLater(client.getUrl(uri), throwsA(isA<FormatException>()));
    expect(lookups, 2);
  });

  test('rejects non-public IPv4 and IPv6 literal targets', () {
    for (final value in [
      'https://[::ffff:127.0.0.1]/catalog.json',
      'https://[::ffff:10.0.0.1]/catalog.json',
      'https://[::]/catalog.json',
      'https://[fe80::1]/catalog.json',
      'https://[fc00::1]/catalog.json',
      'https://[fec0::1]/catalog.json',
      'https://[ff02::1]/catalog.json',
      'https://[2001:db8::1]/catalog.json',
      'https://[64:ff9b::7f00:1]/catalog.json',
      'https://[64:ff9b::a00:1]/catalog.json',
      'https://[64:ff9b:1::1]/catalog.json',
      'https://[2002:7f00:1::]/catalog.json',
      'https://100.64.0.1/catalog.json',
      'https://224.0.0.1/catalog.json',
      'https://240.0.0.1/catalog.json',
    ]) {
      expect(safePublicHttpsUri(value), isNull, reason: value);
    }
    expect(safePublicHttpsUri('https://93.184.216.34/catalog.json'), isNotNull);
    expect(
      safePublicHttpsUri(
        'https://[2606:2800:220:1:248:1893:25c8:1946]/catalog.json',
      ),
      isNotNull,
    );
  });

  test('accepts TypeScript providers for install-time compilation', () {
    final addon = MarketplaceAddon.tryParse({
      'id': 'provider-ts',
      'name': 'TS Provider',
      'manifestURI': 'https://example.com/manifest.json',
      'type': 'onlinestream-provider',
      'language': 'typescript',
    }, repositoryUrl: 'https://example.com/catalog.json');

    expect(addon, isNotNull);
    expect(addon!.isCompatible, isTrue);
    expect(addon.isTypescript, isTrue);
  });

  test('accepts a bounded inline provider payload', () {
    final addon = MarketplaceAddon.tryParse({
      'id': 'provider-inline',
      'name': 'Inline Provider',
      'manifestURI': 'https://example.com/manifest.json',
      'type': 'onlinestream-provider',
      'language': 'typescript',
      'payload': 'class Provider {}',
    }, repositoryUrl: 'https://example.com/catalog.json');

    expect(addon, isNotNull);
    expect(addon!.inlinePayload, 'class Provider {}');
  });

  test('retains marketplace user-config defaults', () {
    // A third-party marketplace may omit the optional version field.
    final addon = MarketplaceAddon.tryParse({
      'id': 'provider-config',
      'name': 'Configured provider',
      'manifestURI': 'https://example.com/provider/manifest.json',
      'payloadURI': 'https://example.com/provider/provider.ts',
      'type': 'onlinestream-provider',
      'language': 'typescript',
      'lang': 'en',
      'userConfig': {
        'requiredConfig': false,
        'fields': [
          {'name': 'api', 'default': 'https://api.example.com'},
          {'name': 'blobDomain', 'default': 'https://media.example.com'},
        ],
      },
    }, repositoryUrl: 'https://example.com/marketplace.json');

    expect(addon!.userConfigDefaults, {
      'api': 'https://api.example.com',
      'blobDomain': 'https://media.example.com',
    });
    final restored = MarketplaceAddon.tryParse(
      addon.toJson(),
      repositoryUrl: 'https://example.com/marketplace.json',
    );
    expect(restored!.userConfigDefaults, addon.userConfigDefaults);
  });

  test('resolves relative catalog and manifest resources safely', () {
    final summary = MarketplaceAddon.tryParse({
      'id': 'relative-provider',
      'name': 'Relative provider',
      'manifestUri': '../providers/relative/manifest.json#ignored',
      'type': 'online-stream-provider',
      'language': 'js',
    }, repositoryUrl: 'https://example.com/catalog/main.json');

    expect(summary, isNotNull);
    expect(
      summary!.manifestUri,
      Uri.parse('https://example.com/providers/relative/manifest.json'),
    );
    expect(summary.isCompatible, isTrue);

    final complete = MarketplaceAddon.tryParse(
      {
        'id': 'relative-provider',
        'name': 'Relative provider',
        'manifestUri': './manifest.json',
        'payloadUrl': './provider.ts#fragment',
        'type': 'anime_stream_provider',
        'language': 'ts',
      },
      repositoryUrl: 'https://example.com/catalog/main.json',
      resourceBaseUri: summary.manifestUri,
    );
    expect(
      complete!.payloadUri,
      Uri.parse('https://example.com/providers/relative/provider.ts'),
    );
    expect(complete.isCompatible, isTrue);
  });

  test('normalizes explicit and structured Web audio metadata', () {
    expect(
      webStreamAudioCapabilityFromWire('Both (Sub & Dub)'),
      WebStreamAudioCapability.subAndDub,
    );
    expect(
      webStreamAudioCapabilityFromWire({
        'availableAudioLanguages': ['ja-JP', 'en-US'],
      }),
      WebStreamAudioCapability.subAndDub,
      reason: 'English plus original-language audio is dual audio',
    );
    expect(
      webStreamAudioCapabilityFromWire({
        'audioTracks': [
          {'language': 'English'},
        ],
      }),
      WebStreamAudioCapability.dub,
    );
    expect(
      webStreamAudioCapabilityFromWire({
        'audioTracks': [
          {'language': 'Japanese'},
        ],
      }),
      WebStreamAudioCapability.sub,
    );
  });

  test('single Web audio metadata remains exclusive', () {
    expect(
      webStreamAudioCapabilityFromWire({'supportsSub': true}),
      WebStreamAudioCapability.sub,
    );
    expect(
      webStreamAudioCapabilityFromWire({'hasEnglishAudio': true}),
      WebStreamAudioCapability.dub,
    );
    expect(
      webStreamAudioCapabilityFromWire({
        'audioCapability': 'sub',
        'subtitleLanguage': 'English',
        'language': 'English',
      }),
      WebStreamAudioCapability.sub,
      reason: 'generic and subtitle language are not audio evidence',
    );
    expect(
      webStreamAudioCapabilityFromWire({'language': 'English'}),
      WebStreamAudioCapability.unknown,
    );
  });
}
