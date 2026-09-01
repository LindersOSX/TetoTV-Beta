# TetoTV 2.0.57 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta restores the Developer release picker, improves cross-tracker Watch Party avatars, and finishes the shared notification/profile styling pass.

## What's changed

- Selecting **Load release history** in Developer Mode now fetches releases and immediately opens the signed-release picker.
- Preloaded and freshly fetched release histories use the same picker and keep Android's build-code downgrade restrictions visible.
- AniList and MyAnimeList users can now see each other's public profile pictures in the Watch Party lobby.
- MyAnimeList's official numeric avatar cache-buster is safely removed before the public image URL is shared; arbitrary query data remains rejected.
- In-app notification text now uses the same label typography as the rest of TetoTV.
- The shared profile trigger, image, focus outline, and popup avatar now use one consistent rounded-square corner radius.
- Popup profile avatars use the same accent border as the top-right profile picture.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.57-universal.apk`
- `TetoTV-v2.0.57-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410034`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410034` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410034 -->
