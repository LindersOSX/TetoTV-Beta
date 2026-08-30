# TetoTV 2.0.46 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta compacts the episode-details actions and restores the player's tighter HUD spacing while keeping scrubbing stable and readable.

## What's changed

- Watch trailer, Cast & crew, Related series, and Download season now occupy about half of their former full-HD TV footprint.
- All four actions remain together in one row with the same left-to-right D-pad focus order and focus styling.
- Compact TV and phone layouts use proportioned button widths so every action remains visible without horizontal scrolling or scaled-down containers.
- Labels can wrap onto two centered lines when space is constrained, and layout checks protect them from clipping across representative TV, phone, tablet, and landscape sizes.
- The active season-download action uses the shorter `Cancel download` label so its state remains clear within the compact row.
- The player HUD once again uses its tighter pre-2.0.45 padding instead of permanently reserving a tall empty lane for the scrub timestamp.
- The scrub timestamp remains aligned to the seek thumb and may overlap the controls slightly without expanding, bouncing, or moving the HUD or Skip Intro/Outro action.
- Real-Debrid's startup account check now exits safely if its settings controller is disposed while secure storage or account validation is still in flight.

## Release assets

- `TetoTV-v2.0.46-universal.apk`
- `TetoTV-v2.0.46-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410023`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410023` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410023 -->
