# TetoTV 2.0.76 Beta

> [!WARNING]
> No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds.

## What's new

- Improved extension compatibility and diagnostics. AnimeGG, KickAssAnime, and Anikoto now pass isolated search, episode, and stream-resolution checks.
- HLS streams from compatible web providers now open correctly in Media3, including common HLS MIME variants and external HLS audio.
- Fixed a Media3 player cleanup error that could occur after HTTPS playback, while preserving the existing safe release wait for a real decoder shutdown.
- Added a narrowly scoped Fire TV workaround for the reported AFTKRT / Fire OS API 30 frame-acquisition ANR. MPV choices and all other devices are unchanged.
- Provider searches now give a healthy hoster longer to resolve while keeping the overall search deadline, concurrency limits, and failed-provider handling bounded.
- Improved reports so a large, privacy-filtered diagnostic export retains more recent troubleshooting history before reducing its contents.
- TorBox connection, timeout, and certificate failures now show a clear retry message rather than raw network details. A temporary network outage does not disconnect an account or repeatedly try unrelated torrents.

## Known issues

- Aniyomi extensions remain experimental and Developer Mode-only. Some extensions need capabilities that TetoTV deliberately does not allow, such as running their own local streaming server; installation alone does not guarantee a working source.
- The Fire TV fix is based on the captured ANR and passed surface lifecycle checks. Actual playback, background/resume, and memory-pressure testing on the affected Fire Stick is still needed.

## Install

Download **TetoTV-v2.0.76-universal.apk** for supported Android phones, tablets, Android TV, Google TV, and Fire TV devices.

**TetoTV-v2.0.76-native-playback-sources.zip** contains developer and license material, not an app installer. **SHA256SUMS** lists integrity hashes.

## Verification and channel

- Beta only, Android build code **410053**. No Public APK is being published.
- No repository, provider, catalog, or media content is bundled or recommended by this update.
- AI tools assisted with implementation, testing, and documentation. The project owner remains responsible for the release.

<!-- tetotv-android-version-code: 410053 -->
