# TetoTV 2.0.63 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta adds a full Developer Mode Manga Preview while keeping TetoTV's no-bundled-catalog boundary.

## What's changed

- Enabling Developer Mode now adds a dedicated book destination with Library, Browse, Downloads, and Sources areas. The destination and reader routes remain hidden and fail closed until Developer Mode has loaded and is enabled.
- The reader supports paged, vertical, and webtoon layouts; right-to-left and left-to-right navigation; single, double, and automatic spreads; fit, spacing, background, preload, cover-page, inversion, tap-zone, animation, and keep-awake controls.
- Automatic spreads recognize a separating fold or hinge so an opened foldable can show two physical pages side by side without losing the current reading position.
- Viewers can add their own public HTTPS OPDS 1.x, OPDS 2.0, or declarative TetoTV manga repositories. TetoTV ships, recommends, and remotely enables none, and it never executes manga repository or APK-extension code.
- Optional source credentials use Android Keystore-backed storage and are sent only to the exact source origin. Redirects, bounded concurrent image fetching with total deadlines, archive limits, and strict ZIP/CBZ validation protect catalog, page, and download handling.
- Compatible chapters can be downloaded to app-private storage for offline reading, with live progress, cancellation, safe retry/recovery, integrity checks, source cleanup, and a best-effort Android foreground-service lease while TetoTV is minimized.
- Profile-local manga library state, reading progress, and reader preferences are restored when a title or completed download is reopened.
- Optional Discord Rich Presence can show the manga title, chapter, and page progress. A reader privacy setting replaces the title with **Reading manga**, and Manga Preview never sends a user-added source, catalog, cover, page, credential, request header, or local path to Discord.
- Public documentation now covers the source schema, credential boundary, downloads, diagnostics exclusions, data handling, content policy, and third-party `xml` and `archive` licenses.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.63-universal.apk`
- `TetoTV-v2.0.63-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410040`.
- No Public APK is being published with this release.
- Manga Preview is experimental and available only while Developer Mode is enabled. Repository compatibility is not a review of a source's content, safety, terms, availability, or legality.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410040` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410040 -->
