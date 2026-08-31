# TetoTV 2.0.56 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta polishes the shared profile control and makes account switching easier to operate with a TV remote.

## What's changed

- The top-right profile picture now uses a rounded-square frame across TetoTV instead of a circular frame.
- The account switcher now uses TetoTV's raised surfaces, accent border, focus ring, typography, and Theme Studio colors instead of the stock Android-style popup.
- The active account receives focus when the account switcher opens, keeping profile selection predictable with a D-pad.
- Pressing **Left**, **Back**, or **Escape** closes the account switcher and returns focus to the profile control.
- The popup can also be dismissed by selecting its visible close button or tapping outside it.
- Account statistics, local profiles, tracking profiles, profile management, and relocated Settings access remain available.
- In-app popup menus and notification messages now share the same TetoTV surface, border, text, and accent treatment.
- Phone, tablet, and television layouts continue to use the shared profile behavior with responsive placement.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.56-universal.apk`
- `TetoTV-v2.0.56-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410033`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410033` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410033 -->
