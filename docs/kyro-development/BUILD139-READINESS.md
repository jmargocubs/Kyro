# Build 139 readiness: IPTV music in Radio and audio polish

Version 1.0.139 (139), iOS only, on `kyro/ios-recovered`. Builds on Build 138 (`f7e0d94702875f09e1f3ae3eada149a0cbf2a095`). Not packaged, not pushed, not device-tested. Home performance was not investigated, as agreed.

## IPTV music in Radio

### Data
- **One catalog:** music channels come from the existing indexed SQLite Live TV catalog. There is no second import, database or service.
- **Read-only access:** `LiveTVService.musicCatalogSnapshot` reads, per provider and active generation, one category `GROUP BY` and six full-text searches of at most 200 rows each (SiriusXM, Sirius, SXM, Music Choice, Stingray, Radio). It also reads channels the listener added by hand.
- **Full catalogs:** a 100,000-channel catalog is never scanned or loaded.
- **Rebuilds:** classification (`KyroIPTVMusicIndexer`) runs off the main thread, only when the catalog revision, provider list, hidden categories or a manual decision changes.
- **Browsing:** collection pages ask the index for 60 channels per category at a time, and re-check each channel.

### Classification rules (`Kyro/Radio/KyroIPTVMusicClassifier.swift`)
- **Normalisation:** case and accents are folded, "&" reads as "and", and words are compared whole and run together, so "Sirius XM" equals "SiriusXM".
- **Brands (in a category or channel name):**
  - **SiriusXM:** `siriusxm`, `sirius`, `sxm`.
  - **Music Choice:** `musicchoice`.
  - **Stingray Music:** `stingray`, except Stingray video services: Qello, Karaoke, Naturescape, Classica, iConcerts, DJAZZ, Hits!, Juicebox, Loud, Retro, Vibe, CMusic, Lite TV, Holidayscapes, Rock and Spotlight.
- **IPTV Radio:**
  - **Matches:** "radio" or "radios", FM, a frequency such as "1027FM", or AM beside a frequency.
  - **Unless:** the name also marks television ("TV", "Tele", "Television", "RTV"), or is a broadcaster such as "Radio-Canada" or "Radio Televizija".
- **IPTV Music:** "music" (or musica, musique, musik) together with an audio word (audio, radio, stream, station). "Music" on its own is never enough.
- **Never music:**
  - **Music television:** MTV, VH1, CMT, Fuse, Revolt, Trace, Mezzo, Qello, karaoke, concerts, video or videos, Clubland, Kerrang, 4Music, "BET Jams" and similar, and "Music TV" or "Hits TV".
  - **Everything else:** sports television, plus "Classic", "Music" and similar words without audio cues.
- **Precedence:** a manual channel decision, then a manual category assignment, then a brand in the channel's own name, then the music-television exclusion, then the channel's category, then a radio name.
- **Identity:** channels keep their `provider:channel` IDs. Two providers' channels with the same name stay separate, and nothing is merged by name.
- **Hidden categories:** categories hidden in Live TV never appear in Radio, and nothing is unhidden. Channels stay in Live TV.

### Radio experience
- **Music Sources shelf on Discover:** Internet Radio plus each IPTV collection that has channels (SiriusXM, Music Choice, Stingray Music, IPTV Radio, IPTV Music), with channel counts and provider names. It is absent without IPTV music, so Radio is unchanged without a provider.
- **Collection pages:** search, a source-aware logo, name, genre (the provider category), source and provider label, favorite, play, and a long-press menu with Watch in Live TV, Move to Collection, Not a Music Channel and Use Automatic.
- **Unified search:** the search menu has a Sources picker (All Sources, Internet Radio, or a collection). Music-channel results appear above Radio Browser results, which are hidden when a single IPTV collection is chosen. Countries, regions, languages and genres are unchanged.
- **Library:** Favorite Music Channels sits above the Radio Browser favorites.
- **History:** one newest-first list mixing both sources, each labelled with its collection and provider. A deleted or removed channel shows "No longer available from this provider" instead of playing.

### Manual management (Radio Settings → Manage Music Sources)
- **Integration:** turn IPTV music channels on or off.
- **Providers:** choose which providers contribute, each with a summary of what was detected.
- **Detected categories:** each with Automatic (showing the automatic result), a collection, or Not Music. Assign Another Category opens a searchable list of every category.
- **Channel Corrections:** search any channel and assign it, or remove a correction.
- **Reset Classification Overrides.**
- **Precedence:** manual decisions take priority over automatic ones. Category assignments are by category name; channel decisions are by channel ID.

## Playback

- **Engine:** IPTV music plays through Radio's existing audio player (`KyroRadioPlayer`, AVFoundation). It keeps the mini-player, background audio, Lock Screen and Control Center (play, pause, stop), AirPlay and Bluetooth, Radio Now Playing in all three themes, and Radio's exclusivity with Podcasts, Live TV, Sports, audiobooks and Silo media.
- **Route (`KyroIPTVAudioRoute`):**
  - **Xtream `.ts`:** tried as HLS (`.m3u8`) first when the account offers HLS or doesn't say, then the original address.
  - **Other streams:** played as given. HLS video streams play as audio, because the player has no video layer.
- **Fallback:** when the audio player can't read a stream (raw MPEG-TS on TS-only accounts), Now Playing offers "Play in Live TV Instead". The Live TV player is also available as "Watch Video in Live TV" to see the video. Radio stops first, so only one session ever plays.
- **Metadata:** the stream's own song and artist when it sends them, and the Live TV guide's current programme ("On now: …") when guide data exists. Nothing is invented.
- **Credentials:** stream addresses can carry credentials. They are never written to Radio's history or favorites, logged, or backed up, and IPTV plays are never reported to Radio Browser.

## Favorites, history and backup

- **IPTV favorites:** these are Live TV's favorites, the one store, so Radio and Live TV never disagree.
- **IPTV history:** saved as channel references (ID, name, collection, provider, and a logo only if it has no query or credentials) under `kyrox.radio.iptvHistory.v1`.
- **Radio Browser:** favorites and history are unchanged.
- **Settings Backup (Radio group):** builds before 139 skip the two new entries.
  - **`radio.musicSources`:** the integration toggle and category assignments by name. Link-like names are dropped. Provider choices, channel corrections and IPTV favorites stay on the device.
  - **`radio.homeShelfLimits`:** the five audio shelf sizes.

## Audio polish

- **Continue Listening (Home):** square cards with a headphones mark, episode and show, a progress bar, minutes or hours left, and a resume glyph. Clearly different from Continue Watching.
- **Audio Shelf Sizes (Customize Home):** Favorite Radio Stations, Recently Played Radio, Continue Listening, Latest Podcast Episodes and Favorite Podcasts. Choices are 5, 10, 12, 15, 20 and 30; defaults stay 20 (radio) and 12 (podcasts). Ordering and visibility are unchanged.
- **Podcast Library:**
  - **Layout:** the search field has its own row; sort (with its name shown), the show count and a segmented grid/list control sit on one aligned row.
  - **Artwork and titles:** tighter grid artwork, two-line titles with the creator on a consistent baseline, and matching list sizes.
  - **Indicators:** saved and downloaded marks on episode cards.
- **Radio artwork:** one source-aware container for Radio Browser and IPTV logos. Logos are fitted, never stretched or cropped. Missing logos show the source's mark (radio, SiriusXM, Music Choice and so on).
- **Mini-players (Kyro Signature):**
  - **Surface:** a more opaque surface (card 0.78, accessory 0.42) with a fine crimson edge.
  - **Separation:** a soft shadow on the card bar.
  - **Unchanged:** artwork sizes (46/34 pt), hosts, controls and single-player coordination. No blur was added.

## Validation

- `bash scripts/run-build139-host-checks.sh`: **127 checks passed**.
  - **Classification:** brand variants, radio and audio-music categories, and false positives (music television, Stingray video, "Music" or "Classic" alone, sports, TV broadcasters named Radio).
  - **Overrides:** precedence of manual decisions.
  - **Index:** hidden categories, de-duplication, two providers with the same channel name, and rebuild signatures.
  - **Large catalog:** a 100,000-channel provider classifies from bounded inputs (2,002 categories and 1,400 matches) in about 150 ms in an unoptimized host build.
  - **Audio route:** Xtream TS/HLS, TS-only accounts, M3U HLS and non-web URLs.
  - **Routing:** IPTV favorites and history route to their stores, no IPTV stream address reaches Radio storage, and older saved stations decode unchanged.
  - **Backup:** round trip, device-only data excluded, restore merges, and malformed values rejected.
  - **Shelf limits:** defaults, bounds and fallback.
  - **Source contracts:** bounded catalog reads only, no Live TV writes, paging, rebuild gating, hidden categories, Live TV favorites, the Live TV fallback stops Radio first, no Radio Browser report, exclusivity unchanged, unified Library and History, no empty collections, the Continue Listening card, shelf limits, no blur, and the Build 131 sports fix.
- **Earlier behaviour checks all pass:**
  - build121 (132 + 20 + 101), build124 (42), build126 (34), build128 (107 + 20 + 101), build129 (52), build130 (79), build131 (30), build132 (60), build133 (99), build135 (76), build136 (23), build137 (29).
  - The older scripts now compile the classifier, and the Radio backup-ID lists and Build 121's version expect Build 139.
- **Release boundaries:** the file-freeze checks at the end of the build132, 133, 135, 136, 137 and 138 scripts compare against those builds' commits.
  - **Expected changes:** they report Build 139's intended changes (Radio player, models, library, backup, theme chrome and Home audio files).
  - **Already stale:** most were also stale before this build, because Build 138 changed ContentView, NowPlayingShelf and KyroHomeShelves.
  - **Build 138's script:** also pins version 138.
- **Release compile:** generic signing-disabled iOS Release (`Silo`, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, `SILO_BUILD_CHANNEL=sideload`) succeeded on the first attempt. There are no new warnings; the only one in Radio files is the existing `showsRouteButton` deprecation.

## Limitations

- **Raw MPEG-TS:** streams the audio player can't read use the Live TV player instead. That player's background behaviour is Live TV's (Picture in Picture), not Radio's.
- **Metadata:** song and artist appear only when the stream sends them. Guide programmes appear only when Live TV guide data is loaded.
- **Shared category names:** category assignments apply to every provider with that category name.
- **Collection counts:** the counts on source tiles come from category sizes, before per-channel checks.
- **Catalog state:** a provider without an indexed catalog (first launch after a legacy JSON migration) shows no music collections until its next import.
- **No device evidence:** host and compile evidence only. No IPTV credentials or real providers were used.

## Physical-device acceptance checklist (none checked yet)

1. **Without IPTV:** Radio Discover, search, filters, Library and History behave exactly as in Build 138.
2. **With an IPTV provider:** Music Sources lists only collections that have channels, with sensible counts. Music video channels (MTV, VH1, Stingray Qello or Karaoke) and TV broadcasters named Radio are absent.
3. **SiriusXM, Music Choice and Stingray:** play a channel from each. Audio starts, the mini-player and Lock Screen show the channel, and background audio, AirPlay and Bluetooth work. Pause, play and stop all work. Song metadata or "On now" appear where available.
4. **Raw TS-only channel:** if one fails, "Play in Live TV Instead" opens Live TV with Radio stopped. Watch Video in Live TV works from a playing channel.
5. **Exclusivity:** start Live TV, a podcast, an audiobook and Silo video while an IPTV music channel plays, and in reverse. Only one source plays.
6. **Favorites:** favorite a music channel in Radio and confirm it is a Live TV favorite, and the reverse. Library lists it with its source, and History mixes both sources newest first.
7. **Manage Music Sources:**
   1. Turn integration off and on, and exclude a provider.
   2. Assign a category, then mark one Not Music.
   3. Move or exclude a channel by long-press and confirm it disappears from its collection.
   4. Reset overrides.
   5. Hide a category in Live TV and confirm it leaves Radio.
8. **Catalog refresh:** refresh the playlist and confirm collections update. With a large (100K) playlist, Radio opens without a noticeable pause.
9. **Backup:** back up and restore onto a clean install. The integration toggle, category assignments and shelf sizes restore; channel corrections and provider choices don't transfer.
10. **Home:** Continue Listening shows the new square cards with time left, and resume plays from the saved position. Shelf sizes apply immediately. Home arrangement and sports cards are unchanged.
11. **Podcast Library:** search placement, sort and layout alignment, grid and list, artwork sizes, and the saved and downloaded marks.
12. **Mini-player:** readable over scrolling content in Kyro Signature, separated from the pills, the keyboard still hides the page bar, and there is never a duplicate bar.
