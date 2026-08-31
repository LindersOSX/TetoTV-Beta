# TetoTV 2.0.54 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta tightens Settings focus behavior on TV while preserving the responsive Settings presentation on phones and tablets.

## What's changed

- TV Settings keeps D-pad focus inside its single vertical content list when a row has no explicit directional mapping, preventing accidental jumps to the navigation rail while moving up and down.
- Settings scroll reveals are now cancelled and generation-checked when a new D-pad event arrives, so stale animations cannot move the viewport after focus has changed.
- Leaving Settings with LEFT now waits for the normal focus traversal result before restoring the active Settings rail item; horizontal controls and phone/tablet navigation are not intercepted.
- Activating the already-selected Settings item in the rail restores the visible Settings content instead of opening a duplicate Settings route. This also handles the fixed TV search field being temporarily removed while the list is scrolled.
- Rail, profile, and content focus recovery ignores detached or non-focusable nodes, reducing intermittent “right does nothing” states after a route or layout change.
- Repeated D-pad focus callbacks no longer restart the Home hero restore animation, reducing visible choppiness during rapid TV navigation.
- Phone and tablet Settings retain their existing responsive layout and direct controls; the TV-only single-list focus graph does not change their presentation.
- The new diagnostic report from a Samsung phone showed no crashes or stream failures. Its retained frame samples indicate occasional startup/rendering spikes, but no evidence of a mobile Settings layout or focus failure; diagnostic-capacity drops are reported transparently.
- AI-assisted development disclosure: AI tools assisted with implementation, design iteration, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.54-universal.apk`
- `TetoTV-v2.0.54-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410031`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410031` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410031 -->
