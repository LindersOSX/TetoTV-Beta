# TetoTV 2.0.77 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

## What's new

- Fixed movie playback from torrents containing one playable video. Torrents with multiple possible videos still ask for a clearer source rather than guessing.
- Improved Watch Party handoff when a host starts a show, with better privacy-limited diagnostics if a guest cannot follow.
- Media3 (Built in) with SurfaceView is now selected on new installs and once for existing installs. You can change the player afterward in Settings; MPV remains available.
- Setup now explains that Debrid services are optional paid third-party subscriptions, not affiliated with TetoTV.
- Replaced the hidden ten-click Developer Mode unlock with an Experimental options switch for Aniyomi, build switching, and other experiments. The regular Manga reader does not require this switch.

## Known issues

- Aniyomi compatibility remains experimental. An installed extension may still fail if its site or extractor changes or requires unsupported capabilities.
- Actual-device acceptance testing of the affected Fire TV playback and Watch Party combinations remains recommended before a wider rollout.

## Install

Download **TetoTV-v2.0.77-universal.apk** for supported Android phones, tablets, Android TV, Google TV, and Fire TV devices.

**TetoTV-v2.0.77-native-playback-sources.zip** contains developer and license material, not an app installer. **SHA256SUMS** lists integrity hashes.

## Verification and channel

- Beta only, Android build code **410054**. No Public APK is being published.
- No repository, provider, catalog, or media content is bundled or recommended by this update.
- AI tools assisted with implementation, testing, and documentation. The project owner remains responsible for the release.

<!-- tetotv-android-version-code: 410054 -->
