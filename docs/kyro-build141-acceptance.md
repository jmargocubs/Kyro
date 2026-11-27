# Kyro X iOS Build 141 — physical acceptance

**Status: accepted stable iOS baseline.** Build 141 was physically tested on the
iPhone 16 Plus through Feather and all 15 acceptance checks passed. The accepted
source is `2ad764bb65c7773721846961d13642d553fbc299` on `kyro/ios-recovered`.

| # | Physical acceptance check | Result |
|---:|---|:---:|
| 1 | Lock Screen IPTV playback card, metadata, and artwork display correctly when iPhone is locked. | PASS |
| 2 | Lock Screen Pause retains the selected station and Now Playing information without tearing down the session or dismissing controls. | PASS |
| 3 | Lock Screen Play and Control Center Play resume and reconnect to the live IPTV stream at the live edge. | PASS |
| 4 | Remote toggle command (Bluetooth / headphones) operates correctly to pause and resume live IPTV playback. | PASS |
| 5 | In-app Stop in Kyro's player explicitly ends and clears the station and releases Now Playing. | PASS |
| 6 | Playback exclusivity is preserved across Radio, Podcasts, Live TV, and Silo media with no conflicting audio sessions. | PASS |
| 7 | Background IPTV audio playback continues reliably while the device is locked. | PASS |
| 8 | All three Radio themes (Modern Stream, Classic Walnut, Crimson Noir) operate correctly. | PASS |
| 9 | Internet Radio playback functions normally through its existing dedicated path. | PASS |
| 10 | Music Sources cards display distinctive local palettes and recognizable symbols (Internet Radio crimson, SiriusXM navy, Music Choice purple, Stingray teal, and fallbacks) without external artwork dependencies. | PASS |
| 11 | Primary navigation customization allows selecting, pinning, and reordering up to four destinations after the fixed Home tab. | PASS |
| 12 | Radio and Podcasts can appear simultaneously as primary navigation tabs. | PASS |
| 13 | Unpinned destinations remain fully accessible through the More menu, preserving sub-navigation, Back buttons, and PiP return. | PASS |
| 14 | Navigation pill collapse/expansion, floating styles, and mini-player separation remain functional without layout regressions. | PASS |
| 15 | Navigation preferences persist across app relaunch, Reset to Default restores the standard layout (Home, Movies, Series, Sports, Live TV), and Settings Backup exports and restores navigation order with backward compatibility. | PASS |

## Stable artifact

- IPA: `Kyro-iOS-v1.0.141-Build141-Unsigned.ipa`
- Version/build: `1.0.141` / `141`
- Bundle: `com.cubbiestream.kyro`
- Size: `45,676,615` bytes (43.56 MiB)
- SHA-256: `2602473b8ae5654021d610cf02c7027bdbb4fb40ca074962e901e504ec873212`
- Source Commit: `2ad764bb65c7773721846961d13642d553fbc299`
- Branch: `kyro/ios-recovered`
- Stable tag: `kyro-ios-v1.0.141-build141-stable`
- Release tag: `kyro-ios-v1.0.141-build141-rc1`
- Catalog listing title: `Kyro X — Build 141`

## Known limitations

- **SiriusXM buffering:** Occasional brief SiriusXM buffering remains undiagnosed. AetherEngine audio playback and recovery perform well, but occasional brief stream hiccups can occur.
- **Home scrolling:** Minor Home scrolling choppiness remains accepted by the user for now, with further performance diagnostics deferred.
- **Historical checks:** Previously pending physical checks from prior candidate builds (e.g. Build 90/91 backup picker issues, superseded by later baselines) are preserved in their respective records and are not falsely marked as passed.
