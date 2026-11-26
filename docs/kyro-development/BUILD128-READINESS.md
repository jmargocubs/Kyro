# Build 128 readiness: Internet Radio

Version 1.0.128 (128), iOS only, on `kyro/ios-recovered`. Builds on the accepted Build 127
(`e2364732`) and its documentation commit (`547a16d0`). Not packaged, not pushed, not
device-tested.

## What it adds

- **Radio** in the More menu (`ellipsis.circle` in the app header), with Discover, Library and
  History. The five tabs and both navigation pills are unchanged.
- **Discover:** search by name or call sign, genre, or city/state. It also has United States,
  Illinois and Worldwide chips, a preferred region, country, state and language filters, genre
  browsing and popular stations. Results load 40 at a time, up to 400. Loading, empty, error
  and Retry states are shown. No location permission is used.
- **Library:** favorites keyed by Radio Browser `stationuuid`, with search and sorting by
  Recently Added or Name. Saved details make favorites usable offline.
- **History:** the 50 most recent stations, with remove and Clear History. It stays on the
  device and is never backed up.
- **Playback:** AVPlayer with MP3, AAC and HLS. Playlists (`.pls` and `.m3u`) are resolved
  first, and HTTPS stream addresses are preferred. It has a mini player in the Now Playing slot,
  a Now Playing sheet with a LIVE badge, song and artist from ICY metadata when the stream sends
  it, favorite and stop controls, and an AirPlay/Bluetooth route picker. It also covers
  background audio, Lock Screen and Control Center (Play, Pause and Stop; no seeking),
  interruptions, pausing when headphones are removed, and three bounded reconnects (1, 2 and
  4 s) after trying the station's other address.
- **One player at a time:** `KyroPlaybackExclusivity`. Radio pauses when Silo video, Live TV,
  Sports or an audiobook starts or resumes. Starting radio pauses those players. Theme music
  stays quiet while radio plays. Existing rules between video and Live TV are unchanged.
- **Home:** Favorite Radio Stations and Recently Played Radio. They are listed in Customize
  Home but **off by default**, and hidden when empty. Existing arrangements are unchanged.
- **Settings:** Radio Settings (the sliders button on Radio) covers the preferred country,
  region and language, history, and a link to Customize Home.
- **Backup:** a new `radio` group with three entries:
  - `radio.favorites`: ID and short name only. Backups refuse links, so streams are fetched
    by ID after a restore, and only the newest 200 are saved.
  - `radio.preferences`.
  - `radio.homeShelves`.

  Build 127 and earlier skip the unrecognized group. The v3 Home arrangement leaves out radio
  tokens, so Build 127 can still restore it.

## Radio Browser integration

- Mirrors come from `all.api.radio-browser.info/json/servers` (cached for a day, only
  `*.api.radio-browser.info` hosts). Kyro picks a random mirror, fails over to two more, and
  uses the round-robin host as a last resort. A mirror that fails or returns 429 rests for
  five minutes.
- User-Agent `KyroX/<version>`, HTTPS, a 12 s timeout and a 3 MB response limit.
- Identical requests are coalesced. A superseded search is cancelled once nobody waits for it.
  Search waits 350 ms after typing stops.
- Searches are cached in memory for 10 minutes. Countries, states, languages and genres are
  cached on disk for 7 days and served stale when offline. Logos use the shared Nuke pipeline.
- `hidebroken=true` hides broken stations, and Ogg, Opus, FLAC and WMA streams are hidden as
  unsupported.
- A click is reported through `/json/url/{stationuuid}` when a listener starts a station,
  at most once a day per station.
- Nothing loads at app launch.
- ATS: the app already sets `NSAllowsArbitraryLoads`. That setting is unchanged; nothing was
  added.

## Validation

- `scripts/run-build128-host-checks.sh`: 107 Radio checks. They cover decoding, queries,
  pagination, mirror failover, rate limits, coalescing, cancellation, caches, click limits,
  playlists, library, history, backup, the state machine, exclusivity and Home. The script also
  runs the backup codec (20) and unified (101) checks.
  - Fixtures follow the live response shape.
  - `--live-sample <file>` decodes a saved live response through the production path. A
    40-station US sample from 2026-11-25 decoded fully: 19 HTTPS, 30 MP3, 9 AAC/AAC+, 1 Ogg
    (hidden).
- `scripts/run-build126-host-checks.sh`: 34 passed.
- `scripts/run-build121-host-checks.sh`: arrangement, backup, sports and navigation pass. Its
  final source-contract check still asserts Build 124 and has failed since Build 125.
- `scripts/run-build124-host-checks.sh`: fails before this change. It looks up `esp.1`, which
  Build 127 removed.
- Generic iOS Release, `CODE_SIGNING_ALLOWED=NO`, `-jobs 2`: **BUILD SUCCEEDED**, with no
  warnings in Radio files.

## Device-only checks

Actual audio, background playback, the Lock Screen, Control Center, AirPlay and Bluetooth
routing, interruptions (calls, Siri), headphone removal, and ICY metadata on real stations can
only be verified on the iPhone.

## Known limitations

- Playing or pausing Live TV from inside its own Picture in Picture window goes straight to
  the engine, so radio is not paused by that one control.
- A favorite restored from a backup shows its name but plays only after Radio Browser returns
  its details (fetched when Radio opens or the station is tapped).
- Radio Browser matches `state` as a substring. "Illinois" also matches values such as
  "Chicago, Illinois", and some stations have no state at all.
