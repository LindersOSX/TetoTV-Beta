import 'dart:io';

import 'package:anime_tv/features/downloads/data/public_catalog_artwork_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allows credential-free public HTTPS artwork', () async {
    await validatePublicArtworkUri(
      Uri.parse('https://cdn.example.test/poster.jpg?width=600'),
      resolveHost: (_) async => [InternetAddress('8.8.8.8')],
    );
  });

  test('rejects credentials, HTTP, private names and private DNS', () async {
    final unsafe = <Uri>[
      Uri.parse('http://cdn.example.test/poster.jpg'),
      Uri.parse('https://user:pass@cdn.example.test/poster.jpg'),
      Uri.parse('https://cdn.example.test/poster.jpg?token=secret'),
      Uri.parse('https://localhost/poster.jpg'),
    ];
    for (final uri in unsafe) {
      expect(
        () => validatePublicArtworkUri(
          uri,
          resolveHost: (_) async => [InternetAddress('8.8.8.8')],
        ),
        throwsA(isA<PublicCatalogArtworkException>()),
      );
    }

    expect(
      () => validatePublicArtworkUri(
        Uri.parse('https://cdn.example.test/poster.jpg'),
        resolveHost: (_) async => [InternetAddress('192.168.1.10')],
      ),
      throwsA(
        isA<PublicCatalogArtworkException>().having(
          (error) => error.code,
          'code',
          'private_host',
        ),
      ),
    );
  });

  test('validates MIME, signature and bounded size', () {
    final png = PublicCatalogArtwork.validate(
      bytes: const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      contentType: 'image/png',
    );
    expect(png.fileExtension, 'png');

    expect(
      () => PublicCatalogArtwork.validate(
        bytes: const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
        contentType: 'image/jpeg',
      ),
      throwsA(isA<PublicCatalogArtworkException>()),
    );
    expect(
      () => PublicCatalogArtwork.validate(
        bytes: const [0xff, 0xd8, 0xff, 0x00],
        contentType: 'image/jpeg',
        maxBytes: 3,
      ),
      throwsA(
        isA<PublicCatalogArtworkException>().having(
          (error) => error.code,
          'code',
          'invalid_size',
        ),
      ),
    );
  });
}
