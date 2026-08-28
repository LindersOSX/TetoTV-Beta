# TetoTV 2.0.26 Beta

This beta tightens offline viewing, player handoff, and TV navigation while fixing a crash found in the previous build.

## What's changed

- Downloads now have a default navigation-bar destination, and whole seasons can be queued from the episode screen.
- Active downloads keep running when TetoTV is minimized. Unfinished season batches are saved and continue after the app is opened again if Android had to stop it.
- Season files are stored in a predictable show, season, and episode structure. Completed episodes appear immediately as offline sources in the normal source picker.
- Download preparation handles Debrid rate limits without repeatedly retrying the same blocked request, and automatic season downloads can fall back to a compatible web source.
- External playback can be set to a specific installed player. TetoTV falls back to MPV if that app is later removed or cannot open the selected source.
- Show pages prefer English transparent title artwork when available. A Display setting switches between title artwork and normal text.
- Modern TV show pages use a larger 60%-height poster and rebalanced three-column layout so the artwork, details, and episode controls match the intended living-room design without overlapping.
- Calendar notifications can be enabled separately for Sub/simulcast and verified Dub releases. Sub alerts use the followed show's Calendar airtime and continue working while TetoTV is minimized; TetoTV does not guess Dub dates from the normal Japanese airing.
- Fixed a crash that could occur when opening the Download Manager from a season-download message after leaving the show page.
- Shared diagnostics now include a privacy-safe 48-hour summary of download outcomes. Credentials, media URLs, filenames, local paths, and private-server details are still removed.
- The player HUD uses the requested simple back arrow for rewind and stays visible while the viewer is navigating, scrubbing, or using a player control.
- Long-press actions now work on remotes that report a hold as rapid OK-button clicks. One physical hold produces one long-press action without clicking through the screen.

## Beta notes

- Source and provider support still determines whether an episode or full season can be downloaded.
- Android force-stop always ends app work. A saved season batch continues the next time TetoTV opens.
- Exact Dub alerts remain idle until TetoTV has a verified Dub schedule; regular AniList airtimes are never mislabeled as Dub drops.
- External players do not provide TetoTV's Watch Party, skip, fallback, or progress controls while the other app is open.
- Transparent title artwork is not available for every show, so TetoTV keeps the text title as a fallback.

This is a Beta-channel build with Android build code `410003`. Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.

APK SHA-256: `d06c2e0900d18b846f6f9570708ee2f8e10f4245e516f968722754287cdcf30f`
