# KyroMediaCore foundation (Phase 0/1)

## Contract and targets

This local Swift package is isolated from application targets and has no UI or app-model dependency. Its deployment targets follow `iosApp/project.yml`: iOS 18, macOS 26, tvOS 26. Swift tools 6.2 and Swift language mode 6 enable strict concurrency. Host-based validation uses the macOS SDK and does not require Simulator, signing, or network access. Existing app bundle IDs and Keychain groups are not changed.

SQLite is provided by the platform `sqlite3` library through a small system module. The module map uses a shim header because the SDK header is not colocated with the package. A serialized writer actor configures WAL, foreign keys, and migration bookkeeping; reader handles are bounded and read-only. Storage paths are injected. Migrations reject version regression. Call `close()` on actors when deterministic handle release is required.

PIN verification uses Apple's CommonCrypto `CCKeyDerivationPBKDF` (PBKDF2-HMAC-SHA256, random 128-bit salt, 210,000 rounds by default, 256-bit output) and constant-time byte comparison. CommonCrypto is a system crypto API, not a package dependency or homemade hashing algorithm. It is imported only by `KyroIdentity`. This resolves the earlier “Foundation/system libraries only” versus CommonCrypto constraint by treating CommonCrypto as a required Apple system library; confirm this interpretation before integrating on non-Apple platforms.

## Package modules

* `KyroFoundation`: typed independent IDs, deterministic HLC ordering/skew clamp, SQLite actors, storage injection, redaction.
* `KyroIdentity`: local household profiles, kinds/tombstones, PIN verifier, provider accounts/scopes, grants and unique writable provider-subject enforcement.
* `KyroLedger`: profile-scoped operation values/log, set-union merge, deterministic last-writer ordering and Continue Watching.
* `KyroCatalog`: portable canonical keys, media/source/version/provenance values, catalog generation and keyset-style API.
* `KyroMatching`: provider-independent identifier/title-year/edition matching with explicit conflict decisions.
* `KyroSources`: source adapter contracts, rate limiter, retry/backoff, circuit breaker, sync coordinator and Jellyfin/Xtream parsers.
* `KyroPlayback`, `KyroCapabilities`: provider-neutral playback/resolution/reporting and capability contracts.

No Silo login is required for a local profile. Source adapters use synthetic data only; no production endpoint or credential is embedded. Silo, Plex and Emby adapters and playback UI bridges remain out of scope.

## Acceptance boundary and known gaps

This is a Phase 0/1 scaffold, not a completed production persistence layer. The catalog and ledger currently hold data in memory; catalog search is a normalized in-memory contains query, not SQLite FTS. Generation replacement is atomic at the value boundary, not a SQLite transaction. Reader-pool methods are serialized by the actor rather than concurrently leased. The retry coordinator applies uniform retry to thrown errors and does not yet model HTTP status/retry-after classification. Jellyfin/Xtream parsers cover minimal catalog fixtures and not full provider dialects. Matching is conservative but needs the requested complete 300-pair labeled corpus before claiming zero false merges. Tests currently exercise 1,000 deterministic shuffled merges, but broader independent algebraic property generation and concurrent update schedules remain needed. The requested C-1…C-11 acceptance specification was not present in the inspected Labs documentation; this package currently has a smaller executable XCTest suite and must not be described as satisfying those absent criteria.

Before app integration, add durable schema/migrations for identity, operation ledger, and catalog; SQLite FTS5-backed search and transactional generation promotion; leased concurrent reader pool; classified HTTP transport with deterministic clock injection; full provider fixtures; comprehensive C-1…C-11 acceptance matrix; and property-based merge/matching fixtures. Keep this package independent and obtain architecture review of PIN policy and provider-subject ownership semantics.
