# Built-in Android playback engines

Media3 is the default built-in player on Android. New installs and existing installs at the one-time 2.0.77 migration use AndroidX Media3/ExoPlayer with SurfaceView for the next playback session, even if a different engine or renderer was previously selected. After that migration, explicit choices remain unchanged. Choose **Settings → Playback → Default player** to switch engines. Existing preferences are never migrated to an external player.

Android Playback settings also include **Media3 SurfaceView**, which is on by default. Turning it off uses TextureView for the next Media3 session without changing the selected player. Turning it on selects Media3 and uses SurfaceView for the next playback session. A later explicit choice of MPV is respected; the rendering preference never changes MPV's output or decoder configuration.

SurfaceView uses native hierarchy composition beneath the shared Flutter HUD. TextureView remains available as a device-compatibility comparison; neither mode guarantees higher FPS on every device. Both modes retain the same controls, native captions, fit/zoom options, and screenshot API. Rendering mode does not change after a session's device compatibility choice is applied. Media3 scrubbing shows only the timestamp bubble, without scene thumbnails.

The Amazon Fire TV model `AFTKRT` has a targeted compatibility trial: when Media3 SurfaceView is selected, TetoTV identifies the device before opening the stream and uses TextureView for that session. The Flutter lookup is limited to two seconds; the native view creation boundary enforces the same exact manufacturer/model rule, even if that lookup times out. This trial is based on the viewer's reported green/corrupt 2160p HEVC output while the same stream rendered in MPV. It still needs physical validation on the affected TV. A rendered-frame counter does not establish correct colors, and the supplied torrent contains metadata, not playable media data. The report's BT.709/SDR color-transfer observations do not justify assuming HDR solely from a 2160p label.

The subsequent affected report confirms that TextureView was already active,
with API 30, `OMX.MTK.VIDEO.DECODER.HEVC`, native `video/hevc` at 3840x2160,
and no recorded codec error despite green output. The pinned
[Media3 1.11.0 factory](https://raw.githubusercontent.com/androidx/media/1.11.0/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/DefaultMediaCodecAdapterFactory.java)
uses asynchronous codec processing on Amazon TVs from API 28. TetoTV now
compares synchronous processing only for that exact manufacturer/model/API,
decoder and native format combination. Audio and all other combinations retain
Media3 defaults; this does not change the chosen engine, decoder, color space or
saved preferences. Actual adapter mode and compatibility selection are exported
as closed technical fields, not inferred from the device API or saved setting.
The same stream must still be retested on the physical AFTKRT; local tests and
rendered-frame counters cannot prove that the green output has been cured.

The SurfaceView option was checked on the Android TV API 36 emulator in both modes: playback, seeking, caption/audio selection, decoder changes, HUD input, view recreation, sizing, screenshots, and bounded playback end passed. Settings tests cover persistence, startup races, reset, automatic Media3 selection, and later explicit MPV selection. These checks do not establish an FPS improvement on the customer's physical TV.

Both engines use the existing TetoTV player screen and controls: resume, pause, seeking, episode switching, skip controls, speed, audio/CC selection, caption preferences, fit/zoom, Watch Party, tracking and Discord activity. Media3 renders video and native captions underneath that shared Flutter interface; Android's own player controls are disabled.

Plex/Jellyfin playback continues through the same server playback requests, audio/subtitle metadata and compatibility recovery. External subtitle tracks are registered together, retaining language and selection metadata. Media3 decoder preferences and outcomes do not overwrite MPV's saved per-series decoder preference or device-health history.

## Engine differences

- Manual audio and subtitle timing offsets remain MPV-only. Media3 1.11.0 cannot safely provide the same general-purpose timing controls; the UI explains this rather than presenting ineffective sliders.
- Media3 uses Android's available decoders. An unavailable software decoder is not a reason to discard working playback. Codec compatibility and performance still vary by device.
- Native Media3 text/bitmap subtitle rendering is not identical to MPV/libass, particularly for advanced ASS effects. TetoTV retains supported native cue styling and exposes its common caption appearance controls.
- Media3 diagnostics identify the actual engine, reviewed decoder identifiers, attached native surface type, Android SDK, buffering and observed rendered/dropped-frame counters. Audio underrun, audio sink and video codec error counters use the same field names across native and Dart boundaries. Unknown decoder names remain excluded by the privacy allowlist. Rendered frame counts are not presented as proof of physical display frame rate or correct color rendering; unavailable metrics remain unknown.

## Implementation and tests

The Android implementation is in `android/app/src/main/kotlin/dev/animetv/anime_tv/player/`. The Dart adapter is `lib/features/player/application/media3_platform_player.dart`, with its surface and shared screen in `lib/features/player/presentation/`.

Regression coverage includes persisted default/selection, stale command/event isolation, first-frame readiness, subtitle batching and identity, MPV preference isolation, server failure classification, and sanitized diagnostics. `integration_test/media3_playback_test.dart` exercises the actual native engine on Android without initializing MPV. Hardware-specific playback quality still requires testing on the affected physical device.

Player exit now bounds auxiliary pause, queued stop, checkpoint and platform-cleanup work, so a stalled command cannot prevent reaching native disposal. Media3 disposal still requires an authoritative native reply; missing creation/disposal acknowledgements fail after six seconds and leave the safe retry path available, rather than assuming ownership was released. Late replies cannot settle a newer attempt. Dart controller closure is started once and allowed a separate 500 ms best-effort window because a paused subscriber can delay stream closure even after native release succeeded. A closing indicator and fixed lifecycle stages distinguish command, native-release and post-release waits without exposing media or account data.

Local verification on September 4, 2026: 2,547 Flutter tests passed (33 conditional tests skipped), 114 Android JVM tests passed, and Flutter analysis found no issues. The Android TV API 36 emulator integration test passed playback, pause/seek/speed, inline and batched language captions, audio/caption selection across software/hardware decoder changes, PNG capture, repeated opens and a bounded media end. These checks do not establish codec performance on every real TV.

AndroidX Media3 is pinned to 1.11.0 with strict dependency verification. Its Apache 2.0 notice is bundled in the APK's license registry and third-party notices. See [third-party notices](THIRD_PARTY_NOTICES.md).
