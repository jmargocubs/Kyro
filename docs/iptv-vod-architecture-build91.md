# IPTV VOD architecture research — Build 91

**Scope:** research and design only. No VOD implementation or provider migration is part of Build 91. “Verified” below means inspected in this repository; “external example” means documented by an Xtream-compatible implementation, not tested against a subscriber account; “proposed” requires approval and validation.

## 1. Current Kyro architecture and existing IPTV capabilities (verified)

- `LiveTVService` owns saved provider metadata, selection, channel catalogs, EPG, refresh, and the one live player session. `LiveTVSourceConfiguration` is kept in `LiveTVSecretStore` (Keychain in production); the provider list stores nonsecret metadata. Pairing calls `savePairedProvider`, which goes through the same validated save path as TV entry, then refreshes the provider.
- M3U import reads `#EXTINF` entries and HTTP(S) URLs into `LiveTVChannel`; Xtream import authenticates through `player_api.php`, fetches live categories and `get_live_streams`, then constructs live URLs. Both currently have a **40,000 accepted-channel / 40 MiB response cap**. They do not distinguish M3U VOD entries; an on-demand URL may currently appear as a live channel.
- The active Live TV provider is `selectedProviderID`, while multiple providers can be saved. Channel snapshots deliberately omit URLs and are browseable but not playable until a fresh download. EPG caches and favorites have Live TV-specific identity. Neither is an IPTV VOD store.
- `TVLibraryTypeTabView` scopes Movies/Series to a **Silo `Library`**. `TVLibraryBrowseView` uses server sections; `TVLibraryGridViewModel` uses Silo v2 catalog cursor pagination (100 items/page), Silo facets, and bounded poster prefetch. `TVLibraryCollectionsView`, item-detail views, favorites, resume state and Continue Watching also use Silo content IDs and APIs. `UnifiedSearchCoordinator` combines Silo results with IPTV *live channels*, not IPTV VOD. Directly inserting provider titles into `BrowseItem` or Silo library IDs would conflate identities and break server-backed behavior.

## 2. Missing VOD capabilities (verified)

No VOD endpoint client, movie/series/season/episode models, VOD catalog cache or index, source-aware Movies/Series navigation, VOD playback route, or local IPTV VOD watch-state store exists in this repo. No cross-device IPTV VOD sync contract is visible. Silo behavior must not be changed merely to add provider content.

## 3. Xtream-compatible API research (external examples, not a compatibility guarantee)

An [Xtream source-analysis reference](https://github.com/worldofiptvcom/xtream-codes-api-documentation/blob/master/XTREAM_CODES_API_DOCUMENTATION.md) documents username/password query authentication on `player_api.php` and the following actions. Examples are sanitized shapes; IDs and domains are illustrative. Kyro already verifies `user_info.auth`, status and expiration for live import; reuse this credential path, not a second credential store.

| Action | Example return and proposed use |
| --- | --- |
| `get_live_categories`, `get_live_streams` | Live category IDs/names and an array of live stream IDs; already used by Kyro. |
| `get_vod_categories` | Movie category IDs/names. |
| `get_vod_streams` | Movie `stream_id`, `name`, `stream_icon`, `category_id`, `container_extension`, optional rating. A category filter is shown; do **not** assume pagination. |
| `get_vod_info&vod_id=456` | `info` (plot, artwork, genre, rating, release date, duration) plus `movie_data` (ID/extension). Fetch on detail opening or bounded prefetch, not for all 50,000 movies. |
| `get_series_categories`, `get_series` | Series category IDs and series summaries, including `series_id`, cover, plot, category and optional rating. |
| `get_series_info&series_id=789` | `seasons`, `info`, and `episodes` keyed by season number, with episode IDs, number, title, extension and nested metadata. Fetch lazily per opened series. |

The reference shows `/movie/{username}/{password}/{stream_id}.{extension}` and `/series/{username}/{password}/{episode_id}.{extension}` playback patterns. A stream path is **credential-bearing**; build only at playback time and never persist or log it. The reference lists MP4, MKV, AVI, TS and other extensions, but an extension does not establish codec or tvOS compatibility. Apple's [HLS authoring specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/) provides the firmest native compatibility target. Probe representative streams, codec/audio/subtitle combinations, seeking and HTTP range behavior on hardware before selecting a playback implementation. Do not reuse the live TS route blindly.

Server differences to expect: absent actions, empty/HTML/error bodies, string versus number IDs and ratings, broken category filters, missing metadata, nonstandard extension or URL path, expired credentials, per-account connection limits and redirects. A catalog response array gives an exact item count **only after that response is fully received and decoded**. The examined API examples document category filtering but not a standard cursor or page parameter, so incremental *local ingestion* is feasible even when server-side pagination is not. Detect capabilities per provider and degrade gracefully. Limit requests, validate response type/size and redirect origin, and redact query strings and stream paths in diagnostics.

## 4. M3U VOD classification research

Extended M3U provides an entry title, URL and optional attributes, not a universal movie/series schema. The [Xtream source-analysis example](https://github.com/worldofiptvcom/xtream-codes-api-documentation/blob/master/XTREAM_CODES_API_DOCUMENTATION.md) includes a movie in an M3U with `tvg-name`, `tvg-logo`, `group-title` and a `/movie/...` URL. The [iptv-org stream-description scheme](https://github.com/iptv-org/iptv/blob/master/docs/stream-description-scheme.md) illustrates that `#EXTINF` itself is also the normal live-channel wrapper. Thus `group-title="Movies"`, `tvg-*`, title patterns such as `S01E02`, direct MP4 URLs and `/movie/` or `/series/` paths are **signals, not proof**. Provider-specific attributes may help but must be allow-listed by tested profiles; the URL path may expose credentials and should not be displayed.

**Proposal:** classify only explicit, validated provider type metadata or high-confidence combinations into Movies/Series. Put ambiguous entries in an “Unclassified provider videos” review bucket (or leave them in Live TV until the user opts in). Offer per-provider group mapping and reversible overrides. Do not infer a series from filename alone. Preserve raw source identity so a corrected classification does not erase watch state. Future import must prevent VOD entries from inflating the live channel count, but Build 91 does not change classification.

## 5. Recommended data and integration model (proposed)

- `MediaSourceID = silo(serverID, libraryID) | iptv(providerID)`, with `ProviderItemID = (providerID, mediaKind, remoteID)`. Never deduplicate by title alone. Optional cross-source equivalence can be a separate explicit mapping, never the primary key.
- `ProviderMovie`, `ProviderSeries`, `ProviderSeason`, `ProviderEpisode`, `ProviderCategory`, and `ProviderArtwork` keep normalized display fields, original remote IDs, provenance, refresh generation and metadata quality. Store no password, credential-bearing URL, or raw unsafe provider payload in the catalog. Resolve a short-lived playback URL through the Keychain-backed provider at tap time.
- Separate `ProviderCatalogStore` (SQLite/WAL, indexed by source/kind/category/title, transactional generation swap) and `ProviderWatchStateStore` (per local profile, provider+item key, position, duration, played/completed date, favorite). Silo watch state remains server-owned. TTL metadata/detail caches may be removed without erasing local watch state; provider removal requires an explicit watch-state retention policy.
- Introduce a source-neutral **presentation** protocol or projection for cards/detail destinations, not a fake Silo `Library` or `BrowseItem`. Keep Silo API, cursor, sections, collections, favorites, resume and playback paths unchanged behind the Silo adapter. Add IPTV-specific adapters for catalog, detail, search and playback.

### UI option comparison

| Option | Assessment |
| --- | --- |
| A: merge into current Silo views/models | Least new UI, highest identity/API coupling; risks Silo pagination, collections, Continue Watching and detail routing. Not recommended. |
| B: separate provider-specific Movies/Series destinations | Safest first milestone and easiest fallback; more navigation and duplicated browsing UI. |
| C: unified Movies/Series navigation with explicit source filters | **Recommended end state**: `All`, `Silo`, each named IPTV provider, with a source badge on cards and search results. `All` is a federated, bounded merge of paged source results, not a giant array or rewritten Silo endpoint. Begin with B behind a common adapter, then add C after source-aware details/playback/watch state are proven. |

Keep Silo Continue Watching and Collections semantics exact. IPTV Continue Watching is a separately labelled local rail initially; a combined rail can merge only projected cards from independent stores, without writing IPTV state to Silo. IPTV favorites and search can be shown in global views with source badges and routed to provider detail. Collections stay Silo-only until explicit IPTV collection semantics are designed. Resume must use the IPTV local state, checked against actual seekability/duration; Silo resume remains untouched.

## 6. Multiple providers and lifecycle (proposed)

Retain one selected Live TV provider, independent from VOD source filters. Import VOD for any enabled saved provider; default `All` includes all available sources. Duplicate titles remain separate cards with provider badges. A provider switch changes Live TV only; VOD filter preference is per profile. Refresh one provider's catalog transactionally; keep its previous generation on failure and mark it stale/unavailable. Handle credential expiry with a provider-level reconnect state. Provider removal deletes its catalog/credentials and asks whether to retain local watch history; never delete another provider's data. All operations must be keyed by provider ID, not display name.

## 7. Performance and caching (proposed)

For 30,000 live channels, 50,000 movies, 20,000 series and potentially hundreds of thousands of episodes, do not materialize all artwork or episode details. Ingest bounded batches to a disk index with a staging generation and atomic promotion. Prefer category-scoped fetches when the server proves reliable; otherwise decode one bounded response off-main and incrementally write locally. Discover series summaries first, fetch `get_series_info` on opening a series, and cache with TTL/LRU. Use FTS search or equivalent indexed title search across sources; page 50–100 cards, virtualize grids, and prefetch a small visible-window poster set (the current Silo TV grid already caps poster prefetch at 48). Keep thumbnails in a quota-limited disk cache. Use ETag/Last-Modified only when supported; schedule foreground/launch refresh with backoff and cancellation. Do not assume long background execution on tvOS: Apple documents suspension behavior in its [background execution guidance](https://developer.apple.com/documentation/uikit/about-the-background-execution-sequence). Validate actual tvOS background-task availability before promising background catalog refresh.

## 8. Risks, phases, estimates and tests (proposed)

1. **Provider capability spike (small–medium):** sanitized fixtures for all eight actions, schema variants, HTTP limits, authorization expiry, category-filter probes, direct playback probes. Real-provider testing only with user-supplied access; never store fixtures with secrets.
2. **Read-only VOD catalog (large):** source IDs, SQLite staging/index, Xtream movie/series summaries, lazy detail/episodes, provider-specific browse. Exercise 50k movies/20k series and memory ceilings on physical Apple TV.
3. **Playback and personal state (large/high risk):** secure URL construction, format probing, native/Aether route decision, seek/resume, local profile-scoped history/favorites, failure handling. Test HLS/MP4 and unsupported MKV/codecs, redirects and expired credentials on hardware.
4. **Unified UX (large):** source filters, mixed search, source badges, Continue Watching projection, provider removal and unavailable states; retain server-only Silo collections. Accessibility/focus and before/after evidence across affected devices.
5. **M3U VOD (medium–large/uncertain):** provider profiles, confidence/ambiguity UI, reversible classification and refresh identity; do not ship heuristic-only automatic series detection.

Complexity is **high** overall (several builds, not one feature patch), dominated by provider inconsistency, huge catalog ingestion and playback compatibility. Test with sanitized variants, 50k/20k synthetic catalogs, high-episode series, cancellation and partial responses, auth rotation, duplicate titles across providers, cache corruption, profile separation, offline/slow networks, memory/performance metrics, hardware seek/resume, and unchanged Silo regression gates. No trustworthy schedule can be quoted without hardware/provider samples.

## 9. Decisions needed before development

1. Approve C as the end-state navigation, with B as the first shippable milestone?
2. Should IPTV VOD be opt-in per provider, and should `All` include every enabled provider by default?
3. For ambiguous M3U entries: keep in Live TV, show an Unclassified bucket, or require explicit user group mapping before display?
4. On provider removal, delete or retain local IPTV watch history/favorites? Should history sync between Kyro devices eventually, and if so via what user-owned service?
5. Should unsupported containers be hidden, shown with a warning, or offered to a future transcoding service? No server changes are proposed here.
6. May representative, credential-sanitized provider response samples and real Apple TV playback checks be used in the next research/implementation build?
