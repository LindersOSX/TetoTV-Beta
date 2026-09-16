# Manga library and reader

The core Manga reader does not require Developer Mode. Its preference is enabled
by default, and first-run setup asks whether to keep it enabled. Disabling the
reader in **Settings > Services** hides its navigation
entry and blocks reader routes without deleting the local library, progress,
settings, or downloads. Disabling the reader pauses active and queued downloads
and suspends Manga tracker delivery. Re-enabling can resume due tracker delivery,
while downloads require an explicit resume. This document describes the current
local implementation, not a device-compatibility certification. TetoTV bundles
no manga catalog. New sources are added through user-supplied Seanime-compatible
manga extension repositories; previously saved OPDS/data catalogs and completed
downloads remain available. See
[Manga repositories](MANGA_REPOSITORIES.md) for that compatibility boundary.

Experimental Aniyomi extension compatibility remains Developer Mode-only. Its
repository, install, discovery, and reader paths are revoked when Developer Mode
is turned off.

## Library and chapters

Save a title from an installed source to add it to the active profile's library.
You can search saved titles, assign a category and reading status, filter by
category/status, show only new chapters or downloaded titles, and sort by title,
recently read, recently added, or new chapters. These are local library choices;
changing a local status does not change an online tracker list.

**Check for updates** explicitly contacts saved Seanime sources for chapter lists.
Each check attempts at most 100 titles sequentially and shows how many remain.
The next check continues from a protected profile-local cursor, including after
an app restart. Failed sources do not prevent later titles from being checked.
After reaching the end, the next check starts a fresh pass. This is an explicit
action, not a scheduled whole-library background monitor.

The chapter sheet shows read state and bookmarks, supports ascending/descending
display order, unread/bookmark filters, individual downloads, and **Download next
5 unread** or **Download next 10 unread**. Display filters do not replace the full
reading-order list. Continue reading uses saved chapter/page progress; downloaded
chapters can be opened without contacting the source. If history cannot be read,
the UI requires a retry before history-dependent continuation or batch selection.
Starting an extension download also saves that title in the library so an
explicit resume can resolve its source identity later.

**Change source** copies matching history to another Seanime edition already
saved in the same profile. Review the selected edition and matched/unmatched
counts before confirming. Automatic suggestions use unambiguous chapter-number
matches, not a fuzzy title match. The original title, unmatched history and
downloads are retained; this does not transfer downloaded page files or tracker
links to the new edition.

## Opening the reader

Open a chapter and select the gear in the reader toolbar to customize it. Tap the
page center to show or hide the toolbar. With a remote, press Up to reach toolbar
actions, or Down to reach the page slider. Back closes settings or exits zoom
before leaving the reader. Previous/next chapter actions appear when the source
or downloaded chapter list supplies a neighboring chapter. The current position
is saved before switching; a failed chapter fetch keeps the existing chapter
open and offers a retry.

## Reading layout

- **Reading mode:** sideways pages, vertically paged reading, or a continuous
  Webtoon strip.
- **Reading direction:** right to left or left to right.
- **Page spread:** automatic, single page, or double page. Automatic adapts to
  wide screens and supported foldable display information.
- **Page fit:** fit the whole page, fit width, or fit height. Webtoon mode
  always fits width so the strip can scroll vertically.
- **Remember layout for this manga:** saves those four choices for the current
  title and source, across chapters. When off, the four choices use and edit
  the defaults for all manga. Display, controls, and privacy choices stay global.
  Reader defaults and source/title layout overrides are device-local settings,
  not separate settings for each library profile.

## Page appearance

Choose black, charcoal, white, or sepia behind the pages. Adjust side margins,
the gap between spread pages, or the gap between Webtoon pages. Dimming,
warmth, grayscale, and inverted colors affect page images only, not the toolbar
or loading/error messages. These are in-app image effects; they do not change
system brightness or alter downloaded files.

## Controls and progress

Pinch to zoom and pan the enlarged page. Optional double-tap zoom switches
between normal size and a closer view. Normal swipes turn or scroll pages when
not zoomed; a page change resets zoom.

The toolbar also offers remote-friendly zoom. In remote zoom mode the D-pad pans
the page; Back resets zoom. Page failures show a retry action instead of exposing
source response text. Reloading a remote page obtains it again from its current
source capability; if access has expired, reopen/reconnect the source.

Tap navigation can use three equal zones or narrower edge zones. The middle
opens the toolbar; the sides follow the reading direction. Invert tap zones
to swap only the tap actions without changing reading order. Turning tap zones
off still allows tapping to show the toolbar and swiping to read.

The optional page counter remains visible when the toolbar is hidden. Page-turn
animation can be disabled, and system reduced-motion preferences are respected.

## Performance, privacy, and reset

Nearby-page preloading is optional and bounded. Visible page requests take
priority over speculative preloads; obsolete queued preloads are cancelled as
reading moves, and leaving the reader cancels its prefetch work. Preloading is
not an offline download. Keep-screen-awake, cover-page, spread-order, and Discord
title-sharing controls also save automatically on this device. Discord sharing
requires the existing enabled and connected Discord integration. A valid public
book cover replaces the large app logo while reading, including from saved
library metadata offline. Protected/signed or unavailable covers use the app
logo; no local image is uploaded. Turning title sharing off hides both title and
cover and uses a generic reading status.

Reset requires confirmation. It restores reader defaults and removes the
current manga's layout override, while leaving other manga-specific layouts
and reading progress intact.

These reader controls do not add a bundled catalog or change extension
compatibility. See [Manga repositories](MANGA_REPOSITORIES.md) for supported
repository formats and their security boundaries.

## Optional AniList and MAL tracking

Connect an account in Settings, then open **Manga tracking** for a saved title.
Choose AniList or MAL, search that service's manga catalog, select a result to
review its title/identifier/edition information, and confirm the match. TetoTV
does not silently link a title by its name. Linking alone sends no reading
progress. SIMKL is not a manga-tracking option.

After linking, completing a chapter in the reader can update the selected
record's chapter progress. Only positive whole-number chapter numbers are sent;
the number of arbitrary local read marks is not used as a substitute. Scores,
volume counts and online list status are left unchanged. TetoTV reads existing
remote progress before sending and does not intentionally lower a higher count.
For specials, numbering gaps, or numbering that restarts by volume, review the
count directly on the tracker. Local mark-read/unread actions are not a tracker
history import, and linking does not upload earlier local history.

Links and pending updates are stored in protected local storage, bound to the
local owner, tracking profile and verified remote account. A completion is saved
to the outbox before the tracker request; the reader need not wait for the HTTP
update. Retries coalesce higher chapter targets, use persisted attempt limits
and backoff, and respect provider retry delays. After the attempt limit or an
account/mapping error, the dialog shows pending work for review. Its manual retry
targets the selected title and tracker. Unlinking removes that local binding and
its pending updates, not the service's list entry. Local reading progress is
saved independently of tracker delivery; a device-storage failure can prevent a
new tracker update from being queued.

## Encrypted local backup

The backup dialog uses Android's document picker to save or open a file you
choose. Export requires a passphrase of at least 12 characters and confirmation
of that passphrase. TetoTV does not retain it or offer passphrase recovery. The
file uses AES-256-GCM with a fresh salt/nonce and a PBKDF2-HMAC-SHA256-derived key
(600,000 iterations); choose a strong passphrase and keep it separately.

The backup includes supported Seanime library titles, categories/statuses,
chapter snapshots, reading history/bookmarks (including supported history for
titles no longer saved), protected title identities, and reader preferences.
It does not include downloaded pages, repositories or extension installs,
credentials, resolved page URLs/headers, legacy OPDS titles, or tracker links and
pending tracker updates. Reinstall/reconnect the required providers and relink
trackers separately. The current limits are fewer than 500 saved library titles,
50,000 combined chapter records, 8 MiB decrypted data and a 12 MiB encrypted file;
an over-limit export fails rather than silently truncating it.

Import first decrypts and previews titles, conflicts, history/settings changes
and sources needing reconnection. Review **Merge newer progress** or **Keep
existing data and settings**, then explicitly confirm. Import does not delete
titles/history absent from the file. Changed local state invalidates a preview;
preview again before confirming. Database changes are transactional and failed
protected writes trigger restoration attempts, but a reported rollback failure
requires checking sources and reader settings. Import is not a tracker sync or
a download request. An exported file is outside app-private storage and is not
removed by clearing TetoTV's data; delete it through its chosen storage provider.
