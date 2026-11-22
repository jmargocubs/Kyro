# Kyro Labs: Jellyfin Standalone Acceptance Test Plan & Regression Suite

**Document Version:** 1.0  
**Target Milestone:** Jellyfin-only Kyro Labs Phase 2 Milestone  
**Baseline Commit:** `1f2fa19b76f5d233414f413ffb1fc13d9c47a5f8` (`kyro/labs-phase2-integration`)  
**Target Device:** iPhone 16 Plus (Physical iOS Device, unsigned IPA distributed via Feather / Nullsign)  

---

## 1. Overview & Architectural Context

Kyro Labs is the experimental edition of Kyro (`com.cubbiestream.kyro.labs`). It enables independent, universal media-client operation where Jellyfin, Emby, Plex, and IPTV operate natively without requiring a Silo server session or subscription.

### Core Architectural Layers

1. **Provider Foundation (M1 - `KyroProviders`):**
   - Typed provider taxonomy (`ProviderKind.jellyfin`, `.silo`, `.plex`, `.xtream`, etc.).
   - Explicit separation between registered providers (Jellyfin, Emby, Plex) and projected providers (Silo, IPTV).
   - Household-scoped `ProviderAccountRef` preventing collisions across identical remote IDs.
   - Provider capabilities protocol (`ProviderCapabilities`) mapping feature states (`.browse`, `.search`, `.resume`, etc.) to `.available`, `.requiresAuthentication`, or `.unsupported`.

2. **Provider-Qualified Unified Catalog (M2 - `UnifiedProviderCatalog`):**
   - Three-arm architecture in SQLite index (`catalog.sqlite`, `XtreamVODCatalogStore` schema version 2):
     - Silo arm (`unified_silo_items`, `unified_silo_active`)
     - IPTV arm (`unified_iptv_keys`, `vod_items`)
     - Generic Provider arm (`unified_provider_items`, `unified_provider_active`, `unified_source_identity`)
   - Non-destructive additive schema with verified `rollbackProviderCatalog()` returning strictly to Build 110 schema.
   - Idempotent catalog mirror and staging (`ProviderCatalogMirror`, `UnifiedProviderSyncEngine`).

3. **Profile Linking (`ProfileLinkRegistry` & `IdentityStore`):**
   - Kyro-owned profiles in `Application Support/Kyro/identity.sqlite` outlive all server connections.
   - Many-to-many associations linking local Kyro profiles to remote provider users.
   - Projected account cleanup (`removedProjectedAccount`) clearing server associations without deleting Kyro profiles or PINs.

4. **Jellyfin Client & Provider Adapter (`KyroSourceJellyfin` & `JellyfinProviderAdapter`):**
   - `JellyfinClient`: Read-only async actor utilizing standard MediaBrowser authorization headers (`MediaBrowser Client="...", Device="...", DeviceId="...", Version="...", Token="..."`).
   - Pure credential isolation: Passwords are used once on `AuthenticateByName` and discarded; tokens are stored in injected `CredentialStore` (`AppleKeychainCredentialStore`).
   - `JellyfinProviderAdapter`: Conforms to `CatalogProviding`, mapping Jellyfin `movies`, `tvshows`, and `mixed` CollectionFolders to `ProviderLibrary` and streaming pages into `ProviderCatalogRecord`.

---

## 2. Standalone Acceptance Test Plan

This 12-stage test plan covers full end-to-end functionality for a Jellyfin-only installation on iOS.

### Stage 1: Fresh Install Without Silo
* **Goal:** Verify that a cold launch of Kyro Labs without Silo opens cleanly into Kyro's independent setup.
* **Pre-conditions:** App container is completely fresh (no previous `identity.sqlite`, `UserDefaults`, or Keychain items).
* **Test Steps:**
  1. Launch Kyro Labs from the Home Screen.
  2. Observe the initial launch route resolved by `KyroStartupPolicy.launchRoute(forSilo: .needsServerSetup)`.
  3. Verify that the app displays `KyroFirstRunSetupView` / Who's Watching rather than Silo's mandatory server sign-in or a server-connection error.
* **Expected Result:**
  - Route is `.needsProfile`.
  - No network calls are dispatched to any Silo server.
  - Who's Watching displays "Create Profile".

### Stage 2: Create & Select Kyro-Owned Profile
* **Goal:** Verify creation, PIN protection, and selection of local Kyro profiles.
* **Test Steps:**
  1. On `KyroFirstRunSetupView`, tap **Create Profile**.
  2. Enter profile name (e.g., "Alex", testing boundary lengths 1–30 characters).
  3. Choose an emoji avatar (e.g., 🍿) and specify a 4-digit PIN (e.g., `4826`).
  4. Save profile.
  5. Repeat to create a second "Kids" profile with `isChild = true` and no PIN.
  6. Tap "Alex", enter PIN when prompted.
* **Expected Result:**
  - Profiles are inserted into `Application Support/Kyro/identity.sqlite` with Argon2id salted PIN hashes.
  - Active profile ID is persisted to `UserDefaults` under `kyro.identity.active-profile-id`.
  - PIN verification rejects incorrect PINs and admits valid PINs.

### Stage 3: Add Jellyfin Server
* **Goal:** Verify entry and validation of a standalone Jellyfin server endpoint.
* **Test Steps:**
  1. On the provider setup view, select **Add Jellyfin Server**.
  2. Enter server URL (e.g., `https://jellyfin.local:8920` or bare IP `http://192.168.1.50:8096`).
  3. Test URL sanitization (leading/trailing whitespace, trailing slashes, scheme validation).
  4. Save endpoint.
* **Expected Result:**
  - Endpoint passes `SourceEndpoint` validation.
  - Server is registered in `ProviderRegistry` with `ProviderKind.jellyfin` and a new UUID `ProviderAccountID`.
  - Non-secret endpoint URL is saved with the account in `IdentityStore`.

### Stage 4: Authenticate and Restore Session
* **Goal:** Verify initial authentication and subsequent cold-launch session restoration.
* **Test Steps:**
  1. Enter Jellyfin username and password.
  2. Submit sign-in request.
  3. Verify network dispatch: `POST /Users/AuthenticateByName` with `MediaBrowser` client headers and JSON payload `{"Username": "...", "Pw": "..."}`.
  4. Confirm token reception: `AccessToken`, `ServerId`, `User.Id`.
  5. Force quit Kyro Labs (swipe away in iOS App Switcher).
  6. Re-launch the app.
* **Expected Result:**
  - Password is never written to disk or Keychain.
  - `JellyfinSession` is stored in Keychain under `kyro.jellyfin.<accountId>`.
  - On re-launch, `client.restoreSession()` restores the session in <5ms without sending any HTTP requests.
  - Capabilities report `.connected`.

### Stage 5: Browse Movies and Series
* **Goal:** Verify that Jellyfin libraries populate the unified Movies and Series grids without Silo.
* **Test Steps:**
  1. Select the **Movies** tab in Kyro Labs.
  2. Trigger catalog sync (`ProviderCatalogMirror.sync(kind: .movie)`).
  3. Verify `GET /Users/{userId}/Views` and subsequent `GET /Users/{userId}/Items` calls.
  4. Verify pagination of items (e.g., 100 items per page with `StartIndex` and `Limit`).
  5. Select the **Series** tab and verify TV shows catalog sync.
  6. Pull-to-refresh to trigger an incremental re-index.
* **Expected Result:**
  - Video libraries (`movies`, `tvshows`, `mixed`) are recognized; non-video collections (`music`, `photos`) are excluded.
  - Items are written to `unified_provider_items` and promoted to `unified_provider_active`.
  - Movies grid displays Jellyfin movie posters and titles sorted alphabetically.
  - Series grid displays Jellyfin series posters and titles.

### Stage 6: Open Movie, Series, and Episode Details
* **Goal:** Verify navigation from catalog grid cards to detail screens and hierarchy browsing.
* **Test Steps:**
  1. Tap a Jellyfin movie card in the Movies grid.
  2. Verify movie detail view: poster, backdrop art, production year, overview, duration, genres, IMDb rating.
  3. Return to Series grid and tap a Jellyfin series card.
  4. Observe seasons list (`GET /Shows/{seriesId}/Seasons`).
  5. Select Season 1 to view episodes list (`GET /Shows/{seriesId}/Episodes`).
  6. Tap an episode to view episode synopsis and runtime.
* **Expected Result:**
  - `KyroProviderCatalogBridge.detailPresenter` routes the `ContentRef` to the Jellyfin media detail screen.
  - Season and episode hierarchies reflect remote server indexes correctly.

### Stage 7: Start Playback Once Available
* **Goal:** Verify playback intent generation and stream delivery negotiation.
* **Test Steps:**
  1. On the movie or episode detail screen, tap **Play**.
  2. Verify player stream URL resolution (`/Videos/{itemId}/stream` or `/Items/{itemId}/Download`).
  3. Inspect stream delivery headers (auth token or query parameter).
  4. Initiate playback in AVPlayer / VLC engine.
* **Expected Result:**
  - `ResolvedPlayback` creates valid stream URLs.
  - Video playback buffers and starts cleanly with correct aspect ratio and audio tracks.

### Stage 8: Resume Playback and Continue Watching
* **Goal:** Verify progress ticks conversion, playback event reporting, and Continue Watching shelf.
* **Test Steps:**
  1. Play a movie for 10 minutes and pause/stop.
  2. Verify playback reporting (`/Sessions/Playing/Progress` or `/Sessions/Playing/Stopped` with `PositionTicks = 6,000,000,000`).
  3. Return to Kyro Home view.
  4. Inspect the Continue Watching rail.
  5. Tap the title to resume playback.
* **Expected Result:**
  - Playback resumes at the 10-minute mark (`resumePositionSeconds = 600`).
  - Home tab displays the in-progress Jellyfin item with accurate progress indicator bar.

### Stage 9: Switch Between Multiple Jellyfin Accounts
* **Goal:** Verify isolation and seamless switching between two distinct Jellyfin servers.
* **Test Steps:**
  1. Register Server A (`https://home.jellyfin.local`) and Server B (`https://remote.jellyfin.org`).
  2. Authenticate Server A as User "Alice"; authenticate Server B as User "Bob".
  3. Link Kyro Profile "Alex" to Server A; link Kyro Profile "Bob" to Server B.
  4. Switch profiles in Who's Watching.
  5. Browse Movies on both profiles.
* **Expected Result:**
  - Profile "Alex" sees only Server A's catalog and watch progress.
  - Profile "Bob" sees only Server B's catalog and watch progress.
  - Neither server's auth tokens, cache, or cookies bleed into the other.

### Stage 10: Sign Out and Reconnect
* **Goal:** Verify explicit sign-out and re-authentication behavior.
* **Test Steps:**
  1. In Settings > Providers, select Jellyfin Server A and tap **Sign Out**.
  2. Verify network dispatch `POST /Sessions/Logout`.
  3. Verify Keychain state: `kyro.jellyfin.server-a` is deleted.
  4. Check Movies grid: catalog rows for Server A remain cached or mark requires authentication.
  5. Tap **Sign In** on Server A and authenticate with new credentials.
* **Expected Result:**
  - Local Kyro profiles are never touched or modified.
  - Capabilities transition from `.connected` -> `.requiresAuthentication` -> `.connected`.

### Stage 11: Remove an Account Safely
* **Goal:** Verify complete teardown of a Jellyfin provider account.
* **Test Steps:**
  1. In Settings > Providers, select Jellyfin Server B and tap **Remove Server**.
  2. Observe database teardown via `ProviderRegistry.remove(accountB)`.
  3. Observe catalog purge via `ProviderCatalogMirror.remove(accountB, store: store)`.
* **Expected Result:**
  - `unified_provider_items` and `unified_provider_active` for Account B are purged completely.
  - Account A titles, IPTV channels, and Silo data are 100% unaffected.
  - Local Kyro profiles and PINs are preserved.

### Stage 12: Verify IPTV-Only and Silo Regressions
* **Goal:** Ensure full backward compatibility for IPTV-only setups and legacy Silo setups.
* **Test Steps:**
  1. Test IPTV Xtream provider: Load live channels, EPG guide, and IPTV VOD items.
  2. Verify channel tuning and streaming.
  3. Test Silo server: Connect to a Silo server instance, authenticate, browse Silo libraries.
  4. Verify `rollbackProviderCatalog()` on `XtreamVODCatalogStore`: verify that dropping version 2 additive tables restores Build 110 schema without losing IPTV or Silo data.
* **Expected Result:**
  - IPTV playback, guide data, and channel lists operate without degradation.
  - Silo authentication, request fencing, and library browsing operate without regression.
  - No database lockups or foreign key constraint violations occur.

---

## 3. Physical iPhone Acceptance Checklist

To be completed on physical iPhone 16 Plus running unsigned release build via Feather:

| Step # | Verification Item | Expected Pass Criteria | Status |
|:---:|---|---|:---:|
| 1 | Cold install launch | Opens `KyroFirstRunSetupView`; no crash, no Silo gating | [ ] |
| 2 | Kyro Profile setup | Profile created with emoji avatar + 4-digit PIN; PIN unlocks profile | [ ] |
| 3 | Add Jellyfin Server | IP/domain input accepts port `:8096` / `:8920`; HTTPS/HTTP validated | [ ] |
| 4 | Authentication | Valid credentials authenticate; password not saved; token in Keychain | [ ] |
| 5 | Background / Resume | App backgrounded and resumed; session restored without re-login prompt | [ ] |
| 6 | Movies Grid Browse | Displays Jellyfin movie library; posters load via imageURL; scroll is 60fps | [ ] |
| 7 | Series Grid Browse | Displays Jellyfin TV shows; metadata (year, seasons) accurate | [ ] |
| 8 | Pull to Refresh | Pulling grid re-syncs catalog quietly; no duplicated cards | [ ] |
| 9 | Media Detail Screen | Tapping title opens movie/show detail; backdrop art renders | [ ] |
| 10 | Hierarchy Navigation | Series > Season > Episode navigation operates cleanly | [ ] |
| 11 | Direct Play Video | Video stream starts in AVPlayer/VLC; audio & subs selectable | [ ] |
| 12 | Playback Resume | Exiting midway and returning shows Resume button with correct timestamp | [ ] |
| 13 | Multi-Account Switch | Second server added; profile switch transitions active server cleanly | [ ] |
| 14 | Token Revocation | Invalidate token on server web UI; app catches 401 and prompts sign-in | [ ] |
| 15 | Remove Server | Removing server cleans index without touching Kyro profile or IPTV | [ ] |

---

## 4. Technical Coverage Gaps Analysis

While core foundational models, client networking, adapters, and schema v2 catalog storage are implemented and verified by automated tests, the following **seven specific gaps** in production UI and orchestration currently prevent executing the acceptance test on a physical iPhone build:

1. **Onboarding UI for Jellyfin (`KyroFirstRunSetupView` / `ServerSetupView`):**
   - Current status: First-run setup offers `Source.mediaServer` (which hard-routes to Silo's `ServerSetupView`) and `Source.iptv`.
   - Gap: Needs a dedicated Jellyfin server onboarding form (Host, Port, SSL toggle, Username, Password) that invokes `JellyfinClient.authenticate(...)` and registers with `ProviderRegistry`.
   - *Note: Active work by parallel integration agent.*

2. **Endpoint Persistence in Provider Account Record:**
   - Current status: `ProviderAccount` historically held only `id`, `provider`, `label`.
   - Gap: The server URL endpoint must be stored with the account (e.g. `endpoint: String?`) so that on cold launch the app knows which base URL to instantiate `JellyfinClient` with before calling `restoreSession()`.
   - *Note: Active work by parallel integration agent.*

3. **Detail Presenter Binding (`KyroProviderCatalogBridge.detailPresenter`):**
   - Current status: `detailPresenter` is `nil` in production (`KyroProviderCatalogBridge.swift:41`).
   - Gap: Tapping a media-server card without an IPTV alternate currently does nothing (`KyroUnifiedBrowseView.swift:181`). A SwiftUI view presenting `JellyfinMediaItem` details (and season/episode hierarchy) must be wired to `detailPresenter`.
   - *Note: Active work by parallel integration agent.*

4. **Player Routing for Jellyfin Streams:**
   - Current status: Playback coordinator is wired for Silo transcode/HLS and IPTV MPEG-TS/HLS streams.
   - Gap: Jellyfin stream URL generation (`/Videos/{itemId}/stream` with container/codec params) and playback handoff to `PlaybackCoordinator` is not yet connected.

5. **Playback Progress Reporting Endpoints:**
   - Current status: `JellyfinClient` is catalog read-only (explicitly documents: "Read-only Jellyfin catalog client. No playback or progress reporting").
   - Gap: Progress reporting methods (`reportPlaybackStarted`, `reportPlaybackProgress`, `reportPlaybackStopped` hitting `/Sessions/Playing/*`) are needed to sync watch progress back to the Jellyfin server.

6. **Home Tab Continue Watching Rail Integration:**
   - Current status: When Silo is signed out, Home shows `KyroHomeView` which offers Live TV and setup shortcuts.
   - Gap: Querying Jellyfin resume items (`/User/{userId}/Items/Resume`) and rendering a Jellyfin Continue Watching row on Kyro Home when Silo is not connected.

7. **Settings UI for Multi-Server Jellyfin Management:**
   - Current status: Server management UI in Settings is tied to `ServerRegistry` (Silo) and `LiveTVService` (IPTV).
   - Gap: Needs a "Media Servers" section in Kyro Settings to view registered Jellyfin accounts, inspect sync status, sign out, or delete a server.
