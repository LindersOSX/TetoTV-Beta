# Third-party notices

TetoTV's built-in Android players and supporting application components use
the following third-party components:

| Component | Use in TetoTV | Upstream license |
| --- | --- | --- |
| Aniyomi source API v0.18.1.2, adapted from commit `39e9a749590b89b432f04b83725aaa12591371b2` | Experimental Developer Mode anime/manga APK compatibility subset, executed only by the isolated Android worker | Apache License 2.0; complete terms and TetoTV adaptation notice in `assets/legal/aniyomi/` |
| Injekt core/API 1.16.1 and Mihon registry patch `91edab2317f605afcee2df94f59a49883fd5cdd0` | Compatibility dependency registry with restricted host bindings | MIT License; original copyright Jayson Minard and Collokia |
| RxJava 1.3.8 | Legacy reactive source ABI and execution | Apache License 2.0; the pinned upstream license includes Copyright 2012 Netflix, Inc. This version is not LGPL. |
| Jsoup 1.19.1 | Compatibility HTML parsing | MIT License; copyright Jonathan Hedley |
| OkHttp 5.4.0 and Okio 3.17.0 | Current Aniyomi HTTP ABI and bounded broker transport; authority-changing transport mutations remain rejected | Apache License 2.0 |
| Kotlin coroutines 1.10.1 and Kotlin serialization core/JSON/Okio 1.9.0 | Compatibility asynchronous source APIs and structured data | Apache License 2.0; original JetBrains NOTICE texts are retained with the full license assets |
| AndroidX Preference/Preference KTX 1.2.1 and Android apksig 9.0.1 | Preference ABI types, bounded invocation-local memory preferences, and APK signature inspection; durable provider preferences are unsupported | Apache License 2.0, as declared by the exact-version Google Maven POMs |
| Cash App QuickJS Android 0.9.2 (locally source-built) | Current Aniyomi `app.cash.quickjs` ABI, loaded only in the disposable isolated worker; rebuilt from the pinned release with 16 KiB ELF alignment | Apache License 2.0 wrapper; embedded QuickJS engine MIT License, copyright Fabrice Bellard and Charlie Gordon |
| Google Material Icons | Rounded/outlined vector glyphs used by the Flutter player and TV interface | Apache License 2.0 |
| AndroidX Media3 1.11.0 (ExoPlayer, HLS, DASH, UI and common components) | Default built-in Android playback engine sharing TetoTV's existing controls; MPV remains selectable as the compatibility engine | Apache License 2.0; Copyright The Android Open Source Project. License text: `assets/legal/native/ANDROIDX_MEDIA3_LICENSE.txt`; upstream source: https://github.com/androidx/media/tree/1.11.0 |
| `media_kit`, `media_kit_video`, and `media_kit_libs_android_video` | MPV compatibility player and Flutter integration | MIT License for the media_kit projects; bundled native components retain their own licenses |
| mpv, FFmpeg, libass, and their selected native dependencies | Compatibility decoding and styled ASS subtitle rendering, compiled by TetoTV from immutable source revisions | LGPL-3.0-or-later is used conservatively for the combined playback library; component MIT/ISC/BSD/Apache/FTL/LGPL notices and the exact build configuration are recorded in `NATIVE_PLAYBACK_REDISTRIBUTION.md` |
| libtorrent4j 2.1.0-38, libtorrent-rasterbar, `try_signal`, Boost, OpenSSL, libdatachannel, libjuice, usrsctp, and plog | Opt-in direct peer-to-peer torrent transport, compiled by TetoTV from source, and verified piece delivery to the app-owned loopback Range bridge | libtorrent4j MIT; rasterbar and `try_signal` BSD-3-Clause; Boost Software License 1.0; OpenSSL Apache-2.0; libdatachannel and libjuice MPL-2.0; usrsctp BSD-style; plog MIT. libsrtp is source-only and is not linked because media support is disabled. |
| Android NDK r25c and r28c runtime/toolchain components | Static zlib, C++ runtime, C++ ABI, unwind, libatomic, and compiler-runtime pieces incorporated by the source-built playback and torrent libraries | Complete Google NDK `NOTICE` and `NOTICE.toolchain` files are bundled; the included components retain their Apache-2.0-with-LLVM-exception, Bionic BSD, zlib, and other per-file terms |
| Vendored `flutter_js` 0.8.7+tetotv.1 | Dart/Android bridge for the isolated add-on JavaScript runtime | MIT License; copyright 2019 Ábner Oliveira |
| Android JS Runtimes bridge 0.3.6 (locally reviewed) | Source-derived FFI bridge used by the in-tree Android QuickJS build | MIT License; copyright 2020 fast-development |
| QuickJS 2026-06-04 | JavaScript engine built from pinned official source inside the Android plugin | MIT License; copyright Fabrice Bellard and Charlie Gordon |
| Discord Social SDK 1.10.18369 | Optional, user-authorized Discord Rich Presence on Android | Discord Social SDK Terms; the open-source notices supplied with the SDK are bundled separately |
| CryptoJS 4.2.0 | Compatibility APIs in the bundled add-on runtime | MIT License |
| LinkeDOM 0.18.12 and its bundled dependencies | Isolated HTML parsing for installed add-ons | ISC License for LinkeDOM; bundled dependencies retain their MIT, ISC, BSD-2-Clause, and other notices |
| Sucrase 3.35.0 and its bundled dependencies | Offline TypeScript transformation for installed add-ons | MIT License for Sucrase; bundled dependencies retain their MIT, Apache-2.0, and other notices |
| Dart `xml` 6.6.1 | Bounded parsing of Plex Media Server XML responses and previously saved OPDS 1.x feeds in the optional manga reader | MIT License |
| Dart `archive` 4.2.0 | Bounded CBZ/ZIP decoding for the optional manga reader | MIT License; copyright 2013-2021 Brendan Duncan. Compression implementations bundled by the package retain their separate notices. |
| Noto Sans Regular | Bundled subtitle font used by the MPV/libass compatibility player | SIL Open Font License 1.1; copyright 2018 The Noto Project Authors |
| Noto Sans Devanagari | Hindi UI fallback font; original unmodified variable font from google/fonts commit `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5` | SIL Open Font License 1.1; copyright 2022 The Noto Project Authors. License: `assets/fonts/NotoSansDevanagari-OFL.txt` |

The optional manga reader's new-source flow installs user-selected
Seanime-format JavaScript/TypeScript manga-provider extensions. It uses the
bounded QuickJS runtime, TypeScript transformation and compatibility components
listed above; executable providers are not data-only catalogs. No manga provider
or catalog is bundled. Previously saved OPDS/declarative catalogs and compatible
downloads remain supported through the existing parsers/decoder. User-installed
extension code and upstream services can have their own license/terms; this
component list does not license their media or establish their compatibility.

The separate experimental Aniyomi runtime contains adapted implementations,
not a bundled Aniyomi application or compile-only extension stubs. TetoTV's
changes replace privileged application/network helpers with a constrained
broker, retain the historical manga ABI, adapt the pinned source to OkHttp 5.4,
supply bounded ephemeral preferences and host-owned QuickJS, and reject durable
preferences and native-player arguments. No provider APK or repository is bundled. The runtime's supported
subset is not a claim that arbitrary third-party extensions are compatible.
Original source attribution, file provenance and the adaptation record remain
in `third_party/aniyomi_compat/`; APK-visible full license texts and dependency
notices are registered in the Flutter license page from `assets/legal/aniyomi/`.
That directory's `LICENSE_SOURCES.json` records immutable license source links
and exact-version artifact declarations; Gradle artifact hashes remain in
`android/gradle/verification-metadata.xml`. These component licenses do not grant
rights to independently installed providers or their media. Release review
still applies to the exact distributed build.

TetoTV's optional filler labels and per-series filler skipping read episode
metadata from the public Jikan REST API. Jikan is a network service rather than
code bundled in the APK; its server implementation is MIT licensed, while the
episode metadata it exposes originates from MyAnimeList and remains subject to
the applicable upstream service terms. TetoTV does not scrape Anime Filler
List or MyAnimeList directly.

Upstream projects and license sources:

- Aniyomi pinned source and Apache-2.0 license:
  <https://github.com/aniyomiorg/aniyomi/blob/39e9a749590b89b432f04b83725aaa12591371b2/LICENSE>
- Injekt registry patch MIT license:
  <https://github.com/mihonapp/injekt/blob/91edab2317f605afcee2df94f59a49883fd5cdd0/LICENSE>;
  core 1.16.1 declaration:
  <https://repo.maven.apache.org/maven2/uy/kohesive/injekt/injekt-core/1.16.1/injekt-core-1.16.1.pom>
- RxJava 1.3.8 Apache-2.0 license:
  <https://github.com/ReactiveX/RxJava/blob/7e3879abfb32eeebb38c970195a7f1e354eb1f82/LICENSE>
- Jsoup 1.19.1 MIT license:
  <https://github.com/jhy/jsoup/blob/5c4c09a5cbf1271ceeac32452cbc77d0795b81f9/LICENSE>
- Exact OkHttp, Okio, Kotlin and AndroidX/apksig license sources:
  [`assets/legal/aniyomi/LICENSE_SOURCES.json`](../assets/legal/aniyomi/LICENSE_SOURCES.json)
- Cash App QuickJS Java release commit used for Android 0.9.2:
  <https://github.com/cashapp/quickjs-java/tree/a738129cc4aa99206c00ae49e9c5b15cb58ad880>
- media_kit and its Android native-library package:
  <https://github.com/media-kit/media-kit>
- mpv: <https://github.com/mpv-player/mpv>
- FFmpeg: <https://ffmpeg.org/legal.html>
- libass: <https://github.com/libass/libass>
- libtorrent4j tag 2.1.0-38: <https://github.com/aldenml/libtorrent4j/tree/v2.1.0-38>
- libtorrent-rasterbar: <https://github.com/arvidn/libtorrent>
- try_signal: <https://github.com/arvidn/try_signal>
- Boost: <https://www.boost.org/users/license.html>
- OpenSSL: <https://www.openssl.org/source/license.html>
- libdatachannel: <https://github.com/paullouisageneau/libdatachannel>
- libjuice: <https://github.com/paullouisageneau/libjuice>
- usrsctp: <https://github.com/sctplab/usrsctp>
- libsrtp: <https://github.com/cisco/libsrtp>
- plog: <https://github.com/SergiusTheBest/plog>
- flutter_js: <https://github.com/abner/flutter_js>
- Android JS Runtimes bridge tag 0.3.6:
  <https://github.com/fast-development/android-js-runtimes/tree/0.3.6>
- QuickJS 2026-06-04: <https://bellard.org/quickjs/>
- Discord Social SDK: <https://discord.com/developers/docs/social-sdk/index.html>
- CryptoJS: <https://github.com/brix/crypto-js>
- LinkeDOM: <https://github.com/WebReflection/linkedom>
- Sucrase: <https://github.com/alangpierce/sucrase>
- Dart xml: <https://github.com/renggli/dart-xml>
- Dart archive: <https://github.com/brendan-duncan/archive/tree/4.2.0>
- Noto Sans: <https://github.com/notofonts/noto-fonts>
- Jikan REST API: <https://github.com/jikan-me/jikan-rest>

The exact resolved Dart package versions are recorded in `pubspec.lock`.
Native Android versions are declared in the immutable native manifest, the
TetoTV build script, Android Gradle metadata, and build provenance. Copyright notices
and complete license texts shipped by those dependencies remain applicable.
When redistributing an APK, retain those notices and comply with the source,
relinking, attribution, and other requirements that apply to the exact native
binaries in that build. This summary is not a replacement for the full license
texts.

The minified JavaScript bundles are produced with license comments removed, so
the separate license assets and the complete notices for every package actually
included by the bundler must ship with the APK. `tool/addon_runtime/package-lock.json`
is the dependency provenance record; `docs/DEPENDENCY_VERIFICATION.md` records
the native QuickJS source archive hash, reviewed bridge delta, and verification
procedure. The Android JS Runtimes and QuickJS MIT notices must remain bundled
with every redistributed APK.

The Flutter license page includes notices generated from resolved Dart and
Android packages. The APK also carries complete GPL 2.0, GPL 3.0, LGPL 2.1,
and LGPL 3.0 texts, the libmpv Android build's default-flavor MIT notice, and
the native playback notices and complete direct-torrent component license
texts under `assets/legal/native/`. Exact binary hashes, source revisions, rebuild and
relink instructions, and known evidence limits are in
[`NATIVE_PLAYBACK_REDISTRIBUTION.md`](NATIVE_PLAYBACK_REDISTRIBUTION.md).
A distributor must run the verifier and stage the corresponding-source bundle
as release evidence. The default release path requires a qualified reviewer to
confirm that GitHub's tagged source archives and the durable public source
locations referenced by this repository satisfy every applicable source
obligation. A prominently disclosed Beta-only exception can instead record
that independent native-license and corresponding-source review was deferred;
automated verification and an owner declaration do not establish compliance
or cure an incomplete source offer. Neither this summary nor the in-APK notice
is, by itself, a source-code offer.

The direct-torrent JNI artifacts are TetoTV source builds included in the same
native source/provenance bundle as the libmpv inputs. A distributor must retain
the pinned libtorrent4j, rasterbar, `try_signal`, libdatachannel and linked
nested dependency sources; the verified Boost/OpenSSL inputs; Android NDK
notices; MPL-covered source availability; and all applicable notices. See
[`DIRECT_TORRENT_STREAMING.md`](DIRECT_TORRENT_STREAMING.md).

## Kasane Teto name and artwork

TetoTV is an independent, unofficial application and is not endorsed by the
Kasane Teto rights holders. The launcher artwork, character name, and related
branding must be used in accordance with the official Kasane Teto character
guidelines: <https://kasaneteto.jp/guidelines/>.

Required character attribution retained by the app:

```text
重音テト © 線 / 小山乃舞世 / TWINDRILL
```

Those guidelines and any separate commercial-use permissions apply in
addition to the software licenses above. A distributor is responsible for
confirming that its particular release, artwork, territory, and monetization
model are permitted.
