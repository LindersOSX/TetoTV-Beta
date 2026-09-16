# Seanime + Aniyomi compatibility — implementation decision

Requested 2026-09-05. **Initial isolated, Developer Mode-only subset implemented;
not universal Aniyomi compatibility.** The user subsequently selected the
experimental one-app implementation and authorized a local APK build, but no
GitHub publishing or deployment. See `ANIYOMI_EXPERIMENT_CHECKPOINT.md` for actual
support, verification and remaining limits. The research comparison below is
retained as architectural background, not a claim that both options were built.

## Required outcome

Keep Seanime manga/video support and add Aniyomi-family manga and video sources
to TetoTV's existing player and reader. No bundled or recommended source repo.
Keep existing libraries, identities, downloads, language preferences, captions,
tracking and profile-bound asynchronous operations intact.

## Verified constraints

- Aniyomi extensions are executable Android packages, not Seanime JavaScript.
  Its upstream loader checks package features/metadata, API version, signatures
  and user trust before loading source classes. Simply allowing an APK repository
  through TetoTV's existing JSON parser cannot make its extensions work.
- The official `extensions-lib` dependency contains compile-only stubs, not a
  runnable provider host. Teto needs actual host implementations and ABI tests.
- The inspected Aniyomi snapshot is
  `4b5b90a3749b2c0504d4ffdd9416051d4730226c`. Its anime loader accepts 14.0 and
  16.0, with separate manga contracts. Compatibility must be declared by tested
  API versions; it must not follow a floating branch implicitly.
- Native provider code loaded in Teto's ordinary application process would
  share access to its private application data. A differently named process
  alone is not a different Android app identity.
- Android's `isolatedProcess` service has no permissions of its own. A protected
  in-app host would need brokered networking and provider-specific storage, not
  arbitrary access to Teto's accounts, files or platform bridge.
- Existing extensions can depend on customized OkHttp clients, application
  context/preferences, cookies/WebViews and local HTTP servers. Those behaviors
  are not automatically compatible with a permissionless worker. Runtime tests
  must establish what is supported, with clear errors for unsupported features.

## Product choice (option 1 selected)

1. **One Teto installation:** embed an isolated Android worker plus a narrow
   request broker. Preserves the one-app setup, but initial compatibility must
   be limited to verified source APIs/behaviors. Never fall back to loading
   failing extensions in Teto's privileged process.
2. **Separate on-device helper package:** a dedicated extension host owns its
   network access, cookies and preferences, while Teto receives validated
   metadata/pages/streams over authenticated IPC. No hosted server is required.
   This is a stronger practical separation from Teto's account storage for a
   broader Android host implementation, but adds an installation/update step.
   It still does not make untrusted extensions harmless or guarantee that every
   extension works. Do not create that extra app without the user's decision.

Do not silently replace these choices with unrestricted loading or a remote
server. Keep the existing native-repository rejection until a real, tested
runtime and explicit trust/install workflow are available.

## Implementation requirements

- Separate ecosystem identity, repository cache and install records; never
  treat an Aniyomi package as a Seanime payload or change Seanime ID semantics.
- Parse supported legacy/new repository formats with bounded sizes and strict
  URLs. Preserve package signing identity across updates; require explicit
  user trust and reject mismatched/unsupported packages before execution.
- Pin and review source API implementations, dependencies and license notices.
  A declared package API version is only a preflight check, not proof it runs.
- Adapter operations: source list, search, details, chapters/episodes, manga
  pages, video streams, relevant request headers and subtitle/audio metadata.
- Apply deadlines, cancellation, worker restart on faults, bounded IPC/results,
  profile/session checks and public-network validation. Do not forward Teto
  tracking/debrid/Discord credentials or accept arbitrary file/intent requests.
- Feed validated video results into the current resolver/HUD and manga results
  into current chapter/progress/download models. No replacement player/reader.
- Test Seanime regressions, cross-ecosystem identity collisions, signer changes,
  malformed/oversized results, expired sessions and worker crashes. Later,
  explicitly authorized APK/device tests must cover fixture extensions and
  verify the isolation boundary. Do not build an APK until the user asks.

## Evidence

- [Aniyomi anime loader](https://github.com/aniyomiorg/aniyomi/blob/4b5b90a3749b2c0504d4ffdd9416051d4730226c/app/src/main/java/eu/kanade/tachiyomi/extension/anime/util/AnimeExtensionLoader.kt)
- [Aniyomi source API module](https://github.com/aniyomiorg/aniyomi/tree/4b5b90a3749b2c0504d4ffdd9416051d4730226c/source-api)
- [Official compile-only extension library](https://github.com/aniyomiorg/extensions-lib)
- [Android isolated service behavior](https://developer.android.com/guide/topics/manifest/service-element#isolated)
- [Android dynamic-code-loading risks](https://developer.android.com/privacy-and-security/risks/dynamic-code-loading)

Local integration points inspected: `MarketplaceClient` and repository-format
rejection, `MarketplaceAddon`/`InstalledStreamingAddon`, `WebStreamAggregator`,
`MangaExtensionController`, Android manifest and Gradle dependencies. No runtime,
schema, UI, privacy declaration or release note was changed for this proposal.
