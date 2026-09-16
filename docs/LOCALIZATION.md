# Interface languages

TetoTV supports English, Spanish, Portuguese, French, Hindi, and German for
app-authored interface text. English is the fallback for an unsupported locale
or a message that has not yet been translated. Translations are bundled in the
APK and do not send text to an online translation service.

## User experience

- On a fresh installation, the language screen appears before the setup/router
  content. Names are shown in their own language so they remain recognizable.
- Choosing a language saves the UI locale, sets preferred dubbed audio to that
  language, and enables CC with the matching preferred subtitle language.
- Home hero/sponsor banners and catalog cards use text titles selected by the
  independent **Title language** preference.
- **App language** translates app-authored interface text. It does not change
  **Title language**, the saved title style, canonical show/provider identity,
  the built-in QWERTY layout, or the device keyboard's input locale.
- **Title language** independently selects English or Romaji presentation for
  visible show titles across Home, Continue Watching, catalog/search, details,
  playback, and Watch Party. Provider searches, aliases, IDs, and shared room
  identity retain their canonical values.
- **Show title style** independently chooses title artwork or text on
  show-details/episode screens. Artwork must match **Title language**: English
  accepts explicitly English-tagged logos and Romaji accepts matching
  original/Japanese-tagged logos. Missing, untagged, or mismatched artwork
  falls back to the selected English/Romaji text title.
- Back from the setup-method choice reopens language selection and focuses the
  saved language without resetting it or changing audio/CC preferences.
- Settings > Appearance > Theme & display > App language changes the choice
  later and seeds those media defaults again, as explained in the picker.
- Audio and CC can subsequently be adjusted separately under Playback. Existing
  per-series manual preferences remain higher priority than global defaults.
- Automatic selection can only choose tracks a stream actually provides. It
  does not create translations, audio dubs, or missing subtitles.
- Existing installations bypass the first-run language screen and keep their
  existing media preferences. Existing English UI is retained until changed.
- App language is separate from the catalog's English/Romaji title metadata.
  Changing the UI locale does not translate show titles or initiate an AniZip
  title lookup. The bundled UI translations themselves still work offline.

Show-details pages make an optional localized-description lookup for a
supported non-English interface. TetoTV resolves the public AniList ID through
AniZip, then requests the matching language-specific public TMDB title page
using only the mapped public media ID and allowlisted locale. Mapping responses
are bounded to 8 MiB and page responses to 2 MiB. The AniList identity and page
language must match, and returned text is sanitized before display. Valid
descriptions are cached for seven days and missing translations for 12 hours.
An unavailable service, unexpected page format, invalid response, or missing
translation fails closed to the existing catalog synopsis; no machine
translation is invented and English skips this lookup entirely.

The language decision is recorded with the existing protected preferences
storage. Setup is marked as started before seeding new preferences so the
legacy setup migration cannot mistake a language choice for completed setup.

## Translation boundaries

Localize app-authored headings, controls, help text, status labels and full
sentences at rendering boundaries. Do not translate persisted enum IDs, route
paths, protocol values, focus/control keys, URLs, logs or user input.

Provider descriptions, track names, usernames, release notes, admin
announcements, external error payloads and legal documents retain their
original text. English/Romaji show-title metadata is selected by **Title
language**, while optional show-detail descriptions follow **App language**;
neither is rewritten through the UI message catalog. Hosted phone-setup HTML,
provider approval websites and native Android system prompts are separate
surfaces; this change does not localize the hosted companion. Technical
diagnostics can retain original wording.

Portuguese UI copy currently uses Brazilian phrasing under the general `pt`
locale. Regional audio/CC aliases are handled by the existing track selectors.
Human/native-speaker review is still useful for translation nuance.

## Maintaining messages

`lib/core/localization/teto_localizations.dart` integrates with Flutter's
`Localizations` and Material/Cupertino delegates. Feature catalogs live under
`lib/core/localization/catalogs/`.

Use `context.tr('Message')` or the const-friendly `LocalizedText('Message')`
for app-authored copy. Use ordinary `Text` for external content.

Write complete messages with named placeholders, rather than concatenating
translated fragments or English plural suffixes:

```dart
context.tr('Episode {episode} has not aired yet.', {'episode': number})
```

Placeholder values are substituted once and never translated or interpreted.
Plural and date helpers use the selected locale. Uppercase static headings
reuse uppercase aliases of known messages; untranslated strings fall back
unchanged. Keep shared terminology consistent with `common_strings.dart` and
avoid creating conflicting translations of the same English key.

Catalog rows must cover `es`, `pt`, `fr`, `hi` and `de`. Unit tests check locale
coverage, placeholder parity, language defaults and changes, English fallback,
preserved metadata, shared MPV/Media3 controls and TV/mobile layout constraints.

Run from the repository root:

```text
flutter pub get
dart run tool/audit_ui_localization.dart --raw
flutter test test/ui_localization_test.dart test/settings_interface_language_test.dart test/playback_localization_test.dart
flutter analyze
flutter test
```

The read-only AST audit identifies untranslated literal `Text` messages and
missing literal catalog entries. It does not prove every dynamically assembled
message is covered; review helper-generated UI labels whenever adding features.
The explicitly allowlisted exceptions are brands, protocol/example strings,
technical units and copyright attribution.

Optional real-font settings captures:

```text
flutter test --dart-define=CAPTURE_LOCALIZATION=true test/settings_interface_language_test.dart
```

Captures are written under the ignored `build/localization-visuals` directory.
They supplement tests, not physical-device or native-speaker acceptance testing.

## Hindi font

`TetoDevanagari` is a UI font fallback; it does not replace the default Latin
typeface or change native playback rendering. The unmodified variable Noto Sans
Devanagari font was obtained from the official `google/fonts` repository:

- Commit: `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`
- Path: `ofl/notosansdevanagari/NotoSansDevanagari[wdth,wght].ttf`
- SHA-256: `9ce7b04f60e363d8870e5997744cf85cf69d38a4d7d129d364d92a3b14b461d7`
- License: SIL Open Font License 1.1, bundled as
  `assets/fonts/NotoSansDevanagari-OFL.txt` and registered in the app notices.

No release version is bumped and no publishing or companion deployment is
performed by this patch.
