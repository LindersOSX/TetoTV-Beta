# Direct torrent streaming

Direct torrent streaming is an optional Android source path. It is disabled by
default and is used only after the viewer accepts the peer-IP, upload, storage,
and legal-use warning. A connected Debrid service remains preferred.

## Pinned engine and provenance

TetoTV resolves these Maven Central artifacts at version `2.1.0-38`:

| Artifact | SHA-256 |
| --- | --- |
| `org.libtorrent4j:libtorrent4j` | `bf8ebde8d9fc20af129f26f28c01d8cfd91d87b831b44dabbe0705d9dc910243` |
| `org.libtorrent4j:libtorrent4j-android-arm` | `46b417c525c35ebd45b225b4e002ab13629cffc1ec8d8290ece02a686491952b` |
| `org.libtorrent4j:libtorrent4j-android-arm64` | `d9ea7d3d82e7484e07260d063a73c8f9fe5778cc06299717eba49858a44045ef` |

Upstream tag `v2.1.0-38` resolves to libtorrent4j commit
`09ffd391d4ef12e668cc032bffcbab47d9e2d5cb`. Its libtorrent submodule is
`a01469c8d1f88dd83bed458ffccffab2727b9d2a`. The Android workflow uses NDK
r28c, Boost 1.89.0, and OpenSSL 3.5.2 and targets API 24 for both
`armeabi-v7a` and `arm64-v8a`. Gradle dependency verification pins the
downloaded POMs and JARs.

The libtorrent4j wrapper is MIT licensed. Its native build also incorporates
libtorrent-rasterbar (BSD-3-Clause), Boost (Boost Software License 1.0),
OpenSSL (Apache License 2.0), and WebTorrent support from libdatachannel
`6ab310b5887eab78cf0c0767a8ced2ebff8c7479` (MPL-2.0). The latter statically
includes the pinned libjuice, usrsctp, libsrtp, and plog revisions recorded in
`DIRECT_TORRENT_NATIVE_NOTICE.txt`. Retain all bundled notices and keep the
MPL-covered source available when redistributing the APK.

## Security and lifecycle boundary

- ARM64 reports the capability on 4 KiB and 16 KiB page-size devices. The
  pinned upstream ARM32 binary is 4 KiB-aligned, so ARM32 reports the
  capability only on a 4 KiB runtime and fails closed on larger page sizes.
- The app accepts a magnet only through its internal platform call. It is not
  returned to Flutter, persisted, or logged.
- MPV receives a `127.0.0.1` URL with a random 256-bit path. The bridge accepts
  only that exact path, GET/HEAD, and one standards-compliant byte range.
- Requested pieces are reprioritized on every range/seek and are served only
  after libtorrent verifies them.
- Multi-file torrents fail closed unless one video matches the requested
  episode or an explicit valid file index. Single-video torrents may use that
  sole video. The selected video is capped at 6 GiB and the app keeps at least
  256 MiB free.
- Closing or cancelling the playback lease removes the active torrent and
  alert listener, disables DHT and peer transports, pauses the process-lifetime
  engine, stops the foreground service, closes the loopback server, and deletes
  its cache. Normal cleanup deliberately does not call libtorrent4j's unsafe
  `SessionManager.stop()` path. If torrent removal cannot be confirmed, the
  engine is poisoned and cannot resume until the app process restarts. The same
  lease cleanup runs when Android removes the app task.

## Release checks

Before distributing a build, compile the Android app and run its JVM tests.
Build the universal APK, run Android SDK
`zipalign -c -P 16 -v 4 <apk>`, and inspect every ABI's
`libtorrent4j.so` program headers with NDK `llvm-readelf -l`. Do not claim
Android 15/16 16-KiB-page compatibility unless every LOAD segment and packaged
entry passes. Archive the resolved dependency graph, verification metadata,
upstream tag/submodule sources, MPL-covered corresponding source, and license
notices with the release evidence.
