# Manga repositories

TetoTV's core Manga reader does not require Developer Mode. Its preference is
enabled by default, first-run setup asks whether to keep it enabled, and it can be disabled
in **Settings > Services**. The new-source UI accepts user-added Seanime/Teto
Marketplace repositories containing compatible
`manga-provider` extensions. It does not offer a new OPDS/data-catalog setup flow,
load Android APK extensions, or provide a default catalog, Marketplace repository,
or provider.

Experimental Aniyomi repository and APK-extension compatibility is separate and
remains available only while Developer Mode is enabled. Disabling Developer
Mode revokes Aniyomi discovery and reader paths without deleting saved local
data or blocking core Manga.

Previously saved OPDS 1.x Atom feeds, OPDS 2.0 JSON feeds and data-only TetoTV
repository definitions remain usable under **Previously saved catalogs**.
Existing library entries and completed downloads are not removed by this UI
change. The OPDS/schema sections below document retained legacy compatibility,
not a second recommended path for adding new sources.

This document describes technical compatibility. It is not a review of a
catalog's safety, content, availability, terms, or legality. A viewer should
add only services and material they are authorized to use.

## Network and legacy data-catalog boundary

- Every repository, OPDS, redirect, cover, page, and acquisition reference
  must use a credential-free public HTTPS URL. URLs containing embedded
  usernames/passwords, local hostnames, or private/loopback/link-local IP
  destinations are rejected.
- Declarative repository documents are limited to 2 MiB, 128 declared sources, bounded
  text/list sizes, and a maximum nesting depth. OPDS documents have additional
  entry, link, contributor, and node limits.
- DTDs and XML entities are rejected in OPDS 1.x documents.
- Repository fields not defined by schema version 1 are rejected rather than
  silently activated.
- Authentication values never belong in a repository document. The document
  can declare an authentication type; the viewer enters the actual credential
  locally, where TetoTV stores it in Android Keystore-backed secure storage.
- Catalog credentials are sent only to that source's exact origin. An
  authenticated catalog or archive request cannot redirect to a different
  origin. Reader-page redirects may change origin, but TetoTV strips the
  source credential before following them. TetoTV does not put credentials in
  URLs, catalog caches, diagnostics, or Discord activity.
- No source is bundled, suggested, endorsed, or remotely enabled by TetoTV.

## In-app repository flow

The Manga **Sources** page directs new additions to extensions and retains
already-saved OPDS/declarative catalogs in a separate legacy section:

1. **Manga repositories** accepts public HTTPS Seanime/Teto Marketplace JSON
   URLs that the viewer enters. The field always starts blank.
2. **Manga extensions** lists `manga-provider` entries from those repositories.
   Supported JavaScript and TypeScript entries can be installed; entries that
   declare another runtime remain visible as unsupported. The viewer must
   explicitly confirm each install or update and can enable, disable, or
   uninstall it independently.
3. **Browse installed sources** searches enabled extensions and can open a
   title, save it to the local library, read chapters, or start a compatible
   chapter download.

The extension catalog can be filtered by name, author, and declared language.
Its list is built lazily so repositories containing hundreds of entries do
not create hundreds of off-screen controls at once. This page manages the same
user-added Marketplace repository list used by the main Marketplace. Disabling
or removing a repository therefore hides its catalog and future updates for
both manga and anime providers. It does not silently uninstall extensions that
were already installed.

Mihon/Tachiyomi `index.pb` URLs are detected and rejected before they are
saved or fetched as Marketplace JSON. Their entries point to native Android
extension APKs, which are not compatible with TetoTV's restricted
JavaScript/TypeScript manga-provider runtime. The provided URL format is
therefore an example of a different repository family, not a supported or
bundled TetoTV source.

## Seanime-format manga-provider extensions

A viewer can add a compatible Marketplace repository and explicitly install
an entry whose type is `manga-provider` and whose payload is JavaScript or
TypeScript. The extension can implement Seanime's public manga operations:
title search, chapter discovery, and chapter-page discovery. Results are
adapted into TetoTV's existing reader, local library, progress, and compatible
chapter-download pipeline. Anime stream providers and manga providers use
separate runtime entry points and discovery lists.

This is executable third-party code, not a data-only catalog. It runs in a
bounded QuickJS isolate and can make only bounded requests to validated public
HTTPS destinations. It is not given Android APIs, native channels, arbitrary
device files, or TetoTV's AniList, MyAnimeList, Discord, Debrid, or personal
server credentials. Returned identifiers and per-page request headers remain
runtime capabilities; opaque upstream title identifiers are kept in protected
storage when a title is saved, while page URLs and headers are not written to
the manga database or diagnostics.

The extension and every host it contacts can still observe the search, title,
chapter, URL path, public IP address, request time, user agent, and other
ordinary connection metadata needed to answer the request. A provider may
also return short-lived cookies or headers for artwork/pages. Install only
repositories and providers you trust, review updates before installing them,
and use only services and material you are authorized to access. Technical
compatibility is not a safety, content, availability, terms, or legality
review.

TetoTV does not directly support Tachiyomi/Mihon APK extensions. Those are
Android packages with a different executable contract and security model.

## Request and redirect limits

- Catalog and repository responses are limited to 2 MiB, use bounded connect
  and receive timeouts, are not retried automatically, and may follow at most
  five redirects. Every hop is revalidated as a public HTTPS destination.
- Remote reader pages are limited to 20 MiB each and may follow at most five
  redirects. The reader permits at most eight active image requests and 64
  unique pending/cached images, with a 45-second total deadline per image.
  Source credentials are attached only on the source's exact origin and are
  omitted after an origin change.
- Before decoding, every reader page must identify as JPEG, PNG, WebP, or GIF
  and fit within 8,192 pixels wide, 16,384 pixels high, and 32 megapixels.
- Chapter acquisitions may follow at most five redirects. If a credential was
  sent, the acquisition must remain on the same origin. TetoTV never persists
  an acquisition URL or request header in its manga download database.
- Redirect limits describe TetoTV's current manga-reader behavior, not a
  promise that every conforming OPDS server or acquisition will be compatible.

## Legacy declarative repository schema version 1

This retained parser accepts a UTF-8 JSON document. The new-source UI does not
offer this format. This complete compatibility example uses reserved
`.example` hosts and contains no live catalog or credential:

```json
{
  "format": "tetotv-manga-repository",
  "schemaVersion": 1,
  "id": "example-library",
  "name": "Example Library",
  "description": "Example OPDS catalogs for schema documentation.",
  "homepage": "https://catalog.example/",
  "icon": "https://catalog.example/icon.png",
  "sources": [
    {
      "id": "example-library-en",
      "name": "Example Library (English)",
      "description": "An OPDS 2.0 example.",
      "protocol": "opds2",
      "entryPoint": "https://catalog.example/opds/v2",
      "homepage": "https://catalog.example/",
      "icon": "https://catalog.example/icon.png",
      "authentication": {
        "type": "none"
      },
      "languages": ["en"],
      "contentRatings": ["safe"],
      "capabilities": ["browse", "search", "download", "pageStreaming"]
    }
  ]
}
```

Root fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `format` | Yes | Must be `tetotv-manga-repository`. |
| `schemaVersion` | Yes | Must be the integer `1`. |
| `id` | Yes | Stable lowercase identifier using letters, digits, `.`, `_`, or `-`. |
| `name` | Yes | Repository display name. |
| `description` | No | Plain-text repository description. |
| `homepage` | No | Public HTTPS informational page. |
| `icon` | No | Public HTTPS artwork. |
| `sources` | Yes | One to 128 OPDS source declarations. |

Source fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | Yes | Stable lowercase source identifier, unique within the repository. |
| `name` | Yes | Source display name. |
| `description` | No | Plain-text source description. |
| `protocol` | Yes | `opds1` or `opds2`. |
| `entryPoint` | Yes | Public HTTPS OPDS feed. A relative reference is resolved against the repository URL. |
| `homepage` | No | Public HTTPS informational page. |
| `icon` | No | Public HTTPS artwork. |
| `authentication` | No | Authentication metadata; defaults to `none`. Never contains the secret. |
| `languages` | No | BCP 47-style language tags such as `en` or `ja-JP`. |
| `contentRatings` | No | One or more of `safe`, `suggestive`, `adult`, or `unknown`; defaults to `unknown`. |
| `capabilities` | No | One or more of `browse`, `search`, `download`, `progressSync`, or `pageStreaming`; defaults to `browse`. |

## Legacy authentication declarations

Unauthenticated source:

```json
"authentication": { "type": "none" }
```

Basic or Bearer authentication declares only the type:

```json
"authentication": { "type": "basic" }
```

```json
"authentication": { "type": "bearer" }
```

An API key also declares a valid, non-reserved request-header name:

```json
"authentication": {
  "type": "apiKey",
  "headerName": "X-Example-Api-Key"
}
```

`Authorization`, `Cookie`, `Host`, `Origin`, `Referer`, proxy, and transfer
headers cannot be selected as a custom API-key header. Basic and Bearer
credentials use the standard `Authorization` header internally.

## Retained OPDS behavior

TetoTV uses OPDS navigation and acquisition relationships supplied by the
configured server. OPDS 1.x must be a valid Atom feed in the Atom namespace;
OPDS 2.0 must provide valid JSON metadata and bounded publication, navigation,
group, facet, and link arrays. Relative links are resolved against the feed's
final validated HTTPS URL.

Support for a declared capability means only that TetoTV understands the
corresponding data shape. It does not guarantee that every OPDS server exposes
that operation or that every acquisition format can be displayed or saved.

## Reading and compatible chapter downloads

For library organization, chapter controls, per-manga preferences, optional
AniList/MAL mapping and encrypted local backup, see
[Manga library and reader](MANGA_READER.md).

Seanime chapter-page discovery supplies bounded HTTPS image resources to the
reader and image-download queue. Saved legacy OPDS publications can still supply
a compatible reading order or ZIP/CBZ acquisition. Legacy source credentials are
loaded from protected storage for the current operation and only for the exact
source origin.

The archive boundary is intentionally strict:

- at most 1,000 image pages and 2,000 total ZIP entries;
- at most 20 MiB per page and 512 MiB total downloaded/uncompressed chapter
  data;
- a maximum 100:1 compression ratio per archive page;
- only ordinary JPG/JPEG, PNG, WebP, or GIF image entries using supported ZIP
  compression, within the same safe decoded-dimension limits; and
- no encrypted entries, symbolic links, special filesystem entries, duplicate
  or traversal paths, mismatched extensions/signatures, or failed CRC checks.

Archive paths are never reused as output paths. Verified pages receive generated
names in app-private storage. Temporary archive/partial files are cleaned up;
individually verified completed pages may be retained after a pause, failure or
interruption so a compatible retry can reuse them. Cancellation/removal cleans
up the cancelled download's local page data.

The queue runs transfers sequentially, with a default maximum of 100 queued/active
jobs and a 4 GiB managed manga-download quota in addition to per-chapter limits.
The Downloads page exposes pause, resume/retry, cancellation and removal. The
chapter sheet also offers bounded batches of the next 5 or 10 unread chapters.
Queue/storage errors ask the viewer to finish queued work or free storage.

An active manga download uses Android's best-effort foreground download lease.
It may continue while TetoTV is minimized, but force-stop or process death ends the
transfer. Job state and verified page records are durable; raw page/archive URLs,
headers and tokens are not. Opening the app recovers interrupted jobs without
automatically starting fresh source requests. Explicitly resume a job or retry
pending interrupted work. A paused job stays paused until individually resumed.

The Seanime resume resolver checks the active profile's saved title identity,
enabled provider and matching chapter IDs, then discovers fresh page capabilities.
Existing retained pages are reused only when the request fingerprint still
matches and their hashes/files validate; changed or expired capabilities may
require downloading pages again. A missing identity or unavailable provider
requires reconnection/reselection. The current automatic capability resolver is
Seanime-specific; legacy downloads remain readable, but a legacy interrupted
transfer can require reopening its original catalog/publication and downloading
again rather than using that resolver.

This is not a scheduled or server-side transfer service. Completed verified pages
remain readable offline until removed, app data is cleared, or TetoTV is
uninstalled. Availability after a provider changes or disappears is not promised.
