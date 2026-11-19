# Kyro iOS Build 98 scalability status

Build 98 remains **in progress**. The iOS-only VOD port and source separation from commits
`d0642d4d` and `32631e1b` remain intact. This milestone hardens VOD indexing and recovery;
it does **not** establish 100,000-channel Live TV readiness or real-device VOD capacities.

## Architecture implemented

- VOD rows remain provider/kind/generation scoped in SQLite. A refresh stages a new generation
  in bounded batches, then switches the active generation transactionally. The previous
  generation remains readable if parsing, storage, cancellation, or promotion fails.
- VOD title search now uses an external-content FTS5 index with insert/update/delete triggers
  in the same SQLite transaction as catalog writes. Existing catalogs are rebuilt once under
  `user_version=2`. Queries join from the FTS index instead of scanning titles with `%LIKE%`.
  Search matches token prefixes; it no longer promises arbitrary mid-word substring matching.
- Browse-only pagination has generation-scoped sparse title checkpoints every 1,024 rows. Deep
  pages seek from the nearest checkpoint instead of offset-scanning the entire 400K-row index;
  duplicate-title boundaries are covered by host checks. Category and search pages still use
  OFFSET and need representative real-provider measurements.
- Opening or migrating the catalog database runs on a utility worker rather than the main actor.
  One in-flight open is shared among callers. Old and crash-orphaned generations are removed in
  cancellable 1,024-row batches, after promotion or before the next refresh. This makes the
  active-generation switch short; it does not make a full provider download incremental.
- Xtream `get_vod_streams` and `get_series` do not supply a reliable revision token in this
  client contract, so VOD refresh remains bounded full replacement. Import concurrency is one
  refresh pipeline at a time, with the existing streaming scanner and 1,024-row insertion batches.
- The default-off VOD preference, unified backup, Silo/IPTV source selection, provider-specific
  IDs and playback from the earlier milestones are unchanged.

## Synthetic Mac host benchmark

The benchmark compiles the **production** VOD model, scanner, and SQLite store using
`KYRO_VOD_HOST_TESTS`; only unrelated Live TV URL/error dependencies are stubbed. Fixtures use
deterministic numbered titles, 40 categories, no artwork or summaries, one provider and one
generation. Every run checks stored count, paging, search and provider isolation. A separate
host checks verify legacy-catalog FTS migration, duplicate upsert, interrupted-generation pruning,
FTS recovery on reopen and pagination across duplicate-title checkpoint boundaries.

Run without Simulator from the repository root:

```sh
swiftc -O -D KYRO_VOD_HOST_TESTS -lsqlite3 \
  iosApp/iosApp/Kyro/IPTVVOD/XtreamVODModels.swift \
  iosApp/iosApp/Kyro/IPTVVOD/XtreamVODCatalogScanner.swift \
  iosApp/iosApp/Kyro/IPTVVOD/XtreamVODCatalogStore.swift \
  iosApp/Benchmarks/IPTVVODStoreBenchmark.swift -o /tmp/kyro-vod-benchmark
BENCH_DIR=$(mktemp -d)
/tmp/kyro-vod-benchmark "$BENCH_DIR"
```

Measured on Apple M2, macOS 26.6, optimized Swift, SQLite WAL, with no Simulator. Times are
one run each, not p95; process peak RSS includes all sequential fixtures and is not per catalog.
The `sqlite_bytes` column measures the main DB file after closing, excluding WAL/SHM and
filesystem overhead. No real iPhone timings or memory measurements were collected.

| Kind | Rows | Import + index | Exact-title-prefix search | Category page | Page 200 | Final page | DB file | Process peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Movie | 100,000 | 2.863 s | 2 ms | <1 ms | <1 ms | <1 ms | 41.7 MB | 18 MB |
| Movie | 200,000 | 5.928 s | 4 ms | <1 ms | <1 ms | <1 ms | 83.3 MB | 19 MB |
| Movie | 400,000 | 12.719 s | 12 ms | <1 ms | <1 ms | <1 ms | 166.6 MB | 21 MB |
| Series | 50,000 | 1.396 s | 1 ms | <1 ms | <1 ms | <1 ms | 20.9 MB | 21 MB |
| Series | 100,000 | 2.837 s | 2 ms | <1 ms | <1 ms | <1 ms | 41.9 MB | 21 MB |
| Series | 200,000 | 5.949 s | 4 ms | <1 ms | <1 ms | <1 ms | 84.0 MB | 21 MB |

Provisional synthetic budgets: 400K movie import + index <30 s, indexed search <50 ms,
category/page query (including final page) <50 ms, main DB <250 MB and host process peak RSS <100 MB. These fixtures
meet those budgets, but do **not** validate provider JSON download/scan time, image load, deep
pagination, populated metadata, disk-full behavior, concurrent UI work, or iPhone memory.

## Live TV work still required

Live TV remains limited to **40,000** channels. Raising the constant now would be unsafe:

- `LiveTVService.channelCatalogs` retains complete `[LiveTVChannel]` arrays, and source switching,
  playback lookup, favorites and EPG filter creation still depend on them.
- `LiveTVChannelSearchIndex` duplicates the catalog metadata and scans every entry per query;
  a blank query materializes every match. Browse/Guide SwiftUI state still receives full arrays.
- The offline channel snapshot is a whole-array JSON encode/decode with a 32 MB file ceiling.
- M3U and Xtream imports build full arrays before replacement. Neither has paged disk-backed
  channels, incremental import, or measured 40K/60K/80K/100K performance.

The next milestone must add a provider-scoped SQLite channel catalog with stable ordinals,
indexed category and FTS search, atomic active-generation replacement, bounded paging and
ID-based playback resolution; then migrate Browse/Guide, favorites, provider switching and EPG
matching off the full-array path. Benchmark 40K, 60K, 80K and 100K and verify EPG lookup,
scrolling and memory before changing the import cap.

## Validation and device acceptance

The generic iOS `build-for-testing` is a compile gate only. It does **not** run XCTest.
The Mac host benchmark exercises VOD SQLite correctness and synthetic scale; iOS tests for
VOD preference, backup, import cancellation and source separation still need an approved
runtime test environment. No Simulator or IPA was used in this milestone.

Before accepting Build 98 on a physical iPhone: import real 100K-channel and large VOD provider
catalogs; observe import duration, app peak memory and UI frame stalls; rapidly switch category,
search, source and provider; play Live TV, movie and episode; verify EPG/current-next, favorites,
Silo history isolation, VOD disable/re-enable, backup preview/restore/Undo, interrupted import
recovery, low-storage failure and offline relaunch. Do not call the capacity targets supported
until those measurements pass.
