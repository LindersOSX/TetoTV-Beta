# TetoTV 2.0.73 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta adds an optional built-in Media3 player using TetoTV's existing player HUD. MPV remains the default.

## What's changed

- Choose **Settings → Playback → Default player → Media3 (Built in)** to try AndroidX Media3/ExoPlayer. The choice applies when you next open a video.
- Media3 shares the existing player layout and controls, including resume, seeking, episode switching, skip controls, speed, audio/CC selection, Watch Party and tracking.
- External subtitle languages and selected audio/caption tracks are preserved across Media3 decoder changes. Unsupported decoder choices no longer interrupt working playback.
- Plex/Jellyfin can recognize supported Media3 decoder/container failures and use their existing compatibility recovery.
- Playback diagnostics identify the selected engine and its available decoder, buffering and rendered/dropped-frame evidence. Media3 results do not change MPV's saved decoder preferences or device-health history.
- Native crash reports now capture a larger bounded trace, select the actual faulting thread instead of substituting another thread, and preserve useful binary build IDs while retaining credential and private-data redaction. Automatic crash reporting still requires opt-in.
- AI tools assisted with implementation, documentation, testing and review. The project owner directs the project and remains responsible for the release.

## Important player differences

- The main HUD is shared, but engine feature parity is not complete: manual audio/subtitle timing adjustments remain **MPV-only**.
- Advanced ASS subtitle rendering and available codecs can differ. Media3 relies on the decoders available on the device; this release does not promise smoother playback on every TV.
- The crash-reporting improvements do not establish that every native crash is fixed. The old incomplete report's underlying SIGSEGV cause remains unconfirmed.

## Install

Download **TetoTV-v2.0.73-universal.apk** for supported Android phones, tablets, Android TV, Google TV and Fire TV devices.

**TetoTV-v2.0.73-native-playback-sources.zip** is developer/license material, not an app installer. **SHA256SUMS** provides integrity hashes.

## Verification and channel

- 2,547 Flutter tests passed (33 conditional skips), 114 Android tests passed, and Android TV emulator playback/track-switching checks passed before release packaging.
- Beta only, Android build code **410050**. No Public APK is being published.
- No repository, provider, catalog or media content is bundled or recommended by this update.

<!-- tetotv-android-version-code: 410050 -->
