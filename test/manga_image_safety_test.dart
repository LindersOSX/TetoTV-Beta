import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads dimensions for every supported manga image container', () {
    final fixtures = <MangaArchiveImageType, List<int>>{
      MangaArchiveImageType.jpeg: _jpeg(2, 3),
      MangaArchiveImageType.png: _png(2, 3),
      MangaArchiveImageType.gif: _gif(2, 3),
      MangaArchiveImageType.webp: _webp(2, 3),
    };

    for (final entry in fixtures.entries) {
      final info = inspectMangaImage(entry.value);
      expect(info.type, entry.key);
      expect(info.width, 2);
      expect(info.height, 3);
    }
  });

  test('enforces pixel area independently of width and height limits', () {
    expect(
      () => inspectMangaImage(_png(8192, 4097)),
      throwsA(
        isA<MangaImageValidationException>().having(
          (error) => error.failure,
          'failure',
          MangaImageValidationFailure.dimensionsExceeded,
        ),
      ),
    );
  });

  test('rejects magic-only and truncated container headers', () {
    for (final bytes in <List<int>>[
      const <int>[0xff, 0xd8, 0xff, 0xd9],
      const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61],
      const <int>[
        0x52,
        0x49,
        0x46,
        0x46,
        0x04,
        0,
        0,
        0,
        0x57,
        0x45,
        0x42,
        0x50,
      ],
    ]) {
      expect(
        () => inspectMangaImage(bytes),
        throwsA(isA<MangaImageValidationException>()),
      );
    }
  });
}

List<int> _jpeg(int width, int height) => <int>[
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  (height >> 8) & 0xff,
  height & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  0x01,
  0x01,
  0x11,
  0x00,
  0xff,
  0xd9,
];

List<int> _png(int width, int height) => <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  (width >> 24) & 0xff,
  (width >> 16) & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 24) & 0xff,
  (height >> 16) & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
];

List<int> _gif(int width, int height) => <int>[
  0x47,
  0x49,
  0x46,
  0x38,
  0x39,
  0x61,
  width & 0xff,
  (width >> 8) & 0xff,
  height & 0xff,
  (height >> 8) & 0xff,
];

List<int> _webp(int width, int height) => <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x16,
  0,
  0,
  0,
  0x57,
  0x45,
  0x42,
  0x50,
  0x56,
  0x50,
  0x38,
  0x58,
  0x0a,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  (width - 1) & 0xff,
  ((width - 1) >> 8) & 0xff,
  ((width - 1) >> 16) & 0xff,
  (height - 1) & 0xff,
  ((height - 1) >> 8) & 0xff,
  ((height - 1) >> 16) & 0xff,
];
