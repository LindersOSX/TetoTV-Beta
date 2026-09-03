# TetoTV 2.0.66 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta improves TorBox linking, filters incompatible streams for each device, adds faster episode browsing, and introduces a persistent app-update inbox.

## What's changed

- TorBox device linking now survives temporary DNS or network failures and remains active while the user switches to a phone browser to approve the code, instead of timing out or failing the pairing screen prematurely.
- Stream results now use the Android device's actual hardware-decoder inventory. A stream is hidden only when its advertised codec and resolution are proven unsupported on that device; unknown codec or device data remains visible. This prevents AV1 streams from appearing on an AVC-only TV while preserving uncertain results.
- Pressing Down from the episode selector now opens a TV-friendly paged browser with series artwork, runtime, clear page controls, direct episode-number entry, and polished handling for episodes or entire series that have not aired yet. Releasing titles also show the next known air date or countdown when AniList provides it.
- A notification bell beside the profile picture now keeps app-update notices until they are read. The inbox shows release details and current download state, with actions to check, retry, download, or install an update.
- Automatic update checks no longer open Android's installer without user intent; completed downloads wait in the notification panel until the user chooses to install.
- Temporary SIMKL availability problems are classified correctly and no longer create misleading anonymous crash reports.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.66-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.66-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410043`.
- No Public APK is being published with this release.
- Codec compatibility is evaluated locally per device. Known-incompatible results are hidden, while missing or ambiguous capability data safely leaves results available.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410043` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410043 -->
