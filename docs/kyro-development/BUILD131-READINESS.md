# Build 131 readiness: Home scrolling

Version 1.0.131 (131), iOS only, on `kyro/ios-recovered`. Builds on Build 130 (`f514e8d20da6d29091cd00f162ea92b963e03227`). Not packaged, not pushed, not device-tested.

## Evidence from the device recording

`ScreenRecording_11-26-2026 00-48-11_1.mp4`: 26.5 s, 1290×2796, constant 60 fps container (1,593 frames). Radio was not playing; Control Center at the end shows another app's podcast. So the stutter happens with radio stopped, and Build 130's radio work could not have fixed it.

Method: every frame decoded with AVFoundation and compared with the one before it on a sampled pixel grid. During fast scrolling (mean change above 8 on both sides), a frame that repeats the previous one is a frame the app did not deliver.

- 87 of 819 fast-scroll frames repeated (10.6%).
- The densest runs, two to four repeats within about 0.3 s (2.70–2.95 s, 5.82–6.05 s, 9.6–9.9 s), all happen during upward flings as **My Teams, My Leagues and Sports Today scroll back into view**. Stills at each repeated frame show those rails entering from the top.
- Single repeats also occur deeper in the feed, where only Silo poster rows are on screen (19–21 s). The recording alone can't attribute these; the diagnostics below are for that.

## Confirmed cause

Build 126 fixed sports-rail clipping (Build 125) by building every card of a sports rail in an eager `HStack` with `fixedSize`. A Home sports rail holds up to 40 cards (`KyroHomeSportsSelection.maximumCards`), and each card is a full Sports Hub card: two `ViewThatFits`, a `Grid`, two logos, minimum-scale text and the card chrome. Home's feed is a `LazyVStack`, which drops rows that leave the screen and builds them again when they return. So each time a sports rail scrolled back into view, all of its cards were built and measured in one frame.

The code is unchanged since Build 126, but its cost grows with the schedule. On Thanksgiving week the user's rails are full (NFL Week 12, college basketball tournaments, WTA, and favorites in My Teams and My Leagues), and three such rails sit at the top of Home.

Measured on the Mac host with SwiftUI and stand-in cards of the same structure: a 41-card rail takes a median of **264.5 ms** to build and lay out eagerly, versus **33.7 ms** with Build 131's rail (7.8× less). These are Mac numbers, not iPhone frame times.

Build 130's radio isolation, More menu equality and the shell were not the cause in this recording: radio was stopped, and the clusters follow the sports rails, not tab switches or playback.

## Correction

`KyroHomeRail.tallestCard` (`Kyro/Home/KyroHomeShelves.swift`):
- **Lazy cards:** the visible cards are in a `LazyHStack`, so only on-screen cards are built.
- **Height probe:** a hidden, zero-width `HStack` of probe cards, built eagerly with `fixedSize()`, sets the rail height. The stack and the scroll view take that height, so a later, taller card is never clipped.
- **Probe selection:** `KyroHomeSportsHeightProbe` (`Kyro/Home/KyroHomePreferences.swift`) groups cards by the lines they draw: status, NFL week, broadcast, wrapped context or tournament line, score and period row. It measures the two cards with the longest wrapped text in each group, typically 3–8 cards instead of 40. The quick-add card is part of the probe, so it still fills the rail.
- **Unchanged:** the same `KyroSportsGameRow` and `KyroSportsTennisMatchRow` cards, card width, tap, context menu, quick add, shelf order, artwork and channel rails.

## Device diagnostics (off by default)

Live TV Settings → Diagnostics → performance overlay (or `-kyroPerformanceOverlay`):
- **Per-section frame pacing:** `KyroPerformanceDiagnostics.section` existed since Build 104 but nothing called it. Home now reports as its own section in the tap-to-copy report.
- **New per-second counters on the overlay:** `home cards`, `probes`, `shell` (`MainTabView.tabLayout` passes) and `header` (`KyroAppHeader` body passes). On a smooth Home, `shell` and `header` stay at 0 while scrolling. Anything else points at shell invalidation, the remaining candidate for the single drops among poster rows.

## Validation

- `bash scripts/run-build131-host-checks.sh`: 32 checks passed.
  - **Layout:** reproduces Build 125 clipping with a lazy rail (107 pt vs a 163 pt card). The Build 131 rail matches the eager rail's height and every visible card's height, the quick-add card fills the rail, and only visible cards are built.
  - **Probe selection:** covers every card shape, keeps rail order, and stays well under 40 cards.
  - **Mac host timing:** recorded under Evidence above.
  - **Source contracts:** sports rail structure, unchanged cards, tap and context menu, diagnostics, the Build 130 corrections, and version 131.
- Earlier scripts all pass: build130 (81), build129 (43), build128 (107 + 20 + 101), build126 (34), build124 (42), build121 (132 + 20 + 101). The version assertions now expect 131.
- Generic signing-disabled iOS Release compile (`Silo`, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, `SILO_BUILD_CHANNEL=sideload`): `** BUILD SUCCEEDED **`, no warnings in changed files; built `Info.plist` reports `com.cubbiestream.kyro`, `1.0.131`, build `131`.

## Not verified

- **iPhone frame rate:** not measured. The next device test should compare Home with the overlay on, scrolling the same way as the recording.
- **Single drops among Silo poster rows:** not attributed. Those rows are unchanged since before Build 127.
- **Probe coverage:** a card taller than every probe in its group would need a wrapped line that is shorter but wraps to more lines. That is possible only through unusual word breaks; the period row and status pill are covered by grouping.
