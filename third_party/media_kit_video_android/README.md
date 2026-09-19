# Scoped Android video surface compatibility

The five Android Java files from media_kit_video **2.0.1** are vendored here;
only `VideoOutput.java` is modified. Their MIT notices and LICENSE are retained;
the pub cache is never edited. Gradle checks the exact original Java file set
and each file's SHA-256 before compiling the override. The five pins live in
`android/build.gradle.kts`; any upstream changes require manual review.

The only upstream change selects `FireTvSurfaceProducer` on Amazon AFTKRT,
Android API 30. A customer ANR from 2.0.75 shows the main thread stuck in
`ImageReader.nativeImageSetup` / Flutter `ImageReaderSurfaceProducer` after
memory-pressure callbacks. The adapter uses Flutter's public SurfaceTexture
registration API, avoiding that ImageReader acquisition path. It does not
force a player preference, change decoding, change native binaries, or change
other devices. It is a targeted mitigation, not proof that all device reboots
are fixed. Real Fire OS playback/background/resume testing remains necessary.

The separate Android instrumentation APK exercises allocation, resize, frame
drawing, and repeated disposal. It and its synthetic media are not packaged in
release builds. Review or remove this override when upgrading media_kit_video.
