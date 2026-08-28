# TetoTV 2.0.33 Beta

This beta makes Home search direct and reliable, and makes season identity clear when title artwork only shows a franchise name.

## What's changed

- The Home header search is now a real text field instead of a shortcut. Enter a query there with either the Teto keyboard or the device keyboard and TetoTV opens the matching Search results.
- Search submissions preserve spaces and symbols, dismiss the keyboard cleanly, and no longer let the background Home field reclaim focus.
- TV D-pad movement around the Home search is predictable: Left returns to the navigation rail, Right moves to the profile switcher, and Down enters Home content. While the device keyboard is open, its arrow-key editing remains intact.
- The TV search pill has corrected proportions and icon spacing, while phone and landscape-phone layouts retain compact sizing.
- Anime detail pages now show a concise season, final-season, part, cour, or special label beneath a title logo when the logo itself does not identify the selected entry.
- Season labels use relationship-aware title matching so standalone titles and numbered names are not incorrectly labeled.

## APK integrity

- `TetoTV-v2.0.33-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `4117a173dffe2edc85fe9bbc6135ca9f208995e60132d7c721db2bb7ffa3e3a5`

## Beta notes

- This is a Beta-channel build with Android build code `410010`.
- Android does not permit an in-place install over an APK with a higher build code; future Public counterparts must use build code `410010` or newer for data-preserving switching.
- If title artwork is unavailable, TetoTV continues to use the configured-language text title.

<!-- tetotv-android-version-code: 410010 -->
