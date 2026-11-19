# Kyro iOS settings backup coverage audit

Audit date: 2026-11-18. Baseline: Build 93 source on `kyro/m1-rebrand`. **Audit only; no behavior, schema, data, or IPA changed.** The accepted iPhone flow is not a claim that every preference is covered.

## Counting and evidence

The unit below is one independently user-editable persisted preference, not one Swift property, one channel, or one subtitle-style subfield. A composite editor persisted as one atomic setting (card presentation, subtitle appearance, menu order, or a category's pin list) counts once. An effective server value and its local cache count once, not twice. Runtime-only filters, histories, diagnostics, migration markers, and generated contract keys without an iOS editor are not counted. A conditional row counts if it is available on a supported server/device. `F` = exported, compared, selectively restored and undoable through the production store; `P` = backed up but with a qualification; `M` = missing, eligible in principle; `D` = needs a product/identity decision; `X` = intentionally excluded; `R` = registry-only flag/inert setting, not counted as a user preference; `C` = contract-only candidate, not counted. `Live` means the owning observable store or `@AppStorage` should repaint; `reload` means explicit refresh/invalidation is needed; `N/A` means not restored. The restore notification currently has **one** consumer, `LiveTVCategoryBrowser`; it is not a general app refresh bus.

Storage abbreviations: `UD` = `UserDefaults`; `SD` = `SharedDefaults`; `API` = canonical Silo settings API with a scope; `UD+API` = local cache backed by the API. Unless stated otherwise all rows persist across launches (`Y`). Defaults are source/contract defaults, not merely the value initially shown while an async read is pending. `—` for a conditional server default means the effective manifest value must be queried; it must not be inferred from a cache. Source anchors: [backup registry](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupLiveRegistry.swift), [codec](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift), [restore](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift), [model](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupModel.swift), [iOS Settings](../../iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift), [contract keys](../../iosApp/iosApp/Networking/SettingKeys.generated.swift).

**Inventory: 74 unique persistent, user-editable preferences: 16 F, 1 P, 43 M, 7 D, 7 X.** Twelve registry-only entries (`R`) and four contract/read-only candidates (`C`) are listed for transparency but excluded from that total. Build 93 registers **29** entries, but only **17** correspond to a currently exposed production user preference. The conservative eligible denominator is **60** (`F + P + M`), excluding 7 decisions and 7 intentional exclusions. Fully supported coverage is **16/60 = 26.7%**; counting the partial entry as present gives **17/60 = 28.3%**. The denominator will change after product decisions. This is source-level coverage, not an end-to-end test result for all 29 entries.

## Complete preference inventory

The `Key / field` column names the production key or canonical setting, **not** the backup-file ID. For the supported rows the backup ID is usually the same spelling as the label's group prefix; the exact mapping is in the registry. `compare/apply` is `yes` for F/P because both use the registered getter/setter. `no` means Build 93 neither exports nor compares/applies it. `P` explains the limitation in Risk. The recommendation column is the proposed disposition, not a change made by this audit.

| Setting | Screen / location | Key / field; storage; default; persists | Backup export / compare+apply | Runtime after restore | Recommendation | Risk |
|---|---|---|---|---|---|---|
| Fourth navigation tab | Settings → Navigation | `kyro.navigation.global.v1.fourthTab`; UD Codable; Sports; Y | F / yes | Live | Keep default | Low |
| Category layout | Live TV → Categories | `kyro.liveTV.categoryPreferences.build78.appearance`; UD; Hybrid; Y | F / yes | reload | Keep default | Low |
| Category grouping | Live TV → Categories | same prefix `.grouping`; UD; Provider Order; Y | F / yes | reload | Keep default | Low |
| Watch-screen guide layout | Live TV → Watch / Guide | `liveTV.watchGuide.style.v1`; UD / AppStorage; List; Y | F / yes | Live | Keep default | Low |
| Soccer extra statistics | No production control; internal Sports flag | `kyro.sports.theSportsDBSupplement.enabled`; UD; on; Y | R / yes | Next read | Remove from future default export | Not user-configurable; backup can create/restore an internal override |
| WTA match statistics | No production control; internal Sports flag | `kyro.sports.wtaMatchStats.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| Tennis news | No production control; internal Sports flag | `kyro.sports.tennisNews.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| ATP match statistics | No production control; internal Sports flag | `kyro.sports.tennisMyLifeStats.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| Tennis player info | No production control; internal Sports flag | `kyro.sports.tennisPlayerInfo.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| Download quality | Downloads & Storage | `downloads.preferredFormat`; UD via `DownloadSettings`; original; Y | P / yes | Live | Keep; fix fidelity | Registry maps an unrecognized stored format to `original`, so export can silently replace a current value |
| Wi-Fi-only downloads | Downloads & Storage | `downloads.wifiOnly`; UD; true; Y | F / yes | Live | Keep default | Low |
| Delete after watching | Downloads & Storage | `downloads.defaultDeleteWatched`; UD; false; Y | F / yes | Live | Keep default | New-subscription default only |
| Default storage cap | Downloads & Storage | `downloads.defaultMaxStorageGB`; UD; 0/unlimited; Y | F / yes | Live | Keep default | New-subscription default only |
| Downloads sort order | Downloads manager | `downloads.sortOption`; UD; largest first; Y | F / yes | Live | Keep default | Low |
| Keep watched downloads | Downloads & Storage | `downloads.keepWatchedDownloads`; UD; false; Y | F / yes | Live | Keep default | Low |
| Simultaneous downloads | Downloads & Storage | `downloads.simultaneousDownloads`; UD; 2; Y | F / yes | Live | Keep default | Device throughput varies |
| Buffer ahead | Advanced Playback | scoped `player.bufferAhead`; UD via `PlayerSettings`; Automatic; Y | F / yes | Live next playback | Keep optional/device | Disk/performance |
| Lossless multichannel bridge | Advanced Playback | scoped `player.losslessAudioEnabled`; UD; true; Y | F / yes | Live next playback | Keep optional/device | Hardware/audio path |
| Background playback / PiP policy | Playback | scoped `player.backgroundPlaybackEnabled`; UD; true; Y | F / yes | Live next lifecycle | Keep optional/device | PiP device availability checked |
| Deinterlacing mode | Advanced Playback | scoped `player.deinterlaceMode`; UD; Automatic; Y | F / yes | Live next playback | Keep optional/device | Hardware path |
| Deinterlacing field rate | Advanced Playback | scoped `player.deinterlaceFieldRate`; UD; Full Motion; Y | F / yes | Live next playback | Keep optional/device | Hardware path |
| TrueHD Atmos/DTS:X heights | Advanced Playback | scoped `player.trueHDAtmosEnabled`; UD; true; Y | F / yes | Live next playback | Keep optional/device | Audio capability |
| Backup's global navigation style | No production control | `kyro.navigation.global.v1.style`; UD Codable; Classic; Y | R / yes | No active UI | Stop exporting; retain old-file decoder | Wrong store for floating-navigation editor |
| Backup's global starting edge | No production control | same record `.startingEdge`; UD; Right; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global idle behavior | No production control | same record `.idleBehavior`; UD; Collapse; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global auto-collapse | No production control | same record `.autoCollapse`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global haptics | No production control | same record `.hapticsEnabled`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global thumb scrubbing | No production control | same record `.thumbScrubbing`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global drag permission | No production control | same record `.allowsDragging`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Live TV floating navigation style | Live TV → Navigation (non-unified/iPad) | `kyro.liveTV.navigation.v1.style`; UD Codable; Classic; Y | M / no | Live | P2/device | Exposed editor writes legacy store, not backup's global store |
| Live TV floating starting edge | Same | same record `.startingEdge`; UD; Right; Y | M / no | Live | P2/device | Device geometry |
| Live TV floating idle behavior | Same | same record `.idleBehavior`; UD; Collapse; Y | M / no | Live | P2/device | Low |
| Live TV floating auto-collapse | Same | same record `.autoCollapse`; UD; true; Y | M / no | Live | P2/device | Low |
| Live TV floating haptics | Same | same record `.hapticsEnabled`; UD; true; Y | M / no | Live | P2/device | Low |
| Live TV floating thumb scrubbing | Same | same record `.thumbScrubbing`; UD; true; Y | M / no | Live | P2/device | Low |
| Live TV floating drag permission | Same | same record `.allowsDragging`; UD; true; Y | M / no | Live | P2/device | Low |
| Profile selection behavior | General | `profileLaunchState.v1.behavior`; SD Codable; Automatic; Y | M / no | reload | P0 portable behavior only | Must not include remembered profile ID or account epoch |
| Show advisory age | General | `catalog.show_advisory_age` profile API; false; Y | M / no | reload | P1 profile group | Server contract/version and profile identity |
| Media card presentation (preset, poster size, captions) | Interface | `ui.card_presentation`; API + scoped SD cache; standard; Y | M / no | reload | P0 profile/family group | Atomic composite; inherited vs explicit and sync conflicts |
| Primary menu order and visible shortcuts | Interface | `nav.primary_menu` + `nav.shortcuts`; API + scoped SD cache; contract layout; Y | M / no | reload | P0, two atomic records | Contains library IDs; resolve against destination catalog |
| Show title art | Interface | `ui.title_art`; profile/profile_device API + cache; on; Y | M / no | reload | P1 | Preserve apply-to-all scope semantics |
| Theme music enabled | Interface | `ui.theme_music_enabled`; profile_device API; off; Y | M / no | reload | P1 | Server capability |
| Loop theme music | Interface | `ui.theme_music_loop`; profile_device API; off; Y | M / no | reload | P1 | Server capability |
| Blur unwatched episode images | Playback | `catalog.hide_unwatched_episode_images`; profile API + cache; false; Y | M / no | reload | P0 | Profile-scoped, server revision gate |
| Hide unwatched episode descriptions | Playback | `catalog.hide_unwatched_episode_overviews`; profile API + cache; false; Y | M / no | reload | P0 | Profile-scoped, server revision gate |
| Streaming resolution | Playback | `playback.preferred_quality`; profile_device API + scoped UD cache; auto; Y | M / no | reload | P0 | Must preserve inherited/explicit state |
| Maximum bitrate | Playback | `playback.max_bitrate_kbps`; profile_device API + cache; unset; Y | M / no | reload | P0 | Distinct axis; no compound overwrite |
| Lower quality when buffering | Playback | `playback.buffering_quality_mode`; profile_device API + cache; contract default; Y | M / no | reload | P1 | Contract revision gate |
| Cellular quality | Playback | `playback.cellular_preferred_quality` and `.cellular_max_bitrate_kbps`; profile_device API + cache; 720p/2000 Kbps; Y | M / no | reload | P1, atomic pair | Device/network applicability |
| Preferred audio language | Playback | `playback.audio_language`; profile_device API + cache; none; Y | M / no | reload | P1 | Effective value can mask scope |
| HDR | Playback | `player.hdr_enabled`; profile_device API + cache; true; Y | M / no | reload | P1/device | Hardware applicability |
| Dolby Vision | Playback | `player.dolby_vision_enabled`; profile_device API + cache; true; Y | M / no | reload | P1/device | Depends on HDR |
| Seek cache | Advanced Playback | `player.seek_cache_enabled`; profile_device API + cache; true; Y | M / no | reload | P1/device | Performance |
| Auto-play next episode | Playback/player | `playback.auto_play_next`; profile_device API + cache; true; Y | M / no | reload | P0 | Do not confuse with `player.autoPlayNextEpisode` cache |
| Show Next Up timing | Playback | `playback.next_up_prompt_seconds`; profile_device API + cache; 30s; Y | M / no | reload | P1 | Validate choices |
| Skip intros | Playback | `playback.intro_skip_mode`; profile_device API + cache; contract default; Y | M / no | reload | P1 | Legacy `skipIntros` is cache/migration only |
| Skip credits | Playback | `playback.auto_skip_credits`; profile_device API + cache; false; Y | M / no | reload | P1 | Low |
| Video skip back | Playback | `player.video_skip_back_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Four-key seek contract; server revision gate |
| Video skip forward | Playback | `player.video_skip_forward_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Same |
| Audiobook skip back | Playback | `player.audiobook_skip_back_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Same |
| Audiobook skip forward | Playback | `player.audiobook_skip_forward_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Same |
| Subtitle language | Subtitles | `playback.subtitle_language`; profile API; none; Y | M / no | reload | P0 | Respect profile vs series override |
| Subtitle behavior | Subtitles | `playback.subtitle_mode`; profile API; auto; Y | M / no | reload | P0 | Respect profile vs series override |
| Show forced subtitles | Subtitles | `playback.show_forced_subtitles`; profile API; true; Y | M / no | reload | P1 | Respect profile vs series override |
| Metadata language | Subtitles | `catalog.metadata_language`; profile API; none; Y | M / no | reload | P1 | AI/server capability |
| Subtitle appearance (font, color, opacity, outline, background, position) | Subtitles/player | `playback.subtitle_appearance`; profile or profile_device API + cache; default appearance; Y | M / no | reload | P1, one atomic record | Preset fields are not separate persisted settings; preserve scope |
| Match device caption settings | Subtitles/player | `subtitle.matches_device` / scoped `player.subtitleMatchesSystemAppearance`; UD/device state; false; Y | M / no | reload | P1/device | iOS Accessibility values themselves must not be exported |
| Subtitle appearance only on this device | Subtitles/player | scoped `player.subtitleUsesDeviceAppearanceOverride`; UD + API scope; false; Y | M / no | reload | P1/device | Scope transition must not erase profile choice |
| Video sizing/aspect | In-player settings | `player.video_gravity`; profile_device API + cache; Fit; Y | M / no | reload | P1/device | Active session may need player command |
| Playback speed | In-player settings | `player.playback_speed`; profile_device API + cache; 1.0; Y | M / no | reload | P1 | Validate allowed numeric values |
| Orientation lock | Player | `player.orientation_mode`; profile_device API + cache; Landscape Locked; Y | M / no | reload | P1/device | iPhone geometry |
| Subtitle sync offset | Player | `player.subtitle_sync_ms`; profile/device API + cache; 0ms; Y | M / no | reload | P2 | Live player command needed |
| Preserve browse sort/filters | Library browse | `ios.browsePrefs.<server>.<profile>.<library>[.type-*].preserve`; SD; true; Y | D / no | reload | Decide optional/catalog-bound | Scope and ID mapping; turning off deletes saved state |
| Remembered browse sort/filters | Library browse | same prefix `.state`; SD Codable; none; Y | D / no | reload | Decide optional/catalog-bound | Catalog-dependent filter IDs; not one row per library |
| Pinned/hidden Live TV categories | Categories | `kyro.liveTV.categoryPreferences.build78.provider.<UUID>.pinned/.hidden`; UD Codable; empty; Y | D / no | reload | Decide optional/provider-bound | Category names can collide across providers; preserve order and avoid wrong catalog |
| Favorite Live TV channels | Guide/channel actions | `liveTV.favorites.v1`; UD string IDs; empty; Y | D / no | reload | Decide optional/provider-bound | IDs embed provider UUID; do not import blindly |
| Favorite movies/series/other library items | Item detail → Favorites | server `/api/v2/favorites` database; empty; Y | D / no | reload | Decide optional/profile-bound data | Server-owned collection, not a scalar setting; catalog IDs need matching and merge policy |
| Active Live TV provider/playlist configuration | Live TV Settings | `liveTV.providers.v1`; UD Codable; none; Y | X / no | N/A | Exclude | URLs and credentials may be embedded |
| Selected Sports league/category | Sports Hub | `kyro.sports.selectedLeague` / `.selectedCategory`; UD; NFL/All; Y | X / no | N/A | Exclude as navigation state | Persisted last location, not a durable preference |
| Calendar filter | Calendar | `calendar.filter`; UD; all; Y | D / no | reload | Decide optional personalization | Persisted filter, not exposed in Settings |
| Selected library / browse page | Library tabs | scoped selected-library ID / `ui.library_page_state`; UD/API; first library; Y | X / no | N/A | Exclude navigation state | Library IDs are server-specific |
| Diagnostics destination | Privacy | diagnostics consent model; account/server storage; hosted; Y | X / no | N/A | Exclude | Privacy routing must be chosen by user on destination |
| Crash-report consent | Privacy | diagnostics consent model; account/server storage; Ask; Y | X / no | N/A | Exclude | Never transfer consent silently |
| Watch Party experimental switch | Appearance / optional features | `experimental.watchParty`; UD; off in Release; Y | X / no | N/A | Exclude | Experimental/internal flag |
| EPG SQLite storage / diagnostics overlays | Advanced diagnostics | `kyro.internal.epg.sqliteStorage` and diagnostics keys; UD; off; Y | X / no | N/A | Exclude operational switches | Debug/performance, not portable preference |
| Hidden libraries | Library visibility (no iOS editor found) | `ui.disabled_library_ids`; API + cache; none; iOS read path | C / no | N/A | Verify iOS editor first | Library IDs cannot be assumed stable; current Apple path only reads |
| Library pin/order | Interface/library actions | `ui.library_order` / `ui.sidebar_pins`; API; contract default; Y | D / no | reload | Decide optional/catalog-bound | Catalog IDs and cross-client scope |
| Home hide watched items | Home customization | `home.hide_watched_items`; API; contract default; unverified iOS persistence | C / no | N/A | Verify iOS editor first | Contract key alone does not prove production iOS control |
| Requests watchlist auto-request | Watchlist/Requests | `requests.watchlist_auto_request`; API; contract default; unverified iOS persistence | C / no | N/A | Verify iOS editor first | May be server preference; avoid claiming iOS editor from manifest |
| Search media scope | Search | `search.media_scope`; API; contract default; unverified iOS persistence | C / no | N/A | Verify iOS editor first | Search session filters must not be confused with saved scope |

**Count qualification:** the four `C` rows are *candidates*, not proven iOS-editable preferences. They are not in the 74 or eligible denominator. Their status must be resolved with a focused production-path check before implementation. The category pin/hidden row represents two fields within one provider-scoped customization record, not a count of category names. The server Favorites collection is counted once as a user-managed collection, not once per title; product may choose to treat it as library data outside settings backup.

## Backup implementation findings

* The allowlist is `SettingsBackupLiveRegistry.make`. The exporter iterates only the selected groups, reads the owning store and validates the scalar. It never scans all of `UserDefaults`. Nine groups exist: five portable (navigation, categories, guide, sports, downloads) and four opt-in same-idiom groups (playback, PiP, advanced A/V, navigation layout). All 29 registered IDs have both read and write closures. There is **no export-only registered entry**, and no evidence of a stale key for the registered category or guide settings: category appearance/grouping use the new dedicated keys, with legacy data only as fallback.
* **Twelve entries are misleading as user preferences.** Five Sports supplement flags have a real UD read/write path and default on, but no production control outside Backup & Restore; they are internal feature flags. Seven `nav.*` entries use `KyroGlobalNavigationStore` (`kyro.navigation.global.v1`), while the actual floating Live TV settings editor uses `KyroLiveTVNavigationStore` (`kyro.liveTV.navigation.v1`). The global style/geometry fields are not consumed by the current native shell; the Live TV editor is only offered when unified navigation is off (including iPad). Thus Build 93 backs up the **wrong storage record** for those seven visible legacy controls. Do not repurpose old backup IDs to mean the legacy store; preserve old-file interpretation and add new IDs if approved.
* The `downloads.preferredFormat` getter's `DownloadFormat(rawValue:) ?? .original` can export **original instead of the actual stored value** when a future/unknown format is stored. Treat this as a fidelity defect, not a reason to add an unsupported string to a backup.
* `SettingsBackupCodec` is schema 1, `minReaderVersion` 1. It rejects oversized (>256 KiB), deep, malformed, mis-hashed, unsafe-name/value files; unknown safe groups/IDs survive decode but preview counts and skips them. Validation accepts booleans, integers and short strings only; current safety fragments reject names containing `profile`, `server`, `provider`, `account`, `url`, `database`, etc. This blocks a naïve registry expansion for scoped or structured settings. Do not weaken this filter just to fit new data.
* Preview compares the incoming value with the registered getter and marks unchanged/invalid/unsupported; the screen selects only changes by default. Apply re-reads each selected setting, journals all previous/applied values **before** writing, verifies read-back, rolls back attempted writes on failure, and keeps the journal for one Undo. Undo skips values changed after restore. The multi-store operation is **not crash-atomic**; recovery is offered when Backup & Restore reopens. The journal is a single local atomic file, not a database transaction.
* The restore notification is posted after apply/undo/recovery, including failures. `LiveTVCategoryBrowser` reloads the category values; the guide uses `@AppStorage` for style. Observable navigation/download/player stores should update their own bound views, but new server-backed groups will require explicit async refresh of their owner, player session and open screens. A notification alone does not prove this.
* Server-backed rows are deliberately absent because their setters can enqueue network writes and can affect profiles/other devices. Their UD/SD caches are **not** authoritative persistence. Backing up a cache would risk exporting defaults, a prior profile's value, or a value that the server rejected. Scope/source (inherited vs explicit) is part of the semantic value.
* No evidence in the inspected iOS settings paths of a persisted user theme, notification switch, or general accessibility preference that should be added now. iOS caption/notification permissions live in system settings; contract keys such as `ui.theme`, `ui.high_contrast` and `ui.text_scale` are not proof of an iOS editor. Temporary playback position, current channel, recents, cache, download files, pairing/authentication, tokens, URLs, identities, and provider credentials remain outside settings backup.

## Priority and Build 94 proposal

**P0:** profile-selection behavior without identity; media-card presentation and menu customization; spoiler switches; quality resolution/bitrate; auto-play next; profile subtitle language/behavior. These are prominent settings whose loss is visible after reinstall. **P1:** title art/music, advisory age, remaining playback choices, seek intervals, subtitle style and forced captions, metadata language, device caption mode, player aspect/speed/orientation, and supported download fidelity fix. **P2:** actual legacy Live TV floating controls (not the global shadow record), subtitle sync, catalog-bound browse/category/favorite/library customizations after identity policy, and advanced controls not already covered. This is prioritization, not permission to implement.

1. Keep the schema-1 decoder and all Build 93 IDs/values intact. A Build 94 file with only new scalar IDs in existing groups may stay schema 1/minReader 1; older builds will skip unknown safe IDs. New structured records, scoped values or explicit provenance need a **new schema version** (or a carefully versioned new group) with `minReaderVersion` chosen honestly. Preserve the old decoder; translate old IDs through the existing registry. Never reinterpret an old ID's meaning.
2. Add a typed production-preference registry that declares key, owner, default/inheritance, scope, sensitivity, backup policy and refresh hook. Compare it to the backup registry in a focused test. Do not enumerate all `UserDefaults` or the generated contract enum and assume everything is a user preference.
3. For server-backed preferences, read confirmed authoritative values and explicit scope; never export cache snapshots as settings. Plan per-scope writes, capability checks, validation and conflict behavior. Stage a restore point before network writes; apply only selected differences; verify server read-back; retry idempotently; on failure roll back changed scopes and retain a resumable failure record. If those guarantees cannot be met, keep that group out of Build 94 rather than implying Undo works.
4. Put catalog-bound favorites, hidden categories, browse filters and library/menu IDs in an **off-by-default optional group** only after a user-approved source/destination matching rule. Include a non-secret catalog fingerprint or mapping plan, preview unmatched items, and never overwrite another provider's catalog. The current scalar-only/200-entry/256-KiB envelope and sensitive-name filter cannot carry arbitrary arrays safely; design bounded structured validation and diff semantics first.
5. Refresh each owner after apply/undo: category browser, Live TV service/guide, navigation shell, UI customization, title art/music, spoiler/seek/advisory stores, profile editor, player settings and active playback bridge as applicable. Test a visible screen and a reopened app. Unsupported or renamed keys should appear as skipped, never reset another setting.

### Focused automated checks (no Simulator/full suite)

For every registered production preference, use isolated UD/SD or fake API transport and assert: change the **real owner**, export, change again, preview exact difference, selectively restore, verify authoritative persistence and owner refresh, then Undo. Test untouched keys, inherited-vs-explicit scopes, unavailable server, unsupported contract, cross-profile/catalog mismatch, changed-since-restore, write failure/read-back failure, crash recovery, and Build 93 fixture import. Add a registry completeness test comparing the iOS user-editable inventory to backup policy (`included`, `optional`, `excluded`, `decision`) so a new setting requires an explicit disposition. Run focused Foundation/XCTest in GitHub Actions; do not resume suspended UI/Simulator suites for this audit.

### Decisions required before implementation

1. Should profile/family-synced preferences be backed up at all, and if so should restore write this profile only or also preserve device overrides? This changes data on the server and potentially other devices.
2. Should Live TV and server-library Favorites, hidden/pinned categories, library/menu IDs and per-library sort/filter state be optional? If yes, what constitutes a matching provider/catalog/profile, and should unmatched entries be skipped or manually mapped?
3. Should privacy/consent and experimental/diagnostic controls remain excluded? Recommendation: **yes**. Should the persisted Calendar filter be included as a minor preference or treated as last-view state?
4. Confirm whether legacy floating navigation style should remain presented in backup when unified navigation is active, and how an unavailable download format should be represented without silently substituting `original`.

**Readiness:** ready for review, **not** for Build 94 implementation or packaging. No tests were run because this change is documentation only; the counts and production-path conclusions are static source audit findings, not runtime verification.

## Build 94 implementation addendum

This section records work after the baseline audit; the original 74/60 and Build 93 16/29 figures above remain the historical baseline. Local backup behavior landed in `ef4236b15e0b635a1724e19ce6f0ffcc677639e1`. The Calendar filter and the other 29 local preferences were verified together at `92029107dc5db9f43f1176c41eff21a0b015f94e`. **No Build 94 IPA has been built.**

| Disposition | Preferences / entries |
|---|---|
| Baseline fully covered | 16 real user preferences |
| Baseline partial, now fixed | Download quality: unknown raw values are omitted from new exports rather than replaced by `original`; preview and Undo retain the actual raw previous value |
| Newly covered from baseline missing list | 7 floating Live TV navigation fields from the editor's actual `kyro.liveTV.navigation.v1` store; profile-selection behavior only; device caption-matching toggle only |
| Newly discovered local preferences, now covered | Audiobook visibility (`AppNavPreferences`); floating Live TV destination order and hidden-destination set |
| Calendar filter, now covered | `calendar.filter` through `CalendarFilterPreference`. Missing or unrecognized stored values stay Following, which is what the Calendar screen shows. The selected day and week are not persisted and are not backed up |
| Removed from new exports | 5 internal Sports supplement flags and 7 dormant global navigation-layout fields. Schema-1 Build 93 files still decode; these 12 old entries are reported as skipped and never written to the wrong store |
| Currently fully covered | **30 of 30 approved local preferences (100%)**; **30 of 64** in the audit's broader potential-eligibility denominator (46.9%). The other 34 are blocked by server ownership under the approved policy |
| Intentionally excluded | Credentials, tokens, provider definitions/URLs, privacy consent, diagnostics, caches, session state, device-specific saved handle positions |

The inventory is now **77** unique persisted user preferences/collections. The broad audit denominator grew from 60 to **63** because the baseline audit missed three real local controls: audiobook visibility and the two Live TV destination customizations. It did already include the seven floating navigation fields, profile launch behavior and the caption-matching toggle. The Calendar filter was a decision item outside that 63. Including it makes the broad denominator **64** and the actionable local denominator **30**, all now registered. The other 34 in the broad denominator are not safe local restore targets. In particular, card/menu presentation, quality, language, spoiler settings, title art and theme music are API-backed, and their local `UserDefaults`/`SharedDefaults` representations are caches or pending-write state. Exporting those caches or restoring via them would be misleading; writing the API would violate the approved server-ownership rule. They remain an explicit blocked gap, not a silent default-value export.

### Catalog-bound group blocker

No optional catalog group was added. `LiveTVProvider.id` is a local UUID; [M3U channel IDs](../../iosApp/iosApp/LiveTV/LiveTVModels.swift) hash that UUID with guide ID/name, and [Xtream IDs](../../iosApp/iosApp/LiveTV/LiveTVService.swift) hash it with a numeric stream ID. A matching numeric stream ID, name, provider type or channel count **does not prove** a matching catalog. A provider UUID alone proves only the same local provider record, not unchanged playlist contents. Category customizations use names within that local provider UUID; Favorites use the generated channel IDs. The iOS source exposes hidden **categories**, not a persisted hidden-channel control, so no hidden-channel preference can be added by assumption. Server-library Favorites are a separate profile-scoped server database collection. The currently available non-secret fields do not provide a verified cross-install provider/catalog identity, and the schema-1 scalar envelope cannot represent bounded per-item add/replace/skip previews with robust Undo. Per the approved rule, mismatches are not imported and no catalog-specific data is exported yet. A future optional group requires an authoritative, non-secret stable identity and explicit transactional/Undo design rather than a newly invented fingerprint.

### Compatibility, runtime and verification

New scalar IDs/groups remain in schema 1 with `minReaderVersion = 1`. Build 93 files import through the existing decoder/checksum checks. Existing supported IDs retain their meaning; the old Sports and global-layout IDs are counted as unknown/skipped, never reinterpreted as the new Live TV editor IDs. New local setters update their observable owners; the existing category notification still refreshes its separate local copy. Device-specific groups now export by default but remain same-idiom-only at restore and are not automatically selected for restore, preserving the accepted review safety behavior. The Review screen displays a skipped count even when no supported setting differs.

Focused production-adapter tests cover export → change → preview → selective restore → persistence → Undo for floating navigation, destination order/visibility, profile launch, audiobook visibility, download format, the local caption toggle, and the Calendar filter. A Calendar restore reloads the open screen's filter and leaves the visible week and selected day alone. The production navigation store's persisted CodingKeys are compared with the backup registry so adding a new stored field without a backup disposition fails a test. This is a focused guard, not a claim of automatic discovery of every future Swift setting; new owner stores still need an explicit backup-policy review.

The Calendar filter is now one of the 30 local preferences. It was the open product decision in the previous addendum. The selected day and week remain transient and are excluded. The previous 29 local preferences are unchanged.

**Test result:** [Cloud Simulator run 44462658968](https://github.com/jmargocubs/Kyro/actions/runs/44462658968) on `92029107dc5db9f43f1176c41eff21a0b015f94e` ran `SiloTests/SettingsBackupLiveRegistryTests`: 26 tests, 0 failures. That run includes the Calendar filter plus the previous local preferences, Build 93 legacy skips, and the server-setting exclusions. The earlier 25-test pass on `8fbad5dc` did not include the Calendar filter.

**Readiness:** Build 94 is ready for the separate unsigned IPA workflow as version 1.0.0 build 94, an unverified pre-release. It is not stable until a physical-iPhone acceptance pass. No IPA has been built in this change.

## Unified-backup follow-up (2026-11-19)

The physical-iPhone acceptance pass found a product-blocking gap: a Build 94 backup restored the fourth navigation tab, but **did not restore playback resolution or subtitle language** after those were changed to 480p and Chinese. The earlier readiness statement above is historical; Build 94 is **not** ready as a complete-settings-backup beta.

The current registry still has 30 entries, all local. `SettingsBackupLiveRegistry.standard()` explicitly excludes server-authoritative values. Its synchronous `BackupSetting.read` and `write` closures feed a synchronous exporter, preview planner, applier, and Undo journal. That design cannot safely incorporate the authenticated, asynchronous settings API by reading `PlayerSettings` caches or by enqueueing its setters: preview would not know the authoritative value, and immediate read-back could report success before a server write persisted.

The current source confirms these owners for the three-setting reproduction:

| Preference | Authoritative path | Build 94 backup status |
|---|---|---|
| Fourth tab | `KyroGlobalNavigationStore.preferences.fourthTab`, device-local | Registered as `navigation.fourthTab`; export/restore/Undo supported |
| Streaming resolution | `playback.preferred_quality`, `profile_device` settings API; `PlayerSettings` is a local observable/cache and write coordinator | Not registered; export omits it |
| Subtitle language | `playback.subtitle_language`, `profile` settings API through `ProfileSettingsWriter` | Not registered; export omits it |

The **64** figure is the potential-eligibility denominator from the Build 94 addendum, **not** 64 confirmed-safe portable settings. It consists of 30 registered local preferences plus 34 API-backed candidates. The full inventory remains 77 persisted user preferences/collections, including entries that require an identity decision or are intentionally excluded. The table above and the original inventory identify the production owner; neither constitutes completion of the 34 server-backed adapters.

Implementation must retain one `.kyrosettings` file and one review screen, but move export, preview, apply, and Undo to an asynchronous typed-adapter pipeline. Each API adapter must capture the authenticated server/profile identity, check capabilities and scope, read the canonical value (including inherited-versus-explicit provenance), write through `SiloAPI.putValue` or `deleteValue`, and confirm with a fresh API read. A failed or offline read must mark that setting unavailable, **not** substitute a cache. The journal must retain enough scope and identity to refuse Undo against a different profile or server. Schema 1 must remain decodable; new scoped records need a versioned envelope with integrity and unknown-field handling. Catalog/provider-bound customizations remain excluded until a stable, non-secret identity and a safe merge/Undo policy are established.

No implementation or cloud test result for this follow-up is claimed by this audit. The iPhone reproduction remains failing until a later code change and a new physical-device acceptance pass prove otherwise. No IPA should be built for this follow-up without the separate device-workflow approval.

## Schema-2 implementation status (2026-11-19)

The paragraph immediately above describes the **pre-implementation** state. The implementation in this worktree adds one asynchronous production export/import path, retaining the existing local registry and schema-1 decoder. The iOS UI now uses that path. A schema-2 document carries all selected local groups and two API-backed groups in one payload. The SHA-256 integrity check covers the scope metadata. The metadata is a SHA-256 fingerprint of the server's verified deployment ID and selected profile ID, not their raw values, URLs, credentials or tokens. The authenticated API remains the authority and refuses requests after an owner switch. A destination mismatch skips remote values while allowing safe local values to be reviewed separately.

### Disposition of the 64 potential candidates

| Class | Count | Disposition |
|---|---:|---|
| Device-local, portable | 14 | Registered through the existing production stores; selected by default for export |
| Device-local, same-idiom | 16 | Registered through the existing production stores; export selected by default, restore opt-in and restricted to phone/pad match |
| API-backed, now implemented | 3 | `playback.preferred_quality` at `profile_device`, `playback.audio_language` at `profile_device`, and `playback.subtitle_language` at `profile`; require a verified server and matching profile for restore |
| Other API-backed candidates | 31 | **Not implemented.** Do not call these backed up, restored or proven ineligible merely because their adapters are absent |

Thus **33/64 candidates are confirmed supported in this implementation**, including **17 cross-device-portable choices** (14 local plus three scoped API choices) and 16 same-idiom local choices. The *final* eligible total among the 64 remains undetermined until the other 31 receive their own API/scope/validation review. The 77-row historical inventory above remains the source-by-source inventory; it includes seven decision items and seven intentional exclusions outside the 64 denominator.

The 31 unsupported API candidates are classified by authoritative owner and risk, rather than silently exported from caches:

| Owner / risk | Candidates still unsupported |
|---|---|
| Profile-scope scalar API | Advisory age; both unwatched-episode spoiler controls; four video/audiobook seek intervals; subtitle behavior; forced subtitles; metadata language |
| Profile-device scalar API | Maximum bitrate; buffering quality mode; audio language; HDR; Dolby Vision; seek cache; auto-play next; Next Up timing; intro mode; skip credits; video gravity; playback speed; orientation; subtitle sync offset; theme music and its loop flag |
| Composite, policy- or catalog-sensitive API/scope | Card presentation; primary menu and shortcuts (library IDs); title art's profile-versus-device scope; cellular quality pair; subtitle appearance record; subtitle appearance's device-only scope transition |

This grouping accounts for the remaining 31 candidate rows from the original inventory. Provider-bound pins, hidden categories and Live TV Favorites, catalog-bound Favorites and browse state, server connection definitions, credentials, diagnostics consent, transient navigation, and unsupported contract-only keys are **outside** the 64. They remain excluded for the identity, privacy, or non-preference reasons stated in the inventory. No provider/catalog identity is guessed from names or local UUIDs.

The remote adapter reads batched effective values with the existing authenticated settings API, preserves inherited versus explicit values, validates scalar values, writes with `putValue` or `deleteValue` at the authoritative scope, and confirms a fresh authoritative read. Playback resolution and Audio Language are `profile_device` settings; Subtitle Language is profile-scoped. Audio Language's empty/no-preference state means no device override, so it is encoded as inherited and restored by deleting only that destination profile-device row. Export flushes queued player writes and refuses to proceed while writes remain unsettled. Preview never substitutes `PlayerSettings` or profile caches when offline. Restore journals previous remote values and fingerprints before the first write, reports partial results if a later write or confirmation fails, and offers recovery/Undo against only the same server/profile. Local values still use the existing synchronous store adapters inside the asynchronous orchestration. The Review screen retains explicit confirmation and per-setting selection.

Build 96 adds `streaming.audioLanguage` to schema 2 without changing the schema version or the interpretation of existing IDs. Its source is `playback.audio_language` from the authenticated effective-settings API; writes/clears use the same API at `profile_device`, never the `PlayerSettings.audioLanguage` cache. A profile or server fingerprint mismatch skips this item with the other remote settings. Existing schema-1 files remain local-only and schema-2 files that omit Audio Language remain valid.

**Validation in this worktree:** macOS host checks executed the production codec and remote adapter/model against controlled API fakes: 6 codec checks and 10 unified-flow checks passed (including the Fourth tab + playback resolution + Audio Language + Subtitle Language round trip, Undo, profile mismatch, offline export, timeout, cancellation, selective restore, partial failure and secret exclusion). The iOS `Silo` scheme and test target **compiled** with `xcodebuild build-for-testing` for a generic iOS Simulator destination; no Simulator was booted and no XCTest cases or cloud workflow were run. Compilation is not an executed iOS test pass. No IPA was built.

**Remaining risk:** 32 API-backed candidates have no adapters, open Settings views may require further refresh testing, the server deployment ID is self-asserted (the authenticated connection still authorizes every API call), and the remote journal is recoverable rather than transaction-atomic across network and local stores. The iPhone 480p/Chinese/Fourth-tab scenario is covered by a controlled host test but **has not been rerun on a physical iPhone**. This implementation is not a complete 64-setting backup and is not beta-ready.

## Follow-up inventory finding (2026-11-19)

The Settings → Features → Watch Party switch was an additional persisted user preference not represented in the original 64-candidate denominator. Its owner is `ExperimentalFeatures`, stored under the explicit `experimental.watchParty` UserDefaults key. It is device-local and contains no server or account identity. It is now included as `features.watchParty`; restore routes through `ExperimentalFeature.watchParty.setEnabled`, so disabling also leaves an active party session. Both `false` and `true` are serialized as explicit booleans. Registry coverage increases by one (34 registered settings including the existing three remote definitions). This does **not** complete the remaining API-backed or identity-bound inventory: coverage remains partial and physical-device testing is still required.
