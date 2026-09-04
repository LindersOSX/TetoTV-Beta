# TetoTV 2.0.70 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta fixes secure manga page loading across approved CDN redirects and adds polished episode details to the paused player HUD.

## What's changed

- Manga pages can now follow bounded HTTPS redirects used by compatible user-added sources while every destination is revalidated before loading. Sensitive credentials are stripped across origins, unsafe destinations remain blocked, and image size and format limits remain enforced.
- Manga loading errors now distinguish common source, authorization, availability, and security failures without exposing private URLs, headers, or credentials in diagnostics.
- Pausing an episode shows its catalog episode name and synopsis in the top-left while the player HUD is visible. The panel ends at the screen midpoint and the synopsis is clipped to three visible lines.
- Long episode descriptions begin a slow vertical scroll after five seconds while the episode title stays fixed. Reduced-motion settings disable the automatic movement.
- The paused HUD remains available for reading until playback resumes or the viewer dismisses it. Startup, completed playback, and error states do not present themselves as a user pause.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.70-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.70-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410047`.
- No Public APK is being published with this release.
- No manga repository, extension, provider, catalog, or title is bundled or recommended by TetoTV.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410047` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410047 -->
