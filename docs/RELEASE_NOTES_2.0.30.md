# TetoTV 2.0.30 Beta

This beta polishes the Home header and featured banner, simplifies appearance settings, improves phone-specific pairing, and fixes Beta update and title-logo reliability.

## What's changed

- The TV Home header keeps the active profile picture, username, and dropdown chevron beside Search. Phones keep the compact picture-only control.
- The featured banner keeps **Watch now** and **My List** and no longer shows **More info**.
- The retired manual Screen layout choice is removed. TetoTV selects its TV or phone layout from the device, while **Theme Studio** now has a clear entry in Display settings.
- Pairing and community screens no longer show QR codes on phones. They provide direct secure browser actions instead; TV QR flows are unchanged.
- Fresh 2.x Beta installations now select the Beta update feed when no channel preference has been saved, avoiding an attempted download of the older Public build.
- Title-logo downloads retry temporary CDN failures and alternate safe network addresses, reject truncated artwork, and clear stale failure caches. Language-matched text remains the fallback when artwork is unavailable.
- Secure phone setup no longer asks viewers to choose an interface mode; new setup bundles use the device-aware Automatic layout while old bundles remain compatible.

## APK integrity

- `TetoTV-v2.0.30-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `4f785bce028b927a3116ec9166e76d0125ca7f5f2161e49cbb6e1f5b38265312`

## Beta notes

- Viewers already on a 2.0.28 build that saved the Public update channel must choose **Beta** once under **Settings > System > Update channel**, then select **Check for updates**. No reinstall is required.
- Clear-logo coverage varies by title. Fanart.tv requires a project API key at build time; AniZip artwork and language-matched text fallback remain available without one.
- This is a Beta-channel build with Android build code `410007`. Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.
