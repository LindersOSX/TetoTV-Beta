# TetoTV 2.0.62 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta makes extension source discovery faster, more resilient, and more accurate for Dub and dual-audio streams.

## What's changed

- Installed Web providers now search through a bounded three-worker queue, show successful streams immediately, stop blocking the screen after an eight-second foreground budget, and continue useful work in the background for up to 45 seconds.
- Each provider receives one initial attempt with a 12-second deadline. Failed providers are not automatically retried during discovery; a new **Retry failed providers** action retries only the providers that actually failed while preserving working results.
- TetoTV distinguishes a clean “no match” from provider, network, runtime, extraction, and timeout failures. Clean empty results do not damage provider health, while actionable failures remain visible and retryable.
- Providers that repeatedly fail or time out are temporarily moved later in the queue. The provider behind the last source that actually validated or played is prioritized on the next search.
- Provider title matching now considers English, Romaji, native/Japanese, and alternate AniList titles with Unicode-aware comparison and stricter season, year, and episode checks.
- Dub discovery now honors declared Sub, Dub, and dual-audio metadata, performs a bounded compatibility probe for older extensions, and never mistakes subtitle tracks for dubbed audio.
- Source-search diagnostics now include privacy-safe session, timing, queue, progress, outcome, and filter counts without recording anime titles, stream URLs, tokens, or headers.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.62-universal.apk`
- `TetoTV-v2.0.62-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410039`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410039` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410039 -->
