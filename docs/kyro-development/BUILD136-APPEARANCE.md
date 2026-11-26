# Build 136: Kyro Signature and Radio browsing

Kyro Signature uses the crimson, burgundy and near-black values from Build 135 Podcast Discover. Signature is the default. Main Settings → App Appearance changes the local, device-wide choice independently of either audio player theme. Classic Dark restores neutral page canvases and the existing navigation glass. The existing device-local Settings Backup schema carries `general.appAppearance`; a backup that omits it leaves the current choice alone.

## Integration points

| File or shared hook | Why it changes |
| --- | --- |
| `Extensions/ViewExtensions.swift` | Routes the existing `SiloPageBackdrop` / `siloPageBackground()` hooks to a restrained Signature wash. This covers Movies, Series, Collections, Favorites, media details, Calendar, and other pages using the shared canvas, without editing each page. Classic Dark keeps the cached Silo wash. |
| `Screens/Home/HomeView.swift`, `Screens/Recommendations/RecommendationsView.swift`, `Screens/Search/SearchView.swift` | Opt Home, For You, and Search into the stronger feature wash. These call sites change only the backdrop. |
| `LiveTV/Home/LiveTVHomeContent.swift`, `LiveTV/LiveTVViews.swift`, `LiveTV/Guide/LiveTVGuideView.swift` | Use the feature wash on Live TV Home and opaque burgundy behind Guide controls and the pinned timeline. Guide programme blocks, team colors, channels, status indicators, and video remain unchanged. |
| `Screens/Settings/IOSSettingsOverview.swift`, `Screens/Settings/SettingsBackdrop.swift`, `Screens/Settings/SettingsSearchField.swift` | Expose App Appearance and route Settings and its search surface through the new tokens. |

Kyro-owned changes live in `KyroTheme` and in audio, Sports, and settings presentation. The floating navigation glass can read the appearance without changing either pill's geometry or behavior. Expanded players still use their existing theme choices and never observe global appearance. Modern Stream aliases the same numeric pigments it already used; its player layout and controls are unchanged. Android, Roku, and Web need no parity changes: this is iOS Kyro branding and local presentation, not a server or cross-client contract.

## Radio

Featured and Popular are labelled by source: Radio Browser community votes and 24-hour clicks, respectively. Local uses the saved country, region, and language, with no location permission. It is omitted if no country is set. Genre, country, language, and field-specific search use the existing directory filters. Recently Played and Favorite Stations appear only when they have content. See All opens ranked directory lists or the matching Library/History tab. Library retains search, sorting and swipe removal; its artwork grid also exposes favorite actions through the context menu and VoiceOver.

The shelves load when shown, preview at most 12 stations each, and use the existing directory cache. Station tiles share a fixed decode target across the shelf and grid. Backdrops have no animation, frame callbacks, or artwork sampling. Existing playback engines, the Now Playing shelf host, and Home's sports-height probe are unchanged.

## Physical acceptance

- Switch both app appearances in Settings while Radio or a podcast plays. Verify the navigation stack, audio route, player theme, and episode position survive. Relaunch and restore a backup exported with the other appearance.
- Check the feature washes on Home, For You, Search, Sports and Live TV. Check poster contrast, media details, Favorites, Calendar, Settings, Guide text and the two navigation pills in both appearances.
- In Audio, switch between Radio and Podcasts. Check Radio rankings, region and genre filtering, search, See All, grid/list, favorites, history and the mini-player on pushed pages. Check VoiceOver, large text and the keyboard with an active session.
- Scroll Home and the Sports rails with audio playing. Verify the cards remain unclipped and Home still feels smooth. The Mac host rail test is not a phone frame-pacing measurement.
