# TetoTV privacy disclosure

Effective date: August 28, 2026

The stable public copy is available without an account or authentication at
<https://tetotv-bot.wisp.uno/privacy>.

TetoTV is an independent Android application. It has no advertising SDK or
third-party analytics SDK. It has no TetoTV account system and does not sell personal data.
This disclosure describes the data handled by the app, user-installed source
extensions, the optional TetoTV pairing and Watch Party services, optional
Beta aggregate presence, and the optional crash and diagnostic receivers.

## Public and Beta builds

Public and Beta use the same account, source, playback, pairing, Watch Party,
and diagnostic features unless a release note says otherwise. They query
different public GitHub release repositories for updates. The material privacy
difference is the **anonymous aggregate live count**: it is available and
enabled by default in Beta, with an opt-out during setup and in Settings, and
is disabled in Public and debug/test builds. Anonymous crash reporting remains
off by default in both channels, and manually sending diagnostics always
requires a separate user action.

## Data kept on the device

TetoTV stores the following data locally:

- account and debrid credentials in Android Keystore-backed secure storage;
- an optional Jellyfin server address, username, access token, and random app
  device ID in Keystore-backed secure storage; the Jellyfin password is used
  only for sign-in and is not saved;
- an optional Plex server address, X-Plex-Token, and random client identifier
  in Keystore-backed secure storage;
- playback history, resume positions, per-series preferences, tracker-sync
  outbox entries, installed source definitions, and app preferences;
- saved offline episode files in app-private storage; downloaded public catalog
  and episode metadata; pinned cover and banner artwork; and durable download
  job state such as public media identifiers, episode and title labels, source
  and provider labels, quality/audio labels, transfer status and progress,
  retry/error state, and an app-private relative path. While a resumable HTTPS
  transfer is pending, its source address can also be retained. Download
  request headers, cookies, and account tokens are never persisted, and a
  direct-peer magnet and native capability remain only in process memory;
- short-lived catalog/artwork caches, a bounded rolling 48-hour history of
  redacted technical events, and up to twelve redacted native-crash or ANR
  summaries from that same window; and
- when Direct torrent is explicitly enabled for immediate playback, one
  temporary selected video of at most 6 GiB plus torrent state in the app
  cache; the session cache is deleted when playback closes or is cancelled,
  and stale session folders are pruned before the next direct session. This
  temporary playback cache is separate from an episode the user explicitly
  saves in Downloads; and
- device playback capabilities such as Android version, ABI, decoder, HDR,
  memory class, and display/audio support.

This data remains until it is removed in TetoTV, Android app storage is
cleared, or the app is uninstalled. Completed offline media and its related
catalog snapshot remain until the user chooses **Delete** in the Download
Manager, resets or clears TetoTV, or uninstalls the app. Cancelling a download
removes its partial media, but its cancelled job record remains until it is
deleted. Artwork and catalog rows are pruned when the last related download is
deleted. Disconnecting a service deletes that service's saved credentials.
Removing local history does not modify AniList or MAL. TetoTV's **Settings >
System > Reset TetoTV** action and Android's **Settings > Apps > TetoTV >
Storage > Clear storage** both remove all TetoTV local data. The separate
**Clear cache** action removes only temporary files and retains accounts,
preferences, sources, history, and saved offline downloads.

## Data sent to services selected by the user

TetoTV makes network requests only for app features the user uses:

- AniList and MAL receive the catalog, search, list, and progress requests
  needed for the tracker features the user chooses. When AniList is
  unavailable, Kitsu can receive bounded read-only title or identifier lookups
  for search/details and for mapping backup catalog results back to real
  AniList and MAL identifiers;
- the selected debrid provider receives account validation, torrent/magnet,
  file-selection, and streaming requests;
- Direct torrent is off by default and requires a separate warning/confirmation.
  When enabled and selected for immediate playback or an offline download
  without a usable Debrid account, the device joins the torrent swarm
  directly. Public peers, trackers, and related network infrastructure can see
  the device's public IP address and protocol traffic, and the device may
  upload verified pieces while downloading. Media bytes do not pass through a
  TetoTV server. For immediate playback, TetoTV exposes the selected file to
  MPV only through a capability-scoped `127.0.0.1` URL and deletes the temporary
  playback cache when the lease closes. For an offline download, the magnet
  and native capability remain only in memory, downloaded bytes are written to
  persistent app-private storage, and the direct-peer session stops when the
  transfer pauses, completes, fails, or is cancelled. A process restart can
  therefore require the user to reselect the torrent before retrying. TetoTV
  does not persist the magnet, peer addresses, capability URL, selected
  filename, or torrent hash in diagnostics;
- During eligible playback, AniSkip may receive a MAL title identifier,
  episode number, and episode duration to look up community intro/outro times.
  This lookup also supports the manual Skip button when automatic skipping is
  disabled;
- when AniList is unavailable, Jikan may receive bounded read-only requests for
  seasonal, popular, filtered-discovery, schedule, studio, or staff catalog
  data. A Discover search term and its public catalog filters can be sent when
  those filters are in use. Jikan also receives the public MAL title identifier
  and paginated episode-list requests needed to read filler flags when filler
  labels are enabled or a user enables **Skip filler** for a series. If AniList
  does not provide a MAL mapping, TetoTV can send one public anime title as a
  bounded exact-match search; the expected episode count and season year are
  used only on the device to reject ambiguous results. TetoTV does not send
  Jikan an account identifier, tracker list, selected stream, or playback
  history.
  When Kitsu cannot map Jikan metadata back to TetoTV's canonical catalog,
  AniZip at `hayase.ani.zip` can receive one public numeric MAL or AniList
  media identifier as an ID-crosswalk request. It receives no account token,
  search term, private-library data, playback history, filename, or stream URL.
  AniList, Jikan, and Kitsu catalog responses are normally treated as fresh
  for 30 minutes. During an outage, an expired response can be reused only
  until it is 24 hours old; older responses are ignored. Expired catalog rows
  can remain in application cache storage until they are overwritten, cache is
  cleared, or application data is removed.
  Public lookup metadata (MAL identifier, lookup route, fetch time, known
  episode count, and confirmed filler episode numbers) is treated as valid for
  24 hours; expired records are ignored and can remain in application cache
  storage until they are overwritten or application data is cleared;
- marketplace repository and manifest URLs are supplied by the user; TetoTV
  ships no default source catalog. Adding or refreshing one fetches that
  catalog from its public HTTPS host. Installing an extension fetches its
  manifest and executable payload from the addresses declared by that catalog.
  Enabled Web-stream extensions receive the public title, episode, language,
  and related request data needed to search their configured websites. Their
  hosts, catalog hosts, payload hosts, redirects, and image/subtitle/stream
  hosts receive ordinary HTTPS connection data such as the device's public IP
  address, time, user agent, and request path. The extension code can receive
  the results of requests it makes within TetoTV's bounded runtime. Users
  should install only extensions and catalogs they trust and are authorized to
  use;
- every installed, enabled Web-stream extension is subject to an automatic
  compatibility probe when TetoTV starts if its last conclusive probe is
  missing or at least 24 hours old. While TetoTV remains open, a timer runs the
  same due-only probe after the 24-hour interval; **Test all** runs it on
  demand. A probe performs bounded search, title, episode, server, and stream
  extraction requests using built-in neutral test titles. This contacts the
  extension and its configured upstream hosts even if the user has not entered
  a search during that session. The probe does not use tracker credentials,
  debrid credentials, private-library addresses, playback history, or the
  user's search text. Its bounded provider ID, version, last-tested time,
  pass/fail stage, reason code, and health counts are stored locally until the
  provider is removed, its health is reset, or TetoTV data is cleared;
- to reduce TV loading delays, ordinary source discovery can begin after
  encrypted source preferences finish loading when an episode is selected on
  its details page; changing the selected episode or leaving the page cancels
  that observer. TetoTV does not ask a debrid provider to resolve a torrent
  merely from opening details. If next-episode autoplay is enabled, the
  selected debrid provider or Web extension can be contacted again during the
  final ten minutes of playback to prepare the next episode;
- voice search uses Android's selected speech-recognition service. If a
  device cannot open its system voice prompt, TetoTV requests microphone
  permission and sends the spoken query to that recognition service only
  while the user has opened voice search;
- when a user-added Stremio source cannot use the available Kitsu identifier,
  Cinemeta may receive the anime title and year to resolve the corresponding
  IMDb series and episode identifier; and
- image hosts receive ordinary artwork requests.

When the user opens local media, Android's system file picker grants TetoTV
read access only to each video the user explicitly selects. TetoTV does not
request broad storage access. Durable provider grants and hashed resume keys
can be retained in an encrypted, newest-first index of up to 24 selected files;
providers that do not grant durable access work only for the current app
session. USB and internal-storage video contents are not uploaded by this
feature.

When the user connects Jellyfin, TetoTV sends the entered username and password
directly to that server for authentication, stores the returned access token,
and sends the token back to that same server for library, artwork, playback,
and logout requests. To offer connected-library episodes in the normal source
picker, TetoTV may send up to ten bounded public catalog title aliases to that
server and keeps only exact local title and episode matches. HTTPS is
recommended. The app permits HTTP only after a warning and only for an explicit
numeric private-network address or localhost; HTTP credentials and video
traffic are not encrypted. Authenticated playback is exposed to the media
engine only through an app-owned loopback address; TetoTV forwards the token
only to the configured server origin and rejects cross-origin redirects or HLS
resources. Jellyfin traffic does not pass through the TetoTV broker.

When the user connects Plex, TetoTV sends the saved X-Plex-Token directly to
that server in an HTTP request header for library, artwork, and playback
requests. The same bounded public title-alias searches may be sent to Plex to
find exact local episode matches. The token is never placed in a media or
artwork URL. Redirects are not followed for authenticated metadata or artwork
requests. Authenticated playback uses the same loopback and strict configured
origin policy described for Jellyfin. HTTPS is recommended; private-network
HTTP requires the same explicit warning and has the same lack of transport
encryption described for Jellyfin. Plex traffic does not pass through the
TetoTV broker.

## Offline downloads, background operation, and external players

An offline download saves the selected episode, its public catalog snapshot,
episode metadata, and available artwork in TetoTV's app-private storage. The
durable queue stores the operational fields listed under **Data kept on the
device** so paused or interrupted HTTPS transfers and whole-season plans can
continue later. A pending whole-season plan stores public catalog and selection
preferences only; it does not store resolved media URLs, magnets, request
headers, cookies, account tokens, or local filesystem paths. Completed jobs
clear their saved source address. Download request headers are used only in
memory during the current process and must be authorized again after a restart.

While a download or whole-season preparation is active, Android can run a
`dataSync` foreground service so the work can continue after the user presses
Home or minimizes TetoTV. Android displays a low-priority ongoing **TetoTV
downloads** notification while that service is active. The notification and
service contain no media title, source, URL, provider, account, or file path,
and the service does not send data to a TetoTV server. A force-stop or process
death ends the foreground work; persisted queue and season state can be
restored when TetoTV is opened again.

External-player support is optional. If the user chooses a default installed
video player, TetoTV stores that app's Android package name and display label
in local preferences until the choice is changed, cleared, or TetoTV data is
removed. A handoff gives the chosen app, or the Android chooser, the selected
header-free compatible media location and MIME type. For an Android `content:`
URI or one completed single-file TetoTV download, Android grants temporary
read access through the intent. TetoTV does not hand off direct torrents,
multi-file offline HLS bundles, a stream that requires request headers, or a
Plex/Jellyfin/private-server playback session. It never sends private-server
headers, server tokens, debrid credentials, tracker credentials, or other
TetoTV account credentials to an external player. After another app opens the
media, that app handles playback under its own privacy policy and permissions.

When the user explicitly links Discord and enables **Discord Rich Presence**,
TetoTV sends Discord the current anime title, episode number, playing or paused
state, playback timing, and the public show-artwork URL so Discord can display
that activity with the show's thumbnail. Discord OAuth
access and refresh tokens are stored in Android Keystore-backed secure storage.
Disabling Rich Presence stops sharing playback activity; unlinking Discord also
revokes the connection when possible and deletes the saved tokens from TetoTV.
TetoTV never asks for or stores the user's Discord password. Playback opened
from USB, internal storage, Jellyfin, or Plex is excluded from Rich Presence so
private filenames and media-library titles are not shared.

On Android TV and Fire TV, Discord linking uses Discord's limited-input device
authorization directly. TetoTV sends a one-time authorization request to
Discord and polls Discord only until the link succeeds, expires, or is
canceled. The private device code is kept only in app memory during that
attempt; completed access and refresh tokens use the same Android
Keystore-backed secure storage described above. The TetoTV broker is not
involved in Discord linking.

Those independent services can see normal connection metadata such as the
device's IP address and user agent, and their own privacy policies and terms
apply. TetoTV does not bundle or recommend a streaming-source repository.

## Pairing and phone-assisted setup broker

TetoTV uses the Wispbyte-hosted HTTPS service at
<https://tetotv-bot.wisp.uno> for limited-input tracker login, separate
phone-assisted source entry, and the unified **Set up on another device**
flow. These are optional. The service has no permanent TetoTV account or
credential database, but it necessarily handles the following transient data:

- A TV/device creates a pairing record containing random pairing and device
  capabilities, an expiry, a device-generated P-256 public key and its
  fingerprint, and a six-digit confirmation value. The private decryption key
  remains on the device and is never sent to the broker or encoded in the QR
  address.
- In unified phone setup, the browser can select app preferences, marketplace
  repository URLs, torrent-manifest URLs, and linked services. When an
  official AniList, MyAnimeList, debrid, or Discord flow returns to the broker,
  the resulting access token, refresh token, API key, provider-issued client
  credentials, expiry, and scopes are temporarily readable by the broker
  process. They are not end-to-end encrypted while the broker is receiving and
  holding them. This short plaintext interval is required to receive the
  provider callback and deliver the result to the already-bound browser.
- Linked-service credentials are held only in volatile server memory and are
  removed after the browser claims them or when their one-hour maximum expiry
  is reached. The bound browser assembles the selected credentials, source
  URLs, and preferences in memory and encrypts the complete setup bundle for
  the paired device using P-256 ECDH, HKDF-SHA-256, and AES-256-GCM before it
  submits the envelope. Credentials are not placed in the QR code, URL,
  browser persistent storage, server logs, crash reports, or diagnostics.
- After browser encryption, the broker can read only pairing metadata and the
  encrypted envelope; it cannot decrypt that envelope because it does not have
  the device's private key. The encrypted envelope remains in volatile memory
  until the device acknowledges or rejects it, the user cancels, the session
  expires, or the broker restarts. Non-secret setup choices can remain
  resumable for up to seven days, but linked-service credentials do not receive
  that longer retention.
- The device decrypts and validates the bundle locally, validates linked
  accounts with their selected providers, and writes accepted credentials to
  Android Keystore-backed storage. If an import fails, TetoTV attempts to
  restore the previous local accounts, sources, and preferences.
- The older phone-assisted source-entry flow holds submitted repository and
  manifest URLs in volatile memory for up to ten minutes. They are deleted
  after the authenticated device confirms local processing or when the session
  expires. The broker does not fetch those URLs; the app independently
  validates a public HTTPS destination before saving or fetching it.
- App updates do not pass through this broker. Public and Beta release metadata
  are requested anonymously from their respective public GitHub repositories,
  and the signed universal APK is downloaded directly from GitHub's release
  asset URL. TetoTV sends no GitHub token or shared Beta credential.

The host and its reverse proxy process ordinary connection information such as
IP address, time, route, status, user agent, and rate-limit counters for TLS
delivery, security, abuse prevention, and operations. Short-lived keyed
address hashes or counters can be used for capacity and rate limits. These are
not used for advertising or cross-service tracking. Exact infrastructure-log
retention is controlled by Wispbyte and must be confirmed before each public
release. Pairing records themselves are held in process memory rather than a
user-profile database; a broker restart can end an active pairing session.

## Optional Beta aggregate live count

Beta builds enable an approximate anonymous aggregate live count by default.
It can be turned off during first-time setup or later in Settings. Public
builds and debug/test builds do not send this presence. The app sends only a
short-lived random process capability and whether that process is active or
has an MPV player route open. A paused or loading player can therefore still
be counted as watching. It never sends a profile, title, episode, source,
device identifier, URL, filename, personal-server address, or other media
information.

The Wispbyte service holds only active-or-player-open state and an expiry time in
bounded process memory. Capabilities are stored only as keyed hashes and
expire within three minutes without a heartbeat. Ordinary HTTPS delivery and
rate limiting necessarily process the connecting IP address, but it is not
stored in the presence record. A separate keyed, short-lived address hash is
used only to enforce per-address capacity and abuse limits. Discord receives
only debounced aggregate active and watching totals, never an individual
presence record. The totals are process-local and subject to per-address
capacity limits, so a large shared or CGNAT network can be undercounted. A
service restart clears all counts. The result is a community activity
indicator, not exact audience analytics.

## Watch Party

Watch Party is optional. Creating or joining a room sends the Wispbyte
TetoTV service an eight-digit room code containing only 2 through 9 and a
high-entropy room capability. The service can read the room state described in
this section; it is not end-to-end encrypted between participants.
Capability-authenticated room members can see a bounded roster containing a
public display name, an optional HTTPS avatar from an allowlisted AniList or
MyAnimeList image host, a random room-scoped participant identifier, Host or
Guest role, and readiness. Names and avatars can identify a person and are
shared with the other people who possess that room's capability. The host can
transfer control to a guest or remove a guest; transfer reassigns the existing
room capabilities without exposing them. When no safe tracker profile is
available, the app shares no tracker identity and the service uses an
anonymous Host or Guest name with deterministic initials. Tracker provider,
account/slot ID, email address, OAuth identifier, and token are never included
in the roster payload.

The room also synchronizes public catalog identity such as AniList title ID
and episode number, optional opaque release-timeline and source fingerprints,
coarse source class, audio type and quality, playback position and play/pause
state, readiness counts, request timing, and a bounded recent window of join,
leave, removal, and host-transfer notices. A source fingerprint is a one-way
SHA-256 digest used only to prefer the same locally available release as the
host; guests fall back to their own eligible source when it is unavailable.
It does not send the fingerprint preimage, stream URL, HTTP header, Plex or
Jellyfin address/token, debrid credential, magnet link, raw torrent hash, local
filename/path, or video/audio bytes.

Room state, the roster, membership notices, short-lived removal markers, and
hashed capabilities are held only in the bot process, are bounded, and expire
automatically within six hours or sooner after inactivity. The service uses
ordinary IP address, request, and rate-limit metadata for HTTPS delivery,
security, and abuse prevention. Infrastructure-log retention is controlled by
the host and must be confirmed before release. There is no application-level
room history or TetoTV user profile database. TetoTV does not put room codes,
participant names or identifiers, or avatar URLs in diagnostics, crash
reports, persistence, or analytics.

The public <https://tetotv-bot.wisp.uno/watch> page can join a room and play a
video selected through the browser's local file picker. The selected file is
represented by a browser-local `blob:` URL and is never uploaded to TetoTV.
Every participant must independently choose a lawful source or local copy.
Because different releases can have different cuts, the app can display a
timeline warning and use coarse synchronization when fingerprints differ.

## Diagnostics and sharing

Anonymous crash reporting is disabled by default. First-time setup and Settings
both let the user explicitly enable or disable it. When enabled, an unexpected
handled app error or unhandled Flutter error can be sent immediately; a JVM
crash is kept locally and sent after the next launch because a terminated
process cannot use the network. On
Android versions that expose historical process-exit details, native crashes
and ANRs can also be recovered on the next launch. TetoTV sends only the app
version/build, crash category, Android
version, CPU architecture, TV-or-phone class, time, and a bounded redacted
technical error/stack trace. It does not intentionally include the show,
episode, account, device or installation identifier, source/provider, URL,
credential, playback history, or full diagnostics database.

The app sends reports over HTTPS to the dedicated TetoTV crash-report receiver
at <https://tetotv-bot.wisp.uno>. That receiver validates and rate-limits each
report, adds a random per-incident reference, and posts it through the TetoTV
Discord bot to the designated crash report channel. Reports remain in Discord
according to that channel's access and retention settings until a moderator
deletes them. The receiver does not store report bodies, though Wispbyte and
Discord process ordinary connection/request metadata under their own policies.
Disabling reporting deletes any queued unsent report and prevents later crashes
from being sent.

Other bounded diagnostics stay on the device unless the user explicitly
copies, exports, or chooses **Send to support** and confirms the disclosure.
The explicit report includes the preceding 48 hours of persisted redacted app
events and locally retained crash/ANR summaries, ordered chronologically. Both
rings have hard capacity limits, and the report states how many records were
discarded because they were older than the window or exceeded capacity. These
events can include a per-playback-session technical timeline: source class
(torrent, web, Plex, Jellyfin, or on-device), stream-open result, decoder mode
and codec, fallback attempt, and final outcome. Sessions use a random local
correlation value and a strict reason-code vocabulary. They never contain a
show or episode name, provider/server ID, media URL, request header, filename,
local path, account value, or room identity. The report also compares the most
recent working and failed sessions using only those technical fields.

These local crash summaries are kept even when anonymous crash reporting is disabled
so a later user-requested report can explain a restart; they are never queued
for automatic upload and expire from the local ring after 48 hours.
That explicit send posts a maximum 480,000-character redacted JSON report over HTTPS to
<https://tetotv-bot.wisp.uno>. The receiver validates and redacts it again,
posts it through the bot to the private diagnostic support channel, and returns
an opaque per-report reference only after Discord accepts the message. A retry
of the same button press is acknowledged without creating a duplicate post.
The app does not contain the Discord bot token, incident secret, or destination
channel configuration.

Manually sent or exported reports contain app/build and
playback-capability information, bounded performance/failure events, Android
version, manufacturer/model, and provider identifiers. TetoTV redacts
account identity, credentials, request headers, signed or encoded URLs,
magnets, hashes, media filenames and file paths, private server addresses and
identifiers, and common token formats before storage and again before sending
or export. Users should still review a
manually exported report before sharing it through another app.

## Security and user choices

Network integrations require HTTPS except an explicitly approved Jellyfin or Plex
connection to a numeric private-network address or localhost. User-added
endpoints are checked against their expected network boundary and are fetched
through constrained clients. No
software can promise absolute security; users should revoke a service token if
they believe a device or account has been compromised.

All account connections, source installation, tracking sync, reminders,
automatic updates, and diagnostics sharing are optional. The app can be used
without connecting an anime-list account.

## Children and changes

TetoTV is not directed to children and does not knowingly collect a child's
personal information. This disclosure may change when features or hosting
change. The effective date will be updated for material changes.

## Contact

Privacy questions, support requests, and deletion requests can be sent to the
TetoTV maintainer through the public TetoTV Discord community:
<https://discord.gg/juC6k7d4WY>. Before any broad public or store release, the
distributor must ensure this contact and a public HTTPS copy of this disclosure
remain accessible.
