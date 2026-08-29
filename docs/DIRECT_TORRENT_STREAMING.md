# Direct torrent streaming

Direct torrent streaming is an optional Android source path. It is disabled by
default and is used only after the viewer accepts the peer-IP, upload, storage,
and legal-use warning. A connected Debrid service remains preferred.

## Pinned engine and provenance

TetoTV compiles the 2.1.0-38 wrapper and both Android JNI libraries from
source. The app module consumes the three JARs produced by
`tool/native/build_native_playback.sh`; it has no Maven JNI binary fallback.
Their exact output hashes are recorded in
`tool/release/native_playback_manifest.json` and the build's
`NATIVE_BUILD_PROVENANCE.json`.

The immutable build graph starts with libtorrent4j commit
`09ffd391d4ef12e668cc032bffcbab47d9e2d5cb` and libtorrent-rasterbar commit
`a01469c8d1f88dd83bed458ffccffab2727b9d2a`. Rasterbar unconditionally
compiles its separate `try_signal` gitlink at
`105cce59972f925a33aa6b1c3109e4cd3caf583d`; TetoTV pins and archives that
source explicitly because ordinary Git archives omit submodule contents. The
build uses hash-verified Android NDK r28c, Boost 1.89.0, and OpenSSL 3.5.2
archives and targets API 24 for `armeabi-v7a` and `arm64-v8a`.

The linked native graph is libtorrent4j (MIT), libtorrent-rasterbar and
`try_signal` (BSD-3-Clause), rasterbar's bundled Ed25519 implementation,
Boost (Boost Software License 1.0), OpenSSL (Apache-2.0), libdatachannel
`6ab310b5887eab78cf0c0767a8ced2ebff8c7479` and libjuice
`2de35247f0b15fa385406f3e2020d0e3d4d5cfcc` (MPL-2.0), usrsctp
`ebb18adac6501bad4501b1f6dccb67a1c85cc299` (BSD-style), and plog
`e21baecd4753f14da64ede979c5a19302618b752` (MIT). The build sets
`RTC_ENABLE_MEDIA=0`, so libsrtp and other media-only nested sources are not
linked. Retain the exact bundled notices, the NDK runtime/toolchain notices,
and the MPL-covered source snapshots when redistributing the APK.

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
entry passes. Archive the TetoTV-built input JAR hashes, final APK `.so`
hashes, build provenance, immutable source/submodule snapshots, MPL-covered
corresponding source, NDK notices, and component license notices with the
release evidence. Verification must reject a compiled gitlink such as
`try_signal` when its independent source snapshot or notice is absent.
