# Marketplace extension compatibility

TetoTV accepts compatible user-supplied online-stream extensions without
assuming one repository layout or hard-coding a provider identity. Catalog
compatibility is intentionally separate from provider health: a catalog can
parse successfully while its user-configured service is unavailable or its
extension needs an update.

TetoTV does not ship, suggest, index, recommend, or endorse a marketplace
repository, provider extension, or media source. Automated tests do not contact
live third-party catalogs. Users must add their own HTTPS repository and may use
an extension only with services and media they are authorized to access.

## Synthetic schema fixtures

The compatibility suite uses local, synthetic fixtures with reserved
`.example` hosts. They cover:

- A direct catalog array with advisory working, broken, deprecated, and
  last-working-version fields.
- A direct catalog array without advisory status fields.
- Catalog and manifest identifiers that differ only by letter casing.
- Plugin and custom-source entries that must not be presented as online-stream
  extensions.
- English and Spanish locale metadata for language filtering and sorting.

The fixture names, descriptions, authors, identifiers, and URLs are invented
for tests. They do not identify, mirror, or connect to a real provider or
repository.

## Compatibility checks

Installed and enabled extensions can be checked when their last compatibility
result is stale. A remote-friendly **Test all** action in Marketplace can run
the same checks on demand. Each check records a bounded result for five visible
stages:

1. Search
2. Title matching
3. Episode lookup
4. Server lookup
5. Stream extraction

Marketplace cards show a health score, last-tested date, stage results, and a
sanitized reason when a stage fails. Scores describe only technical behavior;
they are not an endorsement, safety review, legality determination, or promise
that any media is available. Tests never include tracker credentials,
private-library addresses, playback history, or a user's search text.

## Supported schema surface

- Canonical arrays, bounded named wrappers, and bounded ID-keyed catalogs.
- Relative resource URLs and common manifest, payload, type, and language
  aliases.
- Casing-only ID drift between a catalog and its manifest.
- Manifest wrappers and catalog-only executable fields when the manifest omits
  optional summary metadata.
- Advisory working, broken, and deprecated metadata. When multiple repositories
  contain the same ID, a maintained candidate wins over an explicitly broken
  one; an installed extension remains owned by its original repository.
- Current structured search and media objects, legacy string search, bounded
  result wrappers, common result, episode, and source aliases, and up to eight
  ranked title candidates before returning `NO_MATCH`.
- A bounded interoperability implementation of the documented scanner utility
  contract, invocation-local storage, and the existing DOM, request, Buffer,
  cryptography, URL, sleep, and HLS bridges.

## Trust and resource limits

Compatibility adapters do not relax executable trust or network safety.
Catalogs, manifests, payloads, wrapper depth, entry counts, JavaScript heap and
runtime, request count, concurrency, response bytes, redirects, and returned
streams remain bounded. Repository, manifest, payload, request, subtitle, and
stream targets must use public HTTPS; DNS is validated and socket connections
are pinned to the validated public address. A repository with the same provider
ID cannot silently replace code installed from a different repository.

Provider diagnostics record only bounded IDs, versions, hosts, health counts,
last-tested timestamps, stages, and reason enums. Full URLs, search queries,
response bodies, cookies, credentials, and raw third-party exception text are
excluded.
