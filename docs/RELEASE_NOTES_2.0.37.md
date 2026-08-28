# TetoTV 2.0.37 Beta

This beta restores the larger television interface sizing used before 2.0.36 while retaining the recent playback, profile, and device-detection fixes.

## What's changed

- Restored resolution-aware TV scaling based on the active rendering surface.
- 720p and 1080p output again use the previous `960px` virtual canvas.
- 1440p output again uses the previous `1280px` virtual canvas.
- True 4K output keeps the previous `1600px` virtual canvas.
- A 4K-capable Chromecast rendering at 1080p now receives the larger 1080p interface instead of being forced into the smaller 4K composition.
- Fire TV devices rendering at 4K retain their established 4K layout.
- Phone scaling and the user's interface-scale preference are unchanged.
- The bounded progress-bar seeking, visible scrub timestamp, profile control, and startup TV-detection fixes from 2.0.36 remain included.

## APK integrity

- `TetoTV-v2.0.37-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `fe1ac6c5a9684e5ea50652d0d4c6b646b41d2e10d27e9b06440aed58b11e7389`

## Beta notes

- This is a Beta-channel build with Android build code `410014`.
- Android does not permit an in-place install over an APK with a higher build code; future Public counterparts must use build code `410014` or newer for data-preserving switching.

<!-- tetotv-android-version-code: 410014 -->
