# First-party Aniyomi isolation fixture

These are generated test providers, not downloads from an extension repository. They are not installed as Android applications. Their signed APK bytes are imported into TetoTV's private, non-backed-up snapshot storage, explicitly approved by the test, then loaded only in the disposable isolated service. Generated APKs are ignored by Git and are assets of the separate `androidTest` APK only; neither fixture classes nor fixture APKs belong in the normal debug/release app.

Preparation (from the repository's `android` directory):

```powershell
.\gradlew.bat :aniyomi-compat:testDebugUnitTest
& .\app\src\androidTest\fixtures\build-fixtures.ps1
.\gradlew.bat :app:testDebugUnitTest --tests 'dev.animetv.anime_tv.aniyomi.*'
.\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest
```

The generator uses the already-verified compatibility dependencies, the SDK's Java/DEX/manifest/signing tools, and the local Android **debug** keystore. It never accesses the release keystore or downloads provider code. Android SDK build-tools 36.0.0's older D8 can warn about Kotlin 2.3 metadata on the fixture classes; bytecode loading is independently checked on the device. The normal app uses its Gradle-managed toolchain.

On a disposable API-26-or-newer AVD (the checked configuration is TV API 36, x86_64, 16 KiB pages), install the generated normal debug APK and the separate `app-debug-androidTest.apk`, then run:

```powershell
adb -s emulator-5554 shell am instrument -w dev.animetv.anime_tv.test/dev.animetv.anime_tv.aniyomi.AniyomiIsolationInstrumentation
```

The harness checks actual APK certificate/content-hash inspection, rejection of an unsigned APK, explicit approval, anime/manga DTO operations through Binder and dynamically loaded fixture DEX, isolation from a host-private non-secret sentinel, and direct-socket permission denial. It directly calls the host-owned Cash App QuickJS 0.9.2 ABI from fixture DEX and verifies evaluation inside the disposable worker. A single parsed-source smoke request is brokered to the public `https://example.com` page, with no credentials or cookies. It also exercises noncooperative-worker cancellation, the 30-second hard deadline, successful fresh-worker recovery, and developer-mode revocation (including denial without relying on a cached prior allow).

The expected terminal text is `ALL CHECKS PASSED`; check that text rather than relying only on `adb`'s exit code. A complete run takes approximately 40 seconds because it deliberately waits for the hard deadline. It proves these first-party fixtures and this device configuration, **not** universal Aniyomi extension compatibility, existing third-party providers, OEM variants, or every Android API level.

The harness also checks fixed ABI/capability error stage/cause transport without
provider exception text, and local P-256 key generation/ECDH through the native
phone-setup bridge. The crypto check makes no setup-session POST and emits no
key material.

Subset 9 also checks resource-backed search using UTF-8 properties inside the
fixture APK, safe omission of advisory video-format hints, and migration of an
approved fixture snapshot from the legacy code cache to durable private storage.
The public broker smoke traverses application and network callbacks from fixture
DEX, verifies their ordering and absence of a real network connection, then uses
the same trusted HTTPS broker.
It removes only that fixture's old cache file and reopens the approved snapshot
through a fresh store, preserving the actual signer/content-hash checks.

An opt-in `authorizedAnikotoCurrent=true` check uses the existing split
`authorizedAnikotoPayload` / `authorizedAnikotoPayloadPart2` arguments for only
the separately supplied 89,071-byte Anikoto 16.8 APK, SHA-256
`dabc93fa80b03c38cdf5adf0f9cd1b7ce5e9cbb15f282d0b6d815a061474117b`.
It retains the existing Yuzono certificate/package/source pins and checks the
exact One Piece title, episode 1, and nonempty extracted HTTPS videos without
playing/downloading media. Like other live checks it can fail for external
provider/network reasons; it is not a universal compatibility guarantee.

Run this harness against a **non-debuggable, minified** debug-signed test app as well as ordinary
debug. `debuggable=true` suppresses release-mode R8 optimization and renaming,
even with minification enabled, and therefore misses independently obfuscated
host/provider class-name collisions. Generic Injekt registration signatures are reflection contracts outside
the main API package: unminified tests cannot detect their removal by R8. The
2026-09-05 diagnostic run used a temporary Gradle init script to set only the
debug build type's `minifyEnabled=true`, `debuggable=false` and reuse release ProGuard files; the release
variant and signing settings were not modified.

Fixture providers use the independent `tetotv.fixture` namespace. They must not
live under the reserved host compatibility/broker namespace: the DEX loader's
filtering parent keeps platform/shared API types canonical and refuses APK
shadow copies, while unrelated helpers resolve from the APK rather than app R8
names. The isolated Android UID remains the capability/security boundary.
Different provider-bundled versions of shared libraries (including AndroidX)
are unsupported; this test does not promise arbitrary library compatibility.
Direct extension calls to `QuickJs` bypass the host `JavaScriptEngine` wrapper's
256 KiB input/result bounds. They remain confined by the disposable worker's
hard deadline/process teardown and Android memory limits, but the fixture is not
evidence of an in-engine memory quota.

There is a separate explicit `authorizedAnimeGG=true` diagnostic mode, never
enabled by ordinary fixture runs. It reads only
`targetContext.cacheDir/authorized-animegg-14.2.apk` and requires the exact
previously authorized APK SHA-256
`18cfab3cf1ba29a41a2fb72a6f34b0b00222fcf98ef2ab36bc37a5ac5c32a4e0`, certificate
`cbec121aa82ebb02aaa73806992e0368a97d47b5451ed6524816d03084c45905`, and package
`eu.kanade.tachiyomi.animeextension.en.animegg`. It approves that identity only
for isolated source enumeration, makes no content requests, and revokes the
approval afterward. The APK must be supplied separately with explicit
authorization: no download logic or third-party bytes are bundled in the harness.
For a non-debuggable diagnostic build without `run-as`, a separate optional
`authorizedAnimeGGPayload` instrumentation argument accepts base64 bytes of only
that exact 27,278-byte APK, checks its hash before import, and still performs the
host's actual APK/signature verification. It is test-only and requires the
explicit `authorizedAnimeGG=true` opt-in; no production channel supports it.
The additional `authorizedAnimeGGStreams=true` option searches for the exact
`One Piece` title, validates details, selects numeric episode 1, and extracts
nonempty video rows without opening the returned media URLs. Its output is
limited to stage/count results and fixed response-size buckets when available;
it does not require a particular upstream page size. Discovery-only remains
the default. The temporary AnimeGG APK is deleted and approval revoked on
success or failure.

The separate `authorizedKickAssAnime=true` mode accepts only the separately
authorized 84,701-byte KickAssAnime 14.61 APK (SHA-256
`30e73885f6dca68c074523f913393399936ca5bd8152b66858d0fc0b083e03d3`, the same
certificate above, and package
`eu.kanade.tachiyomi.animeextension.en.kickassanime`). Supply it as
`targetContext.cacheDir/authorized-kickassanime-14.61.apk`, or through the bounded
`authorizedKickAssAnimePayload` base64 argument. This mode verifies actual APK
inspection and isolated source enumeration, then makes one public multiword
`One Piece` search through the trusted HTTP broker. It requires nonempty results,
requests no episodes or videos, and revokes approval and deletes the temporary
APK on exit. It is opt-in and not part of the deterministic offline fixtures;
provider/network availability can fail this smoke test independently of the
runtime. No third-party APK is bundled with the harness or normal app.
An additional explicit `authorizedKickAssAnimeStreams=true` option continues
from the exact `One Piece` title through details, targeted episode 1 lookup,
and video extraction. It reports only stage/count results, does not open the
returned media URLs or play/download media, and retains the same revoke/delete
cleanup. Ordinary KAA mode remains search-only.
