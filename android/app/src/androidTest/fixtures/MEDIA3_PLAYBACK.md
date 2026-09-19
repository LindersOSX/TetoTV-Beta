# Media3 playback regression fixture

The files in `../assets/media3-fixture` are original synthetic test media,
not downloaded shows. They exist only in the separate instrumentation APK.
Generated with FFmpeg from a 320x180, 24-fps `testsrc2` pattern (four seconds),
H.264/yuv420p with a 24-frame GOP, and 440-Hz sine audio encoded as AAC.
The separate audio playlist uses a four-second 880-Hz AAC sine wave.
HLS segment duration is one second and both playlists are finite VOD.

The opt-in `media3Playback=true` instrumentation path opens the production
Media3 bridge using SurfaceView and TextureView, tests both HLS MIME aliases,
external HLS audio, seeks and repeated disposal. StrictMode forbids network I/O
on the UI thread. `media3PublicHttps=true` also plays the fixed public AndroidX
ExoPlayer sample hosted on storage.googleapis.com, exercising TLS cleanup.
No customer account, repository, extension or private URL is used.

It also checks the scoped Fire TV SurfaceTexture adapter against an attached
Flutter engine: allocation, drawing, resize and repeated release. This cannot
replace on-device Fire OS decoding, suspend/resume and memory-pressure tests.
