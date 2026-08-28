# TetoTV 2.0.38 Beta

This beta hardens Real-Debrid and web-stream playback, makes large provider catalogs easier to browse, and keeps player overlays clear of the HUD.

## What's changed

- Real-Debrid source recovery now spaces magnet requests across the app and rechecks rate-limit state after waiting, preventing candidate bursts from causing avoidable timeouts.
- Web-stream proxy requests now use a bounded waiting queue during short bursts instead of returning false overload errors that MPV could mistake for the end of a video.
- If a network stream reports an implausibly early completion, TetoTV now tries the next source from the last real playback timestamp instead of marking the episode complete.
- Intentional seek-to-end actions and genuine near-end completion continue to finish normally.
- Marketplace catalogs can now be filtered and sorted by their declared provider language, including large Seanime-format repositories.
- Skip Intro and Skip Outro keep a visible gap above an expanded Watch Party player HUD.
- The supplied crash report was reviewed; it recorded a handled temporary DNS failure during tracker pairing, and the existing retry path remains intact.

## APK integrity

- `TetoTV-v2.0.38-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `9ae16194cda3797e62778cb34dca9629535cc80e06fce7c17dc1639dd9b118e9`

## Beta notes

- This is a Beta-channel build with Android build code `410015`.
- Android does not permit an in-place install over an APK with a higher build code; future Public counterparts must use build code `410015` or newer for data-preserving switching.

<!-- tetotv-android-version-code: 410015 -->
