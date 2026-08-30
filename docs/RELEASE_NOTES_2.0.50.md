# TetoTV 2.0.50 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta refines the compact TV Settings design so the same controls now use the available screen space more evenly, without changing the approved sizing or the phone layout.

## What's changed

- TV Settings tabs now divide the available width evenly with one consistent gap between every category.
- Settings cards use a consistent compact gutter horizontally and vertically across Appearance, Playback, Services, Accounts, and System.
- Appearance, Services, Accounts, and System now flow as continuous two-column TV layouts, eliminating large blank lanes caused by unrelated cards sharing rigid rows.
- Appearance cards size themselves to their actual controls instead of reserving unnecessary empty height.
- The Settings page no longer leaves a large unused footer below the final TV card.
- Existing control, text, icon, and card sizing remains unchanged from the previously approved compact design.
- Phone Settings retain their existing single-column ordering, spacing, and sizing.
- New layout-contract tests protect the equal tab widths, consistent card gutters, continuous TV card stacks, compact card bounds, and unchanged phone layout.
- TetoTV still does not bundle, recommend, or endorse content providers. Users choose and configure their own lawful services and extensions, and the existing source-safety checks remain enforced.
- Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.

## Release assets

- `TetoTV-v2.0.50-universal.apk`
- `TetoTV-v2.0.50-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410027`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410027` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410027 -->
