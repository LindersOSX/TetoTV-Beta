# TetoTV 2.0.42 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta strengthens account setup, privacy handling, and release integrity while keeping the existing updater, playback, downloads, and account connections compatible.

## What's changed

- New Discord links require a clear minimum-age eligibility confirmation before authorization begins. TetoTV stores only a versioned confirmation marker with the token; it does not request or retain a birth date, actual age, or jurisdiction.
- Secure phone setup uses protocol v3 when Discord is linked, binding the same narrow confirmation object to the encrypted credential bundle. Existing v1/v2 setup remains supported when Discord credentials are absent.
- Existing linked Discord sessions continue to refresh, reconnect, toggle Rich Presence, and survive cache clearing without a forced migration. Unlinking removes both the token and its confirmation marker.
- The privacy disclosure now provides an account-free private request route and accurately separates TetoTV's application retention from Wispbyte and Discord infrastructure processing.
- Featured TV titles use roughly the left half of the sponsor panel and scale/wrap the complete localized title without covering the right-side artwork. Phone and tablet title sizing is unchanged.
- Native redistribution publication supports either the default signed qualified-review path or this explicitly disclosed, owner-declared unreviewed Beta exception. Both paths verify a private GitHub draft before making a release public; the exception never represents automated checks as legal review.
- GitHub workflows use commit-pinned actions, dependency review, CodeQL, protected branches/tags, secret scanning, push protection, and immutable future release controls.
- The known libtorrent4j API-28-only update is held back so Fire OS 6 and Android 7 support remain intact.

## Release assets

- `TetoTV-v2.0.42-universal.apk`
- `TetoTV-v2.0.42-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410019`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410019` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410019 -->
