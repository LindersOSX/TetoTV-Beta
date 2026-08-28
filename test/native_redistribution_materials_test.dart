import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifestFile = File('tool/release/native_playback_manifest.json');

  test('native playback manifest pins the resolved release binaries', () {
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final artifacts = (manifest['binaryArtifacts'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    expect(manifest['schemaVersion'], 1);
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libmpv-default-arm64-v8a',
      )['sha256'],
      '4363dfa5d3d415b91c1f16f6fb90c3fe59a77dfd3f9b824d2b24b492d6b09df9',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libmpv-default-armeabi-v7a',
      )['sha256'],
      '8ead114fc5a43348d89dc0eb8f41823e549b15115c29f73ee26973f973620995',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libtorrent4j-core',
      )['sha256'],
      'bf8ebde8d9fc20af129f26f28c01d8cfd91d87b831b44dabbe0705d9dc910243',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libtorrent4j-android-arm',
      )['sha256'],
      '46b417c525c35ebd45b225b4e002ab13629cffc1ec8d8290ece02a686491952b',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libtorrent4j-android-arm64',
      )['sha256'],
      'd9ea7d3d82e7484e07260d063a73c8f9fe5778cc06299717eba49858a44045ef',
    );
    expect(artifacts, hasLength(5));
    final sourceRoots = (manifest['sourceRoots'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(
      sourceRoots.singleWhere(
        (item) => item['id'] == 'libdatachannel',
      )['revision'],
      '6ab310b5887eab78cf0c0767a8ced2ebff8c7479',
    );
    final sourceArchives = (manifest['sourceArchives'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(
      sourceArchives.singleWhere(
        (item) => item['id'] == 'boost-1.89.0',
      )['sha256'],
      '9de758db755e8330a01d995b0a24d09798048400ac25c03fc5ea9be364b13c93',
    );
    expect(
      sourceArchives.singleWhere(
        (item) => item['id'] == 'openssl-3.5.2',
      )['sha256'],
      'c53a47e5e441c930c3928cf7bf6fb00e5d129b630e0aa873b08258656e7345ec',
    );
    expect(manifest['releaseReadyWithoutStagedBundle'], isFalse);
    expect(manifest['knownProvenanceLimits'], isNotEmpty);
  });

  test('full conservative GPL and LGPL texts are shipped and hash pinned', () {
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final licenses = (manifest['licenseAssets'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    for (final license in licenses) {
      final path = license['path'] as String;
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      expect(pubspec, contains('- $path'), reason: '$path must ship in APK');
      final expectedHash = license['sha256'] as String?;
      if (expectedHash != null) {
        expect(sha256.convert(file.readAsBytesSync()).toString(), expectedHash);
      }
    }

    expect(
      File('assets/legal/native/LGPL-2.1.txt').readAsStringSync(),
      contains('GNU LESSER GENERAL PUBLIC LICENSE'),
    );
    expect(
      File('assets/legal/native/LGPL-3.0.txt').readAsStringSync(),
      contains('Version 3, 29 June 2007'),
    );
    expect(
      File('assets/legal/native/GPL-3.0.txt').readAsStringSync(),
      contains('TERMS AND CONDITIONS'),
    );
  });

  test('resolved declarations and provenance documentation stay aligned', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final verification = File(
      'android/gradle/verification-metadata.xml',
    ).readAsStringSync();
    final documentation = File(
      'docs/NATIVE_PLAYBACK_REDISTRIBUTION.md',
    ).readAsStringSync();

    expect(lock, contains('media_kit_libs_android_video:'));
    expect(lock, contains('version: "1.3.8"'));
    expect(lock, isNot(contains('flutter_vlc_player:')));
    expect(verification, isNot(contains('name="libvlc-all"')));
    expect(documentation, matches(RegExp(r'not reproducible-build\s+claims')));
    expect(documentation, contains('mutable tag'));
    expect(documentation, contains('zipalign'));
    expect(documentation, contains('apksigner'));
  });
}
