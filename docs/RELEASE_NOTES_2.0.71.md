# TetoTV 2.0.71 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta adds a more customizable manga reader and richer, privacy-safe playback diagnostics for investigating buffering and stutter reports.

## What's changed

- Manga reading preferences are reorganized into a cleaner settings sheet with layout, navigation, appearance, and behavior sections.
- Reader layout can be saved per manga, including vertical, single-page, double-page, and automatic spread modes without changing other titles.
- Added configurable reading direction, page fit, gaps and margins, background color, brightness, contrast, saturation, preload distance, page counters, tap zones, and page-turn animation controls.
- Added pinch zoom and double-tap zoom while keeping TV remote navigation predictable. Foldable and wide displays can use side-by-side spreads, and webtoon scrolling uses precise page extents.
- Playback reports now retain bounded per-attempt evidence for the active decoder, codec, frame-drop counters, buffering, cache state, A/V sync, source/display rates, seeking, and app foreground state when the device exposes those values.
- Playback sampling is isolated from recovery behavior: it does not change sources, decoder settings, buffering policy, or playback tuning. Missing engine values remain unknown rather than being reported as zero.
- Reports distinguish a video-parameter startup signal from proof of rendered or smooth playback, and the Diagnostics screen now labels that state as **Started**.
- Performance history uses a separate 48-hour, 24-attempt local store so periodic samples cannot crowd startup, fallback, and failure events out of the normal diagnostics history.
- Explicitly shared diagnostic reports preserve the newest useful playback evidence within the existing size limit and continue to exclude media titles, episode names, URLs, paths, headers, credentials, and account identifiers from performance records.
- AI-assisted development disclosure: AI tools assisted with implementation, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.71-universal.apk` — install this file on a supported Android phone, tablet, TV, Google TV, or Fire TV device.
- `TetoTV-v2.0.71-native-playback-sources.zip` — native playback source and license material for developers and compliance review; normal users do not need it.
- `SHA256SUMS` — integrity hashes for the two files above.

## Beta notes

- This is a Beta-channel build with Android build code `410048`.
- No Public APK is being published with this release.
- This update adds diagnostic evidence; it does not claim that every device-specific playback lag issue is fixed. Native metric availability varies by device and stream.
- No manga repository, extension, provider, catalog, or title is bundled or recommended by TetoTV.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410048` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410048 -->
