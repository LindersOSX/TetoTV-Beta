# TetoTV 2.0.44 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta replaces TetoTV's retired prebuilt playback inputs with native libraries compiled for TetoTV from pinned source. App behavior, update compatibility, playback, downloads, watch parties, and account connections remain on the existing Beta flow.

## What's changed

- The ARMv7 and ARM64 libmpv, media-kit Android helper, and libtorrent4j inputs are built from pinned source by TetoTV's documented Linux build script. Release builds have no fallback to the retired upstream prebuilt JARs.
- The native source bundle now includes the exact build script, output provenance, immutable source snapshots, verified Boost and OpenSSL source archives, and complete checksums.
- The compiled torrent source graph now explicitly includes `try_signal`, libtorrent's bundled ed25519 notice, the full libtorrent-rasterbar license, and the applicable Android NDK runtime and toolchain notices.
- Native component notices for mpv, FFmpeg, libass, mbedTLS, dav1d, libxml2, FreeType, FriBidi, HarfBuzz, OpenSSL, Boost, libdatachannel, libjuice, usrsctp, plog, and the build-only gas-preprocessor tool are bundled and available in the app.
- Source-bundle verification rejects Windows CRLF line endings in shell build scripts, preventing a checksum-valid bundle that cannot run on Linux.
- Release verification inventories every final ARM native library in the signed APK and rejects missing, unexpected, or digest-mismatched entries.
- The guarded publisher now preserves single-item GitHub Actions allowlists under PowerShell strict mode, preventing a verified release from stopping before draft creation.
- This build is source-pinned and checksum-attested, but it has not been independently license reviewed or reproduced in a second isolated builder. Those limitations remain explicit in the manifest and this Beta warning.

## Release assets

- `TetoTV-v2.0.44-universal.apk`
- `TetoTV-v2.0.44-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410021`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410021` or newer for data-preserving channel switching.
- `v2.0.43` was an unpublished candidate tag and was never offered as an app release.

<!-- tetotv-android-version-code: 410021 -->
