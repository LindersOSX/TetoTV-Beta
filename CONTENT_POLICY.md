# Content and source policy

TetoTV is an open-source media library, playback, and tracking client. This
repository contains application source code and release engineering material;
it does not host, index, mirror, supply, recommend, or endorse copyrighted
media, provider credentials, streaming catalogs, torrent indexes, or
preconfigured media sources.

## Repository boundary

- No third-party media provider, catalog, manifest, credential, or default
  source is bundled or preconfigured.
- Documentation and automated tests use synthetic names and reserved
  `.example` hosts rather than live third-party streaming catalogs.
- User-supplied extensions are untrusted third-party code. Technical
  compatibility is not a safety review, legality determination, endorsement,
  or promise of availability.
- The Developer Mode Manga Preview accepts user-added public HTTPS OPDS
  1.x/2.0 catalogs, a declarative TetoTV repository that points to OPDS
  catalogs, or a user-installed Seanime-format manga-provider extension from
  a Marketplace repository entered by that viewer. TetoTV does not bundle,
  recommend, rank, mirror, or maintain manga catalogs, providers, repository
  URLs, chapter archives, page images, or title indexes.
- A TetoTV manga repository is metadata, not executable code. It cannot embed
  credentials or install Tachiyomi/Mihon APK extensions. A manga-provider is
  separately disclosed as untrusted JavaScript/TypeScript and runs within the
  same bounded public-HTTPS extension boundary used by Marketplace providers.
  Compatibility with any repository, extension, or OPDS server is not a
  content review or endorsement.
- Manga catalog requests go directly to the public HTTPS source selected by
  the viewer; page and chapter-archive requests go to public HTTPS resource
  hosts declared by that source. No TetoTV-operated service proxies, caches,
  or receives that manga media. Completed compatible downloads remain only in
  the app's private device storage.
- Users and downstream distributors are responsible for using only services
  and media they are authorized to access, play, copy, or download.
- TetoTV does not operate a media proxy or receive video/audio bytes through
  its setup, Watch Party, diagnostics, or update services.

Contributions that add pirated media, access credentials, live infringing
indexes, circumvention material, provider promotion, or instructions whose
purpose is unauthorized access will not be accepted.

## Rights, names, and affiliation

TetoTV is independent and unofficial. Third-party product names and marks are
used only to identify optional interoperability and belong to their respective
owners. No affiliation, sponsorship, or endorsement is claimed.

The MIT License covers TetoTV-authored software source. It does not replace the
separate licenses, notices, service terms, character guidelines, or branding
permissions identified in `docs/THIRD_PARTY_NOTICES.md`. In particular, the
Kasane Teto attribution and official character-guideline requirements remain
separate from the software license.

## Reporting a rights or content concern

For a repository-specific concern, open a GitHub issue that identifies the
exact file, release asset, or URL and the requested change. Do not put private
personal information, credentials, or confidential legal material in a public
issue. Those matters can be raised through GitHub's applicable content-removal
process at:

<https://docs.github.com/en/site-policy/content-removal-policies/submitting-content-removal-requests>

Security vulnerabilities must be reported privately as described in
`SECURITY.md`, not through a public issue.

This policy is an engineering and contribution boundary, not legal advice or a
guarantee against third-party complaints.
