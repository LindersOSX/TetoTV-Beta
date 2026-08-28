# TetoTV 2.0.29 Beta

This beta polishes first-time setup, Home controls, and empty-screen TV navigation while keeping the established 2.0.25 rail behavior.

## What's changed

- Empty Calendar and Downloads screens now let **Left** from **Refresh** return to the navigation rail.
- Classic layout is disabled. Existing Classic preferences migrate safely to Automatic, which keeps the current TV layout on televisions and the adaptive layout on phones.
- The Home search field is taller and its search icon has balanced spacing. TV keeps the active profile picture, username, and chevron to its right; phones keep the compact picture-only profile control.
- Featured and detail title logos prefer artwork matching the selected English or Romaji title language, remain inside fixed layout bounds, and fall back to the matching text title when artwork is missing or unavailable.
- First-time setup lets users choose TV or phone setup, return to that choice without losing progress, and regenerate an expired or unwanted phone pairing code.
- Phone setup can request Discord linking without transmitting a Discord password or token. TetoTV completes the request through Discord's existing device-authorization screen after the encrypted setup is applied.
- The TV customization step now moves Down from Watch Party or Downloads directly to **Continue**.
- Temporary title-logo CDN connection resets no longer create misleading anonymous crash reports or interrupt the interface; the normal text-title fallback remains visible.

## APK integrity

- `TetoTV-v2.0.29-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `726356683136f3eef593452708e05f073afdae0c78f67bf81d52c2c5f25433ab`

## Beta notes

- Clear-logo coverage varies by title and artwork provider. Fanart.tv fallback is used only when the build is configured with that service's API key; AniZip artwork and text fallback remain available without it.
- Phone setup uses a one-time pairing code, end-to-end encryption, a TV-side review, and resumable expiry handling. The hosted setup service never receives readable account credentials.
- This is a Beta-channel build with Android build code `410006`. Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.
