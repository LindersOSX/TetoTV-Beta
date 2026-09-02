# TetoTV 2.0.64 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta focuses on faster source discovery, clearer episode handling, multilingual playback preferences, and stability across TV and mobile devices.

## What's changed

- Source searches now show successful providers sooner, stop slow or repeatedly failing extensions from holding up the first results, preserve failure details for diagnostics, and prioritize the last provider that worked without hiding alternatives.
- Dub and subtitle matching now understands more multilingual and multi-audio metadata. Playback settings can choose a preferred spoken-audio language and a preferred caption language, and explicit caption choices carry between episodes when the track is available.
- Provider resolution, embedded tracks, HLS variants, Jellyfin playback, direct-torrent service recovery, and next-episode preparation received reliability fixes.
- Episodes that have not aired no longer fall through to a generic playback failure. TetoTV shows a polished availability message and the expected air date when metadata provides one; the episode selector also supports direct numeric entry while keeping the plus and minus controls.
- One-time pairing codes can be copied with a double activation. TorBox linking and the secure phone-setup handoff received compatibility and recovery fixes.
- Opted-in anonymous crash reports now include more actionable, privacy-filtered runtime context and can be delivered automatically after a native crash, without including account credentials, repository URLs, media URLs, or personal library data.
- Developer Mode Manga Preview can use compatible user-added Seanime manga-provider extensions alongside supported catalog sources, with provider health, safer acquisition limits, artwork fallbacks, and reader/download reliability improvements.
- Local-media snapshots, tracking state, marketplace isolation, TV focus behavior, and responsive pairing screens received additional fixes and regression coverage.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.64-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.64-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410041`.
- No Public APK is being published with this release.
- Manga Preview remains experimental and is available only while Developer Mode is enabled. TetoTV does not bundle, recommend, or endorse repositories or provider extensions.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410041` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410041 -->
