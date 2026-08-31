# TetoTV 2.0.53 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

This Beta makes caption behavior predictable between episodes and gives viewers a clear default under Settings > Playback.

## What's changed

- Playback Settings now includes `Preferred CC` with `Automatic`, `On`, and `Off` choices on TVs, tablets, and phones.
- A manual caption choice is remembered between episodes. TetoTV preserves the selected caption language and explicit On/Off intent instead of replacing it with a transient player default.
- Private Plex, Jellyfin, and other unlinked-library playback remembers manual caption choices through the global Preferred CC setting even when no AniList series ID is available.
- Source fallback, manual source changes, validated redirects, and prepared next episodes now carry caption intent and external-subtitle language metadata consistently.
- Provider sidecars only override a remembered language when their reported language matches. Automatic mode can still accept the resolver's best available sidecar.
- Media-open and subtitle-registration work is revision-bound so delayed events from the previous episode cannot select an old track or attach an old sidecar to the new stream.
- Existing v2.0.52 playback rows safely discard transient caption state that was previously mistaken for an explicit viewer choice.
- Searchable, collapsible TV Settings and the existing phone/tablet Settings layout remain unchanged apart from the new Preferred CC row under Playback.
- Existing privacy, update, source-safety, and three-asset release requirements remain unchanged.
- AI-assisted development disclosure: AI tools assisted with implementation, design iteration, documentation, tests, and review. The project owner directed the work, validated the changes, and remains responsible for this release.

## Release assets

- `TetoTV-v2.0.53-universal.apk`
- `TetoTV-v2.0.53-native-playback-sources.zip`
- `SHA256SUMS`

## Beta notes

- This is a Beta-channel build with Android build code `410030`.
- No Public APK is being published with this release.
- Android does not permit an in-place install over an APK with a higher build code. A future Public counterpart must use build code `410030` or newer for data-preserving channel switching.

<!-- tetotv-android-version-code: 410030 -->
