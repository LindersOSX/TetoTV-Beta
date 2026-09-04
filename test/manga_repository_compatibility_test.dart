import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/repository_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes Mihon protobuf links even when a query is present', () {
    final inspection = inspectExtensionRepositoryUri(
      Uri.parse(
        'https://github.com/keiyoushi/extensions/raw/repo/index.pb'
        '?utm_source=example',
      ),
    );

    expect(inspection.family, ExtensionRepositoryFamily.mihonNative);
    expect(inspection.isRejected, isTrue);
    expect(inspection.rejectionMessage, contains('native APK extensions'));
  });

  test('does not classify ordinary JSON names from their URI alone', () {
    for (final value in <String>[
      'https://repo.example/marketplace.json',
      'https://repo.example/repo.json',
      'https://repo.example/index.min.json',
    ]) {
      expect(
        inspectExtensionRepositoryUri(Uri.parse(value)).family,
        ExtensionRepositoryFamily.unknown,
      );
    }
  });

  test('recognizes current and legacy Mihon JSON shapes conservatively', () {
    final fingerprint = List<String>.filled(64, 'a').join();
    final current = <String, Object?>{
      'name': 'Example',
      'badgeLabel': 'EX',
      'signingKey': fingerprint,
      'contact': <String, Object?>{'website': 'https://example.test'},
      'extensionList': <String, Object?>{'extensions': <Object?>[]},
    };
    final descriptor = <String, Object?>{
      'index_v2': 'https://example.test/index.pb',
      'meta': <String, Object?>{
        'name': 'Example',
        'signingKeyFingerprint': fingerprint,
      },
    };
    final legacy = <Object?>[
      <String, Object?>{
        'name': 'Example',
        'pkg': 'eu.kanade.tachiyomi.extension.en.example',
        'apk': 'tachiyomi-en.example-v1.4.1.apk',
        'code': 1,
        'sources': <Object?>[],
      },
    ];

    for (final value in <Object?>[current, descriptor, legacy]) {
      expect(
        inspectExtensionRepositoryJson(value).family,
        ExtensionRepositoryFamily.mihonNative,
      );
    }
  });

  test('does not mistake a Seanime marketplace wrapper for Mihon', () {
    final inspection = inspectExtensionRepositoryJson(<String, Object?>{
      'extensions': <Object?>[
        <String, Object?>{
          'id': 'manga.example',
          'name': 'Example',
          'manifestURI': 'https://repo.example/manifest.json',
        },
      ],
    });

    expect(inspection.family, ExtensionRepositoryFamily.unknown);
    expect(inspection.isRejected, isFalse);
  });

  test('Marketplace parser rejects Mihon JSON with actionable guidance', () {
    final payload = jsonEncode(<String, Object?>{
      'name': 'Example',
      'badgeLabel': 'EX',
      'signingKey': List<String>.filled(64, 'a').join(),
      'contact': <String, Object?>{'website': 'https://example.test'},
      'extensionList': <String, Object?>{'extensions': <Object?>[]},
    });

    expect(
      () => parseMarketplaceCatalog(
        payload,
        repositoryUrl: 'https://repo.example/index.json',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Mihon/Tachiyomi Android extension store'),
        ),
      ),
    );
  });

  test(
    'Marketplace controller rejects protobuf before network or storage',
    () async {
      final store = AddonStore(TetoTvDatabase.instance);
      var validated = false;
      final controller = MarketplaceController(
        store,
        MarketplaceClient(store),
        targetValidator: (_) async => validated = true,
      );
      addTearDown(controller.dispose);

      final error = await controller.addRepository(
        'https://repo.example/index.pb?utm_source=example',
      );

      expect(error, mihonNativeRepositoryRejectionMessage);
      expect(validated, isFalse);
      expect(controller.state.repositories, isEmpty);
    },
  );
}
