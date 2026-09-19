# Experimental Aniyomi compatibility runtime

This is a **runnable, deliberately limited compatibility layer**, not a complete
Aniyomi application and not a claim that arbitrary extension APKs will work.
No third-party content provider, source index or extension APK is bundled here.
Existing Seanime source execution is not replaced.

## Provenance and licenses

The real interfaces, model implementations, HTTP source implementations,
Jsoup parsers, RxJava/coroutine bridge and selected HTTP helpers come from
[Aniyomi v0.18.1.2](https://github.com/aniyomiorg/aniyomi/tree/39e9a749590b89b432f04b83725aaa12591371b2),
commit `39e9a749590b89b432f04b83725aaa12591371b2`.
The annotated tag is `ab99c202602958d66a8f9c05f2fe31d168cf4d1a`.
On 2026-09-05, GitHub's tag API reported a valid verified signature pointing to
that commit. This is not a claim of independent local GPG verification.
`PROVENANCE.json` records the upstream path and Git blob ID of every imported
Aniyomi file. The upstream root had no NOTICE file at this commit.

Aniyomi, Tachiyomi and Mihon contributors retain ownership of their work.
`LICENSE-ANIYOMI` contains the upstream Apache License 2.0. File-specific
upstream comments have been retained. The Android-only and broker adaptations
are TetoTV modifications, described below and marked in modified source files.

The two small patched Injekt registry files come from
[mihonapp/injekt](https://github.com/mihonapp/injekt/tree/91edab2317f605afcee2df94f59a49883fd5cdd0),
commit `91edab2317f605afcee2df94f59a49883fd5cdd0`. Their MIT license, including
Jayson Minard and Collokia copyright notice, is retained in `LICENSE-INJEKT`.
The registry source is used with Maven Central's `injekt-core:1.16.1`, the same
core version specified by that upstream patch. JitPack is not needed.

The official `extensions-lib` compile-only stubs are **not** packaged as the
runtime. The implementation bodies in this module come from full Aniyomi
`source-api`/`core/common`, plus explicit TetoTV host adaptations.

## Implemented subset and modifications

- Anime APIs `14` and `16`: source/factory enumeration, default-filter search,
  details, episodes, legacy direct videos, and API-16 episode -> hoster -> video
  resolution, retaining legacy Video constructors and current model bridges.
- Manga API `1.4`/`1.5`: enumeration, default-filter search, details, chapters,
  pages and deferred image-URL resolution. The historical `Source` JVM interface
  is retained alongside Aniyomi's renamed `MangaSource`.
- Actual model creation, RxJava 1 observables, suspend bridges, source ID
  generation, requests, `HttpSource`, `AnimeHttpSource`, and parsed source
  implementations are compiled into the application. Old `DefaultImpls` bridge
  classes and extension-facing symbols are retained for dynamic DEX consumers.
- Injekt `FullTypeReference` subclasses outside the Injekt package also retain
  their generic signatures. R8 full mode otherwise strips the anonymous
  registration subclasses' type arguments, failing runtime setup before any
  provider class is loaded. This contract is checked in a minified Android
  fixture run, not only unminified JVM tests.
- KMP expect/actual wrappers and Compose marker annotations were removed for
  this Android library. Current preference helpers receive a base-less
  `Application` that implements only bounded, invocation-local in-memory
  `SharedPreferences`; it exposes no real Context, files, package APIs or
  services, and nothing persists after the disposable worker ends.
- Full-app NetworkHelper is replaced by a no-real-Context, no-disk helper. Its
  terminal transport sends only bounded HTTPS GET/POST JSON requests to an
  injected broker. The only Application registered in Injekt is the base-less
  preference capability. No real Context or private app service is registered.
  Host response cookies are scoped to an approved extension and cleared on
  disable/revocation; durable provider credentials and direct cookie access are
  unavailable.
- Provider application interceptors execute against a synthetic OkHttp 5.4
  chain. Timeout overrides and inert request metadata are supported, while DNS,
  proxy, TLS, cookie-jar, cache, socket and other transport mutations fail with
  a fixed unsupported-capability error before the broker is invoked. Subset 9
  also executes network-interceptor request/response callbacks in that isolated
  synthetic chain, after application callbacks, for newer rate-limit helpers.
  They cannot access a connection, change scheme/host/port, or proceed more or
  less than once (including through timeout copies). They never run in the host's
  real HTTP client. WebSocket calls and direct transport remain unavailable. The
  terminal interceptor reads redirect preferences from OkHttp 5.4's real call
  and sends only two booleans to the broker. Removing the broker gives no
  privileged fallback: the isolated worker UID has no network permission.
- Broker failures include a closed, privacy-safe reason enum to distinguish
  client configuration, forbidden credentials, request limits, and unsupported
  callback operations. The host and Flutter independently validate these markers;
  no request URL, header value, query, token or arbitrary exception is included.
- Non-HTTPS playback/page/track URLs and native MPV/FFmpeg commands are rejected.
  The exact advisory demuxer hints `demuxer-lavf-o=force_mpegts=1` and
  `force_mpegts=1` are discarded without discarding an otherwise valid video.
  They are never forwarded to any player; combined/unknown options still fail
  closed. No source-specific exception grants native execution.
  Video extraction returns bounded parser order and API-16 sort hooks are
  honored. Provider preference UI and durable preference state are not supported.
  Only a small playback-header allowlist crosses the JSON boundary. The trusted
  host must independently validate returned hosts/grants/public DNS before any
  image or player consumes them. Syntactic HTTPS checks alone are not SSRF defense.

### Subset 9 storage and packaged resources

Approved immutable APK snapshots live in private `noBackupFilesDir`, not
Android's update-evictable `codeCacheDir`. Existing cached snapshots are migrated
with a bounded copy and content-hash check, then the normal signature and full
approval-identity verification runs before execution. If Android already deleted
the snapshot, the app offers an explicit reinstall and trust prompt; it never
silently downloads, upgrades, approves a new signer, or downgrades a version.

The isolated in-memory DEX loader exposes only `assets/` and `res/raw/` resources
from the same verified APK through read-only in-memory URLs. This supports
extension-bundled localization helpers used by search filters. No host resources,
filesystem paths, or network URL handlers are supplied. Names, duplicates, entry
count (256), entry size (1 MiB), and aggregate size (8 MiB) are bounded. The
Android fixture harness exercises the actual DEX resource lookup and approved
snapshot migration as well as private-file/direct-socket denial.

WebView/Cloudflare challenges, extension-supplied native libraries, native
player commands, arbitrary custom sockets, raw loopback/local HTTP services,
durable authenticated sessions, torrents and FFmpeg/TorrServer helpers are not
supported. References to unavailable capabilities fail visibly in the isolated
worker. In particular, AniNeko's `ServerSocket` path and Anikoto's NanoHTTPD
playlist proxy cannot be made safe by allowing raw loopback; they require a
separate opaque, trusted host-proxy design.

The host supplies Cash App QuickJS Android 0.9.2 under the fixed
`app.cash.quickjs` ABI. It is built hermetically from the exact pinned upstream
source instead of the published 4 KiB-aligned AAR, with the same Java/JNI ABI
and 16 KiB-compatible ELF alignment. Aniyomi's `JavaScriptEngine` wrapper applies 256 KiB UTF-8
input/string-result limits, permits only primitive results, and creates a fresh
engine per evaluation. Extensions that call `QuickJs` directly bypass those
wrapper size/type limits. Such calls still run only in the one-shot isolated UID
and are stopped by the worker deadline/process teardown and Android memory
limits; they receive no host object, Context, file, WebView or network bridge.

## Dependency pins

| Component | Version | Notes |
| --- | --- | --- |
| RxJava 1 | 1.3.8 | Same as pinned Aniyomi |
| OkHttp | 5.4.0 | Current published Aniyomi host ABI; transport remains brokered |
| Okio | 3.17.0 | Resolved by OkHttp 5.4.0 and serialization Okio support |
| Jsoup | 1.19.1 | Same as pinned Aniyomi |
| Kotlin coroutines | 1.10.1 | Same as pinned Aniyomi |
| Kotlin serialization JSON/Okio | 1.9.0 | Same as pinned Aniyomi |
| Injekt core | 1.16.1 | Upstream patched-registry dependency |
| AndroidX preference KTX | 1.2.1 | ABI types plus bounded ephemeral preferences; no UI/disk |
| Cash App QuickJS Android | 0.9.2 source build | Host-owned JavaScript ABI in the disposable worker; 16 KiB ELF-aligned ARM32/ARM64 build from pinned source |
| Kotlin compiler/plugins | 2.3.20 | Host toolchain |

OkHttp 5.4 supplies current duration-mangled client methods used by published
extensions. The compatibility transport implements the expanded OkHttp 5 chain
surface fail-closed: harmless reads are inert, timeout changes are bounded and
forwarded, and authority-changing mutations are rejected. The legacy
response-first `parseAs(Json)` extension preserves the explicitly passed JSON
instance. Core networking/parser/model behavior is covered by offline fixtures;
broad binary compatibility is not asserted.

New dependency SHA-256 entries were generated through the module's scoped
Gradle resolution using the existing Google/Maven Central/plugin portal
repositories. Existing verification entries were preserved, and the module was
then rebuilt/tested with strict dependency verification. Repository provenance
and content hashes are not a complete dependency security review.

## Worker contract and verification

`AniyomiCompatRuntime.execute(loader, descriptor, request, broker)` runs only in
the disposable isolated process. The native host owns APK signature/hash checks,
read-only DEX loading, grants, broker DNS/redirect rules, hard timeout, process
termination and response-size limits. The runtime itself bounds entrypoints,
source count, result count and broker payload size, and clears Injekt afterwards.

Descriptor keys: `kind`, `apiVersion`, `classNames`. Request keys: `operation`,
`sourceId` (required for a multi-source factory), `query`, `page`, `url`, `title`,
and optional bounded `targetEpisode`/`targetSeason` selectors for large episode
lists.
Operations are `sources`, `search`, `details`, `episodes`/`chapters`, `pages`,
`videos`; requests and results are plain JSON, never provider objects.

Failures retain only a fixed broad error code, stage, and cause category.
Reflection constructor/static-initializer wrappers are unwrapped with a bounded
depth so missing ABI and unsupported-capability failures remain distinguishable.
Provider exception messages, class names, paths, URLs and stacks are not sent
over IPC; the host independently allowlists every diagnostic field.

| Operation | Result root |
| --- | --- |
| sources | `sources: [{id,name,lang,kind,baseUrl,supportsLatest}]` |
| search | `items: [{url,title,thumbnailUrl?,description?,author?,artist?,genre?,status}], hasNextPage` |
| details | `item: {url,title,...}` |
| episodes / chapters | `chapters: [{url,name,number,dateUpload,scanlator?}]` |
| pages | `pages: [{index,url,headers}]` |
| videos | `videos: [{url,quality,headers,subtitleTracks:[{url,lang}],audioTracks:[{url,lang}]}]` |

The focused compatibility suite covers source factories, stable ID transfer,
legacy and current model/constructor symbols, API-14 and API-16 video flows,
Rx/coroutine parsing, deferred manga image URL/header resolution, bounded
ephemeral preferences, fixed operation diagnostics, result limits, OkHttp 5
interceptor/redirect contracts, and bounded `JavaScriptEngine` evaluation. All
executable fixtures are first-party synthetic examples on `.example.test`.
These JVM tests do not prove Android UID isolation or arbitrary third-party APK
compatibility. The separate Android fixture exercises dynamic DEX loading and a
direct `QuickJs` call in the isolated process.

On 2026-09-05, a separately authorized exact AnimeGG 14.2 APK was statically
verified and tested for **source discovery only** in a disposable isolated UID.
Its debug discovery passed; a minified build failed at runtime setup because of
the stripped Injekt generic signature; retaining that signature made minified
discovery pass. No third-party APK is included in the app, fixtures, repository
or assets. This narrow test does not establish search/video functionality or
support for arbitrary extensions or capabilities outside the subset above.
