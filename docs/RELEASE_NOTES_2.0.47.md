# TetoTV 2.0.47 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta makes user-configured extension discovery, stream classification, and skip timing more dependable without weakening TetoTV's source-safety boundaries.

## What's changed

- Episode discovery now uses a stable media identifier across localized titles and metadata changes, preventing duplicate searches for the same episode.
- Starting a different episode cancels stale provider work, while a slow or failing provider is isolated behind its own deadline so other configured providers can still return results.
- Provider-health reporting no longer delays result delivery, and diagnostics record only privacy-safe aggregate audio-classification counts.
- HLS classification now recognizes extensionless playlists and preserves bounded stream metadata from compatible extensions.
- HLS inspection gets one bounded retry for transient network, timeout, and server failures without retrying permanent or unsafe failures.
- Dub, dual-audio, and multi-audio evidence from compatible extension metadata and server labels is merged consistently, while strict Sub and Dub filtering remains intact.
- AniSkip lookups now coalesce concurrent requests and use bounded retry backoff instead of producing a burst of probes when the service is unavailable or rate-limited.
- Validated skip markers are cached for 14 days, with a validated stale-cache fallback available for up to 90 days during a temporary AniSkip outage.
- A temporary skip-data outage produces one non-blocking notice instead of repeated interruptions.
- Unsafe and incompatible targets remain blocked, while repository-reported broken or deprecated providers remain visibly warned as advisory; this release does not bypass source protections or bundle, recommend, or endorse any provider.

## Release assets

- `TetoTV-v2.0.47-universal.apk`
- `TetoTV-v2.0.47-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410024`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410024` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410024 -->
