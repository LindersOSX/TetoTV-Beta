# TetoTV 2.0.69 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta fixes a native direct-torrent startup crash, smooths episode browsing, and delivers announcements and update notices while the app remains open.

## What's changed

- Direct-torrent playback now retains only independently owned libtorrent handles after processing native alerts. This prevents a released alert object from leaving a stale handle that can crash Android during torrent metadata startup or cleanup.
- The embedded episode browser now enters with a short fade-and-lift transition that matches the rest of the interface and respects reduced-motion preferences.
- A focused episode's description waits three seconds, then scrolls slowly when all of its text does not fit. Episode titles remain stationary, and leaving the card resets the description.
- App announcements refresh once per minute while TetoTV is in the foreground, GitHub update metadata refreshes every five minutes, and both refresh immediately when the app returns to the foreground. Restarting the app is no longer required to discover a new notice.
- Automatic update checks continue to discover and display newer releases when automatic APK downloads are disabled. When automatic downloads are enabled, background checks can download the verified APK without opening Android's installer.
- A previously verified APK is preserved after an installer error, while a genuinely newer GitHub release correctly replaces an older pending download.

## Release assets

- `TetoTV-v2.0.69-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.69-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410046`.
- No Public APK is being published with this release.
- Direct peer-to-peer playback remains an optional Beta feature that is disabled by default and requires explicit opt-in.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410046` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410046 -->
