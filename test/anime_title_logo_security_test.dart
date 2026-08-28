import 'dart:io';

import 'package:anime_tv/features/catalog/data/anime_title_logo_cache_manager.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('title-logo URLs are restricted to documented artwork CDNs', () {
    expect(
      isSafeAnimeTitleLogoUri(
        Uri.parse('https://artworks.thetvdb.com/banners/show/clearlogo.png'),
      ),
      isTrue,
    );
    expect(
      isSafeAnimeTitleLogoUri(
        Uri.parse('https://assets.fanart.tv/fanart/tv/show/hdtvlogo/logo.png'),
      ),
      isTrue,
    );
    expect(
      isSafeAnimeTitleLogoUri(Uri.parse('https://attacker.example/logo.png')),
      isFalse,
    );
    expect(
      isSafeAnimeTitleLogoUri(
        Uri.parse('https://assets.fanart.tv:8443/logo.png'),
      ),
      isFalse,
    );
  });

  test('title-logo connections reject non-public IPv4 and IPv6 addresses', () {
    for (final value in const [
      '0.0.0.0',
      '10.0.0.1',
      '100.64.0.1',
      '127.0.0.1',
      '169.254.1.1',
      '172.16.0.1',
      '192.168.1.1',
      '198.18.0.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.0.0.1',
      '::1',
      'fc00::1',
      'fe80::1',
      '2001:db8::1',
    ]) {
      expect(isPublicArtworkAddress(InternetAddress(value)), isFalse);
    }
    expect(isPublicArtworkAddress(InternetAddress('8.8.8.8')), isTrue);
    expect(
      isPublicArtworkAddress(InternetAddress('2606:4700:4700::1111')),
      isTrue,
    );
  });

  test('title-logo connections prefer IPv4 and retain alternate addresses', () {
    final ordered = orderPublicArtworkAddresses([
      InternetAddress('2606:4700:4700::1111'),
      InternetAddress('8.8.8.8'),
      InternetAddress('1.1.1.1'),
      InternetAddress('8.8.8.8'),
    ]);

    expect(ordered, isNotNull);
    expect(ordered!.map((value) => value.address), [
      '8.8.8.8',
      '1.1.1.1',
      '2606:4700:4700::1111',
    ]);
  });

  test('one private DNS result rejects the complete artwork destination', () {
    expect(
      orderPublicArtworkAddresses([
        InternetAddress('8.8.8.8'),
        InternetAddress('192.168.1.1'),
      ]),
      isNull,
    );
  });

  test('only temporary HTTP responses are retried', () {
    for (final status in const [408, 425, 429, 500, 502, 503]) {
      expect(isTransientArtworkStatus(status), isTrue);
    }
    for (final status in const [200, 304, 400, 401, 403, 404]) {
      expect(isTransientArtworkStatus(status), isFalse);
    }
  });

  test('truncated artwork bodies are rejected before caching', () {
    expect(
      hasCompleteArtworkLength(declaredBytes: 800, receivedBytes: 400),
      isFalse,
    );
    expect(
      hasCompleteArtworkLength(declaredBytes: 800, receivedBytes: 800),
      isTrue,
    );
    expect(
      hasCompleteArtworkLength(declaredBytes: -1, receivedBytes: 800),
      isTrue,
    );
  });
}
