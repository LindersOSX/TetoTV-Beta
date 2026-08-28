# MPV player HUD contract

TetoTV uses one Flutter-backed MPV player and one shared `TetoPlayerChrome`
HUD. Keeping a single playback engine removes engine-specific navigation and
fallback behavior while preserving the TV-first control contract below.

| Contract | MPV behavior |
| --- | --- |
| Control order | Back, Previous episode when available, Play/Pause, Forward, Audio, CC, Picture, Sources when applicable, Watch Party, Options, Next episode when available |
| Action-to-progress spacing | 18 dp (15 dp compact) |
| Progress and elapsed/duration | Accent progress with elapsed/duration footer; a debounced MPV scene preview follows the active scrub position |
| Auto-hide | 5 seconds in playing and paused states |
| Early dismissal | D-pad Down or tap |
| Reveal/focus | First directional press reveals the HUD and focuses Skip Intro/Outro when available, otherwise Play |
| Keyboard/gamepad shortcuts | J/L seek, K play/pause, S captions, Menu/M/Y options |
| Audio and CC unavailable state | The picker explains when tracks are unavailable |
| Icons and TV focus | Rounded Material glyphs; 3 dp Teto-red ring/glow with dark inner keyline, 1.025 scale over 80 ms |
| Skip segment | Separate translucent overlay that receives priority focus while available |

Sources remains conditional. MPV creates seek-preview screenshots while touch
or D-pad scrubbing rests on a position, discards stale frame requests, and
anchors the newest frame above the active seek thumb. MPV uses libass for
styled subtitles. Track pickers restore focus to the control that opened them.
