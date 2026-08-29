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
    final apkVerifier = File(
      'tool/release/verify_release_apk.ps1',
    ).readAsStringSync();

    expect(verifier, contains('GRADLE_USER_HOME'));
    expect(verifier, contains(r'"transforms"'));
    expect(verifier, contains('RequireResolvedBinaries'));
    expect(verifier, contains('requires all five pinned binary artifacts'));
    expect(verifier, contains('[Environment+SpecialFolder]::UserProfile'));
    expect(verifier, isNot(contains(r'$env:USERPROFILE')));
    expect(verifier, contains(r'$resolvedRecords = @($parsedResolvedRecords)'));
    expect(
      verifier,
      isNot(
        contains(
          r'$resolvedRecords = @(Read-ZipEntryText $refsEntry | ConvertFrom-Json)',
        ),
      ),
    );
    expect(apkVerifier, contains('[Environment]::OSVersion.Platform'));
    expect(apkVerifier, isNot(contains(r'$IsWindows')));
  });

  test('publication is draft-first and requires signed native review', () {
    final publisher = File(
      'tool/release/publish_release.ps1',
    ).readAsStringSync();
    final payloadVerifier = File(
      'tool/release/verify_release_payloads.ps1',
    ).readAsStringSync();
    final reviewVerifier = File(
      'tool/release/verify_native_license_review.ps1',
    ).readAsStringSync();
    final hostedReleaseVerifier = File(
      '.github/workflows/verify-release-assets.yml',
    ).readAsStringSync();
    final reviewerAllowlist = File(
      'tool/release/qualified_native_license_reviewers.allowed_signers',
    ).readAsLinesSync();

    expect(publisher, contains('verify_native_license_review.ps1'));
    expect(publisher, contains('"--draft"'));
    expect(publisher, contains('"--draft=false"'));
    expect(publisher, contains('Remove-GitHubDraftAfterFailure'));
    expect(publisher, contains('Assert-GitHubReleaseAuthorityBoundary'));
    expect(publisher, contains('collaborators?affiliation=all&per_page=100'));
    expect(publisher, contains('unexpected collaborators are present'));
    expect(publisher, contains('immutable future releases must be enabled'));
    expect(publisher, contains('sha_pinning_required'));
    expect(publisher, contains('default_workflow_permissions'));
    expect(
      publisher,
      contains('published immutable releases require investigation'),
    );
    expect(publisher, contains('tetotv-native-license-review-sha256'));
    expect(
      publisher,
      contains('tetotv-native-license-review-attestation-base64'),
    );
    expect(
      publisher,
      contains('tetotv-native-license-review-signature-base64'),
    );
    expect(publisher, isNot(contains(r'$draftCreated')));
    expect(
      RegExp(
        r'catch\s*\{[\s\S]*?Remove-GitHubDraftAfterFailure\s+-Repository\s+\$repository\s+-Tag\s+\$releaseTag[\s\S]*?throw',
      ).hasMatch(publisher),
      isTrue,
      reason: 'every partial draft creation failure must be rolled back',
    );
    expect(payloadVerifier, contains(r'RequireResolvedBinaries = $true'));
    expect(reviewVerifier, contains('-Y verify'));
    expect(reviewVerifier, contains('knownProvenanceLimitsSha256'));
    expect(reviewVerifier, contains('nativePlaybackNoticeSha256'));
    expect(reviewVerifier, contains('githubAppInventory'));
    expect(
      reviewVerifier,
      contains('Publication is blocked while any GitHub App is installed'),
    );
    expect(publisher, contains('SignedReviewAttestationPath'));
    expect(
      publisher,
      contains('complete empty GitHub App inventory'),
    );
    expect(
      hostedReleaseVerifier,
      contains('tetotv-native-license-review-attestation-base64'),
    );
    expect(
      hostedReleaseVerifier,
      contains('tetotv-native-license-review-signature-base64'),
    );
    expect(hostedReleaseVerifier, contains('verify_native_license_review.ps1'));
    expect(hostedReleaseVerifier, contains('id-token: write'));
    expect(hostedReleaseVerifier, contains('attestations: write'));
    expect(
      hostedReleaseVerifier,
      contains('actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d'),
    );
    expect(
      hostedReleaseVerifier,
      contains('tetotv-release-payload-verification'),
    );
    expect(hostedReleaseVerifier, contains('gh attestation verify'));
    expect(hostedReleaseVerifier, contains('gh release verify'));
    expect(hostedReleaseVerifier, contains('--signer-workflow'));
    expect(hostedReleaseVerifier, contains('--source-ref'));
    expect(hostedReleaseVerifier, contains('--deny-self-hosted-runners'));

    final activeReviewers = reviewerAllowlist
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(
      activeReviewers,
      isEmpty,
      reason: 'release must remain fail-closed until a reviewer is vetted',
    );
  });
}
