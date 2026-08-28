# TetoTV 2.0.27 Beta

This beta makes remote navigation more predictable and tightens downloads, web skipping, and external-player handoff.

## What's changed

- The navigation bar now keeps focus on the selected destination. Press Right to enter the page, and key headers and settings rows use predictable D-pad paths without trapping focus.
- A shared TV navigation contract now covers navigation-bar entry, text-input exits, visible focus, held-key handling, and focus restoration after returning from another screen.
- Settings sections for source and quality priority are collapsible, their rows move in sequence, and several Streaming, Tracking, Customize, My List, Discover, Airing, and Downloads focus routes have been corrected.
- **Download season** is back beside Watch trailer, Cast & crew, and Related series. The season-start message closes after five seconds.
- Downloads can now be turned off from Settings. The option is on by default; turning it off hides download actions, the Downloads navigation destination, and offline-copy source entries without deleting saved files.
- Completed downloads can be matched by stable catalog IDs or the exact normalized public show title, so an existing local copy can still appear after catalog metadata changes.
- Web-stream intro and outro lookup can recover when a provider reports a runtime that differs slightly from the episode's reference duration.
- External players receive web streams through TetoTV's temporary local proxy handoff, allowing players such as MX Player to open sources that require TetoTV-managed request headers.

## Beta notes

- Source and provider support still determines whether an episode or full season can be downloaded.
- Turning Downloads off hides the feature but keeps existing files and queue data for when it is enabled again.
- Intro and outro markers are not available for every episode. TetoTV only shows or applies a skip when a valid marker is found.
- External players do not provide TetoTV's Watch Party, skip, fallback, or progress controls while the other app is open.

This is a Beta-channel build with Android build code `410004`. Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.

APK SHA-256: `6b061a23125dda2e72c2f2cf1d9ab5fd2757ead188b9f7526dc7afc7e695924e`
