# Native playback redistribution record

This record covers the native playback binaries resolved by the current ARM
universal Android build. It records evidence and a practical replacement path;
it is not legal advice or a claim of compliance.

## Binary identity

TetoTV builds five Android input JARs from source: two ABI-specific
libmpv/helper JARs, the libtorrent4j Java wrapper, and two ABI-specific
libtorrent4j JNI JARs. The vendored media-kit adapter and Android app module
accept only those local outputs after checking self-build provenance. Neither
path has a network fallback to the older GitHub Release or Maven Central
prebuilt JNI artifacts.

The exact JAR byte lengths and SHA-256 values are recorded after each build in
`build/native-playback/outputs/SHA256SUMS`, copied into
`NATIVE_BUILD_PROVENANCE.json`, and pinned in the machine-readable release
manifest. Release verification also inventories the final post-AGP `.so`
entries in the APK so an input-container hash cannot hide an unexpected
packaging transformation.

The machine-readable record is
[`tool/release/native_playback_manifest.json`](../tool/release/native_playback_manifest.json).

## Source and build chain

The Linux/WSL build entry point is
[`tool/native/build_native_playback.sh`](../tool/native/build_native_playback.sh).
It verifies every downloaded archive, checks out every Git project at an
immutable commit, verifies each media-kit patch before application, and emits
a provenance file beside the five JARs. See `tool/native/README.md` for host
requirements and commands.

The libmpv graph pins build scripts `fe8c3ac1a91c09aa6fb1deccbc833f1bafa54768`,
mpv `78d43740f52db817d98bcf24fb30a76ab6fa13ff`, helper
`42054e5d479f39ccbb0ae604862e2bcaf59b74c2`, Mbed TLS
`1873d3bfc2da771672bd8e7e8f41f57e0af77f33`, dav1d
`676a864a11af2c0522e1f992e770589543894686`, libxml2
`f507d167f1755b7eaea09fb1a44d29aab828b6d1`, FFmpeg
`ea3d24bbe3c58b171e55fe2151fc7ffaca3ab3d2`, FreeType
`de8b92dd7ec634e9e2b25ef534c54a3537555c11`, FriBidi
`6428d8469e536bcbb6e12c7b79ba6659371c435a`, HarfBuzz
`a321c4fee56b15247c10f9aa3db7e7ccb3b8173b`, libass
`e8ad72accd3a84268275a9385beb701c9284e5b3`, and gas-preprocessor
`ac1836309c2e77023c228b7184485597286289d3`. The build configures mpv with
`gpl=false` and FFmpeg with `--disable-gpl --disable-nonfree
--enable-version3`.

The direct-torrent graph pins libtorrent4j
`09ffd391d4ef12e668cc032bffcbab47d9e2d5cb`, rasterbar
`a01469c8d1f88dd83bed458ffccffab2727b9d2a`, the separately archived
`try_signal` gitlink `105cce59972f925a33aa6b1c3109e4cd3caf583d`, and the exact
libdatachannel, libjuice, usrsctp, and plog revisions listed in
`DIRECT_TORRENT_STREAMING.md`. Boost 1.89.0 and OpenSSL 3.5.2 source
distributions are size- and SHA-256-verified. Android NDK r25c is used for the
mpv/helper line and r28c for libtorrent4j; both archives and their exact
runtime/toolchain notices are pinned.

The mpv link consumes r25c's static zlib, libatomic, and compiler-runtime
pieces. The helper statically consumes the r25c C++ runtime, C++ ABI, unwind,
libatomic, and compiler-runtime pieces. The complete r25c `NOTICE` and
`NOTICE.toolchain` files are therefore included rather than treating the NDK
as an unrecorded build-only input. The torrent line similarly retains the full
r28c notices for its statically incorporated runtime pieces.

These are new TetoTV-built artifacts. The project does not claim byte identity
with the retired upstream prebuilts. Host package versions are recorded but a
second isolated build and independent native-license review remain separate
release gates; until they occur, the result remains an explicitly unreviewed
Beta rather than a reviewed or Public compliance claim.

## Relinking and installation

The APK loads ABI-specific shared objects. A recipient may rebuild an
interface-compatible native stack, unpack a copy of the APK, and replace:

- `lib/<abi>/libmpv.so` and its media-kit helper libraries for the MPV stack.
- `lib/<abi>/libtorrent4j.so` for the optional direct-torrent stack.

Repack the APK, run Android SDK `zipalign`, and sign it with the recipient's
own key using `apksigner`. Verify the signature before installation. Android
does not allow an APK signed with a different key to update the official
package, so testing a modified build normally requires uninstalling the
officially signed copy first (which removes its local app data) or using a
separate application ID in a recipient-built TetoTV variant. The distribution
terms must not prohibit modification or reverse engineering needed to debug
such library changes.

## Release procedure

Run the offline verifier first:

```powershell
powershell -ExecutionPolicy Bypass -File `
  tool/release/verify_native_redistribution.ps1
```

At release time, use `-StageBundle`. This performs the network-heavy immutable
source exports, verifies the pinned Boost/OpenSSL archives, includes the exact
TetoTV build script and build provenance, and writes one combined native-source bundle under
`build/release-compliance`. Publish the versioned native source ZIP beside the
corresponding universal APK and `SHA256SUMS`, and retain the same verified
bundle for as long as the binary remains available. GitHub also supplies the
tagged TetoTV source archives automatically. A qualified reviewer must confirm
those archives and the durable public source locations referenced here meet
every applicable corresponding-source obligation before a Public release or a
reviewed Beta release. Do not use either reviewed path if they do not, or if a
revision, binary hash, license asset, or source snapshot is missing. The
explicit unreviewed Beta exception below may only record that this confirmation
was deferred; it does not resolve a source-offer gap.

The default review path is enforced by the SSH-signed, artifact-bound gate
documented in
[`NATIVE_LICENSE_RELEASE_REVIEW.md`](NATIVE_LICENSE_RELEASE_REVIEW.md).
Reviewed `-Publish` requires a fresh approval signed by an exact principal in
the checked-in qualified-reviewer allowlist. The repository starts with no
active reviewer key, so reviewed publication intentionally fails closed until
a project administrator independently verifies and commits a qualified
reviewer's public key. The signed record and its validation are review
evidence, not legal advice or a claim of compliance.

A Beta-only owner-declared exception may be used when independent review is
explicitly deferred. That path publicly states that neither the native-license
material nor corresponding source received independent review, binds a fresh
unsigned declaration to the final artifacts and documented provenance limits,
and retains all automated source, APK, checksum, pinned-input, draft, and
repository-authority verification. It is not an approval or compliance
determination and must not be represented as one. The exception is described
in `NATIVE_LICENSE_RELEASE_REVIEW.md` and is not permitted for Public releases.

The checked-in full GPL/LGPL texts are conservative. Exact component notices,
the selected build configuration, and each file's copyright determine the
applicable terms. Public and reviewed Beta distribution require a different
qualified person to check the final APK BOM, source bundle, notices,
replacement path, and signed review record. An unreviewed Beta must instead
disclose that this independent step was not completed and must not claim
compliance.
