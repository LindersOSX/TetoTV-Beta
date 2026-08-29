# TetoTV 2.0.41 Beta

This Beta refines the TV presentation and release pipeline while preserving the existing updater, playback, account, and setup behavior.

## What's changed

- Featured titles now remain fully visible on TV, including long localized titles, without shifting the metadata or Home actions out of place.
- Episode-detail actions use one compact, consistently sized strip for Watch trailer, Cast & crew, Related series, and Download season across TV logical resolutions.
- Scrubbing now shows the target timestamp in a pink bubble that follows the seek thumb, and the redundant far-right seek timestamp has been removed.
- Skip Intro and Skip Outro remain separated from the taller HUD while the seek bubble is visible.
- Beta publishing and update documentation now target only the canonical Beta repository; retired bridge repositories are no longer referenced.
- Native redistribution verification now locates the Gradle cache on both Windows and Linux so GitHub can validate release assets successfully.

## Release assets

- `TetoTV-v2.0.41-universal.apk`
- `TetoTV-v2.0.41-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410018`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410018` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410018 -->
