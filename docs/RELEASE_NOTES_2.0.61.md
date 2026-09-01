# TetoTV 2.0.61 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta fixes controller-keyboard behavior, developer release-history navigation, cross-tracker Watch Party avatars, and the top-right profile focus treatment.

## What's changed

- Pressing Back on a TV remote while TetoTV's built-in keyboard is open now closes only the keyboard instead of passing the same Back action through to the app.
- On TV, the numeric controller keypad is centered at the bottom and 50% narrower than its previous fitting width; the full QWERTY keyboard is centered at the bottom and 30% narrower. Phone and other narrow-screen keyboard sizing is unchanged.
- Developer Mode release history now scrolls and focuses every release row. Android still blocks installing an APK with a lower build code, so Android-blocked downgrades remain non-installable.
- Late AniList and MyAnimeList Watch Party avatar updates now refresh across participants instead of remaining as initials. This client behavior requires the matching protocol-5 Watch Party broker to be deployed with the Beta.
- The compact top-right profile avatar now uses a direct themed focus ring and glow without the extra black contrast keyline.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.61-universal.apk`
- `TetoTV-v2.0.61-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410038`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410038` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410038 -->
