# Kyro upstream integration checklist (Silo Apple → Kyro)

Persistent record of every upstream `Silo-Server/silo-apple` commit between the shared base
`ec9c9b46` (2026-10-24) and `d9bbdc77` (2026-11-23): 214 non-merge commits. Update this file
whenever upstream is merged again; regenerate the table with the method below.

| Branch | Merge commit | Follow-ups |
| --- | --- | --- |
| `kyro/ios-recovered` | `9f24d850` (parents `2aef2b4f`, `d9bbdc77`) | `43542b98` |
| `kyro/tvos-recovered` | `301070f6` (parents `c771aad1`, `d9bbdc77`; three-way merge on base `ec9c9b46`) | `2cd8288d` (cascade freeze fix, allowlist) |

The tvOS branch is a re-rooted snapshot (root `85869d83`, tree-equal to
`kyro/tvos-build90-provider-readability` apart from the build stamp), so git finds no merge base;
the merge used `ec9c9b46`, that branch's upstream base, explicitly.

## How it was integrated

A sequential cherry-pick dry run of the 214 commits gave 105 clean, 103 conflicting and 6 already
present. One real merge needs only 52 (iOS) and 67 (tvOS) file resolutions and keeps upstream's
dependency order, so both platforms were merged rather than cherry-picked.

**Measured coverage.** For each commit, `coverage.py` takes the lines it added that upstream still
has at `d9bbdc77` (ignoring trivial lines, catalogs, docs, CI) and counts how many are present in the
Kyro branch. "Integrated" means at least 98%. Anything lower is listed with the files where Kyro's
version was kept.

## Statuses

- **Integrated**: the change is in the branch (merge or earlier cherry-pick).
- **Integrated with Kyro adaptation**: in the branch, with Kyro-owned files keeping Kyro behavior.
- **Partially integrated**: some of the commit applies; the rest depends on an excluded change.
- **Blocked by a dependency**: requires upstream's navigation model, which conflicts with Kyro's.
- **Not applied / Superseded**: Kyro's accepted implementation covers the same need.
- **Not applicable**: macOS, the other platform, or repository CI/docs/tooling. These are merged into
  the tree (the files exist) but change nothing in the shipped app.
- **Pending implementation**: none left. Unassessed commits: none.

## Kyro decisions that exclude upstream changes

1. **Navigation batch (blocked on both platforms).** Upstream `88498ec7` deleted the synced primary
   menu model (`PrimaryMenuBuiltin`, `PrimaryMenuPreference`, `nav.shortcuts` writes, Movies/Series
   category roots) that Kyro's iPhone shell, More menu and header, and Kyro's Apple TV top menu are
   built on. Kyro keeps that model (`UICustomizationPreferences`, `SiloAPI+Settings`
   `putNavigationShortcutItem`, `APIv2Client.updateNavigationShortcut`, `LibrariesTabView`,
   `StartupContentPrefetcher`), and on tvOS keeps `TVMainTabView`, `TVTopMenuBar`, `TVCascadeSelector`,
   `TVPageFocusOwner`, `TVPrimaryMenuProjection`, the `TVCatalogGrid` row focus sections and the Settings
   focus fixes. Dependents: the iPhone page docks (`02e20e0c`, `6d90acb1`, `484d8237`, `d49d7bd1`), the
   caption retirement (`876fbd31`), and upstream's tvOS top-menu focus work (`933381d6`, `016abe97`,
   `2b2b7fd5`, `55841508`, part of `0f4d3505`, `7bb8fe3d`, `ddebb9fa`, `3abeaf4f`). Upstream's page
   `onMoveUp` hooks are removed from the Apple TV pages; `KyroTVShellCompat.swift` declares the two
   upstream shell types the merged router and grid reference.
2. **Kyro-redesigned iOS screens.** Settings overview, Playback settings, unified Search and the
   Settings row layout stay Kyro's; upstream changes in them were merged where they did not conflict
   (still-watching row, cellular quality, box-set search). Their English text is not catalog-backed.
3. **Branding.** `scripts/kyro_brand_catalog.py` renames the app to Kyro in the iOS string catalogs.
   Server, password, Silo Diagnostics and Roku-app text keeps Silo. Translations change only where the
   whole English sentence was rebranded. Re-run it after every `scripts/sync-translations`. Apple TV
   keeps the Silo name, as before.
4. **Sign-out.** Upstream's `signOutAndReset` now presents the shared account confirmation. Kyro's
   own confirmations (iOS Settings alert, Apple TV Settings and shell overlays) hand off to it, so
   people are asked once.

## Validation (host-side; no Simulator per scope)

- Generic signing-disabled Release builds with `-jobs 2`: iOS `Silo` and tvOS `SiloTV` (see report).
- `scripts/ci/check-no-api-v1.sh`: passes after allowlisting TheSportsDB's public `/api/v1` URL
  (a third-party sports API, not Silo's).
- `scripts/ci/check-string-localized.sh`: passes.
- `scripts/ci/check-catalog-text.py`: fails on English literals in Kyro-owned screens (Settings
  overview, Settings backup, Playback health, unified Search, Live TV) — expected, see decision 2.
- `scripts/kyro_brand_catalog.py --check`: clean.
- XCTest targets (including upstream's new tests) were not run: they need the Simulator.

## Physical-device acceptance still required

Multiple accounts and Change Account, the profile menu panel (iPhone), sign-out confirmation,
app language, AetherEngine 7.56 playback (direct play, HLS, subtitles, AV1/MPEG-2 claims, TrueHD/DTS
fallback), box sets, collection rows, ratings, Not interested, Roku remote, downloads and audiobooks,
Kyro shell navigation on iPhone, and the accepted Apple TV top menu and focus paths.

## Status counts

| Status | iOS | tvOS |
| --- | ---: | ---: |
| Blocked by a dependency | 6 | 2 |
| Integrated | 155 | 164 |
| Integrated earlier | 7 | 7 |
| Integrated with Kyro adaptation | 5 | 6 |
| Not applicable | 39 | 25 |
| Not applied | 0 | 5 |
| Partially integrated | 2 | 4 |
| Superseded on Kyro | 0 | 1 |

## Commit checklist (oldest first)

| Upstream | Date | Subject | iOS | tvOS |
| --- | --- | --- | --- | --- |
| `2bc275bd` | 2026-10-24 | fix(player): keep Fit video clear of the Dynamic Island and notch (#903) | Integrated. | Integrated. |
| `91021591` | 2026-10-24 | chore(deps): pin AetherEngine with upstream's exact TrueHD Atmos render (#902) | Integrated. | Integrated. |
| `4871de74` | 2026-10-25 | feat(silocontrol): control a Roku from the iPhone (#905) | Integrated. | Integrated. |
| `a70b2551` | 2026-10-25 | feat(pairing): sign in a Roku from the iPhone (#906) | Integrated. | Integrated. |
| `9fbd84cb` | 2026-10-25 | fix(silocontrol): keep a paired Roku sealed and fence the Roku launch read (#907) | Integrated. | Integrated. |
| `a65867ef` | 2026-10-25 | feat(sections): cap Home and library rows at 20 cards with an Explore all page | Integrated. | Integrated. |
| `b514800f` | 2026-10-25 | fix(silocontrol): keep the player alive when replacing remote playback (#909) | Integrated. | Integrated. |
| `97fe5aac` | 2026-10-25 | fix(ios): dither the page background so its glow doesn't band (#916) | Integrated. | Integrated. |
| `ac0d6d84` | 2026-10-26 | fix(player): keep the controls through stalls and show a centered spinner (#918) | Integrated. | Integrated. |
| `2c8f2e1b` | 2026-10-26 | fix(calendar): label the series premiere badge PREMIERE (#919) | Integrated. | Integrated. |
| `004e3811` | 2026-10-26 | fix(player): offer Skip Credits in every credits range (#915) | Integrated. | Integrated. |
| `29557f44` | 2026-10-26 | fix(sections): keep a row page's cards and Back reachable while it loads | Integrated. | Integrated. |
| `eca0bd3d` | 2026-10-26 | fix(player): transcribe the audio track the viewer is listening to (#727) | Integrated. | Integrated. |
| `cb575d4c` | 2026-10-26 | fix(sections): check the row page's owner after every page it reads | Integrated. | Integrated. |
| `2633a49f` | 2026-10-26 | fix(sections): keep a filtered row page able to load more | Integrated. | Integrated. |
| `eafce165` | 2026-10-26 | fix(tvos): end the playback session when the app leaves the foreground (#922) | Integrated. | Integrated. |
| `3c3f08ef` | 2026-10-26 | feat(player): show brightness and volume as top pills, like Infuse | Integrated. | Integrated. |
| `64eec0a1` | 2026-10-26 | fix(player): let only one gesture own a touch on iPhone (#926) | Integrated. | Integrated. |
| `a623fd61` | 2026-10-26 | fix(player): keep a remembered sidecar subtitle when playback starts | Integrated. | Integrated. |
| `876fbd31` | 2026-10-27 | feat(settings): retire the media card caption choice (#923) | Blocked by a dependency: the caption choice lives in UICustomizationPreferences, which Kyro keeps at its primary-menu revision; captions remain selectable. | Blocked by a dependency: same preferences model; Kyro's Apple TV card presets and Captions row are kept. |
| `122d0088` | 2026-10-27 | fix(tvos): stop the library menu freezing the app on Back | Not applicable (tvOS). | Integrated with Kyro adaptation: freeze fix ported into Kyro's TVCascadeSelector (same flyout measurement loop). |
| `ec9278f8` | 2026-10-27 | fix(player): stack the volume chip at top center, clear of the top bar (#930) | Integrated. | Integrated. |
| `a1516002` | 2026-10-27 | feat(requests): show the server's Discover rows with See all pages | Integrated. | Integrated. |
| `aee2370f` | 2026-10-27 | fix(requests): retry a See all row that failed before any titles showed | Integrated. | Integrated. |
| `6c3070cd` | 2026-10-27 | fix(requests): close See all with Requests, and offer it for trimmed rows | Integrated. | Integrated. |
| `72e7fa8f` | 2026-10-28 | fix(tvos): keep a full episode row for series with one-episode seasons | Integrated. | Integrated. |
| `743cc322` | 2026-10-28 | fix(tvos): return the episode row to its anchor once pages load | Not applicable (tvOS code); merged. | Integrated. |
| `01a82a02` | 2026-10-27 | fix(detail): keep every Cast & Crew card when a person has two credits | Integrated. | Integrated. |
| `cbe01b12` | 2026-10-28 | fix(tvos): ease into the anchor when a page loads mid-move, count distinct episodes | Integrated. | Integrated. |
| `f1df54f7` | 2026-10-27 | feat(artwork): use the series and season art episode cards now carry | Integrated. | Integrated. |
| `3e49209a` | 2026-10-27 | fix(player): play a saved series subtitle when Use Device Settings is on | Integrated. | Integrated. |
| `dd55d0f4` | 2026-10-27 | fix(topshelf): match episode type aliases; keep the picker's series link as before | Integrated. | Integrated. |
| `fdd652cc` | 2026-10-27 | fix(watch-party): restore the picker from this branch's base | Integrated. | Integrated. |
| `5ba7829b` | 2026-10-27 | fix(tvos): prefer the detail's series backdrop in hero enrichment | Not applicable (tvOS code); merged. | Integrated. |
| `56448601` | 2026-10-27 | fix(player): keep launch seeds automatic and re-check the policy on a file change | Integrated. | Integrated. |
| `a39a9d66` | 2026-10-27 | test(tvos): decode the enrichment fixture as the server sends it | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `a9cacaa8` | 2026-10-28 | fix(player): match a remembered subtitle only in its own language | Integrated. | Integrated. |
| `7e281bde` | 2026-10-28 | feat(ios): open a row's Explore all page in the detail card | Integrated. | Integrated. |
| `2b2b7fd5` | 2026-10-28 | fix(tvos): let a remote swipe reach the top menu from a page | Not applicable (tvOS). | Not applied: Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept. |
| `eb6c9838` | 2026-10-29 | fix(networking): allow plain HTTP to servers on Tailscale and private names | Integrated. | Integrated. |
| `5fd87a99` | 2026-10-29 | fix(networking): refuse redirects from HTTPS to plain HTTP | Integrated earlier (cherry-pick 4491b6bc / tvOS equivalent). | Integrated earlier (cherry-pick 4491b6bc / tvOS equivalent). |
| `ab903b4b` | 2026-10-29 | fix(push): refuse HTTPS-to-HTTP redirects for saved-server push requests | Integrated. | Integrated. |
| `148d5d70` | 2026-10-29 | fix(ios): keep Continue Watching cards aligned on iPad (#950) | Integrated. | Integrated. |
| `f3347940` | 2026-10-30 | fix(player): wait 30 seconds before following a connection change mid-playback (#952) | Integrated. | Integrated. |
| `fd40ce61` | 2026-10-30 | feat(detail): let Back leave a More Like This chain in two steps (#959) | Integrated. | Integrated. |
| `1a7cceea` | 2026-10-30 | fix(player): show Buffer Ahead's buffer on the seek bar (#965) | Integrated. | Integrated. |
| `d1837b92` | 2026-10-31 | fix(tvos): outline the field a sign-in or address error is about (#966) | Integrated. | Integrated. |
| `538e2e9a` | 2026-10-31 | fix(tvos): fit the declined sign-in screen and stop saying where it was declined (#961) | Not applicable (tvOS code); merged. | Integrated. |
| `b697a962` | 2026-10-31 | fix(pairing): give each TV offer its own card so closing one can't leave a hidden card (#962) | Integrated. | Integrated. |
| `15f4153e` | 2026-10-31 | docs(license): add a platform library exception to the AGPL (#971) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `3bd75734` | 2026-10-31 | fix(player): autoplay only the series' next episode from Up Next (#972) | Integrated. | Integrated. |
| `9e94e24e` | 2026-11-01 | fix(tvos): outline focused cards and the current episode instead of the glass lift (#973) | Integrated. | Integrated. |
| `08c28c8e` | 2026-11-01 | feat(box-sets): browse, open and search movie box sets (#852) | Integrated. | Integrated. |
| `2dffa7af` | 2026-11-01 | fix(topshelf): read only the Continue Watching and Next Up rows (#980) | Integrated. | Integrated. |
| `cc87791c` | 2026-11-01 | feat(player): play embedded subtitles from the stream and switch them in place (#970) | Integrated. | Integrated. |
| `88498ec7` | 2026-11-01 | feat(navigation): fix the top menu and move Requests to the profile menu (#981) | Blocked by a dependency: Kyro's iPhone shell keeps the synced primary menu (PrimaryMenuBuiltin, nav.shortcuts), Movies/Series category roots and More menu. Upstream's fixed roots are not adopted; its router, routes, Requests-in-profile-menu and settings changes are integrated. | Blocked by a dependency: Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept. Pinned-library shortcuts and mixed-library scoping kept; non-navigation parts integrated. |
| `ddebb9fa` | 2026-11-02 | fix(navigation): align the profile menu with Android and the other TVs (#982) | Integrated: iOS profile menu adopted (panel) with Kyro's Live TV and For You rows. | Not applied: tvOS profile menu ordering lives in Kyro's top bar; Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept. |
| `eb654159` | 2026-11-02 | fix(notifications): recover Apple push after the installation key changes (#977) | Integrated. | Integrated. |
| `b2aeae1a` | 2026-11-02 | feat(auth): offer "Forgot password?" on sign-in when the server emails reset links (#887) | Integrated earlier (cherry-pick de1e852b / dba13c5d). | Integrated earlier (cherry-pick de1e852b / dba13c5d). |
| `04807485` | 2026-11-02 | fix(auth): let an account with a temporary password choose a new one (#874) | Integrated. | Integrated. |
| `9723df00` | 2026-11-03 | fix(box-sets): stop grouping box sets in library grids (#991) | Integrated. | Integrated. |
| `54cf0f34` | 2026-11-04 | feat(accounts): keep several accounts per server and add Change Account (#992) | Integrated with Kyro adaptation: accounts per server, Change Account, account-scoped caches (ported into Kyro's UICustomizationPreferences). Kyro keeps Sign Out in Settings, now routed to the shared confirmation; Who's Watching server chip removed as upstream did. | Integrated with Kyro adaptation: accounts and Change Account; Kyro's shell profile panel and Settings Sign Out now use the shared account confirmation; paired-profile lookup is per account. |
| `ffa6e518` | 2026-11-04 | fix(calendar): make calendar time zone tests independent of today (#1005) | Integrated. | Integrated. |
| `586e9ccf` | 2026-11-04 | fix(mac): make the selected sidebar row readable (#1011) | Not applicable: macOS app (not shipped by Kyro); merged. | Not applicable: macOS app (not shipped by Kyro); merged. |
| `1c0c01fb` | 2026-11-04 | fix(assets): draw the Silo wordmark from vector data (#1010) | Integrated. | Integrated. |
| `492a879d` | 2026-11-04 | fix(mac): show option names in settings dropdown menus (#1007) | Integrated. | Integrated. |
| `3b6cb2e6` | 2026-11-04 | feat(mac): show more of the backdrop on movie and series pages (#1009) | Integrated. | Integrated. |
| `2c03722c` | 2026-11-04 | fix(mac): open detail track selectors as drop-downs that list their tracks (#1008) | Integrated. | Integrated. |
| `bbd1e470` | 2026-11-04 | fix(macos): let a mouse click-and-drag scroll horizontal rails (#1006) | Integrated. | Integrated. |
| `bef81e86` | 2026-11-04 | ci: retry stalled Apple build metadata queries (#1012) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `5ac5267b` | 2026-11-04 | chore(player): update AetherEngine to upstream 7.56.0 and drop TrueHD Atmos and DTS:X rendering (#1013) | Integrated: AetherEngine 7.56 line; TrueHD Atmos/DTS:X toggle in Kyro's Advanced Playback gated on availability as upstream did. | Integrated. |
| `05753bf4` | 2026-11-04 | feat(pairing): send several servers and accounts to a TV from a phone (#1014) | Integrated. | Integrated. |
| `7baff3ef` | 2026-11-04 | feat(overlays): draw the combined Resolution + HDR + Audio poster badge (#1016) | Integrated. | Integrated. |
| `f42da472` | 2026-11-05 | feat(ios): show the profile and server at the top of the profile menu (#877) | Integrated: profile panel header with Kyro rows added. | Not applicable (iPhone and iPad). |
| `fd258d7d` | 2026-11-05 | fix(tvos): add Favorite and Finished to the audiobook detail page (#928) | Not applicable (tvOS code); merged. | Integrated. |
| `3e17f86c` | 2026-11-05 | fix(player): keep Fit video centred clear of the sensor housing (#1019) | Integrated. | Integrated. |
| `067e6cee` | 2026-11-05 | fix(tvos): return to the last focused hero action when moving up (#988) | Not applicable (tvOS). | Integrated. |
| `c9fb59be` | 2026-11-05 | fix(tvos): resume playback after a scrub commit that reanchors the stream (#1022) | Integrated. | Integrated. |
| `9720d636` | 2026-11-05 | feat(downloads): download the chosen version for a whole season (#1020) | Integrated. | Integrated. |
| `1f10c72d` | 2026-11-05 | fix(tvos): follow playback after Play/Pause resumes during a scrub (#994) | Integrated. | Integrated. |
| `b3d08d44` | 2026-11-05 | feat(downloads): use the series track preference for downloaded playback (#892) | Integrated. | Integrated. |
| `df891d2e` | 2026-11-05 | feat(requests): let users remove their own failed requests (#986) | Integrated. | Integrated. |
| `77def097` | 2026-11-05 | fix(ios): open Settings at once and stop reloading the profile avatar (#1025) | Integrated. | Not applicable (iPhone and iPad). |
| `abf4ac45` | 2026-11-06 | fix(tvos): keep profile rows still when focus moves on Who's watching (#1032) | Integrated. | Integrated. |
| `eb82bb86` | 2026-11-06 | fix(ios): anchor Duo status column actions to the bottom (#1033) | Integrated. | Integrated. |
| `e28300c6` | 2026-11-06 | feat(release): ship the Mac app to TestFlight (#1034) | Not applicable: Mac TestFlight release; merged, Kyro Mac bundle ID kept. | Not applicable: Mac TestFlight release; merged, Kyro Mac bundle ID kept. |
| `a316d9a3` | 2026-11-06 | fix(ios): run Requests rails to the screen edge (#1038) | Integrated. | Integrated. |
| `80198643` | 2026-11-06 | fix(ios): fill the open iPhone Duo with row pages (#1039) | Integrated. | Integrated. |
| `2ef3a171` | 2026-11-06 | feat(ios): put Close in the status column on the folded iPhone Duo (#1040) | Integrated. | Integrated. |
| `636d61ca` | 2026-11-06 | fix(release): give match its own copy of the macOS certificate types (#1046) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `8ed1558b` | 2026-11-07 | feat(player): scrub with a two-finger trackpad swipe (#1047) | Integrated. | Integrated. |
| `31a44e27` | 2026-11-07 | Ci/remove apple regression (#1049) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `35c08b7d` | 2026-11-08 | fix(player): stop the frame flash on 23.976 fps Matroska titles on Apple TV (#1057) | Integrated. | Integrated. |
| `55841508` | 2026-11-08 | fix(tvos): keep the top bar on the Requests page (#1060) | Not applicable (tvOS). | Not applied: Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept; Requests keeps Kyro's top bar behavior. |
| `6587e57a` | 2026-11-08 | fix(macos): hide the full-screen title bar with the player controls and toggle full screen on double-click (#1064) | Not applicable: macOS app (not shipped by Kyro); merged. | Not applicable: macOS app (not shipped by Kyro); merged. |
| `6a2fd94e` | 2026-11-09 | fix(macos): open the window large enough for sign-in without scrolling (#1073) | Integrated. | Integrated. |
| `97ecec1d` | 2026-11-09 | ci: move feature requests to Discussions and close out-of-policy pull requests (#1074) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `27cf4a24` | 2026-11-09 | fix(macos): give the onboarding tour a Mac layout (#1077) | Integrated. | Integrated. |
| `650a0b8a` | 2026-11-09 | fix(servers): stop a launch crash when saved servers include a duplicate (#1090) | Integrated. | Integrated. |
| `2a9a1b32` | 2026-11-09 | feat(i18n): apply the profile's app language and ship the translation catalogs on Apple (#1078) | Integrated: app language and catalogs. Kyro app name applied by scripts/kyro_brand_catalog.py; Kyro-owned screens keep English text. | Integrated: app language and catalogs. Apple TV keeps the Silo name as before. App Language picker is not in Kyro's Apple TV General page (profile language still applies). |
| `5c59d0a9` | 2026-11-09 | feat(i18n): add the Apple text helpers and the catalog text guard (#1079) | Integrated. | Integrated. |
| `55265991` | 2026-11-09 | feat(i18n): translate Apple settings, servers, accounts and diagnostics (#1080) | Integrated with Kyro adaptation: catalog text merged; Kyro's Settings overview, Diagnostics and Playback settings keep English text. | Integrated with Kyro adaptation: catalog text merged; Kyro's Apple TV General settings page keeps English text. |
| `17de0171` | 2026-11-09 | feat(i18n): translate the Apple player, downloads, audiobook and Remote Control text (#1081) | Integrated. | Integrated. |
| `5261b479` | 2026-11-09 | feat(i18n): translate the Apple browse and detail screens (#1082) | Integrated with Kyro adaptation: catalog text merged; Kyro's Movies/Series page and Search keep English text. | Integrated with Kyro adaptation: catalog text merged; upstream onMoveUp hooks removed from Apple TV pages. |
| `61235506` | 2026-11-09 | feat(i18n): read sign-in, pairing, profile, request, watch party and shell text from the catalog (#1083) | Integrated. | Integrated with Kyro adaptation: catalog text merged; Kyro's kept top-menu files keep their English text. |
| `301840fa` | 2026-11-09 | feat(i18n): format and mirror the Apple apps in the app language (#1084) | Integrated. | Integrated. |
| `acb1ea03` | 2026-11-09 | fix(i18n): fit longer labels and translate the remaining Apple text (#1085) | Integrated with Kyro adaptation (98% of surviving lines; Kyro-kept files: Navigation/UICustomizationPreferences.swift:0/4 Screens/Settings/IOSSettingsOverview.swift:0/1). | Integrated with Kyro adaptation (97% of surviving lines; Kyro-kept files: Navigation/UICustomizationPreferences.swift:0/4 tvOS/Screens/Settings/TVGeneralSettingsView.swift:0/2). |
| `be15e704` | 2026-11-09 | fix(i18n): write Arabic years in the app's digits and keep episode codes in ASCII digits (#1086) | Integrated. | Integrated. |
| `85679e7f` | 2026-11-09 | fix(siri): rename the search intent's catalog keys so App Store accepts the build (#1092) | Integrated. | Integrated. |
| `e792abdc` | 2026-11-10 | docs(agents): tell contributor agents to treat the code as someone else's (#1096) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `3abeaf4f` | 2026-11-11 | feat(menu): offer Switch Profile or Add Profile by profile count (#1103) | Integrated: Switch Profile / Add Profile row in the profile panel. | Partially integrated: shared menu rows; Kyro's top-bar profile panel unchanged (Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept). |
| `88f76ce4` | 2026-11-11 | fix(downloads): keep downloads when one saved record can't be read (#1097) | Integrated. | Integrated. |
| `e11c5aa8` | 2026-11-11 | fix(player): keep the controls hidden when a recap or the credits are skipped (#1100) | Integrated. | Integrated. |
| `b5c73e3a` | 2026-11-11 | fix(profiles): return to Who's Watching when the active profile was deleted (#1101) | Integrated. | Integrated. |
| `4e50ae36` | 2026-11-11 | fix(tvos): refresh a library's first page when it opens from the cache (#1106) | Not applicable (tvOS code); merged. | Integrated. |
| `b4f69c11` | 2026-11-11 | fix(player): show the playing audio track's format in the stream badges (#1105) | Integrated. | Integrated. |
| `1419de11` | 2026-11-11 | fix(detail): stay in Silo when the viewer cancels opening a trailer in YouTube (#1108) | Integrated. | Integrated. |
| `2d7a4011` | 2026-11-11 | fix(auth): let people cancel a server connection attempt (#1107) | Integrated. | Integrated. |
| `034d173e` | 2026-11-11 | fix(player): end a scrub in progress when playback finishes (#1109) | Integrated. | Integrated. |
| `e7b3a54d` | 2026-11-11 | fix(subtitles): keep a custom subtitle font at the chosen size (#1111) | Integrated. | Integrated. |
| `93488d3e` | 2026-11-11 | fix(subtitles): keep text subtitles on screen when the picture fills the display (#1114) | Integrated. | Integrated. |
| `e43612a1` | 2026-11-11 | fix(player): keep the controls up when a tap lands beside a button just after they appear (#1110) | Integrated. | Integrated. |
| `8d9b2395` | 2026-11-11 | feat(accounts): open Change Account at launch when several accounts are saved (#1104) | Integrated. | Integrated. |
| `feb2682f` | 2026-11-11 | fix(tvos): keep the Skip Recap and Skip Credits pill clear of the controls and the remote working (#1102) | Integrated. | Integrated. |
| `fe7aa020` | 2026-11-11 | feat(overlays): lay out poster badges and watch status as the web does (#1117) | Integrated. | Integrated. |
| `02cdb949` | 2026-11-11 | feat(downloads): say why Download is unavailable instead of hiding the button (#1115) | Integrated. | Integrated. |
| `ba3c2409` | 2026-11-11 | fix(account): send the active profile when listing and disconnecting sign-in identities (#1118) | Integrated earlier (cherry-pick f9a14a69). | Integrated earlier (cherry-pick f9a14a69). |
| `9718f17b` | 2026-11-11 | feat(browse): show the years a series ran on its poster (#1112) | Integrated. | Integrated. |
| `165f602c` | 2026-11-11 | fix(ios): claim AV1 and MPEG-2 direct play only within what the device decodes (#1099) | Integrated earlier (cherry-pick 42bf01b2 / 87db9655). | Integrated earlier (cherry-pick 42bf01b2 / 87db9655). |
| `b9446d5d` | 2026-11-11 | fix(player): fail a direct-play load that never opens so the server can replan (#1098) | Integrated earlier (cherry-pick c444dee5). | Integrated earlier (cherry-pick c444dee5). |
| `1fb21c50` | 2026-11-11 | feat(player): ask whether you are still watching after a run of auto-played episodes (#1091) | Integrated. | Integrated. |
| `b8bd65a8` | 2026-11-11 | fix(tvos): keep the Search title off the results after Back (#1066) | Integrated. | Integrated. |
| `4b2470ca` | 2026-11-11 | feat(player): show the end time on iPhone, iPad and Apple TV (#1087) | Integrated. | Integrated. |
| `7f2cbd92` | 2026-11-11 | feat(browse): jump to a letter in library grids on iPhone, iPad and Mac (#1119) | Integrated. | Integrated. |
| `026ac351` | 2026-11-11 | fix(tvos): let Down reach Search results below the Box Sets row (#1067) | Not applicable (tvOS). | Superseded on Kyro: Kyro's TVCatalogGrid row focus sections (accepted) already route Down into rows; upstream's eager first row not applied. |
| `7e478b26` | 2026-11-11 | fix(tvos): let Apple TV HD direct play 1080p MPEG-2 (#1125) | Integrated. | Integrated. |
| `a008b481` | 2026-11-12 | ci: require evidence on every pull request and close contributors' drafts (#1130) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `48a197d3` | 2026-11-12 | ci: check the string catalog without a silo-translations token (#1131) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `0660e273` | 2026-11-12 | docs: require parity issues in the other Silo clients (#1138) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `81ee36f8` | 2026-11-12 | feat(detail): show video, file and audio details on title pages (#1116) | Integrated. | Integrated. |
| `197b5c18` | 2026-11-12 | fix(tvos): restore the Edition selector on the detail page (#1127) | Not applicable (tvOS code); merged. | Integrated. |
| `02e20e0c` | 2026-11-12 | feat(ios): switch library pages from a dock above the tab bar on iPhone (#1137) | Blocked by a dependency: library page dock needs upstream's single Libraries root; Kyro's iPhone shell keeps the synced primary menu (PrimaryMenuBuiltin, nav.shortcuts), Movies/Series category roots and More menu. Dock source compiles but is not wired in. | Not applicable (iPhone only). |
| `5780c84f` | 2026-11-13 | fix(detail): open iPhone and iPad selectors as native menus (#1142) | Integrated. | Integrated. |
| `94a6095f` | 2026-11-13 | fix(detail): keep Auto within the chosen edition (#1143) | Integrated. | Integrated. |
| `e3a38bae` | 2026-11-13 | fix(tvos): keep a next-up pick made while the episode refreshes (#1150) | Not applicable (tvOS code); merged. | Integrated. |
| `1531620d` | 2026-11-13 | feat(ios): draw watch progress as a keyline bar on every card (#1151) | Integrated. | Integrated. |
| `fda71baf` | 2026-11-13 | chore(deps): bump addressable from 2.9.0 to 2.9.1 (#1153) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `0f4d3505` | 2026-11-13 | fix(tvos): keep focus in the library Sort panel instead of the top bar (#1135) | Not applicable (tvOS). | Partially integrated: Sort panel changes merged; its top-bar disabling relies on upstream's shell (Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept), so the panel's preference is published but unused. |
| `9df69eda` | 2026-11-13 | fix(tvos): open the library Sort panel on the current sort (#1136) | Not applicable (tvOS code); merged. | Integrated. |
| `1ed93647` | 2026-11-13 | fix(tvos): label the title page's selectors Version and Audio (#1120) | Not applicable (tvOS code); merged. | Integrated. |
| `417508d9` | 2026-11-13 | fix(detail): keep a subtitle pick on its track when the version changes (#1148) | Integrated. | Integrated. |
| `a82ff603` | 2026-11-13 | feat(calendar): show DIGITAL and PHYSICAL badges on movie releases (#946) | Integrated. | Integrated. |
| `c17d432c` | 2026-11-13 | fix(player): keep skip taps from flashing the scrub preview (#1050) | Integrated. | Integrated. |
| `f66a2b18` | 2026-11-13 | fix(detail): use the Apple TV Version icon on iPhone, iPad and Mac (#1157) | Integrated. | Integrated. |
| `4be5334f` | 2026-11-13 | fix(overlays): scale card badges with text size and poster size (#1158) | Integrated. | Integrated. |
| `2350f95e` | 2026-11-13 | fix(browse): drop the glass capsule behind the A–Z rail while dragging (#1160) | Integrated. | Integrated. |
| `23d95a35` | 2026-11-13 | fix(libraries): count the filtered list in the iPhone library header (#1159) | Partially integrated: filtered count in the browse model; Kyro's Movies/Series page header is unchanged. | Not applicable (iPhone only). |
| `710169c9` | 2026-11-13 | fix(browse): group thousands in library, collection and person counts (#1161) | Integrated. | Integrated. |
| `3651342e` | 2026-11-13 | feat(detail): open details from their card and drag them away on iPhone (#1162) | Integrated. | Integrated. |
| `6d90acb1` | 2026-11-14 | feat(ios): switch For You, Watchlist and Favorites from a dock on iPhone (#1163) | Blocked by a dependency: For You dock is turned off while Kyro's shared header hosts For You (dock source compiles). Watchlist/Favorites dock pages unused. | Not applicable (iPhone only). |
| `8655b06b` | 2026-11-14 | fix(home): drop Explore all from a Continue Watching row that shows its whole list (#1156) | Integrated. | Integrated. |
| `9f60d8ac` | 2026-11-14 | perf(detail): open detail pages from the tapped card and prewarmed data (#1167) | Integrated. | Integrated. |
| `016abe97` | 2026-11-14 | fix(tvos): stop closed top bar menus hiding page controls from focus (#1166) | Not applicable (tvOS). | Not applied: Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept. |
| `c667cf3b` | 2026-11-14 | fix(macos): show the TMDB score in the Home hero when there is no IMDb score (#1154) | Not applicable: macOS app (not shipped by Kyro); merged. | Not applicable: macOS app (not shipped by Kyro); merged. |
| `55da563c` | 2026-11-14 | feat(browse): match the web client's sort options on iOS, iPadOS, macOS and tvOS (#1048) | Integrated. | Integrated. |
| `08ff656f` | 2026-11-14 | fix(player): keep the resume point when playback stops early (#765) | Integrated. | Integrated. |
| `b6585b70` | 2026-11-14 | test(tvos): build the tvOS test bundle again (#1169) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `1d4b6248` | 2026-11-14 | fix(metadata): keep checking for a slow description translation after 45 s (#1028) | Integrated. | Integrated. |
| `fc86b201` | 2026-11-14 | fix(player): close the player from the Up Next pill, now labelled Close (#1171) | Integrated. | Integrated. |
| `9ff49dca` | 2026-11-14 | fix(tvos): let Left and Right seek while a skip pill has focus (#1175) | Not applicable (tvOS code); merged. | Integrated. |
| `c466777f` | 2026-11-14 | fix(detail): list Specials first as season zero on Apple TV and in Downloads (#1177) | Integrated. | Integrated. |
| `23c5e85b` | 2026-11-14 | fix(tvos): keep Search results beside the Grid keyboard (#1174) | Integrated. | Partially integrated: Search changes merged; TVCatalogGrid body keeps Kyro's accepted row focus sections. |
| `d5098c2b` | 2026-11-14 | refactor(player): show each playback stat once and group the player options (#1178) | Integrated. | Integrated. |
| `5569b192` | 2026-11-14 | fix(player): mark every credits range on the iPhone, iPad and Apple TV timeline (#1179) | Integrated. | Integrated. |
| `0de9be23` | 2026-11-14 | fix(player): mark every marker range on the timeline in the shared palette (#1180) | Integrated. | Integrated. |
| `e958f584` | 2026-11-15 | perf(detail): open audiobook pages from the tapped card like movies and series (#1181) | Integrated. | Integrated. |
| `f4075216` | 2026-11-15 | feat(chrome): fade the pinned header into the page on iPhone and iPad (#1184) | Partially integrated: header fade on Home, detail and shared chrome; Kyro's Movies/Series page (LibrariesTabView) keeps the Kyro header runway. | Not applicable (iPhone and iPad only). |
| `ca19185f` | 2026-11-15 | feat(i18n): ship Dutch from translations 2026.11.15-277265f (#1185) | Integrated. | Integrated. |
| `9b8b3528` | 2026-11-15 | fix(remote): show when a TV is connected and open the remote over title pages (#1187) | Integrated. | Integrated. |
| `9d3e20f3` | 2026-11-15 | feat(i18n): ship 13 more languages from translations 2026.11.15-8dbdfe4 (#1188) | Integrated. | Integrated. |
| `ec154f89` | 2026-11-15 | chore(i18n): sync translations 2026.11.15-0ba1666 (#1191) | Integrated. | Integrated. |
| `484d8237` | 2026-11-15 | fix(ios): keep the library dock and tab bar steady while audio plays (#1190) | Blocked by a dependency: refines the page docks (02e20e0c, 6d90acb1). | Not applicable (iPhone only). |
| `3d4d7d1f` | 2026-11-15 | fix(subtitles): stack text subtitles that are on screen at the same time (#1193) | Integrated earlier (cherry-pick c2d1f4db). | Integrated earlier (cherry-pick c2d1f4db). |
| `933381d6` | 2026-11-15 | fix(tvos): make top menu focus moves direct and its menus quicker to open (#1195) | Not applicable (tvOS). | Not applied: Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept; Kyro's top menu focus is physically accepted. |
| `a5a989c4` | 2026-11-15 | feat(downloads): download audiobooks and play them offline (#1192) | Integrated. | Integrated. |
| `c85526df` | 2026-11-15 | fix(tvos): land Down on About and open the full audiobook description (#1197) | Not applicable (tvOS code); merged. | Integrated. |
| `8e467f26` | 2026-11-15 | fix(macos): make the player, featured hero, subtitles and shortcuts feel native (#1196) | Integrated. | Integrated. |
| `8ba9c514` | 2026-11-15 | fix(tvos): show audiobook covers full size and sharp on library landings (#1198) | Integrated. | Integrated. |
| `d0e87752` | 2026-11-15 | fix(profiles): show long profile names in full on Who's watching (#1199) | Integrated. | Integrated. |
| `7bb8fe3d` | 2026-11-15 | fix(tvos): return to the previous screen on Back from Switch Profile (#1200) | Integrated (router change; inert on iPhone). | Partially integrated: router records a shell place, but Kyro's shell does not provide one, so Back from Switch Profile keeps Kyro's behavior (Kyro's accepted Apple TV top menu and focus architecture (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner, TVPrimaryMenuProjection) is kept). |
| `79302970` | 2026-11-15 | fix(tvos): stop the hero backdrop flashing when focus changes items (#1203) | Not applicable (tvOS code); merged. | Integrated. |
| `e0337595` | 2026-11-15 | feat(for-you): add an Audiobooks filter to Watchlist and Favorites (#1202) | Integrated. | Integrated. |
| `dce56e3c` | 2026-11-16 | fix(home): keep the row in place when removing a Continue Watching card (#1204) | Integrated earlier (cherry-pick 2aef2b4f / c771aad1). | Integrated earlier (cherry-pick 2aef2b4f / c771aad1). |
| `6eea7cf7` | 2026-11-16 | feat(home): show rows of collections on Home and library pages (#1211) | Integrated. | Integrated. |
| `29c0dd43` | 2026-11-17 | feat(recommendations): add Not interested on iOS, macOS and tvOS (#1214) | Integrated. | Integrated. |
| `0e17c3e3` | 2026-11-17 | fix(tvos): hide the timeline preview when Up Next takes over (#1213) | Integrated. | Integrated. |
| `d49d7bd1` | 2026-11-17 | fix(ios): line up the first row on Home, Libraries and For You (#1216) | Blocked by a dependency: aligns rows with the page docks (02e20e0c, 6d90acb1). | Not applicable (iPhone only). |
| `c5453eae` | 2026-11-17 | feat(tvos): give each corner of the Home backdrop its own color (#1218) | Integrated. | Integrated. |
| `648091a7` | 2026-11-17 | feat(tvos): blend the backdrop colors more slowly between items (#1217) | Integrated. | Integrated. |
| `b54fefb1` | 2026-11-18 | fix(detail): open the standard edition before comparing quality (#1220) | Integrated. | Integrated. |
| `9dabb621` | 2026-11-18 | fix(tvos): keep the hero wash out of the top-right corner (#1226) | Not applicable (tvOS code); merged. | Integrated. |
| `7e6fefda` | 2026-11-19 | docs: send siloserver.org docs changes to a docs issue (#1231) | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. | Not applicable: Silo repository CI, docs, tests or tooling; merged into the tree, no app change. |
| `0414ff74` | 2026-11-19 | fix(home): refresh watch state across Apple devices (#1234) | Integrated. | Integrated. |
| `1510bcde` | 2026-11-19 | fix(tvos): focus a control on the setup, sign-in and pairing screens (#1235) | Integrated. | Integrated. |
| `f70e16ae` | 2026-11-19 | fix(ios): round top corners of detail hero artwork (#1236) | Integrated. | Integrated. |
| `71a3beb9` | 2026-11-20 | fix(pairing): make device sign-in approval copy device-neutral and remove legacy match-word footnotes (#1238) | Integrated with Kyro adaptation (93% of surviving lines; Kyro-kept files: Screens/Settings/IOSSettingsOverview.swift:0/1). | Integrated. |
| `449ba476` | 2026-11-21 | chore(i18n): sync translations 2026.11.21-f78acfd (#1243) | Integrated. | Integrated. |
| `3709c5fb` | 2026-11-22 | fix(player): report a slow link on a stall only with slow-transfer evidence (#1237) | Integrated. | Integrated. |
| `131efb8c` | 2026-11-22 | feat(tvos): redesign detail More menu with episode watched, submenus, and side-anchored popover (#1253) | Not applicable (tvOS code); merged. | Integrated. |
| `07c4c0d4` | 2026-11-22 | feat(playback): default cellular quality to Auto up to 10 Mbps and cap Low Data Mode at 2 Mbps (#1254) | Integrated. | Integrated. |
| `c4cbdeb4` | 2026-11-23 | feat(detail): rate movies and series from the title page on iPhone, iPad, Mac and Apple TV (#1260) | Integrated. | Integrated. |
| `82b9bfab` | 2026-11-23 | fix(player): count reaching the end credits as watched in the player's own checks (#1256) | Integrated. | Integrated. |
| `80ae9437` | 2026-11-23 | feat(player): say when playback stopped because it was paused too long (#1261) | Integrated. | Integrated. |
| `d9bbdc77` | 2026-11-23 | fix(detail): centre the title and facts in the iPad and iPhone Duo sidebar (#1265) | Integrated. | Integrated. |
