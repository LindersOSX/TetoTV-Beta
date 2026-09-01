# TetoTV 2.0.58 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta keeps TetoTV open when a television remote dismisses the shared profile switcher.

## What's changed

- Controller Back now consumes its complete key-down/key-up sequence while the profile switcher is open.
- The profile switcher closes on Back without leaking the remaining key event to Android and exiting the app.
- Native Android Back continues to close the profile switcher while Home remains visible.
- Left still closes the profile menu immediately, preserving the existing D-pad navigation behavior.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.58-universal.apk`
- `TetoTV-v2.0.58-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410035`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410035` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410035 -->
