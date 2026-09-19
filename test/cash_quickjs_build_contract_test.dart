import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const releaseCommit = 'a738129cc4aa99206c00ae49e9c5b15cb58ad880';
  const sourceArchiveSha256 =
      'b54a2153690533afd0181fc1136ce989eb31e3c39bf2e852b2ff1adf4179d56f';

  test('Aniyomi uses the hermetic source-built app.cash.quickjs module', () {
    final settings = File('android/settings.gradle.kts').readAsStringSync();
    final aniyomiBuild = File(
      'android/aniyomi-compat/build.gradle.kts',
    ).readAsStringSync();
    final moduleBuild = File(
      'android/cash-quickjs-android/build.gradle.kts',
    ).readAsStringSync();
    final cmake = File(
      'android/cash-quickjs-android/src/main/cpp/CMakeLists.txt',
    ).readAsStringSync();
    final verificationMetadata = File(
      'android/gradle/verification-metadata.xml',
    ).readAsStringSync();

    expect(settings, contains('include(":cash-quickjs-android")'));
    expect(
      aniyomiBuild,
      contains('implementation(project(":cash-quickjs-android"))'),
    );
    expect(aniyomiBuild, isNot(contains('app.cash.quickjs:quickjs-android')));
    expect(
      verificationMetadata,
      isNot(
        matches(
          RegExp(
            r'<component\s+group="app\.cash\.quickjs"\s+'
            r'name="quickjs-android"',
          ),
        ),
      ),
    );

    expect(moduleBuild, contains('namespace = "app.cash.quickjs"'));
    expect(moduleBuild, contains('ndkVersion = "28.2.13676358"'));
    expect(moduleBuild, contains('JavaVersion.VERSION_1_8'));
    expect(moduleBuild, contains('"armeabi-v7a", "arm64-v8a"'));
    expect(moduleBuild, contains('dependsOn(verifyVendoredQuickJs)'));
    expect(cmake, contains('add_library(quickjs SHARED'));
    expect(cmake, contains('-Wl,-z,common-page-size=16384'));
    expect(cmake, contains('-Wl,-z,max-page-size=16384'));

    final api = File(
      'third_party/app_cash_quickjs/upstream/quickjs/common/java/'
      'app/cash/quickjs/QuickJs.java',
    ).readAsStringSync();
    final loader = File(
      'third_party/app_cash_quickjs/upstream/quickjs/android/src/main/java/'
      'app/cash/quickjs/QuickJsNativeLoader.java',
    ).readAsStringSync();
    expect(api, contains('package app.cash.quickjs;'));
    expect(loader, contains('System.loadLibrary("quickjs")'));
  });

  test('reviewed source manifest covers every vendored byte', () {
    final vendoredRoot = Directory('third_party/app_cash_quickjs/upstream');
    final manifest = File(
      'android/cash-quickjs-android/SOURCE_MANIFEST.sha256',
    );
    final expected = <String, String>{};
    for (final line in manifest.readAsLinesSync()) {
      if (line.trim().isEmpty || line.startsWith('#')) {
        continue;
      }
      final match = RegExp(r'^([0-9a-f]{64})  (.+)$').firstMatch(line);
      expect(match, isNotNull, reason: 'Malformed source manifest: $line');
      expected[match!.group(2)!] = match.group(1)!;
    }

    final actual = vendoredRoot
        .listSync(recursive: true)
        .whereType<File>()
        .map(
          (file) => file.path
              .substring(vendoredRoot.path.length + 1)
              .replaceAll('\\', '/'),
        )
        .toSet();
    expect(actual, expected.keys.toSet());

    for (final entry in expected.entries) {
      final file = File('${vendoredRoot.path}/${entry.key}');
      expect(
        sha256.convert(file.readAsBytesSync()).toString(),
        entry.value,
        reason: 'Vendored source changed: ${entry.key}',
      );
    }
  });

  test('provenance records the pinned source and only reviewed patch', () {
    final provenance =
        jsonDecode(
              File(
                'third_party/app_cash_quickjs/PROVENANCE.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(provenance['releaseCommit'], releaseCommit);
    expect(provenance['embeddedEngineVersion'], '2021-03-27');
    expect(
      File(
        'third_party/app_cash_quickjs/upstream/quickjs/common/native/'
        'quickjs/VERSION',
      ).readAsStringSync().trim(),
      '2021-03-27',
    );
    expect(
      (provenance['sourceArchive'] as Map<String, dynamic>)['sha256'],
      sourceArchiveSha256,
    );
    final adaptations = provenance['adaptations'] as List<dynamic>;
    expect(adaptations, hasLength(1));
    expect(
      (adaptations.single as Map<String, dynamic>)['path'],
      'quickjs/common/native/Context.h',
    );

    final context = File(
      'third_party/app_cash_quickjs/upstream/quickjs/common/native/Context.h',
    ).readAsStringSync();
    expect('#include <functional>\n'.allMatches(context), hasLength(1));

    final aniyomiProvenance =
        jsonDecode(
              File(
                'third_party/aniyomi_compat/PROVENANCE.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final quickJs = aniyomiProvenance['quickJsAndroid'] as Map<String, dynamic>;
    expect(quickJs['releaseCommit'], releaseCommit);
    expect(quickJs['sourceArchiveSha256'], sourceArchiveSha256);
    expect(quickJs['localModule'], 'android/cash-quickjs-android');
    expect(quickJs['linkerPageSizeBytes'], 16384);

    final licenseSources =
        jsonDecode(
              File(
                'assets/legal/aniyomi/LICENSE_SOURCES.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final components = licenseSources['components'] as List<dynamic>;
    final licenseRecord = components.cast<Map<String, dynamic>>().singleWhere(
      (component) => component['component'] == 'Cash App QuickJS Android 0.9.2',
    );
    expect(licenseRecord['sourceArchiveSha256'], sourceArchiveSha256);
    expect(
      licenseRecord['localSource'],
      'third_party/app_cash_quickjs/upstream',
    );
  });

  test('release BOM pins both source-built QuickJS ABI outputs', () {
    final manifest =
        jsonDecode(
              File(
                'tool/release/native_playback_manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final nativeLibraries = (manifest['apkNativeLibraries'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(nativeLibraries, hasLength(20));
    expect(
      nativeLibraries.map((entry) => entry['path']).toSet(),
      hasLength(20),
    );

    final quickJsLibraries = nativeLibraries
        .where((entry) => entry['path'].toString().endsWith('/libquickjs.so'))
        .toList();
    expect(quickJsLibraries, hasLength(2));
    expect(
      {
        for (final entry in quickJsLibraries)
          entry['path'] as String: <Object?>[entry['size'], entry['sha256']],
      },
      {
        'lib/arm64-v8a/libquickjs.so': <Object?>[
          903792,
          'fabcb388c3f9e716de9eb69285013b1638ef96ff11d7ccc59f5430690edf67d5',
        ],
        'lib/armeabi-v7a/libquickjs.so': <Object?>[
          568956,
          'e355c264ba53d276bffa5cbbddc74db34dcb88436ace71d20befaa53c345b102',
        ],
      },
    );
    for (final entry in quickJsLibraries) {
      expect(
        entry['sourceLocator'],
        contains('third_party/app_cash_quickjs/PROVENANCE.json'),
      );
      expect(
        entry['sourceLocator'],
        contains('android/cash-quickjs-android/SOURCE_MANIFEST.sha256'),
      );
      expect(
        entry['noticeLocator'],
        contains('assets/legal/aniyomi/ANIYOMI_RUNTIME_NOTICE.txt'),
      );
      expect(
        entry['noticeLocator'],
        contains('assets/addon_runtime/QUICKJS_LICENSE.txt'),
      );
    }

    final appLibraries = nativeLibraries
        .where((entry) => entry['path'].toString().endsWith('/libapp.so'))
        .toList();
    expect(appLibraries, hasLength(2));
    for (final entry in appLibraries) {
      // The release manifest now points to published source, not the pre-2.0.75
      // staging placeholder. Keep checking a concrete repo/tag locator without
      // requiring that obsolete placeholder after every release.
      expect(
        entry['sourceLocator'],
        matches(
          RegExp(
            r'^https://github\.com/LindersOSX/TetoTV-Beta/tree/v[12]\.\d+\.\d+$',
          ),
        ),
      );
    }
    expect(
      (manifest['knownProvenanceLimits'] as List<dynamic>).join('\n'),
      isNot(contains('replace their source locator')),
    );

    final releaseVerifier = File(
      'tool/release/verify_release_apk.ps1',
    ).readAsStringSync();
    expect(releaseVerifier, contains(r'$expectedNativeLibraryNames'));
    expect(releaseVerifier, contains('"libquickjs.so"'));
    expect(releaseVerifier, contains(r'$hasDuplicateManifestPath'));
    expect(releaseVerifier, isNot(contains('exactly 18 ABI-specific entries')));
  });
}
