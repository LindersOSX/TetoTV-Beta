# TetoTV 2.0.74 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

## What's changed

- Added **Media3 SurfaceView** in **Settings → Playback** to try if videos stutter. Results vary by device.
- Switching this option on uses Media3 for the next video. Your familiar player controls stay the same; MPV is unchanged.
- Removed the small video-preview window when seeking in Media3. The time bubble stays.

## Install

Download **TetoTV-v2.0.74-universal.apk** for supported Android phones, tablets, Android TV, Google TV and Fire TV devices.

**TetoTV-v2.0.74-native-playback-sources.zip** is developer/license material, not an app installer. **SHA256SUMS** provides integrity hashes.

## Verification and channel

- Focused player, settings/navigation and native Media3 tests passed. Both rendering modes passed Android TV emulator playback, seeking, captions, HUD input, resizing, screenshots and view-recreation checks.
- Physical-TV performance improvement has not been established. Existing engine differences, including MPV-only manual audio/subtitle timing offsets, remain.
- Beta only, Android build code **410051**. No Public APK is being published.
- No repository, provider, catalog or media content is bundled or recommended by this update.

## Developer notes

- Turning SurfaceView off returns Media3 to TextureView without changing the selected player. Rendering changes apply to the next video, not during playback.
- AI tools assisted with implementation, testing and documentation. The project owner remains responsible for the release.

<!-- tetotv-android-version-code: 410051 -->
