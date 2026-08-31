# TetoTV 2.0.55 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta fixes Settings toolbar restoration and the initial TV focus target.

## What's changed

- Opening Settings now focuses **Appearance**, so the first D-pad selection is the active Settings category instead of the search field.
- Re-selecting Settings from the navigation rail returns to the top of the current Settings area, restores the search and collapse controls, and focuses the active category.
- Moving up from the first Settings section restores the fixed toolbar even when the content list had retained an earlier scroll offset.
- Nested dropdowns, reorder lists, and compact controls no longer make the shell incorrectly treat the main Settings page as scrolled.
- TV Settings options have a small focus lane between rows so the selected outline and glow no longer overlap neighboring options.
- The Settings D-pad order remains linear in both directions, including the corrected path from Navigation back through Home screen and Theme & display.
- Phone and tablet Settings keep the same responsive layout and touch behavior.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.55-universal.apk`
- `TetoTV-v2.0.55-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410032`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410032` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410032 -->
