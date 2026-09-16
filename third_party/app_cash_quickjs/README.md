# Cash App QuickJS Android 0.9.2 source build

This directory contains the exact Java/JNI implementation required by
Aniyomi extensions that link against the historical `app.cash.quickjs` API.
TetoTV builds it locally instead of packaging the upstream Maven AAR because
the published 0.9.2 native libraries use 4 KiB ELF alignment and are not valid
on every Android device that uses 16 KiB memory pages.

## Immutable source

- Upstream repository: <https://github.com/cashapp/quickjs-java>
- Release version: `0.9.2`
- Embedded QuickJS engine version: `2021-03-27`
- Commit: `a738129cc4aa99206c00ae49e9c5b15cb58ad880`
- Commit tree: `6a560c8a1d1da88d2eaa8a9c0755ec677333518b`
- GitHub source archive SHA-256:
  `b54a2153690533afd0181fc1136ce989eb31e3c39bf2e852b2ff1adf4179d56f`
- Reviewed local inventory: `android/cash-quickjs-android/SOURCE_MANIFEST.sha256`

Use the full commit, not the repository's current `0.9.2` tag: the repository
was later renamed for Zipline and that tag now identifies a different release.

Only the wrapper license, three Android Java API/loader files, and the complete
native source directory needed by that release are vendored. The build is
hermetic: Gradle does not fetch source code or a QuickJS runtime binary.

## Reviewed adaptation

There is one source-level difference from the pinned commit:
`quickjs/common/native/Context.h` explicitly includes `<functional>`. The
header already uses `std::function`; older transitive headers happened to make
that declaration visible, while current NDK libc++ requires the direct include.
This is a compile-only portability correction and does not change behavior or
the Java/JNI ABI.

The local Android library:

- keeps the Java package and native library name `app.cash.quickjs`/`quickjs`;
- keeps the 0.9.2 Java 8 class shape and all eight JNI entry points;
- compiles the pinned native implementation with NDK r28c;
- links with 16 KiB common and maximum page sizes; and
- currently emits only the app's supported `armeabi-v7a` and `arm64-v8a`
  ABIs. It is not a general four-ABI replacement for the upstream AAR.

The internal module uses AndroidX Annotation 1.2.0 only while compiling the
vendored Java sources. Upstream 0.9.2 published 1.1.0 as an API dependency, but
TetoTV does not publish this module and does not package or expose the
compile-only annotation artifact. The intentional metadata difference does not
change annotation retention, Java descriptors, or extension runtime behavior.

`PROVENANCE.json` records the upstream and patched hashes. Run
`tool/android/verify_vendored_app_cash_quickjs.ps1` whenever this tree changes.
The Gradle `verifyVendoredQuickJs` task also rejects missing, unexpected, or
modified files before every module build.

## Licenses

The wrapper is Apache License 2.0; the complete upstream license is retained at
`upstream/LICENSE`. The embedded QuickJS engine retains its MIT license notices
in the source headers and the APK's bundled QuickJS license asset. Copyright
and license notices must remain with any redistribution.
