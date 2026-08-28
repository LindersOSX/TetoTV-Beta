# TetoTV update channels

TetoTV follows the installed APK family when no update-channel preference has
been saved: a fresh 1.x installation starts on **Public**, while a fresh 2.x
installation starts on **Beta**. An explicit channel choice is stored locally
in encrypted preferences.

Developer Mode can display releases that remain in the selected repository. It
does not make the installed APK debuggable or bypass Android package-manager
downgrade rules. An in-place update still requires the same package and signer,
a compatible device, and an equal or higher Android build code.

Both channels make anonymous GitHub API requests. App updates do not use the
TetoTV companion service, a GitHub token, a shared Beta key, or an update proxy.
The fixed repository selected by the channel is the updater trust boundary.

## Public channel

Public reads completed 1.x releases from:

```text
https://api.github.com/repos/LindersOSX/TetoTV-Public/releases/latest
```

No Public APK is currently published. A `404 Not Found` response from this
endpoint is therefore the expected state and must be handled as no available
Public update. Do not create a Public tag or release until a separate Public
release review is approved.

The legacy `LindersOSX/TetoTV-Releases` bridge also has no current release.
Older Public clients that still use it will not receive an update until a
future reviewed Public release is intentionally mirrored there.

## Beta channel

Beta reads completed 2.x releases from:

```text
https://api.github.com/repos/LindersOSX/TetoTV-Beta/releases/latest
```

The current Beta source build is `v2.0.40` with Android build code `410017`.
Its release title is:

```text
TetoTV 2.0.40 Beta - Android TV / Google TV / Fire TV
```

Publish it as a normal, non-draft, non-prerelease GitHub release so
`/releases/latest` can return it. The clean repository cutover intentionally
starts a new public source history; do not push an old branch, tag, pull-request
ref, import, fork network, or bundle into the replacement repository.

## Legacy Beta updater bridge

Installed Beta builds that still use the original repository name validate the
repository embedded in every APK download URL. Until that migration window is
explicitly closed, mirror each signed Beta tag and release to:

```text
https://api.github.com/repos/LindersOSX/TetoTV/releases/latest
```

`tool/release/publish_beta_release.ps1` must publish and verify the canonical
Beta release and this bridge together. Failure of either publication is a
release failure, and a partial publication must be rolled back.

## Release asset contract

Each future Public or Beta release contains exactly three custom assets:

```text
TetoTV-vX.Y.Z-universal.apk
TetoTV-vX.Y.Z-native-playback-sources.zip
SHA256SUMS
```

The universal APK contains `armeabi-v7a` and `arm64-v8a`. The native source ZIP
contains the pinned source snapshots, rebuild information, license texts, and
hash records required by the released native playback stack. `SHA256SUMS`
contains exactly one SHA-256 record for the APK and one for that ZIP. GitHub's
automatically generated tagged source ZIP and tarball remain additional source
artifacts but are not custom release assets.

The updater ignores non-APK assets. It prefers the unique asset ending in
`-universal.apk` before considering another `.apk`, then downloads directly
from that asset's `browser_download_url`. APK bytes never pass through a TetoTV
proxy.

Release notes must include the exact asset names and this build-code marker:

```html
<!-- tetotv-android-version-code: 410017 -->
```

When build-code metadata is present, the updater rejects a known lower build
before downloading it. The downloaded APK manifest remains authoritative.

## Download and install validation

For both channels, the updater validates:

- exact HTTPS GitHub owner, repository, tag, and release-asset URL shape;
- release version family and non-draft status;
- asset size and GitHub SHA-256 digest when supplied;
- package ID and production signing certificate;
- Android version name and build code;
- minimum SDK and ARM ABI compatibility; and
- APK signatures before opening Android's installer.

These rules apply equally on phones, Android TV, Google TV, and Fire TV.

## Switching and rollback

The current Beta uses build code `410017`. No Public counterpart is available.
An older Public install can move to this Beta when Android accepts the higher
build code, but it cannot move back in place until a future Public build uses
code `410017` or higher. Uninstalling first permits an older APK but deletes
local application data. Developer Mode and in-app settings cannot override
this Android rule.

## Publishing checks

Before publishing either channel:

1. Start from a reviewed clean public root and verify the proprietary Discord
   SDK AAR is absent from every public branch, tag, pull-request ref, archive,
   release asset, and reachable Git object.
2. Build one production-signed universal APK with ARM32 and ARM64.
3. Stage and verify the versioned native source bundle.
4. Generate `SHA256SUMS` from the final APK and native source ZIP.
5. Run `tool/release/verify_release_payloads.ps1` and the full checklist in
   `PUBLIC_RELEASE_CHECKLIST.md`.
6. Publish a normal completed release with exactly the three named assets.
7. Download every hosted asset again, compare sizes and SHA-256 digests, verify
   `/releases/latest`, and install over the preceding Beta on representative
   phone, Android TV/Google TV, and Fire TV devices.

For Beta, use `tool/release/publish_beta_release.ps1`; it is a dry run unless
`-Publish` is passed and it retains the legacy Beta updater bridge. Public
publication is intentionally absent from the release scripts and rejected by
the release workflow. Re-enabling it requires a separately reviewed source
change after the Public channel is approved.

No GitHub token, Beta key, signing secret, provider credential, or companion
secret belongs in a Dart define, APK, preference, source archive, command line,
or public release artifact.
