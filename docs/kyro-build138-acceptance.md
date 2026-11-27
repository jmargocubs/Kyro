# Kyro X iOS Build 138 — separate audio destinations and Home performance

## What the evidence shows

- The Build 137 recording shows inline Podcast search, opening shows, episode playback, Settings, and the same mini-player still visible after switching to Radio at about 2:51. It does not provide a usable Home scrolling pass or a device frame trace. That recording cannot identify the Home bottleneck.
- Compared with physically accepted Build 131 (`2b06e11112b6eff34b08c32c6a448bfe3cc294a7`), Build 136 added the Signature Home gradient. Build 138 installs the same opaque three-stop wash on one native compositor layer; it has no scroll input. This is not evidence that the gradient caused the reported hitching. Verify the visual match on device.
- Builds 133–137 kept the periodic playback clock out of Home and the global accessory. However, playback checkpoints encoded the entire saved progress dictionary on the main actor, even when they did not publish observable state. Build 138 moves serialization and the defaults write onto an ordered worker without changing the storage key or the immediate in-memory resume position.
- Enabled podcast rails previously owned separate cache-restoration tasks and could rescan the same subscriptions together or after a rail remounted. Home now owns one disk-only hydration task, and only while an episode shelf is enabled. Latest-shelf diagnostics count cached rows without building and sorting the card list.
- Sports keeps Build 131’s lazy cards and its hidden tallest-card probe. The Home poster pipeline and decode sizes are unchanged. The shell still caps scroll publications at the header fade endpoint, and both floating pill implementations are unchanged.

These are source findings and Mac host measurements, not an iPhone frame-rate result. No server or cross-client API change is needed: the destination split is specific to Kyro’s iOS shell.

## On-device acceptance

1. With Sports still selected, open Radio and Podcasts from More. Make each one the fourth tab in turn. Check that the selected destination is not repeated in More, the other one remains there, and there are only five tabs. Check both floating pills, the iPad sidebar, the legacy profile menu, and the Radio and Podcast Home shelf headers.
2. Enter a Radio search or open History. Open Podcasts, search, open a result, and return. Reopen Radio and confirm its previous section and query did not get replaced by Podcasts. Repeat with the Podcast Library’s Saved shelf. Check that direct RSS, Featured and Popular links, filters, and the inline keyboard all still work.
3. Start a podcast and open Radio while it plays. Confirm one mini-player, then start a station and confirm playback hands off. Repeat in reverse. Try the keyboard on a pushed audio page, then close it and check that the mini-player returns. Verify the separate Radio and Podcast Settings links and their independent player appearance settings.
4. Compare Build 137 and Build 138 on the same iPhone, data, Home arrangement, pause state, and navigation style. Run the same 20–30 second Home scroll with audio idle and with a podcast playing. Repeat with podcast Home shelves on and off. Check full-height sports cards, artwork, and Signature appearance as well as touch feel.
5. For a trace, enable the existing performance overlay in Live TV Settings → Diagnostics and relaunch. Copy the report immediately after each pass. Compare the Home section’s hitches, stalls and worst frame with the new Home backdrop, audio shelf, audio rail, poster and page-chrome activity. Existing shell/header and sports body counters remain available. The checkpoint timer measures worker time, and the cache timer includes async disk waits; neither is a main-thread stall measurement. For a still-reproducible hitch, capture an Instruments Time Profiler/Core Animation trace around it.

The previous stored fourth-tab value `radio` opens Radio, including when restored from Settings Backup. Podcasts uses the new `podcasts` value. Station, subscription, playback, appearance, history, queue, and download data are not migrated or rewritten.
