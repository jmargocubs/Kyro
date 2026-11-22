# Kyro Labs: Jellyfin Standalone Acceptance Test Plan & Regression Suite

**Document Version:** 1.1 (integration review, 2026-11-22)
**Target Milestone:** Jellyfin-only Kyro Labs Phase 2 Milestone  
**Baseline Commit:** `0af20608ae777717387d480b611aca0e20efa6db` (`kyro/labs-phase2-integration`, before acceptance-test cherry-pick)
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
  - Endpoint passes `KyroJellyfinConnections.endpoint(_:)` validation; enter a full `http://` or `https://` URL.
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
  - `client.restoreSession()` reads the saved session locally. The app then validates it with an authenticated libraries request before marking the account connected; test both online and offline launches.
  - A revoked token prompts reconnection without deleting the saved account or Kyro profile.

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
  6. Inspect episode title and synopsis in the series detail view. Opening a separate episode detail is not yet implemented.
* **Expected Result:**
  - `KyroUnifiedBrowseView` routes the provider-qualified `ContentRef` through `AppRouter.presentJellyfinDetail`.
  - Seasons can be selected and their episode lists reflect remote server indexes.

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
  1. Once a sign-out control exists, select Jellyfin Server A and tap **Sign Out**. This step is currently blocked.
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
  1. From the Add Media Server sheet on Kyro Home, select Jellyfin Server B and tap **Remove**.
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
| 10 | Hierarchy Navigation | Series detail shows selectable seasons and episode lists; standalone episode detail remains deferred | [ ] |
| 11 | Direct Play Video | Deferred until Jellyfin playback routing is implemented | Blocked |
| 12 | Playback Resume | Deferred until playback reporting and Continue Watching are implemented | Blocked |
| 13 | Multi-Account Switch | Second server added; profile switch transitions active server cleanly | [ ] |
| 14 | Token Revocation | Invalidate token on server web UI; app catches 401 and prompts sign-in | [ ] |
| 15 | Remove Server | Removing server cleans index without touching Kyro profile or IPTV | [ ] |

---

## 4. Technical Coverage Gaps Analysis

The integration at `0af20608` resolves three of the seven previously reported blockers:

1. **Jellyfin onboarding and authentication — resolved in code, device check pending.** `KyroFirstRunSetupView` opens `KyroJellyfinSetupView`; the connection owner authenticates, checks libraries, registers the account, and links it to the active Kyro profile. The form accepts a complete server URL rather than separate host, port, and SSL fields.
2. **Endpoint persistence and restoration — resolved in code, device check pending.** `ProviderAccount.endpoint` supplies the URL on cold launch. `KyroJellyfinConnections.restore()` reads the saved session and validates it with a network library request. An offline launch cannot be called connected until that check succeeds.
3. **Jellyfin detail routing — partially resolved.** Movie and series cards open `KyroJellyfinDetailView` through `AppRouter`, with selectable seasons and an episode list. The old optional `detailPresenter` is not used for this route. A separate tappable episode detail is still missing.

The remaining limitations are:

4. **Playback:** Jellyfin detail deliberately shows “Playback is not available yet”; stream resolution and player handoff are not integrated. Do not include unfinished playback work in this milestone.
5. **Progress and resume:** No Jellyfin playback reporting, resume action, or Continue Watching rail exists yet. Stages 7–8 and checklist items 11–12 are deferred.
6. **Account management:** The Add Media Server sheet lists saved accounts and supports reconnect and remove. Explicit sign-out and a dedicated Settings management section are absent. Stage 10 is deferred; stage 11 can run through the sheet.
7. **Physical-device evidence:** Generic iOS compilation and macOS package tests cannot establish real-server authentication, Keychain restoration, artwork rendering, profile switching, or Silo/IPTV behavior on the iPhone. Run the checklist only after a separately approved unsigned IPA build.
