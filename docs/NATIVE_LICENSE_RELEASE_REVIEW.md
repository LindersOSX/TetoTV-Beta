# Native-license release review gate

This gate records a qualified human review of the native playback and optional
direct-torrent redistribution evidence. It is not legal advice, does not
replace professional review, and does not claim that a release complies with
every applicable license.

## Security boundary

`-Publish` is blocked unless `publish_beta_release.ps1` can verify an OpenSSH
signature over the exact attestation bytes. The attestation binds the review
to all of the following:

- canonical release tag and full Git commit;
- final universal APK SHA-256;
- final native source ZIP SHA-256;
- checked-in native manifest SHA-256;
- checked-in `NATIVE_PLAYBACK_NOTICE.txt` SHA-256;
- the exact digest of every recorded upstream provenance limitation; and
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
  -AcknowledgeKnownProvenanceLimits
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
in the eventual GitHub release notes.

## Draft-first publication

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

GitHub receives a private draft first. The script re-downloads all three
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

Failed drafts are deleted automatically. A release that may already be public
is never deleted or mutated by rollback logic, which preserves immutable
release evidence for investigation.
