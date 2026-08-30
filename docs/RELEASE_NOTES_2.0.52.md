# TetoTV 2.0.52 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta makes the phone-inspired TV Settings list faster to navigate by adding search and collapsible sections while leaving the existing phone and tablet Settings experience unchanged.

## What's changed

- TV Settings now includes a compact search field at the top of the screen. Results identify and open the matching category and section, then focus the requested control when it is currently available.
- An `Expand all` / `Collapse all` action sits between search and the profile picker. It applies only to the currently active Settings category so other categories keep their own section state.
- Every TV Settings card can be collapsed to its section title and expanded again without removing any existing setting or category.
- Appearance, Playback, Services, Accounts, and System keep the same phone-inspired, full-width vertical card list and compact TV sizing introduced in the previous Beta.
- D-pad navigation now follows the visible interface exactly: search, the active-area expand/collapse action, profile picker, category tabs, section headers, and every mounted setting form one predictable path.
- Moving Down from the final control in an expanded section enters the next section header. Moving Up from a section's first control returns to that section header, while Left keeps a deterministic path back to the Settings navigation rail.
- Search jumps account for conditional controls such as connected accounts, developer update tools, download options, and Beta-only diagnostics, falling back to the matching section header when a requested control is not currently available.
- Phone and tablet Settings retain their existing responsive layout, sizing, and direct controls; TV-only search and collapsible card behavior are not shown there.
- Existing privacy, update, source-safety, and three-asset release requirements remain unchanged.
- AI-assisted development disclosure: AI tools assisted with implementation, design iteration, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.52-universal.apk`
- `TetoTV-v2.0.52-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410029`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410029` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410029 -->
