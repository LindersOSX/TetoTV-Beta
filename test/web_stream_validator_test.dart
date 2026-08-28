import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts common media MIME types and manifest signatures', () {
    expect(
      isPlayableWebResponse(
        Uri.parse('https://cdn.example/video'),
        'application/vnd.apple.mpegurl',
        '#EXTM3U',
      ),
      isTrue,
    );
    expect(
      isPlayableWebResponse(
        Uri.parse('https://cdn.example/manifest'),
        'text/plain',
        '<MPD type="static">',
      ),
      isFalse,
    );
    expect(
      isPlayableWebResponse(Uri.parse('https://cdn.example/video.mkv'), '', ''),
      isTrue,
    );
  });

  test('rejects HTML pages and strips transport-controlled headers', () {
    expect(
      isPlayableWebResponse(
        Uri.parse('https://cdn.example/watch'),
        'text/html',
        '<!doctype html>',
      ),
      isFalse,
    );
    final headers = sanitizeWebStreamHeaders({
      'Referer': 'https://provider.example/',
      'User-Agent': 'TetoTV test',
      'Host': 'attacker.example',
      'Connection': 'close',
      'X-Bad': 'one\r\ntwo',
      'Authorization': 'Bearer provider-secret',
      'Cookie': 'provider=session',
      'X-Api-Key': 'provider-api-secret',
      'X-Auth-Token': 'provider-auth-secret',
    });
    expect(headers['Referer'], 'https://provider.example/');
    expect(headers['User-Agent'], 'TetoTV test');
    expect(headers, isNot(contains('Host')));
    expect(headers, isNot(contains('Connection')));
    expect(headers, isNot(contains('X-Bad')));

    final redirected = sanitizeWebStreamHeaders(
      headers,
      stripCredentials: true,
    );
    expect(redirected, isNot(contains('Authorization')));
    expect(redirected, isNot(contains('Cookie')));
    expect(redirected, isNot(contains('X-Api-Key')));
    expect(redirected, isNot(contains('X-Auth-Token')));
  });
}
