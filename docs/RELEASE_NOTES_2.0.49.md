# TetoTV 2.0.49 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta focuses on dependable playback recovery, safer Discord Rich Presence lifecycle handling, more useful diagnostics, and a cleaner Settings experience across TVs and phones.

## What's changed

- Settings are reorganized into Appearance, Playback, Services, Accounts, and System so related controls are easier to find without removing existing functionality.
- The Settings layout uses consistent dark cards, clear pink focus states, responsive two-column TV organization, and a single-column phone presentation.
- TV Settings controls, cards, tabs, dialogs, and spacing are substantially more compact so more options fit on screen without changing the existing mobile layout.
- Offline download controls now live with source and media services instead of occupying a separate Settings tab; the Download Manager and every existing download option remain available.
- Developer release history now keeps lower-build releases visible but clearly disabled, preventing a failed download/install attempt when Android cannot perform an in-place downgrade.
- Proxied HLS streams receive an appropriate first-frame readiness budget, preventing valid streams that need more than 12 seconds to start from being abandoned prematurely.
- Automatic fallback advances cleanly past failed direct-stream validation and records each failed candidate once for more useful troubleshooting.
- Optional HLS metadata inspection is deduplicated, bounded, and concurrent so compatible extensions return usable results sooner.
- Explicit VOD playlists that omit `#EXT-X-ENDLIST` are safely finalized for playback, while live, event, low-latency, and otherwise mutable playlists remain blocked from an unsafe frozen rewrite.
- Discord Rich Presence operations are serialized and stale callbacks are invalidated, preventing overlapping activity writes, disconnects, and reconnects from racing the native WebSocket lifecycle.
- Immediate Discord reconnects now wait for both token readiness and complete socket teardown before opening exactly one replacement connection.
- Diagnostics retain a larger bounded event window, aggregate repeated technical stream failures, classify interrupted playback sessions, and preserve whether the interruption was native, Java, Flutter, ANR, or another platform failure.
- Empty GitHub repository-access collections are now interpreted correctly by the fail-closed Beta publisher without weakening checks for actual collaborators, invitations, apps, webhooks, runners, or deploy keys.
- TetoTV still does not bundle, recommend, or endorse content providers. Users choose and configure their own lawful services and extensions, and the existing source-safety checks remain enforced.
- Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.

## Release assets

- `TetoTV-v2.0.49-universal.apk`
- `TetoTV-v2.0.49-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410026`.
- No Public APK is being published with this release.
- Skip-button availability still depends on valid timing data from the configured metadata service or TetoTV's validated local cache; TetoTV does not guess unsafe skip points when that service is unavailable.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410026` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410026 -->
