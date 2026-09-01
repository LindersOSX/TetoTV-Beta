# Manga repositories

TetoTV's Manga Preview is hidden unless Developer Mode is enabled. It can read
user-added OPDS 1.x Atom feeds, OPDS 2.0 JSON feeds, or the data-only TetoTV
manga repository format described below. It does not execute repository code,
load Android APK extensions, or provide a default catalog.

This document describes technical compatibility. It is not a review of a
catalog's safety, content, availability, terms, or legality. A viewer should
add only services and material they are authorized to use.

## Supported source boundary

- Every repository, OPDS, redirect, cover, page, and acquisition reference
  must use a credential-free public HTTPS URL. URLs containing embedded
  usernames/passwords, local hostnames, or private/loopback/link-local IP
  destinations are rejected.
- Repository documents are limited to 2 MiB, 128 declared sources, bounded
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
- Redirect limits describe TetoTV's current Developer Preview behavior, not a
  promise that every conforming OPDS server or acquisition will be compatible.

## Declarative repository schema version 1

The repository is a UTF-8 JSON document. This complete example uses reserved
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

## Authentication declarations

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

## OPDS behavior

TetoTV uses OPDS navigation and acquisition relationships supplied by the
configured server. OPDS 1.x must be a valid Atom feed in the Atom namespace;
OPDS 2.0 must provide valid JSON metadata and bounded publication, navigation,
group, facet, and link arrays. Relative links are resolved against the feed's
final validated HTTPS URL.

Support for a declared capability means only that TetoTV understands the
corresponding data shape. It does not guarantee that every OPDS server exposes
that operation or that every acquisition format can be displayed or saved.

## Reading and compatible chapter downloads

TetoTV can read bounded public HTTPS image resources from an OPDS reading
order. Compatible downloads can use those image resources or a ZIP/CBZ
acquisition selected from the publication. Source credentials are loaded from
protected storage only for the current operation and only for the exact source
origin.

The archive boundary is intentionally strict:

- at most 1,000 image pages and 2,000 total ZIP entries;
- at most 20 MiB per page and 512 MiB total downloaded/uncompressed chapter
  data;
- a maximum 100:1 compression ratio per archive page;
- only ordinary JPG/JPEG, PNG, WebP, or GIF image entries using supported ZIP
  compression, within the same safe decoded-dimension limits; and
- no encrypted entries, symbolic links, special filesystem entries, duplicate
  or traversal paths, mismatched extensions/signatures, or failed CRC checks.

Archive paths are never reused as output paths. Verified pages receive
generated names in app-private storage, while temporary archives and partial
files are removed after completion, cancellation, or failure.

An active manga download uses Android's best-effort foreground download lease
so it can normally continue when TetoTV is minimized. It is not a scheduled or
server-side job. TetoTV deliberately does not persist the remote page/archive
URL or request headers, so force-stop or process death ends the transfer and
the interrupted job requires the viewer to reconnect or reselect the source
before retrying. Completed verified pages remain readable offline until the
viewer removes them, resets app data, or uninstalls TetoTV.
