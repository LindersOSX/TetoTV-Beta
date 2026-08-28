# TorBox streaming

TetoTV supports TorBox as a second debrid backend. TorBox playback does not
start the optional direct-torrent engine or connect the device to peers.

## Account setup

1. Open **Accounts & streaming** in TetoTV and choose **Connect by QR**.
2. Scan the TorBox QR code, confirm the six-digit code, and approve the TV.
3. The TV polls TorBox's device-token endpoint and validates the returned token
   with `GET /v1/api/user/me`.
4. The app stores the validated token with `flutter_secure_storage`.

Manual API-token entry remains available as a fallback.

TorBox currently requires a paid plan for third-party API streaming.

## Episode flow

1. A source explicitly configured by the user supplies release metadata and a
   magnet.
2. The user selects the exact Sub or Dub/Dual release.
3. TetoTV submits the magnet to `POST /v1/api/torrents/createtorrent` with
   `add_only_if_cached=true`, so an uncached release is rejected atomically.
4. It briefly checks `GET /v1/api/torrents/mylist` with `bypass_cache=true`
   only to obtain the already-cached files. Any stale cache result is deleted.
5. It preserves a source-provided file index when selecting the episode from a batch,
   with episode-name matching as a fallback.
6. It requests the temporary CDN stream from
   `GET /v1/api/torrents/requestdl`.
7. Only that TorBox-generated HTTPS URL is admitted to the MPV player.

The API token is never placed in project configuration or source control.
