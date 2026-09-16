# Manga asynchronous profile boundary — fix verification

Date: 2026-09-05. Outcome: **fixed** for the reproduced Dart application boundary.
This is a narrow correctness/privacy fix, not a repository-wide security audit
or a claim that all manga features are release-certified.

## Finding and compatibility contract

An action initiated under profile A could wait for a title lookup, local file
verification, saved-progress restoration or download retry lookup. If the active
profile changed to B during that await, some callers subsequently read the
current controller/resolver. They could combine A's selected title/request with
B's chapter sheet, progress owner or source resolution context.

The controlling inputs here are selected profile/source and asynchronous
completion order. No claim of an unauthenticated remote exploit was established.
The invariant is that one initiating action keeps its original controller,
owner and selected legacy source until admission; a changed identity makes that
action fail safely rather than rebinding it.

Existing behavior that must remain: ownerless completed downloads are shared on
the device and may be opened under any profile, with that opening profile's own
progress; already-admitted transfers continue across profile switches. Disabled
or missing extensions must not prevent reading verified local chapters.

## Patch strategy and changed files

Use repository-native captured bindings and validation callbacks, not a new
authentication scheme or a change to device-download ownership:

- `lib/features/manga/presentation/manga_screen.dart`: capture the originating
  hub/extension/source at entry, recheck after awaits, bind chapter callbacks and
  stop stale later batch admissions. Retained catalog requests reuse captured
  page-resource headers instead of consulting another selected source.
- `lib/features/manga/application/manga_hub_controller.dart`: reject an explicit
  mismatched reader owner; adopt ownerless local requests only through the
  initiating hub, restoring chapter-specific position and fractional offset.
- `lib/features/manga/application/manga_acquisition_controller.dart`: capture
  each action's resolver session synchronously, before awaiting initialization.
- `lib/features/manga/data/manga_acquisition_service.dart`: validate admission
  after job lookup and source resolution and immediately before a fresh retry.
- Regression tests in `test/manga_screen_test.dart`,
  `test/manga_hub_controller_test.dart`, and
  `test/manga_acquisition_service_test.dart`.

An independent pre-patch investigator traced the boundary. One fresh read-only
candidate review found the Retry/Resume late-resolver path; the parent confirmed
that path, corrected it and added the staged-await regressions. No second review
cycle or broader speculative security changes were made.

## Ordered verification

1. **Diff and type checks — pass.** Inspected bindings and callers, including
   legacy sources, local downloads and already-admitted transfers. `dart analyze`
   reports no issues; `git diff --check` reports no whitespace errors.
2. **Original trigger — pass after fix.** Before the fix, the test named
   `profile replacement during title lookup cannot open a stale chapter sheet`
   failed because the stale sheet appeared. It now passes: holding title lookup,
   replacing the controller and completing lookup opens no sheet and produces
   no uncaught widget exception.
3. **Alternate lifecycle triggers — pass.** Tests switch profiles during verified
   local lookup and saved-state restoration. Retry tests suspend `job lookup`
   and `resolver` separately, switch identity and release the wait: there is no
   new transport request or admitted operation. A new-download test similarly
   blocks admission after service initialization.
4. **Legitimate controls and package checks — pass.** Screen tests open a verified
   offline chapter with the extension disabled or absent without provider calls.
   Hub tests reject an explicitly different owner but allow ownerless device
   downloads to adopt the initiating profile. Existing acquisition queue,
   fresh-resolution retry, pause/resume and integrity tests still pass.
   `flutter test --reporter expanded` completed with **2,942 passed, 33 skipped,
   zero failures**. Log: `build/manga-final-app-tests.log`.

Other verification for the integrated work:

- `flutter test test/playback_performance_storage_test.dart
  test/manga_library_persistence_test.dart --reporter expanded`: **23 passed**.
  The initial whole-app run failed three stale expected-version-13 assertions;
  the checks now use the actual schema constant, retain data-preservation
  assertions and add upgrade-from-13 coverage. No migration logic was relaxed.
- `dart run tool/audit_ui_localization.dart`: **pass**, 3,552 keys including
  uppercase aliases; zero missing literal messages or raw Text literals.
- `gradlew.bat :app:testDebugUnitTest --tests
  dev.animetv.anime_tv.DiscordRichPresenceBridgeAbiTest --tests
  dev.animetv.anime_tv.DiscordMangaArtworkUrlPolicyTest --tests
  dev.animetv.anime_tv.MangaBackupDocumentCodecTest --tests
  dev.animetv.anime_tv.MangaBackupDocumentBridgeContractTest --console=plain`:
  **15 JVM tests passed**. This was a unit-test task, not APK assembly.

## Remaining uncertainty and skipped validation

The 33 suite skips are not passes. No physical phone, TV or foldable was
connected, and no live Discord or production tracker account was used. JVM ABI
reflection and source-contract tests do not prove native Discord image rendering
on a device. Later APK/device acceptance is still required for that feature.
The profile fix's tested enforcement is in Dart; it adds no native boundary.

The user explicitly prohibited local APK builds until asked. No APK was built,
uploaded or published for this pass; no bot was deployed and no shutdown ran.
All work remains local and uncommitted, preserving unrelated existing changes.
