# Build 132 readiness: Classic Vinyl Radio player

Version 1.0.132 (132), iOS only, on `kyro/ios-recovered`. Builds on physically accepted Build 131 (`2b06e11112b6eff34b08c32c6a448bfe3cc294a7`). Not packaged, not pushed, not device-tested.

## What changed

The expanded Radio Now Playing sheet is now a vintage turntable in two themes, **Crimson Noir** (default) and **Classic Walnut**. Both themes share one layout and one set of components; `KyroRadioPlayerPalette` supplies each theme's colours and finishes.

### Files
- `Kyro/Radio/KyroRadioPlayerTheme.swift` (new, host-testable):
  - `KyroRadioPlayerTheme`.
  - `KyroRadioPlayerAppearance`, the observed theme store under `kyrox.radio.playerTheme.v1`. Unknown or missing values mean Crimson Noir.
  - `KyroTurntableMotion`, the pure rules from playback state to platter, tonearm and lamp.
- `Kyro/Radio/KyroRadioTurntable.swift` (new): palette, cached textures, the Core Animation record, tonearm, deck, hardware controls, the new `KyroRadioNowPlayingView`, and the theme preview tiles with the Player Appearance section.
- `Kyro/Radio/KyroRadioViews.swift`: the old Now Playing view and its route picker are removed. Radio Settings now starts with Player Appearance. The sheet presentation (`KyroRadioNowPlayingPresentation`, large detent, drag indicator) is unchanged.
- `Kyro/Radio/KyroRadioBackupSettings.swift`: new `radio.playerTheme` entry.

### Turntable
| Playback state | Record | Tonearm | Pilot lamp |
|---|---|---|---|
| Playing | Spins up to 33⅓ rpm over 1 s | In the grooves | Lit |
| Connecting / reconnecting | Still (no audio yet) | Cued over the lead-in | Blinking |
| Paused / stopped | Coasts to a stop over 2.4 s | Returns to rest | Off |
| Failed | Still | Rest | Red fault |

- **Record:** a black disc with concentric grooves, track-gap bands, a rolled rim and a run-out ring. It sits on a metal platter with a knurled edge, under a fixed (non-rotating) light sheen and the spindle.
- **Label:** the station's real logo, its name and "INTERNET RADIO", composed on the theme's label colour. A station without a logo gets a radio-mast glyph.
- **Tonearm:** counterweight, S-shaped tube, offset headshell, cartridge and finger lift, on a static base. It swings about its pivot with a spring.
- **No invented data:** no track progress, waveform, or skip, shuffle or repeat controls. Live radio provides none of them.

### Controls
- **Information panel:** station logo, status kicker (LIVE RADIO / CONNECTING / RECONNECTING n/3 / PAUSED / UNAVAILABLE), LIVE badge, station name, the stream's real song and artist (or the station's location), codec and bitrate, the error message, and Save to Library.
- **Buttons:** machined Stop (stops and closes, as before) and a large metal Play/Pause knob (Try Again after a failure, a spinner while connecting).
- **Header:** Close, the existing Kyro X wordmark with "INTERNET RADIO", and the system AirPlay/Bluetooth output picker.
- **Volume:** the system volume slider (`MPVolumeView`) with a themed track and knob, plus "Playing on <output>" from the live audio route.

### Player Appearance (Radio Settings)
Two preview tiles, a miniature plinth, record and tonearm per theme, select the theme. The change applies at once, including on an open player, and never touches playback.

### Settings Backup
`radio.playerTheme` holds `"crimsonNoir"` or `"classicWalnut"`:
- **Older builds:** Builds 128–131 skip it as an unrecognized setting.
- **Older backups:** a backup without it leaves the theme unchanged (Crimson Noir on a fresh install).
- **Earlier entries:** unchanged IDs and order.

## Visual assets

Everything is drawn in code. There are no bitmap assets in the bundle and no new dependencies.

| Asset | How | When |
|---|---|---|
| Record grooves | Core Graphics, fixed-seed generator, off the main thread | Once per pixel size, cached |
| Walnut grain (background and plinth) | Core Graphics: wavy grain lines, figure swirls and a lacquer sheen, off the main thread | Once at 440×956 pt, up to 2×, cached |
| Record label | `UIGraphicsImageRenderer` with the station's logo (from Nuke's shared cache) | Once per station, theme and size, cached |
| Volume knob | Radial metal gradient | Once per theme, cached |
| Plinth, platter, screws, tonearm, buttons, lamp, badge | SwiftUI shapes and gradients; the tonearm is one `Canvas` | Drawn on change only |

## Performance

- **Rotation:** the record and label share one rasterized `CALayer` rotated by `CABasicAnimation`: an ease-in spin-up, a repeating revolution, and an ease-out coast. SwiftUI isn't involved per frame, and there are no timers, display links or `TimelineView`.
- **Lifecycle:**
  - The record only turns while the sheet is on screen in an active app.
  - Leaving the screen or the app removes its animations, freezing the record in place.
  - Dismantling the view removes them too.
  - The blinking lamp is the only other repeating animation, and it runs only while connecting on screen.
- **Reduce Motion:** the record holds still, the tonearm moves straight to its position, and the lamp doesn't blink.
- **Isolation:** the theme lives in its own observed store, read only by the expanded player and the Settings tiles.
  - The mini-player, the app-wide Now Playing slot and Home never read the theme or the turntable.
  - `KyroRadioPlayer`, the playback machine, discovery, library, the Now Playing slot, Home, Sports, Live TV and the shell are byte-for-byte unchanged since Build 131; the Build 132 script checks this with `git diff`.

## Validation

- `bash scripts/run-build132-host-checks.sh`: 62 checks passed.
  - **Theme:** default, persistence, unknown-value fallback.
  - **Backup:** round trip, validation and labels, plus compatibility with older backups.
  - **Motion:** every playback state, Reduce Motion, and lifecycle (dismissed, background, paused).
  - **Source contracts:** Core Animation only and no timers, dismantle freezes the record, no fake track controls or waveform, all working controls present, presentation unchanged, mini-player and Home isolation, Build 131 sports fix present.
  - **Protected files:** the git check above passes.
- Earlier scripts all pass: build131 (32, Mac host 41-card rail 256.5 ms eager vs 34.4 ms probed), build130 (81), build129 (43), build128 (107 + 20 + 101; its ID list now includes `radio.playerTheme`), build126 (34), build124 (42), build121 (132 + 20 + 101).
- Generic signing-disabled iOS Release compile (`Silo`, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, `SILO_BUILD_CHANNEL=sideload`): `** BUILD SUCCEEDED **` on the first attempt, no errors or warnings in Radio files; built `Info.plist` reports `com.cubbiestream.kyro`, `1.0.132`, build `132`.

## Device checks

1. Play a station and open Now Playing in each theme: the record spins up and the tonearm swings in; Pause coasts the record down and parks the arm.
2. Connect to a slow station: the arm is cued, the lamp blinks, the record is still. Then try a failing station: red lamp, arm at rest, error text, Try Again.
3. Switch themes in Radio Settings while playing: audio continues and an open player restyles.
4. Turn on Reduce Motion: no spinning or blinking.
5. Background the app, then return: the record resumes only while still playing.
6. AirPlay picker, volume slider, "Playing on …", Save to Library, Stop and Close all work.
7. Home scrolling with radio playing is unchanged from Build 131.
