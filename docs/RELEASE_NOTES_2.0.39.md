# TetoTV 2.0.39 Beta

This beta simplifies first-time phone setup while strengthening how linked accounts and preferences are transferred to TetoTV.

## What's changed

- Phone setup now guides users through official sign-in or linking flows for AniList, MyAnimeList, Real-Debrid, TorBox, AllDebrid, Premiumize, and Discord, then returns them to one TetoTV setup page.
- The setup bundle is encrypted end to end for the paired app. Credentials are never placed in the QR code, URL, browser storage, logs, or diagnostics.
- Imported accounts, sources, and preferences now apply as one transaction. If any step fails, TetoTV restores the previous configuration instead of leaving a partial setup.
- Account-link credentials expire from the broker within one hour; resumable non-secret setup choices may remain available for up to seven days.
- Existing version 1 setup pairings remain compatible.
- Premiumize uses its official device authorization flow when the server has a Premiumize client ID configured, with a secure manual API-key fallback otherwise.

## APK integrity

- `TetoTV-v2.0.39-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `e07fc33a60374c653a4af308f4900816d423d264fb91c1c1e23ee96b88bda43c`

## Beta notes

- This is a Beta-channel build with Android build code `410016`.
- Android does not permit an in-place install over an APK with a higher build code; future Public counterparts must use build code `410016` or newer for data-preserving switching.

<!-- tetotv-android-version-code: 410016 -->
