# Kyro X iOS Build 121 readiness

**Status: implemented, host-checked and iOS Release compilation verified; physical-device acceptance pending.** Built on Build 120
(`d800bf6039be234658ae98976c12cf4dee9806b4`, physically tested on November 25, 2026). iOS app and
its two extensions target version `1.0.121`, build `121`. Bundle identifiers, tvOS
(`kyro/tvos-recovered`, Build 108) and every other target are unchanged.

## Physical acceptance findings addressed

| Finding (Build 120) | Confirmed root cause | Build 121 fix |
| --- | --- | --- |
| Launch shows a square K/X icon above a separate wordmark | `KyroCinematicSplashView` drew `KyroXLogo` (the app icon artwork) and the wordmark as two marks, plus a halo bloom | One centred wordmark on the Crimson Noir backdrop. "Kyro" fades up, the crimson X swings into place, then the mark settles into the unmodified approved image. Reduce Motion shows the static wordmark. No icon, no bloom, no loop. |
| Navigation icons and Home controls still blue | `KyroTheme` (the semantic palette for Kyro's chrome, nav glass, Sports Hub and the shell tint) still held the C3 electric blue (`#0034FB`/`#738FFD`); Build 120 only recoloured `KyroBrand` startup surfaces | `KyroTheme` now holds Crimson Noir: accent `#8C263B` (filled controls; white on it 8.6:1), ink `#F06A7C` (text/icons/tint; 7.1:1 on black), secondary `#B53B4D` (selection), depth `#4A1424`, glass `#1F0E14`, secondary text `#C7A5AA`. LIVE red, favorite orange, warning/error/success, team colours, artwork and Silo's own content theme are unchanged. |
| Kyro shelves only after ~20 Silo rows | `HomeView` appended `KyroHomeShelves()` after `ForEach(sections)` | `KyroHomeArrangement` interleaves the six shelves among Silo's sections by stable section id (see below). Separate "Kyro Home" heading removed; Customize Home sits at the top of Home. |
| Recently Watched Live TV, Favorite Live TV Channels empty | Home's channel rails are built by `LiveTVService.scheduleHomePreviewRebuild`, which needs the selected provider's catalog in memory or SQLite. Only the Live TV page and Sports playback called `restoreCachedState`/`prepareSelectedProvider`, so after launch Home had no catalog and published empty rails until Live TV was opened | Home's shelf host restores the selected provider's cached catalog itself (disk only, no playlist download). Existing favorites (`favoriteChannelIDs`) and history (`recentlyWatchedRecords`) are used as-is; recents are shown most-recent first. |
| My Teams, My Leagues failed or wrong | (1) Home loaded only All Sports for today and tomorrow, which excludes soccer and any favorite team's game later in the week. (2) Team matching was the exact `league|City Nickname` string; Sleeper's NFL teams can arrive without a city, so ESPN-saved favorites didn't match. (3) My Leagues showed every event of the league including finished and canceled ones, in plain time order. | A second store loads each relevant league's own provider window (as the Hub does for one sport), only for favorite leagues and favorite teams' leagues. Name-tolerant matching for pro teams (exact first; nickname when a provider omits the city; provider alternate names); college still needs the full name. Selection: live first, then upcoming by start, then today's finals; older and canceled/postponed events excluded. |

The original Kyro iOS Sports Hub has no team/league favorites of its own; the only sports favorites
in this app are the Build 120 store (`kyrox.sports.leagues`, `kyrox.sports.teams`), set by touching
and holding an event in Sports Hub or Home, or in Customize Home. Hub and Home share that one store
(`KyroSportsFavoritesStore.shared`); no Home-only favorites exist.

## Integrated Home arrangement

- Silo's feed stays authoritative: same sections, content, rows and relative order on every load.
  Nothing is written to the server.
- Default: Continue Watching, Next Up, Sports Today, Recently Watched Live TV, Favorite Live TV
  Channels, My Teams, My Leagues, Upcoming Sports, then the remaining Silo rows in server order.
  Missing Continue Watching/Next Up are handled (shelves then lead).
- Each Kyro shelf is anchored after a Silo section **id** (stored tokens `silo:<id>` / `kyro:<shelf>`),
  never an array offset. Server reorders move shelves with their anchors; removed anchors fall back
  to the previous surviving row; new server rows appear in server order.
- Stored per server, local account and profile (`kyrox.home.arrangement.v2.<server>.<account>.<profile>`).
  Build 120's device-wide hidden shelves seed the first arrangement.
- Customize Home (top of Home, and Settings): the real Home order with server rows fixed; Kyro
  shelves can be shown/hidden, dragged (Edit) or moved with buttons and VoiceOver actions; Reset to
  Default Arrangement. Favorite leagues and teams are edited there too. Before Home has loaded, only
  show/hide is offered.
- Settings Backup: `home.localShelves` is now `{"version": 2, "order": [...], "hidden": [...]}` for the
  active profile. Build 120 backups (`{"order","hidden"}`) still restore their visibility.
- Empty shelves still hide automatically. Customize Home › Shelf status, and `os_log`
  (category `KyroHome`), report per shelf: shown, hidden in Customize Home, no source (no
  favorites/history/provider), loading, unresolved (sources exist but don't resolve; catalog not
  loaded or IDs not in the playlist), failed (named leagues unavailable), or empty window, with source
  and shown counts.

## Launch layers provenance

`KyroXWordmarkKyro` and `KyroXWordmarkX` are the approved `KyroXWordmark` (SHA-256
`1881e4b8…99a0`, unchanged) separated by colour with `scripts/kyro-brand/split_wordmark.swift`.
They share its 1825×498 canvas; a host check confirms the two layers add back to the original with
zero differing pixels. The installed app icon is unchanged. `KyroXLogo` stays in the catalog but is
no longer shown at launch.

## Preserved

Navigation pills and their collapse/expand (no changes to `LibrariesTabView`, `PageDock`,
`LibraryDock`, `SiloTabBar`), Silo playback, Live TV and Guide, Sports Hub behaviour (one read-only
accessor added to its store), Seekr, AetherEngine `f470d8dc`, the 100K channel limit, unified
settings backup, bundle IDs, tvOS. No IPTV VOD or universal catalog.

## Validation

- `scripts/run-build121-host-checks.sh`: Build 121 90/90, settings backup codec 20/20, unified backup
  101/101 (host only; no Simulator).
- Generic signing-disabled iOS Release build (`Silo`, `-jobs 2`): `BUILD SUCCEEDED` on the first run,
  no warnings in the changed files.
- No changes to `LibrariesTabView`, `iOS/` docks, `SiloTabBar`, `LiveTV/` or the player.
- XCTest targets were not run (they need the Simulator). No IPA was packaged.
Build 120's host-check program is replaced by Build 121's; its still-valid assertions (assets, Aether
revision, 100K, navigation pill policy, routing) moved into the new program.

## Physical-device acceptance checklist

1. Launch: single centred Kyro X wordmark, crimson X animates into place, smooth fade into the app;
   no square icon, no rectangle behind the mark; with Reduce Motion, a static mark.
2. Accent: tab/navigation icons, selected pills, Home's Customize Home control, Sports Hub chips and
   Settings toggles are crimson, not blue; LIVE badges stay red.
3. Home order (default): Continue Watching, Next Up, then the six Kyro shelves (when they have
   content), then the rest of your server rows. No "Kyro Home" heading.
4. Customize Home (top of Home): move My Teams below a server row, hide Upcoming Sports, return to
   Home: both apply. Relaunch: kept. Switch profile: the other profile has its own arrangement.
   Reset to Default Arrangement restores the default.
5. Without opening Live TV first after launch: Favorite Live TV Channels shows your existing
   favorites; Recently Watched Live TV shows channels watched before; tap one: the exact channel plays.
6. Watch a new channel, return to Home: it leads Recently Watched Live TV. Favorite/unfavorite a
   channel in Live TV: Home's Favorite rail follows.
7. Favorite a team (touch and hold an event in Sports Hub): My Teams shows its live or next games,
   including games later in the week. Favorite a league: My Leagues shows its live/upcoming events,
   live first, no old or canceled games.
8. Tap an event on Home: details open; Watch plays the matched stream through Sports as in Build 120.
9. Customize Home › Shelf status explains any hidden shelf.
10. Settings Backup export/restore includes the Home arrangement and sports favorites; a Build 120
    backup still imports.
11. Regression: navigation pills and collapse, Silo playback, Live TV/Guide/PiP, Sports Hub, Seekr,
    Settings Backup, 100K channels.
