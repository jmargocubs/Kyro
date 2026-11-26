# Build 129 readiness: Radio Navigation Accessibility

Version 1.0.129 (129), iOS only, on `kyro/ios-recovered`. Builds on Build 128 (`5621374a6ba84105e45dacbc0898ddd0a8818f7b`). Not packaged, not pushed, not device-tested.

## What changed

### 1. More menu environment propagation
- **Root cause fixed:** `ContentView.swift` (`MainTabView.tabLayout`) and `KyroDebugLiveTVFixtureRoute.swift` (`KyroDebugUnifiedShell`) applied `.environment(\.kyroMoreMenu, ...)` before `.overlay(alignment: .top) { KyroAppHeader(...) }` and `.overlay { statusColumnBar(statusColumn) }`. In SwiftUI, `.environment` flows inward to the wrapped child and not outward to sibling `.overlay` modifiers, so `KyroAppHeader` and `statusColumnBar` read `nil` and `KyroMoreMenuButton` (`ellipsis.circle`) rendered nothing.
- Moved `.environment(\.kyroMoreMenu, moreMenuContext)` outside both overlays in `ContentView.swift` and outside the `KyroAppHeader` overlay in `KyroDebugLiveTVFixtureRoute.swift`.
- `KyroAppHeader`, `statusColumnBar`, and `SiloTabBar` now receive `moreMenuContext`, exposing Radio and eligible secondary destinations (`Calendar`, `Downloads`, sibling libraries, and non-tab `Sports`/`Radio`).

### 2. Radio navigation accessibility
- **Customizable fourth tab:** Added `.radio` to `KyroGlobalDestination` and `KyroFourthTab` (`KyroGlobalNavigation.swift`), preserving `.sports` as `KyroFourthTab.default` and keeping the five-tab layout (`Home`, `Movies`, `Series`, fourth tab, `Live TV`). Updated `KyroNavigationSettings.swift`, `KyroAppHeader.swift`, and `ContentView.swift` (`MainTabDestination.global`, `kyroGlobalDestination`, `moreMenuContext`). When Radio is chosen as the fourth tab, More omits Radio and includes Sports; when Sports/For You/Favorites is the fourth tab, More includes Radio.
- **Hosted Radio tab presentation:** Updated `KyroRadioView` (`KyroRadioViews.swift`) with `isSecondaryDestination` and `kyroShellHeader` awareness so it leaves the `KyroAppHeader` runway, hides the duplicate system navigation bar, reports scroll state, and provides inline search and Radio Settings access when hosted as the fourth tab, while keeping native `NavigationStack` chrome when pushed.
- **Settings:** Extracted `KyroRadioSettingsForm` (reused by both the Radio sheet and Settings push) and added `KyroRadioSettingsRow` (`Radio`) to `IOSSettingsOverview.swift`.
- **Home Radio shelves:** Made `KyroHomeRadioRail` headers interactive buttons (`kyroHomeRadioHeader-*`) routing through `KyroRadioEntry.open(router:)` (selects the Radio tab if active, otherwise pushes `.secondaryDestination(.radio)`).
- **iPad and legacy navigation:** Added Radio to `ProfileAvatarMenu` (`TabTopBarActions.swift`) via `KyroRadioEntry.profileMenuOffersRadio` (`!KyroUnifiedNavigation.isActive`) alongside Live TV, and added a Radio row (`kyroSidebarRadio`) to iPad `sidebarList` (`ContentView.swift`).

### 3. Live TV Picture in Picture playback coordination
- In `LiveTVPlaybackController.phaseChanged(_:generation:)` (`LiveTVModels.swift`), resuming from `.paused` via direct-to-engine Picture in Picture Play (`isTransportInPictureInPicture()`) or system resume (`systemPauseAwaitingResume`) now calls `announcePlaybackStart()` (`KyroPlaybackExclusivity.shared.begin(self, source: .liveTV)`), pausing active Radio. Rejected automatic engine resumes outside PiP continue to pause the engine without yielding Radio.

### 4. Historical regression updates
- Updated `KyroBuild121HostChecks.swift` version checks from Build 124 (`1.0.124` / `124`) to Build 129 (`1.0.129` / `129`).
- Updated `KyroBuild124HostChecks.swift` soccer fallback fixture from retired `esp.1` to active `usa.1` (`KyroSoccerCompetitionRegistry`), preserving all competition-scoping and wrong-league rejection assertions.

## Validation

- `bash scripts/run-build129-host-checks.sh`: **43/43 passed** (SwiftUI `.environment` + `.overlay` propagation, fourth-tab Radio persistence, five-tab preservation, `KyroRadioNavigationPolicy` across unified/More/iPad/legacy, `LiveTVPlaybackController` PiP resume exclusivity, and source contracts).
- `bash scripts/run-build128-host-checks.sh`: **107 Radio + 20 backup codec + 101 unified backup checks passed**.
- `bash scripts/run-build126-host-checks.sh`: **34/34 passed**.
- `bash scripts/run-build124-host-checks.sh`: **42/42 passed**.
- `bash scripts/run-build121-host-checks.sh`: **132 focused + 20 backup codec + 101 unified backup checks passed**.
- `KyroUnifiedNavigationTests.swift`: added unit tests for fourth-tab Radio, `KyroRadioNavigationPolicy`, and PiP resume yielding Radio (not run in Simulator; compiled in Release build scope checks require test target).
- Generic signing-disabled iOS Release compilation (`Silo`, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, `SILO_BUILD_CHANNEL=sideload`): **`** BUILD SUCCEEDED **`** with zero warnings in modified files. Built `Info.plist` reports `com.cubbiestream.kyro`, version `1.0.129`, build `129`.

## Device-only acceptance checklist

1. Verify `ellipsis.circle` (More menu) appears in the top-right header on Home, Movies, Series, Sports, and Live TV, and opens Radio.
2. Verify Settings → Appearance & Navigation → Navigation offers **Radio** as a fourth-tab option while keeping **Sports** as default, and switching to Radio keeps both bottom floating navigation pills working cleanly.
3. Verify Settings → **Radio** opens Radio Settings directly and persists region/language changes.
4. Enable Favorite Radio Stations or Recently Played Radio on Home, tap the shelf header, and confirm it opens Radio.
5. On iPad (sidebar and compact) or legacy shell, verify Radio is reachable from the sidebar / profile menu.
6. Play a Radio station, start Live TV in Picture in Picture, pause Live TV in PiP, resume Radio, then tap Play inside the Live TV PiP window: confirm Radio pauses.
