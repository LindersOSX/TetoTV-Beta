import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('x86_64 JNI libraries are excluded from release packaging only', () {
    final buildScript = File('android/app/build.gradle.kts').readAsStringSync();

    final releaseOnlyExclusion = RegExp(
      r'androidComponents\s*\{\s*'
      r'onVariants\(selector\(\)\.withBuildType\("release"\)\)\s*'
      r'\{\s*variant\s*->\s*'
      r'variant\.packaging\.jniLibs\.excludes\.add\('
      r'"lib/x86_64/\*\*"\)\s*'
      r'\}\s*\}',
      multiLine: true,
    );

    expect(
      releaseOnlyExclusion.hasMatch(buildScript),
      isTrue,
      reason:
          'The public release APK must not claim x86_64 support without '
          'x86_64 Flutter AOT libraries. Keep the exclusion scoped to release '
          'variants so x86_64 debug emulator builds continue to work.',
    );
    expect(
      RegExp(
        r'packaging\.jniLibs\.excludes\.add\("lib/x86_64/\*\*"\)',
      ).allMatches(buildScript),
      hasLength(1),
      reason: 'Do not duplicate or globally broaden the release-only rule.',
    );
  });
}
