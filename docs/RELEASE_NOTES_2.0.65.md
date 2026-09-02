# TetoTV 2.0.65 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta improves playback recovery, restores dependable Recently released results, handles calendar outages more accurately, and adds secure SIMKL account linking.

## What's changed

- Audio and subtitle codec failures no longer incorrectly force software video decoding after hardware video playback has started, reducing avoidable stutter on affected devices. Genuine video-decoder failures retain the existing compatibility fallback.
- The Kitsu backup now requests the correct season and year. An enabled **Recently released** shelf remains visible with a clear empty or temporarily unavailable message instead of disappearing.
- Temporary AniList and Jikan calendar outages are now treated as retryable availability problems—not application crashes—and retain only a sanitized local diagnostic warning.
- **Settings > Accounts** now includes secure SIMKL linking through its official authorization flow, with profile verification, reconnect, and disconnect support. Linking requires a compatible TetoTV companion with SIMKL OAuth enabled; SIMKL list and progress syncing remain disabled until titles can be mapped safely to canonical SIMKL IDs.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.65-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.65-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410042`.
- No Public APK is being published with this release.
- SIMKL account linking is available only when the configured companion reports SIMKL support; the SIMKL client secret remains server-side.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410042` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410042 -->
