# TetoTV 2.0.45 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta makes skip timing more resilient, explains provider discovery more clearly, and refines the TV experience around featured titles, episode actions, scrubbing, Watch Parties, and franchise navigation.

## What's changed

- Skip-intro and skip-outro timing now retries temporary lookup failures after playback starts instead of permanently giving up after the first short retry window.
- Clean no-match responses remain terminal, while unresolved transient failures receive bounded delayed retries without keeping unnecessary background work alive.
- A skip marker is consumed only after the player confirms that playback reached the requested position. Failed automatic skips remain available for a manual retry.
- Skip retries are tied to the active playback source so a delayed result cannot seek or suppress a marker after the user switches streams.
- Diagnostic exports now distinguish installed, enabled, searchable, blocked, completed, and result-producing providers for each source search.
- Provider diagnostics include bounded failure categories and raw-versus-visible provider/result counts with the active audio and quality filters, making it clearer when many choices came from only a few providers.
- The expanded diagnostics remain privacy-safe: they do not record show titles, episode titles, search queries, stream URLs, request headers, credentials, or account tokens.
- Diagnostic history retains enough structured provider and skip events to troubleshoot a playback session without exceeding the exporter's bounded event limit.
- Featured titles on TV now use a consistent font size and roughly half of the banner width, wrapping long localized titles across additional lines instead of shrinking or cutting them off.
- Watch trailer, Cast & crew, Related series, and Download season remain together in one compact row with all available actions visible and predictable left/right focus order.
- The player seek-time bubble now floats above the progress bar without expanding or bouncing the HUD during touch or D-pad scrubbing.
- Watch Party identities accept the public AniList and MyAnimeList avatar CDN aliases used by their APIs while continuing to reject untrusted avatar hosts and exclude private account data.
- Related Series now presents a deterministic recommended watch order with numbered TV, movie, OVA, special, prequel, sequel, side-story, and spin-off labels while preserving the selected title language.

## Release assets

- `TetoTV-v2.0.45-universal.apk`
- `TetoTV-v2.0.45-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410022`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410022` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410022 -->
