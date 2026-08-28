# Real-Debrid integration

The app uses Real-Debrid's official open-source device OAuth flow. The TV
displays `https://real-debrid.com/device` as a QR code and a short user code.
Access token, refresh token, and user-bound client credentials are encrypted
with `flutter_secure_storage`.

TetoTV does not ask users to paste a Real-Debrid private API token. Existing
encrypted credentials from older private builds remain usable until the user
disconnects the account, but new connections use device OAuth only. Never ship
account tokens inside an APK or source file.

The OAuth client automatically refreshes an expiring access token when refresh
credentials are present. Disconnect removes all Real-Debrid credentials from
the device.

The player route also carries a Real-Debrid provider marker. URLs that were not
resolved by a supported debrid backend are rejected before MPV is created.

## Stream resolution

`RealDebridStreamResolver` performs:

1. display candidates from the configured `ReleaseSource` so the user can
   select Sub, Dub/Dual Audio, resolution, codec, size, and provider;
2. `POST /torrents/addMagnet`;
3. `GET /torrents/info/{id}`;
4. select an exact source-provided file index when supplied, or match the episode
   filename with `POST /torrents/selectFiles/{id}`;
5. immediately inspect the post-selection status;
6. if it is queued/downloading/not promptly ready, delete the torrent and try
   another release instead of waiting for a cloud download;
7. use the selected file link only when status is already `downloaded`;
8. `POST /unrestrict/link`;
9. pass the returned HTTPS URL directly to the player.

Real-Debrid no longer documents a separate instant-availability preflight.
Its supported file-selection call can briefly begin provider-side work, so
TetoTV is accurately described as **cached-preferred**, not zero-download:
it selects only the requested episode, checks immediately, and deletes any
miss instead of waiting. A cleanup failure stops failover and tells the user
to inspect the Real-Debrid dashboard. The undocumented endpoint is not used.

TetoTV ships without a torrent index, source repository, or preconfigured
Stremio add-on. A user may explicitly add a compatible HTTPS manifest in the
app. The adapter only accepts torrent `infoHash` results; Real-Debrid
credentials remain on the device and are never placed in an add-on URL. Use
only sources and content you are authorized to access.

The included `HostedReleaseSource` calls:

```text
GET {RELEASE_RESOLVER_BASE_URL}/v1/releases
  ?anilist_id=...
  &mal_id=...
  &title=...
  &episode=...
  &alternative_titles=Title%201%7CTitle%202
```

The resolver returns either an array or `{ "releases": [...] }`:

```json
{
  "releases": [
    {
      "info_hash": "hex-or-base32-hash",
      "magnet_uri": "magnet:?xt=urn:btih:...",
      "release_name": "Release name",
      "seeders": 12,
      "source_id": "user-configured-indexer",
      "is_batch": false
    }
  ]
}
```
