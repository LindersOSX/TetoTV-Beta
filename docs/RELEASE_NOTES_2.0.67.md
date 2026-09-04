# TetoTV 2.0.67 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta completes SIMKL tracking, makes the episode browser and update inbox available in the shipped APK, and hardens the Android paths implicated by recent TV freezes.

## What's changed

- SIMKL is now a complete tracking-account option alongside AniList and MyAnimeList. TetoTV uses SIMKL's official TV PIN flow with a public application ID, stores the returned token in Android secure storage, and supports account verification, Home and My List shelves, status changes, watched-episode progress, profile artwork, account switching, and Watch Party identity.
- SIMKL library reads now follow the required two-phase sync model: one account-scoped initial pull, user-driven activity checks no more than once every 20 minutes, incremental changes, deletion reconciliation, bounded transient retry, and a persistent cache that is discarded when the account is disconnected or becomes too old.
- Every SIMKL-backed list item includes visible SIMKL attribution and a validated link to its matching SIMKL page. Tokens are never included in artwork or attribution URLs.
- Pressing Down from the episode selector opens an eight-item, TV-friendly paged episode browser with thumbnails, names, runtimes, direct episode-number entry, edge paging, and polished unaired-series or unaired-episode dates.
- The navigation bar notification bell keeps app announcements and update notices until they are read, including update check, download, retry, and install actions.
- TorBox approval remains active while the user changes screens or browsers, tolerates temporary DNS failures, and explains provider-side approval failures without discarding a still-valid code.
- Android crash storage, TV Watch Next updates, and release-reminder alarm synchronization now run away from Flutter's platform thread through one bounded worker. This removes synchronous provider/file work from the UI path that could freeze slower TVs.
- Android 11+ ANR collection now reads enough of the bounded system trace to retain the main-thread stack instead of reporting only the runtime preamble, improving future diagnosis without weakening redaction.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.67-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.67-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410044`.
- No Public APK is being published with this release.
- SIMKL linking is available only when the deployed TetoTV companion advertises the registered public SIMKL client ID. No SIMKL client secret is embedded in the APK.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410044` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410044 -->
