# TetoTV 2.0.40 Beta

This Beta refreshes TetoTV's public-source and release boundaries without changing how users configure or play their own authorized media.

## What's changed

- Replaced named third-party catalog examples, provider screenshots, and live catalog fixtures with synthetic `.example` data.
- Clarified that TetoTV does not bundle, index, recommend, or endorse media sources, provider catalogs, credentials, or content.
- Expanded the privacy disclosure and store data-safety inventory to cover unified phone setup, user-installed extension probes, Watch Party, diagnostics, infrastructure metadata, and the Beta-only aggregate live count.
- Added public security and content-reporting policies.
- Release verification now requires the signed universal APK, the corresponding native playback source bundle, and an exact checksum manifest.
- The Beta repository starts from a clean public root so the locally supplied proprietary Discord SDK archive is not reachable through public source history or pull-request refs.

## Release assets

- `TetoTV-v2.0.40-universal.apk`
- `TetoTV-v2.0.40-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410017`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410017` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410017 -->
