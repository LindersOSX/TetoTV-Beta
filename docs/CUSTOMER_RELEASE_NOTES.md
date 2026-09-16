# Customer update notices

The TV post-install popup, Settings update details, notification bell and Discord
release/catalog messages show short customer highlights, not the raw GitHub body.

## Writing each release

Use one `## What's new` or `## Highlights` section with three to six short bullets.
Each bullet should describe a visible improvement, a fixed problem, or something
the customer needs to do. Aim for one sentence and no more than 180 characters.
Put any customer-facing limitations under `## Known issues` so they are retained.
The compact notification inbox uses up to three bullets of 140 characters.

For example:

```markdown
## What's new

- Added a Media3 rendering option in Settings → Playback for devices with choppy video. Results vary by device.
- Removed the small video preview while seeking. The time bubble stays.
- Your player controls and MPV settings are unchanged.
```

Do not put build codes, test results, signatures, dependency names, source ZIP
instructions or AI-development disclosures in these highlights. Keep the normal
install, source, licensing, disclosure and verification sections in the complete
GitHub release body. The customer summary does not replace any of those records
or update validation. Discord keeps links to the APK and full release notes.

Do not claim a fix or performance improvement that has not been established.
Legacy release notes are cleaned and bounded, not rewritten into invented fixes.
If no customer changes can be extracted, show an honest full-notes fallback.

## Unpublished implementation checkpoint — September 5, 2026

- App helper: `lib/core/updates/release_notes_summary.dart`.
- App bullet list and remote-scrollable popup: `lib/core/widgets/release_highlights.dart`.
- Companion helper: `Discord-Bot-fix/src/lib/release-summary.ts` in the sibling bot repository.
- Discord updates its matching bot-owned messages on normal synchronization once
  the companion is deployed; it does not delete or repost messages for formatting.
- No GitHub upload, companion deployment or live Discord edits were made for
  this change. The already-built September 5 APK predates these notice changes;
  a new APK is needed to include them. Do not present that earlier APK as updated.
- Verification: full Flutter suite 2,738 passed / 33 platform skips; analyzer
  clean; localization audit 0 missing / 0 untranslated literal messages.
  Companion type-check and all 242 tests passed. Both worktrees pass diff checks.
  App logs: `build/customer-release-full-tests.log` and
  `build/customer-release-analysis.log`.
