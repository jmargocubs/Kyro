# Kyro X 1.0.124 (124): readiness

Build 124 extends Build 123 (`5f5e51cfcf3db7b87d187637ccc167100b2987a4`). No IPA, Simulator, tvOS changes, push, publication or delegation is part of this task. Physical acceptance remains pending; Build 122 remains the physically accepted baseline.

## Sports Settings inventory

The sliders button beside the existing Sports Hub heading opens a native, dark Crimson Noir form. It remains reachable with an inline event pinned.

| Section | Controls and ownership |
| --- | --- |
| My Favorites | Shared searchable team/player and league selectors; followed teams removable without events; cached logos and competition affiliations. Same selector as Home quick-add and Customize Home. |
| Dashboard | Default opening sport; enabled sports/league families; league ordering; live, upcoming and completed visibility; reset. Existing Live TV watch-guide List/Grid and category List/Hybrid/Grid/grouping preferences use their original keys. |
| Home Integration | Sports Today, My Teams, My Leagues and Upcoming Sports visibility through the existing scoped Home arrangement; link to unified Customize Home. |
| Playback & Channels | Link to existing provider settings, including active-provider selection. Explanatory text describes automatic event matching and in-player controls; no invented auto-matching toggle or separate sports-player store. |

The current Sports Hub renders its schedule, not Guide/List/Grid category layouts. Existing per-league Live/Upcoming/Results mode keys remain backed up and are cleared by dashboard reset, but are not offered as misleading controls over a schedule that does not consume them. Reset does not change favorites, Home arrangement or shared Live TV layout choices.

League visibility/order applies to Sports Hub, not favorites or Home discovery. Soccer is the existing Soccer league family; individual competitions remain directory browse routes, not new dashboard switches. Filtering does not rewrite the schedule cache or the pinned player's session.

## Directory providers and actual coverage

ESPN's free public site API is the only new directory provider. The app requests
`https://site.api.espn.com/apis/site/v2/sports/<sport>/<league>/teams?limit=1000`.
No account, subscription or key is required. These are unofficial public endpoints, not a guaranteed availability contract.

Bounded live probes on 2026-11-25 returned the following actual directory counts, independent of fixtures:

- NFL 32; NBA 30; MLB 30; NHL 32.
- College football 763; men's college basketball 365; women's college basketball 363. These are provider-returned teams, not a guarantee of every division or every school.
- All 45 existing soccer registry routes returned nonempty team lists:
  - `eng.1` 20, `esp.1` 20, `ger.1` 18, `ita.1` 20, `fra.1` 18, `ned.1` 18, `por.1` 18, `sco.1` 12, `bel.1` 18, `tur.1` 18, `aut.1` 12, `gre.1` 14.
  - `usa.1` 30, `mex.1` 18, `bra.1` 20, `bra.2` 20, `arg.1` 30, `col.1` 20, `chi.1` 16, `uru.1` 16.
  - `jpn.1` 20, `aus.1` 12, `chn.1` 16, `ind.1` 13.
  - `uefa.champions` 36, `uefa.europa` 36, `uefa.europa.conf` 36, `uefa.super_cup` 2, `conmebol.libertadores` 44, `conmebol.sudamericana` 56, `concacaf.champions_cup` 7, `afc.champions` 32, `caf.champions` 61, `fifa.cwc` 32.
  - `uefa.euro` 24, `conmebol.america` 16, `concacaf.gold` 16, `caf.nations` 24, `afc.asian.cup` 24.
  - `usa.nwsl` 16, `eng.w.1` 14, `esp.w.1` 16, `fra.w.1` 12, `fifa.wwc` 32, `uefa.weuro` 16.

Nonempty does not mean complete. Competition directories can reflect a season, qualifying pool or partial field (notably CONCACAF Champions Cup's seven entries). No complete soccer coverage claim is made.

### Tennis limitation

ATP and WTA site `/teams` returned no teams, and the probed site ATP `/athletes` did not return a usable player list. Core ATP/WTA athlete routes both returned the same 18,233-reference tennis index, not populated tour-specific player records. Hydrating that index would require many individual requests and does not establish tour affiliation. This build deliberately does not crawl it. ATP/WTA favorites work with players from loaded matches, including the shared selector's explicit schedule-loading action. Offseason tennis player discovery is **not** claimed complete.

### Cache and request bounds

- No directory network requests on app launch. Opening the selector loads one chosen route only; switching routes is on demand.
- One request per route; limit 1000, 20-second timeout, 4 MB accepted response limit, 2 MB encoded cache limit per route. No pagination crawl.
- Durable local directory cache: one day freshness; explicit refresh throttled to one minute. Concurrent requests for the same route are suppressed; failed and empty responses retain cached data.
- Search spans downloaded directories, provider aliases/abbreviations, affiliations and loaded schedules. It does not silently fetch all directories or promise global remote search.
- When a directory fails, the existing schedule path supplies fallback choices. The selector also offers explicit loading of schedule teams and tennis players.
- New ESPN favorites carry league-scoped stable provider IDs with bounded readable names. Existing name-only favorites are preserved, recognized and removable without rewriting them. Ambiguous historical soccer/name-only identities are not guessed or silently migrated. Same-name new ESPN IDs and different league identities stay distinct.
- Favorite limits remain 64 entries and 64 characters per key for existing backup compatibility. Long names can be shortened in the stored fallback label; cached directories retain full names and logos. Backups do not contain the disposable directory cache.
- Backward compatibility here means Build 124 imports older backups and preserves their name-only selections. New stable-ID selections require Build 124's matching logic; downgrading to Build 123 is not a supported matching round trip.

## Integration and validation scope

`KyroSportsFavoritesStore` remains the only favorites owner. The shared picker, long-press actions, Home shelves and Customize Home use it. New dashboard settings have one durable record and one observable owner; Unified Settings Backup validates and restores that record alongside unchanged favorite and Home entries. Older backup files remain supported by the existing additive registry/restore path.

Host suites cover real decoding/loading/cache/favorites/settings/backup functions with injected fixture transport, plus the Build 123 quick-add and preserved-feature source contracts. Live provider probes are separate from those fixture tests. Static navigation and playback-route checks are not physical-device execution. No visual or runtime acceptance is claimed from signing-disabled compilation.

Host validation results:

- `scripts/run-build124-host-checks.sh --live-samples`: 26 fixture-based checks passed, plus production decoding of three saved live responses (NFL 32, women's college basketball 363, English Premier League 20).
- `scripts/run-build121-host-checks.sh`: 132 Build 123/124 Home/quick-add/preservation checks, 20 backup codec checks and 101 unified backup checks passed.
- `shellcheck scripts/run-build124-host-checks.sh` and `git diff --check`: passed.
- Generic signing-disabled iOS Release compilation passed twice (exit 0), including a final incremental compilation after implementation freeze: `xcodebuild -project iosApp/Silo.xcodeproj -scheme Silo -configuration Release -destination 'generic/platform=iOS' -jobs 2 CODE_SIGNING_ALLOWED=NO build`. Shared default DerivedData was reused. No Simulator, archive or IPA was produced. Logs remain under `artifacts/build124/release-compile.log` and `artifacts/build124/release-final.log`.
- Built app Info.plist confirms bundle `com.cubbiestream.kyro`, version `1.0.124`, build `124`.
- The first legacy suite run failed because it asserted Build 123's name-only favorite encoding; the assertion now checks the deliberate stable-ID encoding and cross-provider removal. A second run reached the old version-number assertion, which was updated to 124. The expanded suite passes. New host-test compilation errors were corrected before the final passing run.

The default opening selection preserves the last used sport unless the user chooses All Sports or a specific league. Shared Live TV layout preferences keep their original backup entries; only the new dashboard record adds a backup setting.

Android, Roku and Web are outside this Kyro-local iOS enhancement; no server API or shared Silo client feature changes. No PR is being opened, so no parity issue publication is triggered.

## Combined Build 123/124 physical acceptance checklist

After separately authorized packaging, on the iPhone 16 Plus:

- [ ] Upgrade from accepted Build 122; confirm branding, launch animation, Crimson Noir and both approved navigation pills.
- [ ] Verify unified Silo/Kyro Home order and each shelf's visibility survive upgrade and relaunch.
- [ ] Use Build 123 Add Team/Add League cards, including an empty favorite shelf. Hidden shelves must not reappear.
- [ ] Open Sports Settings with and without a pinned player. Confirm dismissal preserves feed position and playback.
- [ ] Browse NFL, college men/women and soccer directories; search an offseason team by name and abbreviation; verify logo and league label.
- [ ] Follow from settings; verify Home and event long-press actions immediately agree. Remove a team without scheduled games. Check identical names in different leagues do not merge.
- [ ] Load a directory, relaunch offline, search cached teams, fail refresh, and verify cached results remain. Confirm schedule fallback and the labeled ATP/WTA limitation.
- [ ] Reorder and disable leagues, change default opening sport, toggle game statuses; relaunch and verify persistence. Reset and check favorites remain intact.
- [ ] Toggle all four sports Home shelves from Sports Settings and Customize Home; verify both editors and Home agree.
- [ ] Change existing Guide List/Grid and category layout/grouping; verify Live TV uses those same preferences.
- [ ] Export, change, restore and Undo Unified Settings Backup; check favorites, dashboard and scoped Home arrangement. Restore a Build 122/123 backup without losing compatibility.
- [ ] With no IPTV provider, browse sports scores, schedules, standings/details/statistics and news.
- [ ] With the existing provider, verify live matching, stream alternatives, inline/fullscreen/PiP and player/session coordination.
- [ ] Smoke-check Silo media playback, Live TV/Guide, Seekr and AetherEngine; confirm production 100K channel capacity and original bundle identifier remain unchanged.

Compilation and host checks do not replace these unchecked device gates.
