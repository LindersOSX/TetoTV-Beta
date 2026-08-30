# TetoTV 2.0.51 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta replaces the side-by-side TV Settings dashboard with a simpler phone-inspired list while preserving the compact TV sizing and the existing phone and tablet layouts.

## What's changed

- Every TV Settings category now uses one full-width vertical card list instead of side-by-side columns.
- Appearance, Playback, Services, Accounts, and System all follow the same consistent 8-pixel card spacing.
- Appearance keeps `Reset appearance and navigation` as its final remote action, so Down stops there and Left returns to the Settings rail as before.
- D-pad navigation now follows the visible list through caption controls, source toggles, connected tracking actions, Discord actions, update controls, storage actions, and legal/privacy controls.
- Connected tracking-account and Discord disconnect actions can no longer be skipped with a TV remote.
- The TV Settings rail, compact control sizing, five category tabs, and all existing Settings functionality remain available.
- Phone and tablet Settings retain their existing responsive layout and control sizing.
- Expanded layout and focus regression tests protect both the new TV list and unchanged non-TV behavior.
- TetoTV still does not bundle, recommend, or endorse content providers. Users choose and configure their own lawful services and extensions, and the existing source-safety checks remain enforced.
- Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.

## Release assets

- `TetoTV-v2.0.51-universal.apk`
- `TetoTV-v2.0.51-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410028`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410028` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410028 -->
