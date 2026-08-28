import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const master = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-STREAM-INF:BANDWIDTH=14500000,AVERAGE-BANDWIDTH=12000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.B0,mp4a.40.2"
video/2160/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080,NAME="Full HD"
https://video.example.com/1080/master.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1280x720
http://insecure.example.com/720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480
https://192.168.1.20/private.m3u8
''';

  test('parses secure HLS variants and resolves relative locations', () {
    final variants = parseHlsMasterPlaylist(
      master,
      Uri.parse('https://cdn.example.com/show/master.m3u8'),
    );

    expect(variants.map((variant) => variant.quality), ['2160p', '1080p']);
    expect(
      variants.first.uri.toString(),
      'https://cdn.example.com/show/video/2160/index.m3u8',
    );
    expect(variants.last.uri.host, 'video.example.com');
  });

  test('variant results keep same-origin headers and protect cross-origin', () {
    final variants = expandHlsResultVariants(
      {
        'url': 'https://cdn.example.com/show/master.m3u8',
        'title': 'Default / Auto',
        'quality': 'Auto',
        'headers': {
          'Referer': 'https://provider.example/',
          'User-Agent': 'Fixture player',
          'Authorization': 'Bearer master-secret',
          'Cookie': 'session=master-secret',
          'X-Api-Key': 'custom-master-secret',
        },
        'subtitleUrl': 'https://cdn.example.com/subtitles/en.vtt',
      },
      master,
      Uri.parse('https://cdn.example.com/show/master.m3u8'),
    );

    expect(variants.first['title'], 'Default / 2160p');
    expect(variants.first['quality'], '2160p');
    expect(
      variants.first['headers'],
      containsPair('Authorization', 'Bearer master-secret'),
    );
    expect(
      variants.first['subtitleUrl'],
      'https://cdn.example.com/subtitles/en.vtt',
    );

    final crossOrigin = variants.singleWhere(
      (variant) => Uri.parse('${variant['url']}').host == 'video.example.com',
    );
    final crossOriginHeaders = crossOrigin['headers'] as Map;
    expect(crossOriginHeaders['Referer'], 'https://provider.example/');
    expect(crossOriginHeaders['User-Agent'], 'Fixture player');
    expect(crossOriginHeaders, isNot(contains('Authorization')));
    expect(crossOriginHeaders, isNot(contains('Cookie')));
    expect(crossOriginHeaders, isNot(contains('X-Api-Key')));
  });
}
