# Build 130 readiness: Radio mini-player and Home scrolling

Version 1.0.130 (130), iOS only, on `kyro/ios-recovered`. Builds on Build 129 (`728dde71b806007b1abbc77085ac253138b4f15c`). Not packaged, not pushed, not device-tested.

## 1. Radio mini-player on the Radio page

**Root cause.** The app has one Now Playing slot, `NowPlayingShelfAttachment`, attached to `SiloTabBar` inside the root `NavigationStack` (`ContentView.swift`, `tabLayout`). On iOS 26 it is the tab bar's `tabViewBottomAccessory`; on iOS 18 and the status-column layout it is a bottom inset on the same `TabView`. Radio opened from More, a Home radio shelf header or the profile menu is a pushed route (`.secondaryDestination(.radio)`). A pushed page covers the whole `TabView`, including the tab bar and its accessory, so Discover, Library and History never showed the bar. Back on Home the tab bar returns, and so does the bar. Radio as the fourth tab already showed it, because tab roots keep the tab bar.

**Fix.**
- `KyroRadioView` adds a bottom `safeAreaInset` with `KyroRadioPageNowPlayingBar` when `KyroRadioNavigationPolicy.pageHostsNowPlayingBar(isSecondaryDestination:shelfCoversPushedPages:)` is true: pushed Radio, unless the layout already pins a bar over pushed pages.
- The inset sits inside the `.searchable` content, so it rests above the bottom search bar, and the `List` reserves its height as scroll space. It hides while the keyboard is up.
- The bar is the app's own `NowPlayingShelf(style: .card)`, so the same single bar shows (TV remote session, then audiobook, then radio) with station artwork, name, track metadata and Play/Pause. A tap opens the existing Now Playing sheet. It reads `KyroRadioPlayer.shared`; no second player or session exists.
- The iPad sidebar layout already pins a bar over every page; it sets `\.nowPlayingShelfCoversPushedPages` so pushed Radio adds none there. The fourth tab keeps the tab bar accessory.
- The radio card bar now has the audiobook bar's 16 pt side and 8 pt bottom margins.

## 2. Home scrolling

Home code is unchanged since accepted Build 127 apart from the opt-in radio shelves. Build 128/129 changed what the app shell observes. Confirmed causes:

1. **Radio transport state observed at the app root.** `KyroRadioPlayer.machine` was an observed struct written through `inout` on every event, including no-op ones. Video, Live TV, Sports and audiobooks ask radio to yield every time they start, even when radio is idle, and AVPlayer reports "playing" again after every stall. Each write invalidated every reader of `hasSession`, `station` or `state`. Those readers include `NowPlayingShelfAttachment` around the whole `TabView`, the Movies/Series and For You docks, and theme music. Reproduced on the host: 10 idle yields fired 10 invalidations in the Build 129 shape and 0 now.
   **Fix:** `machine` is `@ObservationIgnored`. `KyroRadioPlaybackStatus` publishes `station`, `state`, `hasSession` and `isActive`, writing each only when it changes. The root slot reads `hasSession`, which changes only when a session starts or ends. No-op transitions also skip the Lock Screen update.
2. **Mini-player logo re-requested as the tab bar minimizes.** Home minimizes the tab bar on scroll, which switches the accessory between 46 pt and 34 pt. `KyroRadioArtwork` sized its Nuke request from the display size, so each switch during a scroll started a new request and decode. **Fix:** the bar decodes once at 46 pt (`decodeSize`).
3. **Whole radio shelf redrawn on playback changes.** Each card in `KyroHomeRadioRail` read player state in the shelf body. **Fix:** the badge is its own view, `KyroHomeRadioPlayBadge`.
4. **More menu environment invalidation widened in Build 129.** `MainTabView` rebuilds `KyroMoreMenuContext` (closures, not comparable) on every body pass. Build 129 moved `.environment(\.kyroMoreMenu, …)` outside the header overlay, so every pass also invalidated the header's More button over every tab. **Fix:** `KyroMoreMenuContext` is `Equatable` by item id, title and symbol. Root item ids now include the destination identity, so equal menus always open the same routes.

Ruled out:
- **Hidden radio shelves:** `KyroHomeArrangement.entries` leaves them out, and their diagnostics return before touching the library.
- **Stream metadata:** `receiveStreamTitle` writes `track` only on change, and only the bar and Now Playing read it.
- **Navigation pills and scroll observation:** unchanged since Build 127.
- **Build 126 eager sports shelves:** unchanged and present in accepted Build 127. Kept as is (`sizing: .tallestCard`) to prevent the Build 125 clipping regression.

Instrumentation: the radio state log line (`KyroRadio` category) now reports `published N of M transitions`.

## Validation

- `bash scripts/run-build130-host-checks.sh`: 81 checks passed. Covers the root-cause baseline, state isolation across start, repeated player-started events, reconnect, pause/resume and stop, the pushed-page bar policy and entry-point routing, and source contracts: no second player, a single Now Playing presentation, the inset inside the searchable content, the keyboard hide, logo decode size, the Home badge, Equatable More menu, sports tallest-card sizing and version 130.
- Earlier scripts all pass: build129 (43), build128 (107 + 20 codec + 101 unified), build126 (34), build124 (42), build121 (132 + 20 + 101). The build121 and build129 version assertions now expect 130.
- Generic signing-disabled iOS Release compile (`Silo`, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, `SILO_BUILD_CHANNEL=sideload`): `** BUILD SUCCEEDED **`, no warnings in changed files. The built `Info.plist` reports `com.cubbiestream.kyro`, `1.0.130`, build `130`.

## Device-only checks

1. Play a station, open Radio from More: the bar shows above the search bar on Discover, Library and History, and the last rows scroll clear of it.
2. Tap the search field: the bar steps aside for the keyboard and returns when it closes.
3. Tap the bar: the existing Now Playing opens. Play/Pause works from the bar.
4. Radio as the fourth tab: one bar, in the tab bar accessory.
5. iPad sidebar: one bar at the bottom of the window on the Radio page.
6. Home scrolling with radio playing and stopped, compared with Build 127. No frame-rate measurements exist yet.
