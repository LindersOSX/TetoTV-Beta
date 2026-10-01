# Next TetoTV Beta — draft, not published

## What's new

- Added Spanish, Portuguese, French, Hindi and German menus, with a language picker during setup.
- Your language choice also sets preferred audio and subtitles. You can still change them separately.
- Home hero/sponsor banners always show text titles in every language.
- App language changes interface text without changing show-title selection or the keyboard layout.
- Title Language independently chooses English or Romaji show titles. Title-logo mode uses matching artwork where available, including explicitly English-tagged logos for English, and otherwise falls back to the selected text title.
- Language names stay recognizable, and Back during setup returns to the language picker.
- Fixed remote navigation between Manga tabs and through the Sources page.
- Cleaned up dark-color highlights and made update notices on TV and Discord shorter and easier to read.
- Improved troubleshooting details for crashes and manga pages, with keyboard input kept out of the new diagnostic trail.
- Organize your manga library with categories, reading status, filters and chapter-update checks.
- The core Manga reader is available without Developer Mode, starts enabled, and asks during setup whether to keep it enabled, with an option in Settings to hide and disable the reader without deleting its local data. Disabling it pauses Manga downloads and tracker delivery; downloads resume only when requested.
- Resume downloaded manga offline, bookmark chapters, and zoom or pan pages with a TV remote.
- Added encrypted manga backups and optional AniList/MAL reading-progress tracking.
- Discord can now show the book cover while you read. Hiding the title also hides the cover.
- Added optional Aniyomi experiments in Developer Mode for supported anime and manga extensions. Aniyomi compatibility and its reader paths remain Developer Mode-only; core Manga does not require Developer Mode.
- Fixed an optimized-build issue that prevented installed Aniyomi extensions from loading, and added clear source-readiness status and retry controls.
- Improved Aniyomi searches with multiword titles and support for larger provider pages. Failed requests now retain clearer, privacy-limited troubleshooting details.
- Extensions that require an unsupported private streaming server now explain that limitation instead of showing a generic compatibility error. Installing an extension does not guarantee that its website or extractor is working.

## Developer notes

This is customer-copy preparation only, not authorization to publish. Before a
release, use the normal versioning, verification, license disclosure, source
bundle and signing process. Keep its machine-readable integrity metadata intact
on GitHub; the short Discord/TV display does not replace those checks.

AI tools assisted with development and testing. The project owner remains
responsible for the release. Translation nuance and actual-device acceptance
testing remain appropriate before a wider rollout.
