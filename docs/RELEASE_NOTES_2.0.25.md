# TetoTV 2.0.25 Beta

This beta introduces an offline-viewing foundation and makes the TV player easier to use from a remote.

## What's new

- A persistent Download Manager shows the queue, progress, transfer speed, storage use, and pause, resume, retry, cancel, and delete actions.
- Whole seasons can be queued from a TV-friendly quality and source chooser. Automatic mode prefers the configured Debrid service, then falls back to compatible web sources; direct torrent downloads remain an explicit opt-in with a public-IP warning.
- Completed downloads use the normal source picker and MPV player, including watch progress and the usual episode controls.
- Downloaded show metadata and artwork remain available without a connection. AniList and MyAnimeList progress updates made offline are queued and retried later.
- The player HUD has clearer control groups and more room between transport, episode, and playback options. Playback Speed sits directly before Audio and supports 0.5x, 0.75x, 1x, 1.25x, 1.5x, 1.75x, and 2x.
- Supported trailers play inside TetoTV. An optional setting can hand a video to another installed player.
- Show detail pages can display compact transparent title artwork when it is available, while keeping the normal title as the fallback.
- Offline catalog fallback and saved artwork handling are stricter about trusted local files and public artwork URLs.

## Beta notes

- Offline downloads are new in this build. Availability depends on the selected source and provider.
- Whole-season discovery skips episodes already downloaded. Start it with an empty download queue and keep TetoTV open until the season finishes.
- Downloads that require private or short-lived source authorization may need to be selected again after an app restart.
- Web sources that depend on a separate caption file are not downloadable in this beta; choose a source with embedded or burned-in captions instead.
- External players do not provide TetoTV's Watch Party, skip, fallback, or progress controls while the other app is open.
- Transparent title artwork is not available for every show.

This is a Beta-channel build. It raises Android's build code to `410002`, so Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.
