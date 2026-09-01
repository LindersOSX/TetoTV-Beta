# TetoTV 2.0.60 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta fixes several runtime issues reported after 2.0.59 and restores the refreshed controller keyboards to a compact lower-screen footprint.

## What's changed

- Developer release history now ignores non-installable companion release tags so the downgrade picker can open normally.
- Watch Party public identities stay synchronized at provider scope, allowing AniList and MyAnimeList participants to share profile pictures throughout the lobby flow.
- Watch Party notifications now use TetoTV's shared typography and consistent square avatar styling.
- Profile trigger and avatar outlines now use matching rounded-square geometry.
- The refreshed QWERTY and numeric controller keyboards keep their new layouts while using the compact lower-screen height of the original keyboard.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.60-universal.apk`
- `TetoTV-v2.0.60-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410037`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410037` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410037 -->
