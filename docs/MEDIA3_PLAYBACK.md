# Built-in Android playback engines

MPV remains the default. On Android, choose **Settings → Playback → Default player → Media3 (Built in)** to use AndroidX Media3/ExoPlayer for the next playback session. Choose MPV again to switch back. Existing preferences are not migrated to an external player.

Android Playback settings also include **Media3 SurfaceView** (experimental, off by default). Off uses the existing TextureView video output. Enabling it selects Media3 as the default player and uses SurfaceView for the next playback session. Disabling it returns Media3 to TextureView without changing the selected player. A later explicit choice of MPV is respected; the rendering preference never changes MPV's output or decoder configuration.

SurfaceView uses native hierarchy composition beneath the shared Flutter HUD. It is an optional device-comparison setting, not a guarantee of higher FPS. Both modes retain the same controls, native captions, fit/zoom options, and screenshot API. Rendering mode does not change in the middle of an active playback session. Media3 scrubbing shows only the timestamp bubble, without scene thumbnails.

The SurfaceView option was checked on the Android TV API 36 emulator in both modes: playback, seeking, caption/audio selection, decoder changes, HUD input, view recreation, sizing, screenshots, and bounded playback end passed. Settings tests cover persistence, startup races, reset, automatic Media3 selection, and later explicit MPV selection. These checks do not establish an FPS improvement on the customer's physical TV.

Both engines use the existing TetoTV player screen and controls: resume, pause, seeking, episode switching, skip controls, speed, audio/CC selection, caption preferences, fit/zoom, Watch Party, tracking and Discord activity. Media3 renders video and native captions underneath that shared Flutter interface; Android's own player controls are disabled.

Plex/Jellyfin playback continues through the same server playback requests, audio/subtitle metadata and compatibility recovery. External subtitle tracks are registered together, retaining language and selection metadata. Media3 decoder preferences and outcomes do not overwrite MPV's saved per-series decoder preference or device-health history.

## Engine differences

- Manual audio and subtitle timing offsets remain MPV-only. Media3 1.11.0 cannot safely provide the same general-purpose timing controls; the UI explains this rather than presenting ineffective sliders.
- Media3 uses Android's available decoders. An unavailable software decoder is not a reason to discard working playback. Codec compatibility and performance still vary by device.
- Native Media3 text/bitmap subtitle rendering is not identical to MPV/libass, particularly for advanced ASS effects. TetoTV retains supported native cue styling and exposes its common caption appearance controls.
- Media3 diagnostics identify the actual engine and decoder, buffering and observed rendered/dropped-frame counters. Rendered frame counts are not presented as proof of physical display frame rate; unavailable metrics remain unknown.

## Implementation and tests

The Android implementation is in `android/app/src/main/kotlin/dev/animetv/anime_tv/player/`. The Dart adapter is `lib/features/player/application/media3_platform_player.dart`, with its surface and shared screen in `lib/features/player/presentation/`.

Regression coverage includes persisted default/selection, stale command/event isolation, first-frame readiness, subtitle batching and identity, MPV preference isolation, server failure classification, and sanitized diagnostics. `integration_test/media3_playback_test.dart` exercises the actual native engine on Android without initializing MPV. Hardware-specific playback quality still requires testing on the affected physical device.

Local verification on September 4, 2026: 2,547 Flutter tests passed (33 conditional tests skipped), 114 Android JVM tests passed, and Flutter analysis found no issues. The Android TV API 36 emulator integration test passed playback, pause/seek/speed, inline and batched language captions, audio/caption selection across software/hardware decoder changes, PNG capture, repeated opens and a bounded media end. These checks do not establish codec performance on every real TV.

AndroidX Media3 is pinned to 1.11.0 with strict dependency verification. Its Apache 2.0 notice is bundled in the APK's license registry and third-party notices. See [third-party notices](THIRD_PARTY_NOTICES.md).
