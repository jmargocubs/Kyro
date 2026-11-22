# KyroSourceJellyfin: read-only Jellyfin client

`JellyfinClient` (actor) is UI-free and has no playback or progress reporting. The legacy
`JellyfinSource`/`JellyfinParser` in `Jellyfin.swift` are untouched.

## Public interface
- `init(baseURL:clientInfo:credentialStore:credentialKey:transport:)`. Inject
  `AppleKeychainCredentialStore` in the app; use a per-server key such as
  `kyro.jellyfin.<accountID>`. Nothing touches Silo's `TokenStore`.
- Auth: `authenticate(username:password:)`, `restoreSession()`, `signOut()`. Requests send
  `Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…[, Token=…]`; no
  `X-Emby-Token`. The password is never stored; the `JellyfinSession` JSON (with token) goes
  to the `CredentialStore`. A 401 on any authed call clears the stored session.
- Catalog: `libraries()`, `items(JellyfinPageRequest)` (movies/series/etc., optional
  `parentID`), `seasons(seriesID:)`, `episodes(seriesID:seasonID:)`.
- Detail: `movie(id:)`, `series(id:)`, `season(id:)`, `episode(id:)`.
- `imageURL(itemID:kind:tag:maxWidth:)` builds token-free artwork URLs.
- Models: `JellyfinMediaItem` (title, overview, year, runtime seconds, provider IDs,
  hierarchy IDs, artwork tags, `JellyfinUserState` with resume seconds / watched / favorite).
- Errors: `JellyfinError` (`unauthorized`, `serverUnavailable`, `malformedResponse`, …).
- Bounds: page size 1…500, response ≤ 8 MiB, 15 s timeout, same-host redirects only,
  non-advancing or oversized pages rejected, path segments validated.

## Connecting to M1 `MediaProvider` (later)
Write a `JellyfinProviderAdapter` outside this module (so it can depend on `KyroProviders`):
- `JellyfinContentID.rawValue` (`jellyfin:<serverID>:<itemID>`) → provider-scoped remote ID
  in `ContentRef`; the server ID is stable across URL changes.
- `JellyfinItemKind` → the M1 media kind; `libraries()` → library listing;
  `items`/`seasons`/`episodes` + `nextStartIndex` → paged browse; `movie/series/season/episode`
  → detail; `userState` → resume/watched projection.
- Capabilities to advertise: browse, detail, resume state. Not yet: playback, progress.
- Transport: `JellyfinTransport` is a POST-capable seam (the shared `HTTPClient` is GET-only);
  M3 may wrap `ResilientHTTPClient` once it supports methods/bodies.
