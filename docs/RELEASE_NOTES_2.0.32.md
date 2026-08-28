# TetoTV 2.0.32 Beta

This beta focuses on reliable playback, correct dual-audio filtering, working title artwork, a more compact player HUD, and safer update-channel handling.

## What's changed

- Web streams and Real-Debrid sources now have a bounded decoded-video readiness check. Sources that open without producing video frames automatically advance to the next eligible fallback instead of leaving a black or endlessly loading player.
- Real-Debrid release-unavailable and rate-limit responses are handled as normal service outcomes instead of being recorded as app crashes.
- Web playback preserves safe provider origin data through the local playback proxy while continuing to reject private or unsafe origins.
- HLS sources are inspected for English and Japanese audio renditions at every advertised quality. Dual-audio sources appear under both Sub and Dub, and their master playlists are retained so the player can choose the requested track.
- Duplicate Sub and Dub entries for the same provider stream are combined into one dual-audio result.
- Android title-logo downloads now work with artwork resolved through AniZip, including stricter HTTPS, redirect, image-type, size, and cache validation. Previously failed artwork is retried; text remains the fallback when no language-appropriate logo exists.
- The player HUD is substantially shorter while keeping the same controls and TV-friendly target sizes.
- Update checks now distinguish same-build, lower-build, and signing-certificate conflicts. Developer mode can switch between signed channel counterparts that use the same Android build code, while accurately reporting Android's platform restriction on lower build codes.

## APK integrity

- `TetoTV-v2.0.32-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `9932ae5cd02574c96a53324e1bc19aafeadb69886d84b4e7d2007dda1b2abb46`

## Beta notes

- This is a Beta-channel build with Android build code `410009`.
- Android does not permit an in-place install over the same app when the target APK has a lower build code. Future Public and Beta counterparts must use this build code or a higher one for data-preserving channel switching.
- Clear-logo artwork is not available for every title or language. TetoTV falls back to the configured-language title text when suitable artwork cannot be found.
