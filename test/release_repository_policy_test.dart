import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Beta publication targets only the Beta repository', () {
    final publisher = File(
      'tool/release/publish_release.ps1',
    ).readAsStringSync();
    final updateChannelDocs = File(
      'docs/UPDATE_CHANNELS.md',
    ).readAsStringSync();
    const repositoryOwner = 'LindersOSX';
    const retiredRepositoryName = 'TetoTV';
    final retiredRepository = '$repositoryOwner/$retiredRepositoryName';
    final retiredRepositoryPattern = RegExp(
      '${RegExp.escape(retiredRepository)}(?![A-Za-z0-9_-])',
    );
    final retiredReleaseBridge = '$retiredRepository-Releases';

    expect(
      RegExp(
        r'\$repository\s*=\s*"LindersOSX/TetoTV-Beta"',
      ).allMatches(publisher),
      hasLength(1),
    );
    expect(publisher, isNot(contains('releaseTargets')));
    expect(publisher, isNot(matches(retiredRepositoryPattern)));
    expect(publisher, isNot(contains(retiredReleaseBridge)));
    expect(updateChannelDocs, isNot(matches(retiredRepositoryPattern)));
    expect(updateChannelDocs, isNot(contains(retiredReleaseBridge)));
  });

  test('native release verification resolves Gradle caches cross-platform', () {
    final verifier = File(
      'tool/release/verify_native_redistribution.ps1',
    ).readAsStringSync();

    expect(verifier, contains('GRADLE_USER_HOME'));
    expect(verifier, contains('[Environment+SpecialFolder]::UserProfile'));
    expect(verifier, isNot(contains(r'$env:USERPROFILE')));
  });
}
