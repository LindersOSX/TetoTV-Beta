import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts supported provider IDs and a safe thumbnail', () {
    final trailer = AnimeTrailer.tryCreate(
      provider: 'YouTube',
      videoId: 'abcDEF_12-3',
      thumbnailUrl: 'https://images.example/trailer.jpg',
    );

    expect(trailer, isNotNull);
    expect(trailer!.provider, AnimeTrailerProvider.youtube);
    expect(trailer.videoId, 'abcDEF_12-3');
    expect(trailer.thumbnailUrl, 'https://images.example/trailer.jpg');
  });

  test('rejects unknown providers and malformed provider IDs', () {
    expect(
      AnimeTrailer.tryCreate(provider: 'vimeo', videoId: 'abcDEF_12-3'),
      isNull,
    );
    expect(
      AnimeTrailer.tryCreate(
        provider: 'youtube',
        videoId: 'abcDEF_12-3?autoplay=1',
      ),
      isNull,
    );
    expect(
      AnimeTrailer.tryCreate(provider: 'dailymotion', videoId: '../escape'),
      isNull,
    );
  });

  test('drops an unsafe thumbnail without dropping a valid trailer', () {
    final trailer = AnimeTrailer.tryCreate(
      provider: 'youtube',
      videoId: 'abcDEF_12-3',
      thumbnailUrl: 'https://user:secret@images.example/trailer.jpg#token',
    );

    expect(trailer, isNotNull);
    expect(trailer!.thumbnailUrl, isNull);
  });
}
