# Native-license release review gate

This gate records a qualified human review of the native playback and optional
direct-torrent redistribution evidence. It is not legal advice, does not
replace professional review, and does not claim that a release complies with
every applicable license.

## Security boundary

Reviewed `-Publish` is blocked unless `publish_beta_release.ps1` can verify an
OpenSSH signature over the exact attestation bytes. The attestation binds the
review to all of the following:

- canonical release tag and full Git commit;
- final universal APK SHA-256;
- final native source ZIP SHA-256;
- checked-in native manifest SHA-256;
- checked-in `NATIVE_PLAYBACK_NOTICE.txt` SHA-256;
- the exact digest of every recorded upstream provenance limitation; and
- a complete, empty inventory of GitHub Apps installed for the Beta repository,
  reviewed from the repository's Installed GitHub Apps settings page no more
  than 24 hours before publication; and
- explicit approval, qualification, corresponding-source review, and
  provenance-limit acknowledgement fields.

The signature namespace is `tetotv-native-license-review`. Reviewer public
keys and exact principal names are allowlisted in
`tool/release/qualified_native_license_reviewers.allowed_signers`. Wildcard
principals are prohibited. Private keys must stay outside this repository and
outside release artifacts.

The checked-in allowlist intentionally starts with no active keys. That is a
fail-closed release state, not a sample key to replace automatically. A project
administrator must independently verify both a reviewer's qualification and
public-key fingerprint before committing one exact allowed-signers entry.

## Explicit unreviewed Beta exception

The Beta publisher also supports a deliberately conspicuous exception when an
independent reviewer is not yet available. This exception is Beta-only, is
never the default, and cannot be combined with reviewer evidence. It requires:

- `-PublishWithoutIndependentNativeLicenseReview`;
- the exact acknowledgement `PUBLISH UNREVIEWED BETA`;
- a fresh `tetotv-unreviewed-beta-release-declaration` created from the final
  tag, commit, APK, native-source ZIP, manifest, notice, and provenance limits;
- an owner-confirmed complete empty GitHub App inventory for the Beta
  repository, created within 24 hours; and
- a prominent public warning that no independent native-license or
  corresponding-source review occurred.

The unsigned owner declaration is not an approval, qualified review, legal
advice, or a compliance determination. It never contains reviewer fields or a
fake signature. The publisher and hosted workflow reject mixed reviewed and
unreviewed evidence while retaining the same draft-first asset, checksum, APK,
native-source, pinned-input, repository-authority, immutable-release, and
GitHub attestation checks. This exception must not be used for a Public release.

After the final tag and payloads exist, create it with:

```powershell
.\tool\release\new_unreviewed_beta_release_declaration.ps1 `
  -ApkPath .\build\fire-tv\v2.x.y\TetoTV-v2.x.y-universal.apk `
  -NativeSourcePath .\build\release-compliance\v2.x.y\TetoTV-v2.x.y-native-playback-sources.zip `
  -OutputPath .\build\release-compliance\v2.x.y\unreviewed-beta-release-declaration.json `
  -ConfirmNoIndependentNativeLicenseReview `
  -ConfirmCorrespondingSourceNotIndependentlyReviewed `
  -AcknowledgeKnownProvenanceLimits `
  -ConfirmNoGitHubAppsInstalledForRepository
```

Pass it only through the explicit exception path:

```powershell
.\tool\release\publish_beta_release.ps1 `
  -ApkPath .\build\fire-tv\v2.x.y\TetoTV-v2.x.y-universal.apk `
  -NativeSourcePath .\build\release-compliance\v2.x.y\TetoTV-v2.x.y-native-playback-sources.zip `
  -ChecksumsPath .\build\fire-tv\v2.x.y\SHA256SUMS `
  -ReleaseNotesPath .\docs\RELEASE_NOTES_2.x.y.md `
  -UnreviewedBetaDeclarationPath .\build\release-compliance\v2.x.y\unreviewed-beta-release-declaration.json `
  -PublishWithoutIndependentNativeLicenseReview `
  -UnreviewedBetaAcknowledgement "PUBLISH UNREVIEWED BETA" `
  -Publish
```

## Create and sign the statement

After the final APK and native source bundle exist, a qualified reviewer should
complete the review described in `NATIVE_PLAYBACK_REDISTRIBUTION.md`. From a
clean checkout whose release tag resolves to `HEAD`, generate the exact JSON:

```powershell
.\tool\release\new_native_license_review_attestation.ps1 `
  -ApkPath .\build\fire-tv\v2.x.y\TetoTV-v2.x.y-universal.apk `
  -NativeSourcePath .\build\release-compliance\v2.x.y\TetoTV-v2.x.y-native-playback-sources.zip `
  -ReviewerIdentity reviewer@example.com `
  -ReviewerRole "Qualified native-license release reviewer" `
  -OutputPath .\build\release-compliance\v2.x.y\native-license-review\attestation.json `
  -Approve `
  -ConfirmQualifiedReviewer `
  -ConfirmCorrespondingSourceReviewed `
  -AcknowledgeKnownProvenanceLimits `
  -ConfirmNoGitHubAppsInstalledForRepository
```

The helper refuses a dirty or untagged checkout and verifies the source bundle
and all five pinned binary artifacts before writing the statement. The JSON
shape is documented in
`tool/release/native_license_review_attestation.template.json`; use the helper
to avoid transcription errors.

Sign the exact file bytes with the private key matching the committed
allowlist entry:

```powershell
ssh-keygen -Y sign `
  -f <private-key-path> `
  -n tetotv-native-license-review `
  .\build\release-compliance\v2.x.y\native-license-review\attestation.json
```

This produces `attestation.json.sig`. Verify before publication:

```powershell
.\tool\release\verify_native_license_review.ps1 `
  -AttestationPath .\build\release-compliance\v2.x.y\native-license-review\attestation.json `
  -ReleaseTag v2.x.y `
  -GitCommit <40-lowercase-hex-commit> `
  -ApkPath .\build\fire-tv\v2.x.y\TetoTV-v2.x.y-universal.apk `
  -NativeSourcePath .\build\release-compliance\v2.x.y\TetoTV-v2.x.y-native-playback-sources.zip
```

The review must be no more than 30 days old and cannot be future-dated. Any
content change invalidates both the detached signature and the digest embedded
in the eventual GitHub release notes. The GitHub App inventory is intentionally
stricter: it must be empty, complete, signed as part of the same statement, and
no more than 24 hours old. GitHub's personal-account API does not expose this
complete inventory to a normal `gh` OAuth token, so the qualified reviewer must
open **Repository settings > Integrations > GitHub Apps** and confirm that no
  App is installed for `LindersOSX/TetoTV-Beta`. Reviewed publication fails
  closed if that confirmation is absent or stale.

## Reviewed draft-first publication

Pass the attestation when publishing:

```powershell
.\tool\release\publish_beta_release.ps1 `
  -ApkPath .\build\fire-tv\v2.x.y\TetoTV-v2.x.y-universal.apk `
  -NativeSourcePath .\build\release-compliance\v2.x.y\TetoTV-v2.x.y-native-playback-sources.zip `
  -ChecksumsPath .\build\fire-tv\v2.x.y\SHA256SUMS `
  -ReleaseNotesPath .\docs\RELEASE_NOTES_2.x.y.md `
  -NativeLicenseReviewPath .\build\release-compliance\v2.x.y\native-license-review\attestation.json `
  -Publish
```

The publisher adds the nonsecret attestation SHA-256 plus base64-encoded copies
of the signed attestation and detached signature to hidden release-body
markers. These public markers are independently retrievable evidence, not a
fourth release asset. Do not put private keys or private reviewer details in
the attestation; its stable reviewer identity and role become public release
evidence.

In reviewed mode, GitHub receives a private draft first. The script re-downloads all three
assets, decodes the exact public evidence, verifies the allowlisted OpenSSH
signature and every artifact binding, verifies hosted sizes and hashes, and
runs the complete APK, native-source, binary-artifact, checksum, and notes
verification against those downloaded copies. Only a passing draft is changed
to a normal release. The pinned post-publication workflow independently repeats
the signature and artifact verification from the release body; a digest marker
alone is never accepted as evidence. After every check passes, that workflow
creates a GitHub generic attestation over the three hosted payloads with a
predicate that records the tag, commit, signed-review digest, and checks
performed. It is verification provenance; it does not falsely claim that
GitHub Actions built the locally signed APK. The workflow also requires
GitHub's immutable-release attestation (`gh release verify`) and verifies its
own generic attestation bundle against the exact signer workflow and tag ref.

The unreviewed Beta path uses the same draft-first hosted payload checks, but it
verifies the fresh owner declaration and exact public `unreviewed-beta` status
instead of a reviewer signature. Its GitHub predicate records
`nativeLicenseReviewStatus: unreviewed-beta`, the declaration digest, and only
the automated checks actually performed. It does not claim independent review.

Failed drafts are deleted automatically. A release that may already be public
is never deleted or mutated by rollback logic, which preserves immutable
release evidence for investigation.
