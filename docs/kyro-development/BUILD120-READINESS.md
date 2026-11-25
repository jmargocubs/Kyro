# Kyro X iOS Build 120 readiness

**Status: implementation committed locally; Release compilation is not verified.** The single requested Xcode compile failed with a secondary Sports route type error. That error was corrected and focused checks/syntax parsing were rerun, but there was no second Xcode compile under the one-compile instruction. Build 120 is not yet cleared for physical acceptance or packaging.

## Scope and source

- Accepted foundation: `7341542d7150456286d923c106d5bba97d16f4aa`, iOS Build 119 (user accepted on a physical iPhone).
- Implementation stays on `kyro/ios-recovered`. The final delivery report records the implementation commit.
- iOS app and its two embedded extensions target version `1.0.120`, build `120`.
- Bundle ID, URL schemes, keychain/app-group identifiers, stored account/profile data and preference keys are not migrated or renamed.
- `kyro/tvos-recovered` remains at `0443c60dd937b8da761a97b1527f9e380b22bd94` (Build 108). No tvOS source, Top Shelf, tvOS Info.plist or tvOS target settings changed.
- Independent Kyro X remains shelved at `bb2d21bf8bda29e63aa9d79396ecc67582960c70`; it is a read-only donor for this task.

## Branding and provenance

Reused from `Development/KyroX`, revision `bb2d21b`:

| Asset/component | Donor | Build 120 use |
| --- | --- | --- |
| Approved silver/crimson interlocking K/X | `CubbieStreamPlayerLab/Assets.xcassets/AppIcon.appiconset/KyroXAppIcon.png` | Byte-identical iOS app icon and launch logo |
| Header wordmark | `Assets.xcassets/KyroXWordmark.imageset/KyroXWordmark.png` | Header, account/loading surfaces, introduction and animated startup |
| Crimson Noir palette | `App/KyroTheme.swift`, `.crimsonNoir` | Brand-only background `#10090C`, accent `#8C263B`, secondary `#B53B4D`, highlight `#F06A7C` |
| Startup background presentation | `App/KyroTheme.swift`, `KyroStartupView` | Static crimson radial gradients behind the approved artwork |

Asset SHA-256:

- Icon/logo: `4b23e166e3e77bd8ed17e8a9a76af3a53bb314593ac81bc6a0066432878d478d`.
- Wordmark: `1881e4b8444d6a7d4f3c84901b9de23ddde8481c269a44786362165fc58599a0`.

The independent app contains a static startup view, **not a separately recoverable animated launch asset**. Build 120 combines its actual approved artwork/background with the accepted fork's existing `KyroCinematicSplashView` single-pass reveal, shimmer and bloom. Reduce Motion and cancellation remain supported. iPhone and iPad use this branded startup; the existing phone-only introduction eligibility remains unchanged.

`AppBrand.name`, iOS display name, About wording and the English local-network prompt identify the app as Kyro X. Silo server terminology, upstream license/source links, attribution, original Silo content colors and the existing player are retained. No global replacement of the word “Silo” or broad content-theme recoloring was performed.

## Navigation recovery

Inspected the actual upstream tree at `d9bbdc77` and the independent implementation at `bb2d21b`.

Recovered/wired the upstream components already integrated as dormant source in Build 119:

- `iOS/PageDock.swift`: `PageDock`, `PageDockModel`, `PageDockHost`, segment layout/drag/accessibility behavior, floating dock and native accessory styles.
- `iOS/LibraryDock.swift`: `LibraryDockModel`, actual grouped library-switch menu, `LibraryPageScrollClaim`, claim links and scroll-view reporting.
- `Screens/Browse/LibraryPageScrollToTop.swift`: selected-segment scroll-to-top and retained Browse reload requests.
- Existing `Control/iOS/NowPlayingShelf.swift`: `NowPlayingShelfAttachment` and now-playing/remote accessory priority, unchanged.

The secondary dock does **not** require adopting upstream's single Libraries primary root. `LibrariesTabView` binds it to the original selected page and the existing root-scoped `visibleLibraries`, selection persistence and router. Movies, Series and pinned-library roots remain intact, as do synced primary menu customization, More, Live TV and Sports.

The page host retains visited pages, selects the active vertical scroll view and refreshes hidden Browse after media watch-state mutations. Collections remains reachable even before collection presence is known; its own empty/error state is authoritative. The original top chip selector remains for regular-width/sidebar/status-column layouts.

Pushed library pages use the floating dock, never an accessory on the hidden tab bar. An iOS-only `SecondaryDestinationID.sports` route resolves to the original Sports Hub with a visible native Back bar when Sports is not a primary tab. More offers it for non-Sports fourth-tab choices; Home also exposes a direct Sports Hub link, including on legacy/iPad layouts.

Dependencies and resolutions:

- **iOS 26.1+:** existing native accessory hosts the actual upstream secondary pill. Native minimization collapses primary navigation to its selected destination, keeps the secondary pill available inline, expands when the selected control is tapped and restores on scrolling up/to the top. This remains OS behavior, not a replacement primary menu.
- **Now playing/remote active:** that accessory keeps priority; the secondary dock floats in its page.
- **iOS 26.0:** floating upstream secondary dock avoids the unstable dynamically enabled accessory API; native primary minimization remains available.
- **iOS 18:** fixed native primary bar plus floating secondary dock. No unsupported collapse behavior is simulated.
- **Short pages:** reuse independent `App/TabDockScrollRange.swift` hysteresis (48/128-point thresholds) inside the upstream scroll claim, preventing accessory resize feedback. The independent `CollapsibleTabDock` itself is not copied because the actual upstream accessory host already provides that function.
- **Live TV/Sports:** no media secondary dock is attached. Their existing contextual navigation and routes are unchanged.

## Additive Home shelves

Silo's authoritative `HomeViewModel.sections`, original `ForEach` order, artwork, Continue Watching, Next Up, Explore All, watch-state refresh and native detail routing remain the original feed. `KyroHomeShelves` appends a separate block **after all original server sections**. When the server has no rows, the original loading/error/empty state remains above the local block rather than preventing local shelves from rendering.

Six optional shelves, enabled by default in this order:

1. Recently Watched Live TV
2. Favorite Live TV Channels
3. Sports Today
4. My Teams
5. My Leagues
6. Upcoming Sports

Implementation:

- Live TV uses the original `LiveTVService.shared` bounded, provider-scoped recent/favorite previews. No 100K-channel catalog is copied into Home. Buttons retain the exact `LiveTVChannel` and call `choose(_:from: .shell)`, preserving the existing session, presentation and PiP policy.
- Sports uses the original `KyroSportsHubStore`, ESPN/Sleeper clients, cache and original game models. A separate presentation instance loads today's and tomorrow's schedules without changing the user's Sports Hub league/day. No new sports backend or universal catalog is introduced.
- Original Sports Hub scoreboard/tennis card views are reused. Event cards open original `KyroSportsEventPreview` and its existing detail store. Watch requires an in-progress event and strong existing stream matches, then opens Sports Hub and calls the original `playSportsEvent` pipeline. Home does not overwrite the Hub's shared Live Now evidence.
- Build 119 has no team/league favorite store. The independent `SportsHubStore` preference/key pattern is therefore adapted into one `KyroSportsFavoritesStore`, shared by Hub context menus, Home and customization. Existing independent preference keys are retained. My Teams/My Leagues show matching events. A long-press on a Hub or Home event adds/removes its teams/league.
- Independent `UniversalHomeRail` presentation and `UniversalHomeCustomization` interaction patterns are adapted, **not** their universal feed/catalog architecture. Settings → Appearance & Navigation → Kyro Home Shelves, plus the Home Customize link, provide visibility toggles, drag reorder, accessible Move Up/Down and reset-to-defaults for only these six additions.
- Empty content never writes preferences. Loading, empty and failed schedules are separate; unavailable/stale sports data gets a local notice and Retry, not a replacement/error for Silo Home. Shelf order and visibility survive temporary emptiness and relaunch.
- Sports lists are bounded to 40 cards per shelf. Favorites use the independent league/name key pattern, and are bounded to the existing backup codec's portable limits.

### Unified backup

`KyroHomeBackupSettings` explicitly registers:

- `home.localShelves` in General: one validated structured record with the complete ordered shelf set and hidden subset.
- `sports.favoriteLeagues` and `sports.favoriteTeams` in Sports: validated, bounded favorites shared with the Hub.

The settings registry uses the same defaults/store keys, existing schema-4 codec, read-back validation, preview, selective restoration and Undo. No provider credentials, channel IDs, stream URLs, account/profile identities or histories are added to backup. Older backups leave the new preferences unchanged.

A focused regression exposed the legacy local-only exporter's hardcoded schema-1 envelope. Structured local values now use the existing validated structured encoder; legacy scalar-only exports remain schema 1. No decoder, integrity or sensitive-content safety gate was weakened.

## Preserved functionality and platform boundaries

The accepted AetherEngine revision `f470d8dc610537929c83ef31877287e9d2ad9d28` (7.56), multiple accounts, authentication, profiles, subtitle/rendering improvements, player/PiP, Seekr previews, native library features, production 100K channel capacity and publishing scripts/workflows remain untouched. Sports event-card visibility is widened only to reuse the same views on Home; their rendering is unchanged.

No IPTV VOD, universal media catalog, extra media-server integration, Simulator run, delegation, worktree, IPA archive/package, push or publication is part of this task. Android/Roku/Web are out of scope for these Kyro-specific iOS additions.

## Validation

- `bash scripts/run-build120-host-checks.sh`: 59 Build 120 focused checks; 20 existing codec checks; 101 existing unified backup checks. The final run is recorded in `artifacts/build120-readiness/host-checks.log`.
- Behavioral checks cover order normalization, visibility, relaunch, empty-result preference retention, exact favorites, sports date/status selection and bounds, validated export/decode/preview/restore/read-back/Undo, and native-dock scroll-range hysteresis.
- Source/asset contracts supplement those behavioral checks for approved image hashes, original channel/Sports routing calls, additive original feed order, upstream dock/scroll-claim wiring, accessory availability/priority, primary tabs/Live TV, Aether revision and capacity.
- `shellcheck scripts/run-build120-host-checks.sh`, Swift iOS syntax parsing and `git diff --check` passed.
- One generic signing-disabled Release compile (`-jobs 2`, shared default DerivedData): **failed, exit 65**. The compiler reported `SecondaryDestinationID` had no `kyroRoot` member at the new Home Sports fallback call. The call now uses the explicit iOS-only `.sports` secondary route, mapped to the original Hub, with native Back and non-primary-tab access. This correction is syntax/source-contract checked but **not recompiled with Xcode**. Evidence: `artifacts/build120-readiness/ios-release.log`.
- Existing warnings included Swift-6-isolation warnings in `AppLanguagePreferences`/`HomeWatchStateRealtime`, a non-Sendable default function in `KyroSportsPinnedEvent`, and an unused mutable variable in `ContentView`. Unrelated warning remediation was not included.

Host/source checks and compilation do not validate native UI animations, real streams or device rendering. There was no Simulator or physical-device execution for Build 120.

## Remaining limitations

- Physical acceptance is still required; Build 119 acceptance is the baseline, not acceptance of these new behaviors.
- A new successful Release compilation of the corrected source is required before readiness can be claimed. The one-compile attempt was not repeated.
- Primary minimization/inline secondary placement requires the relevant native iOS versions. Older systems intentionally use the compatibility behavior above.
- Sports Home covers today and tomorrow, refreshes on entry/foreground or Retry, and is not a continuously polled scoreboard. Longer-range sports browsing remains in Sports Hub.
- Team favorites use the independent league/name identity pattern; provider-side team-name changes can require re-favoriting. There was no pre-existing Build 119 team/league favorite state to migrate.
- No separate animated startup asset was present in independent Kyro X; animation is the existing accepted fork implementation applied to the approved independent artwork.
- New local shelf/settings wording is English; existing Silo translations are preserved rather than guessed.

## Physical-iPhone acceptance checklist

- Upgrade over accepted Build 119: confirm bundle identity, accounts, saved Silo servers, profiles, settings, history and channel favorites are retained.
- Check Home/header/account/loading/About identity, K/X app icon, startup animation, Reduce Motion and replay introduction. Confirm no unexpected Silo content recoloring or missing upstream attribution.
- On a long Movies/Series page, scroll down: primary collapses to the active icon while Recommended/Browse/Collections remains visible. Tap the collapsed icon; return to top. Repeat for each page and a short/empty library.
- Switch libraries, mixed-library media scope, pinned roots and accounts/profiles; confirm correct routing, page state, collections and preserved menu customization.
- Start audiobook/remote playback and verify accessory priority with the secondary pill still reachable; check the supported older-iOS fallback if available.
- Verify Live TV and Sports remain accessible, including through More/non-default fourth-tab choices, with no inappropriate media secondary pill.
- Play a recent channel and a favorite channel; verify exact provider/channel and existing player/PiP transitions. Change active Live TV provider; remove an unavailable favorite/provider and check stale cards do not play another stream.
- Open live/scheduled/final/tennis sports event details; test Game/Stats/News and Watch Live only where existing strong stream evidence permits it. Check no duplicate player/session and the existing Other Streams flow.
- Favorite/unfavorite teams and leagues in Sports Hub, return Home, and verify My Teams/My Leagues. Test no matching events and an endpoint failure independently of a healthy Silo Home.
- Toggle/reorder all six local shelves, relaunch, make rows temporarily empty, restore content and reset defaults. Confirm original Silo section order never changes.
- Export settings, change shelf layout/favorites, preview/restore selected groups and Undo; verify credentials/history/channel favorites were neither exported nor overwritten.
- Recheck Aether playback, subtitles, Seekr scrub previews, PiP, multiple accounts/profile switching, Continue Watching/Next Up and large-provider Live TV browsing.
