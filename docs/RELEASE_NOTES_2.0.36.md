# TetoTV 2.0.36 Beta

This beta makes the Home interface consistent across Android TV and Fire TV devices and fixes progress-bar seeking that could incorrectly jump a network stream to the end.

## What's changed

- All television resolutions now use one canonical TV layout, so 720p, 1080p, 1440p, and 4K devices keep the same compact Home composition instead of changing spacing based on resolution.
- TV detection now uses a safe startup fallback and retries the native device check in the background, preventing slower Fire TV and Chromecast bridges from being permanently treated as phones during launch.
- The TV profile switcher now matches the phone presentation with a compact avatar-only control while retaining profile management and switching in its menu.
- Progress-bar scrubbing now displays the exact target timestamp while the user moves through an episode.
- Scrub targets are bounded away from the exact end of the file, preventing an accidental end-of-episode completion when seeking near the final frame.
- Web, Debrid, torrent, Plex, and Jellyfin streams now perform one committed seek when the user releases the progress bar instead of sending repeated overlapping network seeks while it moves.
- Local and downloaded files retain responsive live preview seeking.
- Web playback proxy concurrency remains bounded but now permits the normal overlapping audio, video, subtitle, and range requests produced by MPV without falsely ending playback.
- Discover focus regression coverage now adapts to the active TV canvas instead of assuming one fixed resolution.

## APK integrity

- `TetoTV-v2.0.36-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `9dcd3ed0ca569626161f047f3a8afae81162f875900bbdc1134d689e182f1c47`

## Beta notes

- This is a Beta-channel build with Android build code `410013`.
- Android does not permit an in-place install over an APK with a higher build code; future Public counterparts must use build code `410013` or newer for data-preserving switching.

<!-- tetotv-android-version-code: 410013 -->
