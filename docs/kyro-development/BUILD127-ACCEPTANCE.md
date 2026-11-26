# Kyro X iOS Build 127 — physical acceptance

**Status: accepted stable iOS baseline.** Build 127 was physically tested on the
iPhone 16 Plus through Feather and all 16 acceptance checks passed. The accepted
source is `e2364732e67514843c60687d793f5c040002b3a1` on `kyro/ios-recovered`.

| # | Physical acceptance check | Result |
|---:|---|:---:|
| 1 | Upgrade from the prior accepted build; Kyro X branding, launch animation, Crimson Noir palette and approved navigation pills remain intact. | PASS |
| 2 | Unified Silo/Kyro Home ordering and individual shelf visibility survive upgrade and relaunch. | PASS |
| 3 | Home quick-add cards add and remove teams and leagues, including empty favorite shelves. | PASS |
| 4 | Sports Settings opens and dismisses correctly with and without a pinned player, preserving feed position and playback. | PASS |
| 5 | Sports directory browsing and search return correctly scoped teams, logos, abbreviations and league labels, including offseason discovery. | PASS |
| 6 | Favorites added in Sports Settings, Home, quick-add cards and event-card actions synchronize immediately; unscheduled favorites can be removed. | PASS |
| 7 | Cached directories remain available offline or after a failed refresh, with schedule fallback and the ATP/WTA limitation presented correctly. | PASS |
| 8 | Dashboard league ordering, visibility, default sport and live/upcoming/completed settings persist across relaunch; reset preserves favorites. | PASS |
| 9 | Sports Home shelves can be shown or hidden from Sports Settings and Customize Home, with both editors remaining synchronized. | PASS |
| 10 | Existing Guide List/Grid and category layout/grouping preferences continue to control Live TV. | PASS |
| 11 | Unified Settings Backup export, change, restore and Undo preserve favorites, dashboard settings and Home arrangement; older backups remain compatible. | PASS |
| 12 | Sports scores, schedules, standings, details/statistics and news remain accessible without an IPTV provider. | PASS |
| 13 | Existing-provider live channel matching, stream alternatives, inline playback, fullscreen and PiP continue to work. | PASS |
| 14 | Player/session coordination remains correct across sports playback transitions. | PASS |
| 15 | Original Silo media playback, Live TV and Guide remain functional, with the existing bundle identifier retained. | PASS |
| 16 | Seekr, AetherEngine and production-scale channel browsing remain available without regression. | PASS |

## Stable artifact

- IPA: `Kyro-iOS-v1.0.127-Build127-Unsigned.ipa`
- Version/build: `1.0.127` / `127`
- Bundle: `com.cubbiestream.kyro`
- SHA-256: `eb94f05b7f74b03b9102b10d60c392fe7923e6841393a8c45485e639e5419a83`
- Stable tag: `kyro-ios-v1.0.127-build127-stable`
