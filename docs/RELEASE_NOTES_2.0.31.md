# TetoTV 2.0.31 Beta

This beta restores QR pairing across devices, makes the initial setup choices clearer, and fixes title-logo loading.

## What's changed

- QR codes are available again on both phones and TVs for account, debrid, Discord, source, and support pairing flows.
- Initial setup now clearly offers **Setup on device** or **Setup on another device**, with a short explanation of each option.
- Fixed AniZip metadata responses that were sometimes returned as JSON text or bytes, preventing supported anime title logos from appearing.
- Cleared stale failed-logo cache entries so previously missed logos are retried after updating.
- Language-aware logo selection and properly scaled text fallback remain in place.
- Malformed or unexpectedly large logo metadata responses are rejected safely.

## APK integrity

- `TetoTV-v2.0.31-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `0c8a88b1382f039a0fadc6d9accadd4114bbf4602ea791d3f368daffd43e29c4`

## Beta notes

- If **Settings > System** still shows Official 1.0.4 as the latest version, choose the **Beta** update channel once and check again. No reinstall is required.
- Clear-logo artwork is not available for every title. When suitable artwork cannot be found, TetoTV continues to show the title as text.
- This is a Beta-channel build with Android build code `410008`. Android will not install the current Official 1.0.4 build over it. A later official build with the same or a higher build code can restore normal channel switching.
