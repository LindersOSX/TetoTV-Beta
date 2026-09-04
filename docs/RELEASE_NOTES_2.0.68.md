# TetoTV 2.0.68 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta adds a complete user-added manga-source workflow, expands Plex and Jellyfin track support, and polishes the episode browser, notifications, navigation, and diagnostics across televisions and phones.

## What's changed

- The Developer Manga Preview now has a repository → extension → browse workflow. Compatible user-added Seanime/Teto Marketplace repositories can expose `manga-provider` extensions with searchable, filterable install, update, enable, disable, and uninstall controls. No manga repository or provider is bundled, suggested, or prefilled.
- OPDS and declarative book catalogs remain supported separately. Native Mihon/Tachiyomi `index.pb` stores are identified clearly as incompatible instead of being saved as if they were usable by TetoTV's bounded QuickJS extension runtime.
- Marketplace repository types are pinned after validation so a saved manga repository cannot silently become an online-video provider repository, or vice versa.
- Plex and Jellyfin episode sources now expose available audio and subtitle tracks. Compatible server-side audio changes preserve the exact playback position, SRT/WebVTT sidecars use TetoTV's caption controls, and embedded tracks remain available through MPV.
- The episode browser is integrated into the episode screen with a cleaner two-column, three-row page, full thumbnails, episode titles, direct selection, and remote edge paging.
- App announcements and update notices can be dismissed directly. The notification control follows the active profile across the same top-level screens and keeps a bounded unread badge.
- The supplied in-app TetoTV mark now appears in the top-left navigation rail and automatically follows the viewer's selected accent color. The Android launcher icon is unchanged.
- TorBox pairing keeps a valid approval session through temporary connectivity changes, offers a retry path, and warns users about the current provider-page issue seen in Chrome.
- Diagnostics now retain the full bounded event ring and distinguish provider runtime errors from genuine empty results, making failed third-party source searches easier to troubleshoot without exposing credentials or media URLs.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.68-universal.apk` — install this file on a supported Android device.
- `TetoTV-v2.0.68-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410045`.
- No Public APK is being published with this release.
- Personal-library audio switching depends on the Plex or Jellyfin server and the selected delivery mode. Bitmap subtitles such as PGS may require direct play or server-side transcode/burn-in.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410045` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410045 -->
