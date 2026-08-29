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

    expect(manifest['schemaVersion'], 2);
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libmpv-default-arm64-v8a',
      )['sha256'],
      'dbbf4c9adf6351904f5d50337d3afb78bbd77891376df1363e8908911e94d132',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libmpv-default-armeabi-v7a',
      )['sha256'],
      '07361e222d73dd60db69133e60b0fc7c8db44b5b3654f4f2d0798be039edcc23',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libtorrent4j-core',
      )['sha256'],
      'cb86224533873de990b24360a8ba26cb66286a0842eac3b4facc58a7370fcf91',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libtorrent4j-android-arm',
      )['sha256'],
      '5a98e854b8f7e338a3746600be5cf22a13055853f88f7894592d62e1681865f6',
    );
    expect(
      artifacts.singleWhere(
        (item) => item['id'] == 'libtorrent4j-android-arm64',
      )['sha256'],
      '223e27338fb0a9dad9b6a6db6add7ec791c8633698a69e958757571c63e7de23',
    );
    expect(artifacts, hasLength(5));
    final sourceRoots = (manifest['sourceRoots'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(sourceRoots, hasLength(19));
    expect(
      sourceRoots.every(
        (item) =>
            RegExp(r'^[0-9a-f]{40}$').hasMatch(item['revision'] as String),
      ),
      isTrue,
    );
    expect(
      sourceRoots.singleWhere(
        (item) => item['id'] == 'libdatachannel',
      )['revision'],
      '6ab310b5887eab78cf0c0767a8ced2ebff8c7479',
    );
    expect(
      sourceRoots.singleWhere((item) => item['id'] == 'try-signal')['revision'],
      '105cce59972f925a33aa6b1c3109e4cd3caf583d',
    );
    expect(
      sourceRoots.singleWhere(
        (item) => item['id'] == 'gas-preprocessor',
      )['revision'],
      'ac1836309c2e77023c228b7184485597286289d3',
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
    expect(manifest['libmpvDeclaredDependencyRefs'], isEmpty);
    expect(
      (manifest['build'] as Map<String, dynamic>)['scriptSha256'],
      sha256
          .convert(
            File('tool/native/build_native_playback.sh').readAsBytesSync(),
          )
          .toString(),
    );
    expect(
      (manifest['licenseAssets'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (item) =>
                item['path'] ==
                'assets/legal/native/NATIVE_PLAYBACK_NOTICE.txt',
          )['sha256'],
      'a68d117fbee0945ccfb5354b71eef6548d715556ce815aa38af0b467ad7d9d16',
    );
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
      expect(expectedHash, isNotNull, reason: '$path must be hash pinned');
      expect(sha256.convert(file.readAsBytesSync()).toString(), expectedHash);
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
    expect(lock, contains('version: "1.3.8+tetotv.1"'));
    expect(lock, isNot(contains('flutter_vlc_player:')));
    expect(verification, isNot(contains('name="libvlc-all"')));
    expect(documentation, contains('second isolated build'));
    expect(documentation, contains('does not claim byte identity'));
    expect(documentation, contains('independent native-license review'));
    expect(documentation, contains('zipalign'));
    expect(documentation, contains('apksigner'));
  });
}
