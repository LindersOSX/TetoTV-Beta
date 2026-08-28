# TetoTV store data-safety inventory

Reviewed against the application source on August 28, 2026.

This is a conservative engineering inventory for preparing a store privacy or
Data safety form. It is not a completed Google Play, Amazon Appstore, or other
store submission, and it is not legal advice. Store definitions and exceptions
can differ. The person submitting a build must compare this inventory with the
exact APK, deployed TetoTV service, provider agreements, host logs, and current
store questions instead of copying answers without review.

TetoTV has no advertising SDK, no third-party analytics SDK, no permanent
TetoTV account, and does not sell personal data. A row marked **Shared** below
uses the conservative ordinary meaning that data leaves the device for a
service, infrastructure provider, another room member, or a user-selected
provider. A store may classify some user-directed transfers or service-provider
processing differently, but that exception must be documented by the release
owner.

## Off-device data matrix

| Data category | Trigger and data | Recipient and purpose | Optional? | Application-level retention | Conservative sharing treatment |
| --- | --- | --- | --- | --- | --- |
| Account and authentication information | Linking AniList, MyAnimeList, Discord, or a debrid service can produce access/refresh tokens, API keys, provider-issued client credentials, expiry, token type, and scopes. | The selected provider authenticates the account. In unified phone setup, the TetoTV broker temporarily receives provider callbacks so the bound browser can claim the result and encrypt it for the paired device. | Yes; each account can be used, omitted, or disconnected. | Broker-readable credentials are volatile and removed when claimed or within one hour. Accepted credentials remain in Android Keystore-backed storage until disconnect/reset/uninstall or provider expiry/revocation. | **Collected by the setup service and shared with the user-selected provider.** Claim any service-provider or user-initiated exception only after store-policy review. |
| App preferences and user-supplied source addresses | Unified phone setup can include audio/title preferences, interface choices, feature toggles, marketplace repository URLs, and torrent-manifest URLs. | The browser encrypts the bundle for the paired device; the broker transports only the encrypted envelope after submission. | Yes; phone setup can be skipped and each field is optional. | The encrypted envelope is volatile until acknowledgement, cancellation, expiry, or restart. Non-secret resumable choices may remain for up to seven days. Imported choices remain locally until changed/reset/uninstall. | **Collected as encrypted application data by the setup transport.** The broker cannot decrypt the submitted envelope, but its ordinary request metadata is still processed. |
| Public profile information | Watch Party can send a public display name, optional allowlisted profile-avatar URL, room-scoped participant ID, role, and readiness. | TetoTV Watch Party service and other capability-authenticated room members use it for the room roster and controls. | Yes; Watch Party is optional, and an anonymous Host/Guest identity is used when no safe public tracker profile exists. | Volatile room state expires within six hours or sooner after inactivity/restart. No application-level room history is retained. | **Shared with the TetoTV service and other room participants.** |
| Watch Party app activity | Public catalog ID, episode, playback position, play/pause/readiness, timing, coarse source class, audio/quality, one-way source/timeline fingerprints, and bounded room notices. | TetoTV Watch Party service synchronizes playback and room actions. No stream URL, credential, private-server address, filename, or media bytes are sent. | Yes. | Volatile and bounded; expires with the room within six hours or sooner after inactivity/restart. | **Shared with the TetoTV service and capability-authenticated participants.** |
| User-installed catalog and extension activity | Adding/refreshing a repository fetches its catalog; installing an extension fetches its manifest/payload. Enabled extensions receive public title/episode/language inputs. Due compatibility probes automatically perform neutral search-to-stream requests at startup and every 24 hours while open; **Test all** is manual. | User-selected catalog, extension, and upstream HTTPS hosts provide source discovery and compatibility results. | Yes; no catalog or extension is bundled by default and each can be disabled or removed. Automatic due probes occur for an enabled installed extension. | Catalogs, installed definitions, and bounded health result/time/stage/reason counts remain locally until removal/reset/uninstall; remote-host retention is controlled by that host. | **Shared with user-selected third-party hosts.** This remote executable-code/content feature requires separate store-policy approval or removal. |
| Search, catalog, list, and tracking activity | Public title IDs, search terms and filters, list status, episode progress, and bounded catalog lookups are sent when the corresponding feature is used. | AniList, MyAnimeList, Kitsu, Jikan, AniZip, AniSkip, Cinemeta, and artwork hosts provide the requested catalog, mapping, skip-time, image, or tracking function. | Tracker connection and automatic skipping are optional; ordinary catalog/search network use is core to online discovery. | TetoTV keeps bounded local caches as described in `PRIVACY.md`; recipient retention follows each service's policy. | **Shared with the service needed for the user-requested feature.** |
| Debrid and source-resolution activity | Account validation, magnet/torrent metadata, selected file, and stream-resolution requests are sent when a configured debrid source is used. | The user-selected debrid provider supplies account and streaming functionality. | Yes. | TetoTV does not retain credentials on its server. Local credentials remain until disconnect/reset/uninstall; provider retention follows its policy. | **Shared with the user-selected debrid provider.** |
| Personal-media server data | Jellyfin username/password during sign-in, returned access token, Plex token, configured server address, bounded public title aliases, library/artwork/playback/logout requests. | Sent directly to the user-configured Jellyfin or Plex server, not through the TetoTV broker. | Yes. | Password is not saved; server addresses/tokens stay in Keystore-backed local storage until disconnect/reset/uninstall. The configured server controls its own logs. | **Shared with the server selected or operated by the user.** Private-network HTTP is unencrypted and requires an explicit warning. |
| Crash logs and app/device diagnostics | With anonymous crash reporting enabled: app/build, crash category, Android version, ABI, TV/phone class, time, and bounded redacted error/stack. A manual support report additionally includes model/manufacturer, playback capabilities, provider identifiers, and a bounded 48-hour technical timeline. | TetoTV HTTPS receiver validates/redacts and posts through the TetoTV bot to restricted Discord crash or diagnostic channels for support and reliability. | Anonymous crash reporting is off by default. Manual diagnostics always require an explicit send action. | Receiver does not retain the body after Discord accepts it. Discord retains the posted report according to channel/platform retention until a moderator deletes it. Local rings retain at most 48 hours and twelve crash/ANR summaries. | **Collected by TetoTV support infrastructure and processed by Wispbyte and Discord.** No advertising or cross-service profiling. |
| Beta aggregate presence | Short-lived random process capability plus active/player-route-open state; no profile, title, episode, source, device ID, or media URL. | TetoTV service calculates aggregate active/watching totals and posts only totals to Discord. | Beta only; enabled by default with setup/Settings opt-out. Disabled in Public and debug/test builds. | Capability hashes/state expire within three minutes without a heartbeat; restart clears counts. | **Collected by TetoTV in Beta.** Only aggregate totals are sent onward to Discord. |
| Voice audio/search | Spoken query while the user has explicitly opened voice search. | Android's selected speech-recognition service converts speech to text. | Yes and user initiated. | TetoTV does not retain or receive an audio recording; recognition-service retention follows that provider's policy. | **Shared with the device-selected recognition provider.** |
| Direct-peer network activity | Magnet-selected torrent protocol traffic and verified media pieces when Direct torrent is explicitly enabled and used. | Public peers, trackers, and network infrastructure deliver peer-to-peer media; peers can see the public IP and the device may upload pieces. | Yes; off by default with a separate warning/confirmation. | Immediate-playback cache is temporary; a user-saved download remains locally until deleted. Peer/tracker retention is outside TetoTV's control. | **Shared with public torrent peers and trackers.** This must be declared and separately reviewed for store content/network policy. |
| Update and integrity information | App release channel, anonymous GitHub release request, APK request, and ordinary download metadata. | GitHub supplies release metadata and signed APK bytes directly. | Manual checks are optional; automatic checks can be disabled. | TetoTV stores only bounded local update state/release notes. GitHub controls request-log retention. | **Shared with GitHub for app updates.** A Play build must use Play-managed updates instead. |
| Connection and abuse-prevention metadata | IP address, time, route, status, user agent, and rate-limit/capacity data accompany all HTTPS requests; TetoTV services can use keyed short-lived address hashes. | Wispbyte/reverse proxy/TetoTV service for TLS delivery, security, operations, and abuse prevention; third-party endpoints receive their own ordinary connection metadata. | Inherent when an online feature is used. | Application records use the bounded expiries described above. Exact infrastructure-log retention is host controlled and must be verified before release. | **Collected by the contacted service and its infrastructure providers.** Conservatively consider IP-derived approximate location if the store form requires it. |

## Data that remains local unless the user exports or hands it off

- Android Keystore-backed credentials after import; local profiles; app
  preferences; playback history and resume positions; tracker-sync outbox;
  downloaded media; cached metadata/artwork; installed source definitions and
  provider-health records.
- Videos selected through Android's file picker. A local file is not uploaded
  by TetoTV. If the user chooses an external player, Android grants that app
  temporary access to only the selected compatible media.
- The package name and display label of a user-selected external player.
- The phone-setup device private key. It never leaves the paired device.

Manual export through Android's share sheet is a user-directed transfer to the
destination the user chooses. TetoTV cannot control that destination's privacy
or retention.

## Required release/store decisions

1. Verify that the deployed privacy page is identical to the release copy and
   that Wispbyte/reverse-proxy log fields and retention have been documented.
2. Validate every matrix row against the exact Public or Beta APK. Public must
   declare no Beta live-count collection; Beta must declare it as optional
   collection that starts enabled until the user opts out.
3. Do not mark data as uncollected merely because it is encrypted in transit,
   temporary, optional, or stored by a service provider. Document any store
   exception relied on for user-initiated transfers or service providers.
4. Provide in-product controls described by the form: disconnect linked
   accounts, disable crash reporting/Beta presence, leave Watch Party, remove
   sources/downloads/history, reset TetoTV, and request deletion of a Discord
   support report through the published contact route.
5. Keep the store privacy-policy URL, support contact, screenshots,
   permissions declaration, content rating, target audience, and Data safety
   answers synchronized with the shipped build and hosted services.

## Sideload build versus Google Play

The current GitHub APK is a sideload distribution. It contains a signed
direct-GitHub updater and requests Android's package-install permission. It can
also download user-selected JavaScript extensions and can perform optional
direct-peer playback. **Do not submit this APK unchanged to Google Play.**

A Play-specific build must remove `REQUEST_INSTALL_PACKAGES` and the direct APK
installer, use Play-managed updates, and receive a separate policy review for
remote executable extensions, user-supplied catalogs, source results,
downloads, direct-peer networking, and intellectual-property/content rules.
Disabling or removing a feature changes the matrix and requires a fresh source,
binary, runtime, privacy-page, and Data safety review. Passing automated tests
or publishing this inventory is not store approval.
