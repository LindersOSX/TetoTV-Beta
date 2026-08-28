# TetoTV 2.0.28 Beta

This beta restores the proven 2.0.25 TV navigation behavior, refreshes Home with a clearer cinematic featured experience, and adds a phone-optimized layout without changing the TV experience.

## What's changed

- Navigation-bar selections now open their destination and place focus on the first useful page control again. Press Right while browsing the rail to enter the current page manually.
- Settings is anchored at the bottom-left of the TV navigation rail, separated from the main destinations while keeping predictable Up/Down movement.
- Home now keeps Search and the active profile switcher together at the top-right. The profile control appears whenever a tracker or local profile is available.
- The featured area has a full-width cinematic layout with rating, year, format, episode count, duration, status, genres, description, and dedicated **Watch now**, **My List**, and **More info** actions.
- Featured titles use a safe transparent title logo by default. TetoTV requests artwork matching the user's English or Romaji title preference, scales it within a fixed boundary, and falls back to the matching text title when no suitable logo is available.
- Featured actions use an explicit TV focus graph: Left/Right moves between actions, Up reaches the Home header, Down reaches the first shelf, and returning restores the prior action.
- Android phones now use the same TetoTV theme and features with responsive spacing and touch targets. Portrait phones use a persistent bottom navigation bar, while landscape phones move navigation to the left rail.
- Home, Search, Discover, My List, Calendar, Downloads, Watch Party, local-media, Settings, setup, show details, source selection, and the player HUD have phone-size layout coverage in both orientations.
- First-time setup now starts with a choice between completing setup on the TV or pairing a phone. Phone setup can transfer reviewed preferences, source URLs, and optional account credentials to the TV using end-to-end encryption.
- Phone pairing is resumable without leaving readable credentials on the setup service. Codes are one-time, sessions expire, the TV verifies the paired encryption key, and the final setup must still be reviewed on the TV before it is applied.

## APK integrity

- `TetoTV-v2.0.28-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `d1c5c0b3b792abbcb0543c7437e5c2ade31fe04e9ac7308d6783b44f0ae95db8`

## Beta notes

- Clear-logo availability varies by title and artwork provider. A missing or unsafe logo never blocks Home; the selected-language text title is used instead.
- Fanart.tv fallback coverage is available only in builds configured with that service's API key. AniZip artwork and text fallback remain available without it.
- Phone setup requires the official HTTPS TetoTV setup service. Account and debrid device-authorization flows inside the app remain available when users prefer not to enter credentials on the phone setup page.
- This is a Beta-channel build with Android build code `410005`. Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.
