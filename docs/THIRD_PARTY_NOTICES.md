# Third-party notices

TetoTV's MPV Android player and supporting application components use
the following third-party components:

| Component | Use in TetoTV | Upstream license |
| --- | --- | --- |
| Google Material Icons | Rounded/outlined vector glyphs used by the Flutter player and TV interface | Apache License 2.0 |
| `media_kit`, `media_kit_video`, and `media_kit_libs_android_video` | MPV compatibility player and Flutter integration | MIT License for the media_kit projects; bundled native components retain their own licenses |
| mpv, FFmpeg, and libass | Compatibility decoding and styled ASS subtitle rendering inside the media_kit Android runtime | Their respective upstream licenses apply; the exact v1.1.7 binary provenance and conservative GPL/LGPL license set are recorded in `NATIVE_PLAYBACK_REDISTRIBUTION.md` |
| libtorrent4j 2.1.0-38, libtorrent-rasterbar, Boost, OpenSSL, libdatachannel, libjuice, usrsctp, libsrtp, and plog | Opt-in direct peer-to-peer torrent transport and verified piece delivery to the app-owned loopback Range bridge | libtorrent4j MIT; libtorrent-rasterbar BSD-3-Clause; Boost Software License 1.0; OpenSSL Apache License 2.0; libdatachannel and libjuice MPL-2.0; usrsctp and libsrtp BSD-style; plog MIT. Exact artifact, nested source, and license provenance is recorded in `DIRECT_TORRENT_STREAMING.md` and the bundled native notice. |
| Vendored `flutter_js` 0.8.7+tetotv.1 | Dart/Android bridge for the isolated add-on JavaScript runtime | MIT License; copyright 2019 Ábner Oliveira |
| Android JS Runtimes bridge 0.3.6 (locally reviewed) | Source-derived FFI bridge used by the in-tree Android QuickJS build | MIT License; copyright 2020 fast-development |
| QuickJS 2026-06-04 | JavaScript engine built from pinned official source inside the Android plugin | MIT License; copyright Fabrice Bellard and Charlie Gordon |
| Discord Social SDK 1.10.18369 | Optional, user-authorized Discord Rich Presence on Android | Discord Social SDK Terms; the open-source notices supplied with the SDK are bundled separately |
| CryptoJS 4.2.0 | Compatibility APIs in the bundled add-on runtime | MIT License |
| LinkeDOM 0.18.12 and its bundled dependencies | Isolated HTML parsing for installed add-ons | ISC License for LinkeDOM; bundled dependencies retain their MIT, ISC, BSD-2-Clause, and other notices |
| Sucrase 3.35.0 and its bundled dependencies | Offline TypeScript transformation for installed add-ons | MIT License for Sucrase; bundled dependencies retain their MIT, Apache-2.0, and other notices |
| Dart `xml` 6.6.1 | Bounded parsing of Plex Media Server XML responses | MIT License |
| Noto Sans Regular | Bundled subtitle font used by the MPV/libass compatibility player | SIL Open Font License 1.1; copyright 2018 The Noto Project Authors |

TetoTV's optional filler labels and per-series filler skipping read episode
metadata from the public Jikan REST API. Jikan is a network service rather than
code bundled in the APK; its server implementation is MIT licensed, while the
episode metadata it exposes originates from MyAnimeList and remains subject to
the applicable upstream service terms. TetoTV does not scrape Anime Filler
List or MyAnimeList directly.

Upstream projects and license sources:

- media_kit and its Android native-library package:
  <https://github.com/media-kit/media-kit>
- mpv: <https://github.com/mpv-player/mpv>
- FFmpeg: <https://ffmpeg.org/legal.html>
- libass: <https://github.com/libass/libass>
- libtorrent4j tag 2.1.0-38: <https://github.com/aldenml/libtorrent4j/tree/v2.1.0-38>
- libtorrent-rasterbar: <https://github.com/arvidn/libtorrent>
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
- Noto Sans: <https://github.com/notofonts/noto-fonts>
- Jikan REST API: <https://github.com/jikan-me/jikan-rest>

The exact resolved Dart package versions are recorded in `pubspec.lock`.
Native Android versions are declared in `android/app/build.gradle.kts`, plugin
Gradle metadata, and the resolved Gradle dependency graph. Copyright notices
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
as release evidence. Before using the one-APK GitHub asset policy, a qualified
reviewer must confirm that GitHub's tagged source archives and the durable
public source locations referenced by this repository satisfy every applicable
source obligation. Neither this summary nor the in-APK notice is, by itself, a
source-code offer.

The direct-torrent JNI artifacts are ordinary Maven dependencies rather than
part of the libmpv corresponding-source bundle. A distributor must separately
retain their Gradle verification hashes; the pinned libtorrent4j,
libtorrent-rasterbar, libdatachannel and nested dependency sources; the
Boost/OpenSSL inputs named in the upstream build; MPL-covered source
availability; and all applicable notices. See
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
