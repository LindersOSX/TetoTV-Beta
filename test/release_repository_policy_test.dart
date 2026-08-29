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

  test('reviewed publication remains draft-first and verifies signed review', () {
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
    expect(publisher, contains('android-actions/setup-android@*'));
    expect(publisher, isNot(contains('subosito/flutter-action@*')));
    expect(publisher, contains(r'$selectedActionsPolicy.verified_allowed'));
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
    expect(publisher, contains(r'$reviewEvidence.githubAppInventory'));
    expect(publisher, contains('complete empty GitHub App inventory'));
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
    expect(hostedReleaseVerifier, contains('workflow_dispatch:'));
    expect(hostedReleaseVerifier, contains('expected_tag_commit:'));
    expect(hostedReleaseVerifier, contains('refs/heads/main'));
    expect(hostedReleaseVerifier, contains('--source-digest'));
    expect(hostedReleaseVerifier, contains('--signer-digest'));
    expect(hostedReleaseVerifier, contains("sed -i 's/\\r\$//'"));
    expect(
      hostedReleaseVerifier,
      contains(
        '447878859d01ca9bfdb99a85f245af07ed8a15fedcd9d189c4749e8e92d1f185',
      ),
    );
    expect(hostedReleaseVerifier, isNot(contains('subosito/flutter-action@')));

    final activeReviewers = reviewerAllowlist
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(
      activeReviewers,
      isEmpty,
      reason: 'release must remain fail-closed until a reviewer is vetted',
    );
  });

  test('unreviewed publication is explicit, Beta-only, and cannot claim review', () {
    final betaPublisher = File(
      'tool/release/publish_beta_release.ps1',
    ).readAsStringSync();
    final publisher = File(
      'tool/release/publish_release.ps1',
    ).readAsStringSync();
    final payloadVerifier = File(
      'tool/release/verify_release_payloads.ps1',
    ).readAsStringSync();
    final declarationCreator = File(
      'tool/release/new_unreviewed_beta_release_declaration.ps1',
    ).readAsStringSync();
    final declarationVerifier = File(
      'tool/release/verify_unreviewed_beta_release_declaration.ps1',
    ).readAsStringSync();
    final reviewedAttestationVerifier = File(
      'tool/release/verify_native_license_review.ps1',
    ).readAsStringSync();
    final hostedReleaseVerifier = File(
      '.github/workflows/verify-release-assets.yml',
    ).readAsStringSync();
    final releaseNotes = File(
      'docs/RELEASE_NOTES_2.0.42.md',
    ).readAsStringSync();

    expect(
      betaPublisher,
      contains('[switch]\$PublishWithoutIndependentNativeLicenseReview'),
    );
    expect(
      betaPublisher,
      contains(
        r'$arguments.PublishWithoutIndependentNativeLicenseReview = $true',
      ),
    );
    expect(betaPublisher, contains(r'Channel = "Beta"'));
    expect(
      publisher,
      contains(
        r'$unreviewedBetaAcknowledgementText = "PUBLISH UNREVIEWED BETA"',
      ),
    );
    expect(
      publisher,
      contains('"api", "--paginate", "--slurp"'),
      reason: 'draft verification must enumerate every release page',
    );
    expect(publisher, contains('"repos/\$Repository/releases?per_page=100"'));
    expect(
      publisher,
      contains(r'$releases = @($pages | ForEach-Object { @($_) })'),
      reason: 'slurped release pages must be flattened before exact tag lookup',
    );
    expect(
      publisher,
      isNot(contains('"repos/\$Repository/releases/tags/\$encodedTag"')),
      reason: 'GitHub\'s release-by-tag endpoint hides drafts',
    );
    expect(publisher, contains(r'$maxSnapshotAttempts = 10'));
    expect(
      publisher,
      contains(r'Get-GitHubRelease $Repository $Tag -AllowMissing'),
      reason: 'draft verification must tolerate bounded list consistency lag',
    );
    expect(publisher, contains('Start-Sleep -Milliseconds 1500'));
    expect(publisher, contains('[StringComparison]::Ordinal'));
    expect(
      publisher,
      contains(
        'Reviewed native-license evidence and the unreviewed Beta exception are mutually exclusive.',
      ),
    );
    expect(
      publisher,
      contains(
        'Unreviewed Beta inputs require -PublishWithoutIndependentNativeLicenseReview.',
      ),
    );
    expect(
      publisher,
      contains(
        'Reviewed publication requires -NativeLicenseReviewPath and fails closed without a signed qualified-reviewer attestation.',
      ),
    );
    expect(
      publisher,
      contains(
        'Unreviewed Beta publication requires -UnreviewedBetaDeclarationPath.',
      ),
    );
    expect(
      RegExp(
        r'\[ValidateSet\("Beta"\)\]\s*\[string\]\$Channel',
      ).hasMatch(publisher),
      isTrue,
    );
    expect(payloadVerifier, contains(r'if ($Channel -cne "Beta")'));
    expect(
      declarationCreator,
      contains(r"'(?m)^version:\s*(2\.\d+\.\d+)\+\d+\s*$'"),
    );
    expect(
      declarationVerifier,
      contains("ReleaseTag must be a canonical Beta v2.x.y tag."),
    );
    expect(
      declarationVerifier,
      contains('function Get-CanonicalUtcJsonString('),
      reason:
          'timestamp validation must inspect the exact JSON string instead of '
          'PowerShell\'s culture-formatted DateTime conversion',
    );
    expect(
      declarationVerifier,
      contains(r'$declaredAtText = Get-CanonicalUtcJsonString `'),
    );
    expect(
      declarationVerifier,
      contains(r'if ($keyOccurrences.Count -ne 1)'),
      reason: 'duplicate timestamp properties must fail closed',
    );
    expect(declarationVerifier, isNot(contains('[Text.Json.JsonDocument]')));
    expect(
      reviewedAttestationVerifier,
      contains('function Get-CanonicalUtcJsonString('),
      reason: 'the reviewed path must preserve exact timestamp text too',
    );
    expect(
      reviewedAttestationVerifier,
      isNot(contains(r'$reviewedAtText = [string]$attestation.reviewedAtUtc')),
    );

    expect(
      declarationCreator,
      contains(r'independentNativeLicenseReview = $false'),
    );
    expect(
      declarationCreator,
      contains(r'correspondingSourceIndependentlyReviewed = $false'),
    );
    expect(
      declarationVerifier,
      contains(r'$value -isnot [bool] -or $value -ne $false'),
    );
    expect(
      declarationVerifier,
      contains(
        'This evidence explicitly records that no independent native-license or corresponding-source review was performed.',
      ),
    );
    expect(declarationCreator, isNot(contains('ssh-keygen')));
    expect(declarationVerifier, isNot(contains('-Y verify')));

    const statusMarker =
        '<!-- tetotv-native-license-review-status: unreviewed-beta -->';
    final disclosureMatch = RegExp(
      r'\$unreviewedBetaDisclosureText\s*=\s*"([^"]+)"',
    ).firstMatch(publisher);
    expect(disclosureMatch, isNotNull);
    final disclosure = disclosureMatch!.group(1)!;
    expect(releaseNotes, contains(disclosure));
    expect(hostedReleaseVerifier, contains("disclosure='$disclosure'"));
    expect(publisher, contains(r'$unreviewedBetaVisibleWarningPrefix'));
    expect(
      hostedReleaseVerifier,
      contains(r'[[ "${warning_lines[2]}" != "> [!WARNING]" ]]'),
    );
    expect(declarationVerifier, contains('Compare-Object -CaseSensitive'));
    const reviewedDisclosureRejection =
        'Reviewed release notes must not claim that independent native-license review was not performed.';
    expect(
      publisher,
      contains(
        r'[regex]::Matches($normalizedReleaseBody, [regex]::Escape($unreviewedBetaDisclosureText))',
      ),
    );
    expect(publisher, contains(reviewedDisclosureRejection));
    expect(
      payloadVerifier,
      contains(r'$releaseNotesText.Contains($unreviewedDisclosure)'),
    );
    expect(payloadVerifier, contains(reviewedDisclosureRejection));
    expect(
      hostedReleaseVerifier,
      contains(
        r'if grep -Fq "${disclosure}" "${download_dir}/RELEASE_NOTES.md"; then',
      ),
    );
    expect(hostedReleaseVerifier, contains(reviewedDisclosureRejection));
    expect(publisher, contains(statusMarker));
    expect(hostedReleaseVerifier, contains(statusMarker));
    expect(
      publisher,
      contains(
        'Unreviewed Beta release notes must not contain qualified-review evidence.',
      ),
    );
    expect(
      payloadVerifier,
      contains(
        'Unreviewed Beta release notes must not contain qualified-review evidence.',
      ),
    );
    expect(
      hostedReleaseVerifier,
      contains(
        'Unreviewed Beta release notes must not contain qualified-review evidence.',
      ),
    );
    expect(hostedReleaseVerifier, contains('review_status="unreviewed-beta"'));
    expect(
      hostedReleaseVerifier,
      contains('"owner-unreviewed-beta-declaration"'),
    );
    expect(hostedReleaseVerifier, contains('else null'));
    expect(
      hostedReleaseVerifier,
      isNot(contains('Attest the independently verified release payload')),
    );
    expect(
      hostedReleaseVerifier,
      contains('Attest the verified release payload'),
    );
  });

  test('both release-evidence paths preserve the three-asset contract', () {
    final publisher = File(
      'tool/release/publish_release.ps1',
    ).readAsStringSync();
    final hostedReleaseVerifier = File(
      '.github/workflows/verify-release-assets.yml',
    ).readAsStringSync();

    expect(
      RegExp(
        r'\$assetPaths\s*=\s*@\(\$resolvedApk,\s*\$resolvedNativeSource,\s*\$resolvedChecksums\)',
      ).hasMatch(publisher),
      isTrue,
    );
    expect(
      RegExp(
        r'"release",\s*"create",\s*\$releaseTag,\s*\$resolvedApk,\s*\$resolvedNativeSource,\s*\$resolvedChecksums,\s*"--repo"',
        multiLine: true,
      ).hasMatch(publisher),
      isTrue,
    );
    expect(
      publisher,
      contains(
        r'Release must contain exactly $($ExpectedAssets.Count) assets.',
      ),
    );
    expect(hostedReleaseVerifier, contains(r'"${#actual_assets[@]}" -ne 3'));
    final subjectBlock = RegExp(
      r'subject-path:\s*\|([\s\S]*?)predicate-type:',
    ).firstMatch(hostedReleaseVerifier);
    expect(subjectBlock, isNotNull);
    final subjects = RegExp(
      r'^\s+\$\{\{ runner\.temp \}\}/tetotv-release/',
      multiLine: true,
    ).allMatches(subjectBlock!.group(1)!).length;
    expect(subjects, 3);
    expect(
      RegExp(
        r'\$\{\{ env\.RELEASE_TAG \}\}',
      ).allMatches(subjectBlock.group(1)!).length,
      2,
    );
    expect(
      subjectBlock.group(1),
      isNot(contains('github.event.release.tag_name')),
    );
    expect(
      subjectBlock.group(1),
      isNot(contains('unreviewed-beta-release-declaration')),
    );
  });
}
