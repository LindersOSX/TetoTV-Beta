# SIMKL integration boundary

SIMKL is an optional first-class tracking provider under **Settings > Accounts
> Anime tracking**. A connected account can provide its public profile, anime
lists, list status, and watched-episode progress. TetoTV can update status and
progress from the same catalog and playback actions used by AniList and
MyAnimeList.

## Current sign-in flow

Current Android builds use SIMKL's official limited-input PIN flow. The
companion is only the source of public application capability metadata for a
standalone TV link:

1. `GET /health` must report `provider_device_flows.simkl: true` and a bounded
   public `provider_client_ids.simkl` value.
2. The app requests a short-lived code directly from
   `GET https://api.simkl.com/oauth/pin` and displays the official
   <https://simkl.com/pin> page.
3. The app polls
   `GET https://api.simkl.com/oauth/pin/{user_code}` only at SIMKL's returned
   interval until the user approves, the code expires, or linking is canceled.
4. SIMKL returns the access token directly to the app, which stores it in
   Android Keystore-backed secure storage.

`SIMKL_CLIENT_ID` is public OAuth application metadata, not a user API key or
secret. No SIMKL client secret, TetoTV callback, or companion-held access token
is involved in the normal standalone path. The legacy companion callback path
can remain available for older builds when an optional secret is configured,
but current builds do not require it.

Unified phone setup uses the same official PIN endpoints through its bound
browser session. In that path, the companion temporarily holds the returned
token in volatile link state until the already-bound browser claims it. The
browser places it in the setup bundle and encrypts the complete bundle for the
TV with the device's temporary public key. The companion transports the
encrypted envelope but cannot decrypt it. The device validates the SIMKL
credential before committing it to secure storage.

## Profile, list, and progress behavior

Authenticated SIMKL requests include the required `client_id`, `app-name`,
`app-version`, `User-Agent`, and bearer metadata. The integration supports:

- profile name, account information, and an allowlisted SIMKL avatar from
  `POST /users/settings`;
- one account-wide anime list load that TetoTV filters into its list buckets;
- exact watched-episode progress reads;
- watched-history writes from completed playback;
- list-status updates and removal from a SIMKL list; and
- the same profile/avatar identity in supported Watch Party surfaces.

Catalog-originated actions send the AniList or MyAnimeList identifier that
SIMKL accepts directly. String-valued external IDs remain explicitly typed and
are never reinterpreted as a canonical SIMKL integer. Items returned by SIMKL
retain their canonical SIMKL ID and validated slug. Their list cards expose a
visible **View on SIMKL** action so SIMKL-sourced metadata remains attributable
and traceable to the corresponding SIMKL page. Poster paths are restricted to
SIMKL's documented format and loaded through its recommended image-proxy form.

## Caching and rate limits

Opening Home or My List is a user-driven read, not a background timer poll. On
the first load for a verified SIMKL profile, TetoTV retrieves
`/sync/all-items/anime` once and then saves the bootstrap watermark from
`/sync/activities`. It keeps a persistent cache scoped by that non-secret
profile ID, filters the cached list locally for each TetoTV shelf/status, and
single-flights simultaneous Home/My List requests.

The persisted activity watermark prevents another `/sync/activities` check for
20 minutes, and a cache snapshot is never accepted after 90 days without a
successful refresh. When `anime.all` changes, TetoTV requests only the
`date_from` delta using the exact prior activity timestamp and merges it into
the cached anime list. When `anime.removed_from_list` changes, it additionally
diffs the cache against a compact `extended=simkl_ids_only` response so remote
removals cannot survive a partial merge. The account profile shares the same
account cache and is refetched only on the initial load, an explicit user
recheck, or a change to `settings.all`. Transient reads use bounded,
Retry-After-aware exponential backoff for at most five attempts; if the network
remains unavailable, a previously verified stale cache can keep the UI useful
without inventing newer data. Disconnect removes the exact account's cache and
clears its in-memory session; no token-derived cache key is persisted.

All default SIMKL clients share one serialized lane for POST operations, with
at least one second between starts. Mutating requests are not automatically
retried, which prevents a network timeout from duplicating a history write.
Rate-limit responses remain explicit so the UI or outbox can retry later under
the normal bounded tracking-sync policy.

## Deployment and release gate

Source support does not make the live integration available by itself. Before
enabling SIMKL for users, the operator must:

- register the TetoTV application in SIMKL's developer settings;
- obtain any SIMKL API or commercial-use approval required for the intended
  public distribution;
- configure the registered public ID as `SIMKL_CLIENT_ID` in the private
  companion environment;
- deploy the companion revision that advertises the PIN capability and setup
  schema; and
- verify direct TV linking, encrypted phone setup, profile/list reads, status
  changes, progress writes, activity-gated refresh, attribution links, privacy
  disclosures, and disconnect with a dedicated test account.

Until those steps pass, the companion must report SIMKL unavailable and the
app must not present a link action that cannot complete.

Official references: [API overview](https://api.simkl.org/),
[PIN authentication](https://api.simkl.org/api-reference/auth),
[watched progress](https://api.simkl.org/api-reference/simkl/get-watched),
[add to list](https://api.simkl.org/api-reference/simkl/add-to-list),
[remove from history](https://api.simkl.org/api-reference/simkl/remove-from-history),
[anime list buckets](https://api.simkl.org/api-reference/simkl/get-all-items),
[user settings](https://api.simkl.org/api-reference/simkl/get-user-settings),
[images](https://api.simkl.org/conventions/images), and
[API rules](https://api.simkl.org/api-rules).
