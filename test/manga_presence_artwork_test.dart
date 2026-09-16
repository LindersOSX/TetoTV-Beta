import 'package:anime_tv/core/discord/manga_presence_artwork.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public covers normalize without changing the image path', () {
    expect(
      safeMangaPresenceArtworkUrl(' HTTPS://COVERS.EXAMPLE.COM:443/book.jpg '),
      'https://covers.example.com/book.jpg',
    );
    expect(
      safeMangaPresenceArtworkUrl('https://cdn.example.com/a%2Fb.webp'),
      'https://cdn.example.com/a%2Fb.webp',
    );
  });
  for (final url in <String?>[
    null,
    '',
    'https://cdn.example.com/${'a' * 301}',
    'http://cdn.example.com/cover.jpg',
    'file:///private/cover.jpg',
    'https://user:secret@cdn.example.com/cover.jpg',
    'https://cdn.example.com/cover.jpg?token=secret',
    'https://cdn.example.com/cover.jpg?',
    'https://cdn.example.com/cover.jpg#',
    'https://cdn.example.com:0443/cover.jpg',
    'https://cdn.example.com:8080/cover.jpg',
    'https://localhost/cover.jpg',
    'https://host.local/cover.jpg',
    'https://a.home.arpa/cover.jpg',
    'https://a.internal/cover.jpg',
    'https://a.test/cover.jpg',
    'https://127.0.0.1/cover.jpg',
    'https://[::1]/cover.jpg',
    'https://2130706433/cover.jpg',
    'https://0x7f000001/cover.jpg',
    'https://127.1/cover.jpg',
    'https://cdn.example.com./cover.jpg',
    'https://cdn.example.com\\@localhost/a.jpg',
    'https://cdn.example.com/a%0a.jpg',
    'https://cdn.example.com/a%250a.jpg',
    'https://cdn.example.com/a%5c.jpg',
    'https://cdn.example.com/a%20b.jpg',
    'https://cdn.example.com/a\u200b.jpg',
    'https://cdn.example.com/a%EF%BB%BF.jpg',
    '\nhttps://cdn.example.com/a.jpg',
  ]) {
    test('unsafe or credential-bearing cover is omitted: $url', () {
      expect(safeMangaPresenceArtworkUrl(url), isNull);
    });
  }
}
