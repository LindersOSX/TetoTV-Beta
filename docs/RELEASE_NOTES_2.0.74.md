# TetoTV 2.0.74 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

## What's changed

- Added **Settings → Playback → Media3 SurfaceView**, an experimental rendering toggle for Android. Off uses TextureView (the default). Turning it on automatically selects **Media3 (Built in)** for the next video.
- Turning it off returns Media3 to TextureView without changing your selected player. You can still select MPV independently; MPV playback and rendering are unchanged.
- Both Media3 modes use the same TetoTV HUD, captions, seeking and sizing controls. Rendering changes apply when you next open a video, not during playback.
- Removed the Media3 scrubbing scene-preview window. The seek timestamp bubble remains.
- SurfaceView is an optional device-specific comparison, not a guaranteed fix for low FPS.
- AI tools assisted with implementation, testing and documentation. The project owner remains responsible for the release.

## Install

Download **TetoTV-v2.0.74-universal.apk** for supported Android phones, tablets, Android TV, Google TV and Fire TV devices.

**TetoTV-v2.0.74-native-playback-sources.zip** is developer/license material, not an app installer. **SHA256SUMS** provides integrity hashes.

## Verification and channel

- Focused player, settings/navigation and native Media3 tests passed. Both rendering modes passed Android TV emulator playback, seeking, captions, HUD input, resizing, screenshots and view-recreation checks.
- Physical-TV performance improvement has not been established. Existing engine differences, including MPV-only manual audio/subtitle timing offsets, remain.
- Beta only, Android build code **410051**. No Public APK is being published.
- No repository, provider, catalog or media content is bundled or recommended by this update.

<!-- tetotv-android-version-code: 410051 -->
