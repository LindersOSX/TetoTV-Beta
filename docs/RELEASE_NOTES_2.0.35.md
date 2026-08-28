# TetoTV 2.0.35 Beta

This beta makes TV navigation more predictable, tightens the Home layout, and fixes dual-audio provider results in the source picker.

## What's changed

- Settings content now returns Left to the active Settings icon on the side navigation bar.
- Home opens with Search focused on TV and other side-rail layouts; Down moves into the featured controls.
- The TV search bar and featured area are shorter so more Home content remains visible without crowding the header.
- Navigation and logo size preferences now update every side-rail layout, including landscape phones and devices that report a generic landscape class.
- In Customize settings, Down from Title language now reaches Show title style in order.
- Reset appearance and navigation no longer jumps to the navigation bar when Down is pressed; Left remains the explicit exit.
- Add-ons that report Both or dual audio now appear under All, Sub, and Dub. Structured English/Japanese audio metadata and matching Sub/Dub results are recognized without treating subtitle language as dubbed audio.
- Sub-only and Dub-only provider results remain exclusive to their correct filters, and automatic source selection uses the same audio rules as manual filtering.
- Playback now carries structured provider episode identity through source selection, launch, pre-cache, source switching, and fallback. Trustworthy episode fields override misleading server labels; confirmed wrong episodes or seasons are skipped, while genuinely ambiguous and translated labels remain playable.
- Multi-file Debrid and direct-torrent releases now prefer the file that explicitly matches the requested season and episode, including later seasons stored with absolute numbering, even when an add-on supplied a different preferred file index.
- Technical decimals and extras such as samples, NCOP, and NCED are no longer mistaken for requested episodes, and rejected prepared streams are closed cleanly.
- The TV player HUD now uses the compact reference layout: title on the left, engine/source badges on the right, transport and time on one row, utility controls grouped to the right, and the scrubber along the bottom.

## APK integrity

- `TetoTV-v2.0.35-AndroidTV-FireTV-ARM32-ARM64-universal.apk`
- SHA-256: `bec572a657054fd1e2da68f41e4a910eaebfe61d57fc32c2870107863e29da64`

## Beta notes

- This is a Beta-channel build with Android build code `410012`.
- Android does not permit an in-place install over an APK with a higher build code; future Public counterparts must use build code `410012` or newer for data-preserving switching.

<!-- tetotv-android-version-code: 410012 -->
