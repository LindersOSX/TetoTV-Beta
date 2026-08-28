# TV navigation contract

Every TetoTV screen must remain usable with only Up, Down, Left, Right, Select,
and Back. The shared contract is:

- Select on a navigation-bar destination opens that page and lets the page's
  normal first action receive focus, matching TetoTV 2.0.25. If focus is moved
  back onto the navigation bar, Right enters the page content again.
- Left moves through the current row before reaching the navigation bar. It
  must never jump across the page or become trapped on a text field.
- Up and Down follow the visual order. When focus changes, the selected control
  must be scrolled fully into view.
- Text inputs do not open a keyboard merely because they receive focus. Before
  editing begins, every applicable D-pad direction has an explicit exit. While
  the Android keyboard is active, cursor keys remain with the editable field.
- Pushing a details, dialog, or player route preserves the last valid focus in
  the page. Returning restores it unless that control was removed; the screen
  must then choose its nearest safe fallback.
- Configured semantic edges consume key-up without creating a duplicate move.
  Held directions intentionally keep moving in the new focus context; shelves
  and complex pages share a
  `TvDirectionalRepeatGate` so that movement is rate-limited and predictable.

## Shared implementation

- `TetoTopLevelShell` owns the Modern Layout navigation bar boundary and its
  visible first-action entry.
- `HomeSideNavigation` opens destinations without attaching a route-focus
  intent, so each page restores its normal content entry behavior.
- `TvTextInput` exposes `onExitLeft`, `onExitRight`, `onExitUp`, and
  `onExitDown` for deterministic keyboard-free navigation.
- `handleTvDirectionalFocusEvent` applies the same semantic edge to key-down,
  repeat, and key-up packets without moving again on key-up.
- `requestTvFocusAndReveal` is used for programmatic moves that Flutter's
  directional traversal cannot reveal automatically.
- `TvShelfFocusController` owns horizontal card-row memory, rapid-repeat
  handling, edge callbacks, and lazy-list reveal.

Prefer these primitives over screen-specific raw key handling. A screen still
needs a small explicit graph when geometry is ambiguous, such as a wrapped
filter row, a source picker header, or a list with a navigation-bar escape.

## Regression coverage

`test/tv_navigation_contract_test.dart` is the reusable contract suite. Screen
tests should use `test/support/tv_navigation_test_harness.dart` and add focused
regressions for their semantic edges, empty/loading states, dynamic row removal,
and off-screen focus restoration.
