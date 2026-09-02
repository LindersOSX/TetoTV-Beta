# SIMKL integration boundary

SIMKL account linking is visible under **Settings > Accounts > Anime
tracking**. It is capability-gated: the companion completes SIMKL's
confidential OAuth flow at
`/oauth/simkl/callback`, while the client secret remains only in the companion
environment. Its `/health` response reports `providers.simkl: true` and a
public `provider_client_ids.simkl` only when both server-side credentials are
present. The app accepts that capability only when the callback is the exact
same-origin `/oauth/simkl/callback` URL.

The app-side SIMKL API client implements the required `client_id`, `app-name`,
`app-version`, `User-Agent`, and Bearer metadata. It reads the account name and
avatar from `POST /users/settings`. All default client instances share one
app-wide, serialized one-request-per-second POST lane, and a failed history
write is never retried automatically.

History writes accept `SimklAnimeId`, a canonical SIMKL identifier type, rather
than the existing generic tracking `mediaId`. This is deliberate: current list
and playback models can carry AniList or MAL IDs in similarly named integer
fields, so treating one of those integers as a SIMKL ID could update the wrong
title. Account linking, encrypted token storage, disconnect, and profile
verification are enabled. SIMKL list reads and progress-outbox writes remain
disabled until a verified crosswalk persists a canonical SIMKL ID for each
title and carries that typed ID end to end.

Companion deployment prerequisites:

- Register `https://tetotv-bot.wisp.uno/oauth/simkl/callback` (or the exact
  callback under the configured `PUBLIC_BASE_URL`) in the SIMKL developer
  console.
- Set `SIMKL_CLIENT_ID` and `SIMKL_CLIENT_SECRET` only in the private companion
  environment.
- Confirm `/health` reports SIMKL ready before testing the Connect SIMKL row.

References: [authentication](https://api.simkl.org/authentication),
[OAuth](https://api.simkl.org/api-reference/oauth),
[headers](https://api.simkl.org/conventions/headers),
[rate limits](https://api.simkl.org/resources/rate-limits),
[sync](https://api.simkl.org/guides/sync), and
[user settings](https://api.simkl.org/api-reference/simkl/get-user-settings).
