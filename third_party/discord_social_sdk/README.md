# Discord Social SDK

TetoTV uses the official Discord Social SDK for optional, user-authorized Rich
Presence on Android TV, Fire TV, and Android phones.

- Version: `1.10.18369`
- Release date: 2026-08-04
- Upstream archive: `DiscordSocialSdk-1.10.18369.zip`
- Authorized local Android artifact: `android/app/libs/discord_partner_sdk.aar`
- AAR SHA-256: `85A5B0C9B2B828C84D27A7D7839D834BD7DAC323895A691E2A19E056543D2FAA`
- Application ID: `1536801401710055474`
- Rich Presence app-icon asset key: `tetotv_app_icon`

## Rich Presence artwork

Discord does not read the Android launcher icon from the APK. The TetoTV
Discord application therefore has `assets/branding/tetotv_icon.png` uploaded
under **Rich Presence > Art Assets** with the exact key
`tetotv_app_icon`. `discord_rich_presence.cpp` sends the current show's public
HTTPS artwork as the activity's large image and this key as the small TetoTV
badge. When show artwork is unavailable or invalid, the app-icon key is used as
the large-image fallback.

The portal key and native key must remain identical. If the portal asset is
removed or renamed, Discord displays a placeholder/question-mark image until
the matching asset exists and its cache refreshes.

The proprietary SDK archive and Android AAR are not committed or distributed
with TetoTV's source. An authorized developer must obtain the pinned SDK from
Discord after accepting the Discord Social SDK Terms, then place its Android
AAR at `android/app/libs/discord_partner_sdk.aar`. Gradle verifies the pinned
SHA-256 above before any build so a missing or substituted SDK fails closed.
Official private release automation may supply the same reviewed AAR
from protected artifact storage. The feature remains disabled until a user
explicitly links a Discord account.
