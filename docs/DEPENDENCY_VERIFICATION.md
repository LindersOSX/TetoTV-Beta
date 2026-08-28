# Dependency integrity and provenance

TetoTV's Android build fails closed when an external Gradle artifact changes.
The trust baseline is `android/gradle/verification-metadata.xml`; it records a
SHA-256 checksum for every resolved artifact and its Maven/Gradle metadata.
`android/gradle.properties` explicitly selects Gradle's `strict` verification
mode, and the Gradle 9.1.0 wrapper distribution itself is pinned by
`distributionSha256Sum`.

Checksums protect build integrity, not vulnerability status or publisher
identity. Most Maven Central and Google artifacts in the baseline were
bootstrapped by Gradle and still require normal dependency review. Critical
non-central binaries must be independently compared with their publisher's
repository before their checksum is accepted.

## QuickJS trust record

TetoTV builds its native engine from reviewed source in
`third_party/flutter_js/android/src/main/c`; it no longer downloads a QuickJS
AAR from JitPack. The engine is the official QuickJS `2026-06-04` release:

| Source | Immutable identity |
| --- | --- |
| Official archive | <https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz> |
| Archive SHA-256 | `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a` |
| `android-js-runtimes` bridge origin | tag `0.3.6`, commit `0f72f7409ff610b33b0e09bd9460213f0e487bf0` |
| Original bridge SHA-256 | `54b873706d077451d843ca564f511582479c3562438d34fdb883f3639a5ed047` |
| Reviewed local bridge SHA-256 | `8e1953548f72b5f68040421fa2919aeea2c755edb27a6fb001c4cfd66e71c03b` |

The local bridge keeps the `flutter_js` FFI ABI but replaces the obsolete
private `JS_IsPromise` call with QuickJS's public promise-state API, uses
monotonic execution deadlines around every bytecode entry point, frees its
runtime opaque allocation, and links native segments for 16 KiB Android page
sizes. CMake compiles the same reviewed source for ARM32, ARM64, x86, and
x86_64.

Run the provenance verifier whenever these files change:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tool\android\verify_vendored_quickjs.ps1
```

It downloads only the pinned official archive and immutable bridge revision,
checks their SHA-256 values, compares every compiled QuickJS file byte for
byte, verifies the reviewed local bridge hash, rejects unexpected native
source files, and compares the packaged MIT notices. A source update requires
reviewing the API delta and intentionally updating every affected checksum.

## Updating the verification baseline

Never accept a generated checksum merely because Gradle downloaded it. Review
the dependency/version change first, verify critical binaries through an
independent official path, and then run from `android/`:

```powershell
.\gradlew.bat --write-verification-metadata sha256 :app:dependencies
.\gradlew.bat --write-verification-metadata sha256 :app:processDebugResources
.\gradlew.bat --write-verification-metadata sha256 :flutter_js:assembleDebug
```

Review the XML diff. Unexpected coordinates, new repositories, duplicate
hashes for one artifact, permissive `trusted-artifacts` patterns, or an
unexplained `also-trust` entry require investigation. Do not disable metadata
verification to make a build pass.

Validate both debug execution-time tools and the release dependency graph:

```powershell
.\gradlew.bat --dependency-verification strict :app:processDebugResources
.\gradlew.bat --dependency-verification strict :app:compileDebugKotlin
.\gradlew.bat --dependency-verification strict :flutter_js:assembleDebug
.\gradlew.bat --dependency-verification strict :app:dependencies `
  --configuration releaseRuntimeClasspath
```

Run the normal Android unit tests, lint, and release build afterward because
some plugins resolve additional host tools only when their task executes.

## JavaScript runtime bundles

The add-on runtime bundles are generated from the exact `package-lock.json` in
`tool/addon_runtime` using `npm ci`; do not rebuild them with an unlocked npm
tree. The shipped top-level inputs are CryptoJS 4.2.0, LinkeDOM 0.18.12, and
Sucrase 3.35.0. Their compiled bundles also contain transitive packages, whose
notices must be preserved when redistributing the APK.

Executing user-installed add-on JavaScript is also a distribution-policy
question, separate from dependency integrity. The current sandbox and explicit
install flow reduce runtime risk, but a store reviewer may still classify
downloaded provider code as dynamic code. Obtain policy review for each target
store; a sideload build passing technical tests does not establish store
eligibility.
