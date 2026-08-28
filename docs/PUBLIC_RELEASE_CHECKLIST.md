# Public-release checklist

This checklist treats TetoTV as a public product even when a build is shared
only with a private test group. Passing automated tests is necessary but is not
the same as legal, store, or codec certification.

## Release blockers

- Sign every APK with a unique protected release key. Reject debug keys at
  build time, keep at least two encrypted/offline backups, and never lose the
  signing identity used by installed sideload builds.
- Verify <https://tetotv-bot.wisp.uno/privacy> returns the current privacy
  disclosure without authentication, confirm `/health` advertises that exact
  URL and effective date, keep the in-app disclosure accessible by remote and
  touch, and provide a working public support/contact route.
- Choose and publish an explicit software license before exposing the source
  repository. APK distribution does not by itself grant permission to reuse
  TetoTV's source or branding.
- Verify Public and Beta update checks use anonymous GitHub requests to their
  fixed public repositories, send no token or shared Beta credential, prefer
  the `-universal.apk` asset, and download directly from its
  `browser_download_url`. Confirm the current app and Wispbyte companion expose
  no legacy update proxy, `/v1/app-updates/*` route, or update-specific secret.
  Users upgrading from builds older than Public 1.0.2 or Beta 2.0.5 may need to
  install one current signed APK manually before in-app updates work.
- Deploy exactly one Wispbyte bot process while phone-source pairing state is
  process-local, verify `/v1/source-pairings/health` advertises protocol 2, or
  move pairing/rate-limit state to an atomic shared TTL store before scaling.
- Confirm the Wispbyte bot can attach files in the server-side diagnostic
  channel, then exercise **Diagnostics > Send to support** and verify the app
  receives the same opaque reference shown in Discord. Never put the bot token,
  incident secret, or channel routing configuration in the APK.
- Obtain any required AniList authorization for a client that also integrates
  MAL, and confirm the current terms for every metadata, tracking, skip-time,
  and debrid service.
- Confirm that the intended Teto name/artwork use and monetization comply with
  the official character guidelines and obtain permission where required.
- Archive the exact third-party notices, native binary provenance, and
  GPL/LGPL source/relinking materials required for the release build. Run
  `powershell -ExecutionPolicy Bypass -File tool/release/verify_native_redistribution.ps1`
  before building, then run it with `-StageBundle` and retain the generated
  native source bundle as release evidence. Review every reported upstream
  provenance limit before approving distribution. A qualified release reviewer
  must confirm that the tagged repository archive and linked public source
  locations satisfy the exact binary's source obligations; if they do not, the
  three-asset GitHub release contract is a release blocker.
- Run
  `powershell -ExecutionPolicy Bypass -File tool/release/stage_third_party_notices.ps1 -StageBundle -RequireDiscordSdkBinary`
  from the release revision. Retain the generated notices ZIP with the release
  evidence; its verifier must pass against the staged ZIP. Complete notices
  required at runtime must remain available in the APK and tagged source.
- Obtain the Discord Social SDK only through an account authorized under
  Discord's current terms. Keep its pinned AAR in the ignored local build path
  or protected private build storage. Before publishing any branch or tag,
  confirm `git ls-files --error-unmatch android/app/libs/discord_partner_sdk.aar`
  fails and that the raw AAR is absent from the public checkout and source
  archives. Shipping the verified SDK integrated into the APK does not authorize
  distributing the standalone AAR through the source repository.
- Verify the three pinned libtorrent4j 2.1.0-38 Maven artifacts against Gradle
  verification metadata, retain the source tag/commit and libtorrent submodule
  revision listed in `DIRECT_TORRENT_STREAMING.md`, and bundle its MIT notice
  plus the complete libtorrent, Boost, OpenSSL, libdatachannel, libjuice,
  usrsctp, libsrtp, and plog notices. Make the pinned MPL-covered source
  available to APK recipients. Confirm the feature is off by default and its
  peer-IP/upload/cache warning still appears before use.
- Verify the vendored QuickJS 2026-06-04 archive and reviewed FFI bridge with
  `powershell -ExecutionPolicy Bypass -File tool/android/verify_vendored_quickjs.ps1`, then run the packaged runtime and
  infinite-loop interruption tests on a 16 KiB-page Android device. Do not
  reintroduce the legacy QuickJS 2021-03-27 JitPack AAR.
- Decide whether automatic/manual AniSkip lookups are enabled in the public
  product, and ensure the privacy disclosure and settings accurately describe
  when episode identifiers and durations are sent.
- Revoke any credential ever embedded in an older APK and remove compromised
  historical assets before making release history public.

## Privacy and store-declaration gate

- Compare the release revision and deployed companion service with
  `docs/PRIVACY.md` and `docs/STORE_DATA_SAFETY.md`. Treat the latter as a
  conservative engineering inventory, not as a completed Google Play form.
  Record the reviewer, APK digest, companion deployment revision, policy
  effective date, and date of this comparison in the release evidence.
- Verify the deployed `/privacy` page is the August 28, 2026 disclosure, is
  readable without an account, matches the in-app summary, and provides a
  working contact route for access/deletion questions. Do not claim a shorter
  retention period than the Wispbyte host, reverse proxy, Discord channels, or
  provider services actually enforce.
- Document the Wispbyte host and reverse proxy's real IP/request-log fields,
  rate-limit metadata, access controls, backup behavior, and deletion/retention
  schedule. Confirm the privacy policy names the relevant controller/processor
  relationships before accepting public setup, Watch Party, live-count, crash,
  or diagnostic traffic.
- Exercise unified phone setup end to end with a test AniList/MAL account, each
  supported debrid service, and Discord. Confirm provider-returned access,
  refresh, API, and client credentials are readable by the broker only during
  the transient handoff; are removed when the bound browser claims them or
  within one hour; are encrypted in the browser before submission; and never
  appear in URLs, browser persistent storage, application logs, crash reports,
  or diagnostics. Confirm the device private key remains local and nonsecret
  setup state expires within seven days.
- Confirm enabled installed extensions are the only extensions automatically
  health-probed, a missing or at-least-24-hour-old result can trigger a probe at
  startup, and only due extensions can be retried by the 24-hour in-app timer.
  Verify the probe uses neutral test queries and sends no account credential,
  watch history, or user search. If behavior differs, update the implementation
  or privacy disclosure before release.
- Test a Watch Party with two accounts. Verify the room discloses participant
  display names, avatars, and synchronized playback state only to people with
  the room capability; contains no source URL, debrid credential, or media
  server credential; and expires within six hours. Confirm the companion's
  ordinary IP/request metadata follows its documented retention schedule.
- Verify anonymous crash reporting is opt-in and manually send both a crash
  report and a diagnostic bundle. Confirm the report's exact fields, the
  restricted Discord destination, moderator access, retention/deletion
  procedure, and that no password, token, stream URL, or setup secret is
  included. Do not describe Discord-hosted reports as locally retained.
- Verify the aggregate live-count feature remains Beta-only, is disabled for
  Public and debug builds, is user-disableable in Beta, sends no stable user or
  device identifier, and expires a presence record after three minutes. Keep
  Public and Beta store/privacy declarations separate whenever their behavior
  differs.
- Reconcile every row in `docs/STORE_DATA_SAFETY.md` with the target store's
  current definitions of collection, sharing, optionality, encryption, and
  deletion. Do not infer that data is uncollected merely because it is optional,
  transient, encrypted after receipt, or sent to a user-selected service.

## Distribution modes

The GitHub/sideload build may keep the signed in-app updater and
`REQUEST_INSTALL_PACKAGES`. A Google Play build must remove that permission and
the direct APK installer, use Play-managed updates, complete and independently
review the Data safety form against `docs/STORE_DATA_SAFETY.md`, and link the
public privacy policy. Do not upload the sideload flavor to Google Play or
describe a GitHub/sideload declaration as Google Play approval.

The extension marketplace downloads user-selected JavaScript and runs it in a
bounded interpreter. A Play distribution must separately review or disable
that feature and prove that every remotely loaded extension and resulting
content complies with current Google Play dynamic-code, device/network-abuse,
content, and intellectual-property policies. Passing Android security tests is
not a Play policy approval.

The current GitHub APK also supports direct peer networking and companion
features whose policy, disclosure, and permission treatment may differ in a
store build. A Play-targeted flavor requires its own manifest, feature audit,
privacy verification, and store declaration; disabling only the updater is not
sufficient.

Choose a permanent application ID before the first store release. Changing
`dev.animetv.anime_tv` later creates a different Android app and breaks normal
in-place updates.

## Technical gate

1. Start from a reviewed, clean commit and explicitly stage files; never use a
   broad add that could include screenshots, keystores, or local configuration.
2. Run Flutter formatting, analysis, unit/widget/integration tests, broker
   syntax/self-tests, Android JVM tests, release lint, and Kotlin compilation.
3. Build exactly one public APK with the protected production signing key: the
   Universal APK containing `armeabi-v7a` and `arm64-v8a`. Keep x86_64 and
   separate per-ABI APKs test-only; do not upload them as release assets unless
   policy changes.
4. Verify package ID, version codes, signer identity, v2/v3 signatures,
   `zipalign -c -P 16 -v 4` output and every native ELF LOAD alignment,
   supported ABIs, min/target SDKs, manifest permissions,
   and absence of debug flags/secrets/default source URLs.
5. Install the universal APK on at least one phone and one TV; test first-run
   setup, D-pad/touch navigation, all pairing flows, source import, search,
   stream recovery, audio/subtitle selection, resume, tracking, and update
   download/install.
6. Install the same Universal APK on a 32-bit Fire TV, ARM64 Google
   TV/Chromecast, foldable phone portrait/landscape, and a 16-KiB-page Android
   device or emulator.
7. After all local checks pass, publish one normal completed release with
   exactly three custom assets: the verified Universal APK, the versioned
   native playback source ZIP, and `SHA256SUMS`. Do not attach per-ABI APKs or
   additional generated archives; GitHub supplies the tagged source ZIP and
   tarball automatically. Immediately download all three hosted assets, verify
   their exact sizes and SHA-256 digests, and rerun the payload verifier before
   announcing the release.

## Content/source policy

Release builds must contain no torrent index, default source repository,
preconfigured Stremio manifest, provider credential, or instructions that
promote an infringing source. Users must deliberately add compatible sources
they trust and are authorized to use. This design reduces risk but does not
guarantee immunity from copyright, trademark, service-terms, or platform
complaints.
