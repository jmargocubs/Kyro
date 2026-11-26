# Build 135 readiness: Modern Stream and Podcast Discover

Version 1.0.135 (135), iOS only, on `kyro/ios-recovered`. Builds on Build 134 (`e2bbac97e4f2254067a2edf6d45256cdb715fb06`). Not packaged, not pushed, not device-tested.

## What changed

### Modern Stream players (`Kyro/Podcasts/KyroModernPlayers.swift`, new)
Modern Stream is now an artwork-led streaming player with a crimson-to-black gradient, burgundy cards, a large square cover, white primary controls and crimson accents. There is no record, tonearm, cassette or reels, and no green. Crimson Noir and Classic Walnut keep the vinyl and cassette hardware players unchanged. The stored theme value is still `modernStream`, so existing selections get the redesign automatically, for Radio and Podcasts independently. Settings Backup is unchanged.

- **Podcasts**
  - **Header:** collapse control, show name, and an options menu (save, mark played, download, queue, chapters, player appearance, stop).
  - **Main area:** large artwork, episode title, show name with its artwork, and Save.
  - **Scrubber:** a crimson track with elapsed and remaining time, plus the current chapter when the feed publishes chapter data.
  - **Controls:** speed menu, skip back and forward using the configured intervals, a large white play/pause button, sleep timer, AirPlay/output picker, share (the episode's public media link), queue, and episode notes from the feed.
  - The half-second playback clock is read only by the timeline row.
- **Radio**
  - Large square station logo, LIVE / CONNECTING / RECONNECTING n/3 / PAUSED / UNAVAILABLE status, station name, and the stream's own song and artist.
  - Favorite, a large play/pause button (spinner while connecting, Try Again after a failure) and Stop.
  - System volume, AirPlay/output picker with the current output name, and codec/bitrate.
  - No progress bar, skipping or shuffle.
- **Routing:** `KyroPodcastPresentation` and `KyroRadioNowPlayingView` choose the player by theme. Theme previews and the mini-player accent use the crimson palette.

### Podcast Discover (`Kyro/Podcasts/KyroPodcastDiscoverHome.swift`, new; `KyroPodcastBrowser.swift`)
The Podcasts page uses the red-and-black palette and has two sections, **Discover** and **Library**. The Radio / Podcasts switch, both floating pills and the five tabs are unchanged. The pushed page keeps its own mini-player.

- **Header:** Podcasts heading, a search field (debounced 900 ms, or submitted), and a menu with Add RSS Feed and Podcast Settings. Queue and Settings stay in the page actions.
- **Featured:** the top 5 of Apple's Top Shows chart, as swipeable cards with title, summary and Open Show. Nothing advances automatically.
- **Browse by Category:** Comedy, Sports, News, True Crime, Religion & Spirituality, Society & Culture, Business, Technology, Health & Fitness, Music, History, Education and TV & Film. Choosing one shows that Apple chart, with See All.
- **Popular Podcasts:** Apple Top Shows, with See All opening a ranked list of up to 100.
- **Continue Listening:** progress and time left, with resume.
- **Subscriptions:** a shelf with subscribed badges; See All opens the Library.
- **Latest Episodes:** from subscribed shows, with played/unplayed, date, duration, download and play.
- **Empty states:** personal shelves are hidden when empty. Search results replace the shelves and are labelled "From Apple Podcasts search".

### Podcast Library and show pages
- **Library tabs:** Shows (grid or list, search, sort by Recently Updated / Recently Added / A–Z), Latest, Saved, Downloads (with storage used) and History (with Clear).
- **Management menu:** Add RSS Feed, Refresh All, and Import/Export OPML.
- **Show pages:** large cover, title, creator, expandable description, Subscribe/Subscribed, favorite, refresh, and episode cards.
- **Existing data:** subscriptions, downloads, progress, queue and backups use the same unchanged library.

## Data sources (`Kyro/Podcasts/KyroPodcastCharts.swift`, new)

| Section | Source | Requests |
|---|---|---|
| Featured, Popular Podcasts | Apple iTunes RSS `itunes.apple.com/<cc>/rss/toppodcasts/limit=25/json` (Apple's top podcast chart) | 1 when Discover appears, cached 6 h on disk |
| Category rows | Same feed with `/genre=<Apple genre id>` | 1 per chosen category, cached 6 h |
| See All | Same feed, `limit=100` | Only when opened |
| Opening a chart show | Apple lookup `itunes.apple.com/lookup?id=<id>&entity=podcast` → public feed address → existing RSS preview | 1 per show, remembered |
| Search | Existing Apple Search API client (Build 133) | Debounced, spaced, cached |
| Continue Listening, Subscriptions, Latest, Library | The device's own library | None |

- **Free, no key:** all requests are spaced at least 3.2 s apart, coalesced and cancellable.
- **Failures:** a failed refresh keeps the stale chart. With no chart at all, Discover says so and points to search and RSS.
- **No background refresh:** charts never refresh in the background. Opening Discover doesn't refresh every feed; the existing bounded, interval-gated automatic refresh from Build 133 is unchanged.
- **Labelling:** chart rows are labelled as Apple Podcasts charts, and search results as search.
- **Not used:** `rss.applemarketingtools.com`, which redirects (301).

## Validation

- `bash scripts/run-build135-host-checks.sh`: **76 checks passed** offline; with `--live`, **79 passed**.
  - **Live result:** the Comedy chart's #1 was The Joe Rogan Experience; its lookup returned a feeds.megaphone.fm feed, with two requests in total.
  - **Charts:** decoding (ranking, duplicates, bad IDs, one-entry and empty charts, 600 px artwork), addresses (storefront and limit clamping, lookup ID validation), and all 13 categories with distinct genres.
  - **Cache and requests:** one request for two opens, disk persistence, the 6 h stale fallback, 3.2 s spacing between requests, and one lookup per show.
  - **Library sorting.**
  - **Themes:** three themes with the `modernStream` value unchanged; stored Radio and Build 134 Podcast choices load as the redesign.
  - **Source contracts:**
    - Theme routing and the vintage players kept, with no green.
    - No comments or device-casting features, and chapters only from feed data.
    - Configured skip intervals; speed, sleep, share, queue and output; episode notes.
    - Only the timeline observes the playback clock.
    - Radio has no progress, skipping or shuffle, but keeps volume, codec, live, favorite, stop and retry.
    - Discover loads charts on demand, has no timers or auto-advancing carousel, debounces search, labels sources, hides empty shelves, and uses lazy shelves and grids.
    - The Library has all five tabs, OPML stays, and the hub and pushed mini-player stay.
  - **Protected files:** the radio and podcast engines, podcast library, network, feed, downloads and backup, Home, Sports, Live TV, the shell, the mini-player slot and `ContentView` are unchanged since Build 134 (`git diff`).
- Earlier scripts pass: build133 (95), build132 (60), build131 (30), build130 (79), build129 (43), build128 (107 + 20 + 101), build126 (34), build124 (42), build121 (132 + 20 + 101).
  - Stale version assertions in build121, build129 and build133 now expect 1.0.135.
  - build129's route check now expects `KyroAudioHub`, which replaced `KyroRadioView` in Build 133.
- Generic signing-disabled iOS Release compile (`Silo`, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, `SILO_BUILD_CHANNEL=sideload`): **BUILD SUCCEEDED** on the first attempt. No new warnings in the new files; the only Radio/Podcast warnings are the existing `showsRouteButton` deprecations.

## Limitations

- **Coverage:** Apple's chart RSS is per storefront (the device region, US by default). Some charted shows have no public RSS feed (Apple-exclusive or subscriber-only) and can't be opened; Kyro says so.
- **No colour extraction:** Modern Stream uses its fixed crimson palette, as the reference shows.
- **Chapters:** only Podcasting 2.0 JSON chapters (Build 133's parser).
- **Not rendered:** no Simulator by request, so no rendered screenshots. Everything above is compile and host evidence only.

## Physical-device acceptance checklist (none checked yet)

1. **Modern Stream, Podcasts:**
   1. Choose Modern Stream in Podcast Settings.
   2. Play an episode with chapters and one without: the Chapters pill and current chapter appear only for the first.
   3. Scrub, use skip with custom intervals, try 0.5× and 2×, set a sleep timer, Save, Share, open the queue, and switch output with AirPlay.
   4. Read the notes, collapse the player and reopen it from the mini-player.
2. **Modern Stream, Radio:** play a station and check the logo, LIVE, song/artist, favorite, Stop, volume, output and codec. Then try a slow station (spinner) and a failing one (Try Again).
3. **Theme switching:** switch Radio and Podcasts themes independently from Settings and from each player's menu during playback. Audio continues and episode progress doesn't reset. Crimson Noir and Classic Walnut still show the turntable and cassette.
4. **Discover:**
   1. Check that Featured, Popular and a category row show real Apple chart shows.
   2. Open a show from each and subscribe.
   3. Check that See All lists up to 100, and that search debounces and shows "From Apple Podcasts search".
   4. Add an RSS feed from the menu.
   5. In Airplane Mode, the cached charts still show.
5. **Personal shelves:** Continue Listening resumes at the saved position. Subscriptions → See All opens the Library. Latest Episodes download and play, and the played dot clears after listening.
6. **Library:** grid and list, search, all three sorts, Latest, Saved, Downloads (storage), History (Clear), OPML import and export, Refresh All. Show pages subscribe and unsubscribe.
7. **Mini-player:** stays visible through Discover, Library, show pages and See All, as a tab and pushed from More. No duplicate bar.
8. **Navigation and Home:** the Radio ↔ Podcasts switch, five tabs and both floating pills are unchanged. Home scrolls smoothly with a podcast playing, with sports cards still full size, compared with Build 131.
9. **Backup:** restore a Build 134 backup. The Radio and Podcast theme choices, subscriptions and progress are kept.
10. **Accessibility:** with Dynamic Type at accessibility sizes, the players and Discover scroll and controls stay reachable. Reduce Motion: nothing in Modern Stream animates continuously.
