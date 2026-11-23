#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import XCTest
#if !KYRO_VOD_HOST_TESTS
@testable import Silo
#endif

/// Kyro Labs M2: the provider-qualified Movies/Series catalog. Runs on the Mac without a simulator
/// (`-D KYRO_VOD_HOST_TESTS`, see docs/kyro-development/kyro-labs.md) and in the iOS test target.
final class UnifiedProviderCatalogTests: XCTestCase {
    private let jellyA = "jellyfin:00000000-0000-0000-0000-00000000000a"
    private let jellyB = "jellyfin:00000000-0000-0000-0000-00000000000b"
    private let plex = "plex:00000000-0000-0000-0000-0000000000c1"
    private let siloAccount = "silo:00000000-0000-0000-0000-0000000000d1"
    private let p1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private var directory: URL!
    private var store: XtreamVODCatalogStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("unified-provider-\(UUID().uuidString)")
        store = try XtreamVODCatalogStore(directory: directory)
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    private func record(_ id: String, _ title: String, _ year: Int? = nil) -> UnifiedProviderRecord {
        UnifiedProviderRecord(contentID: id, title: title, year: year, poster: nil, payload: Data("{\"id\":\"\(id)\"}".utf8))
    }

    @discardableResult
    private func importProvider(_ account: String, library: String = "1", kind: XtreamVODKind = .movie,
                                _ records: [UnifiedProviderRecord], promote: Bool = true) async throws -> String {
        let snapshot = UUID().uuidString
        try await store.stageProvider(records, account: account, library: library, kind: kind, snapshot: snapshot)
        if promote {
            try await store.promoteProvider(account: account, library: library, kind: kind, snapshot: snapshot,
                                            itemCount: records.count, syncedAt: Date())
        }
        return snapshot
    }

    private func importSilo(_ records: [UnifiedSiloRecord], scope: String = "scope-a", library: Int = 1) async throws {
        let snapshot = UUID().uuidString
        try await store.stageSilo(records, scope: scope, libraryID: library, kind: .movie, snapshot: snapshot)
        try await store.promoteSilo(scope: scope, libraryID: library, kind: .movie, snapshot: snapshot,
                                    itemCount: records.count, syncedAt: Date())
    }

    private func siloRecord(_ id: String, _ title: String, _ year: Int?) -> UnifiedSiloRecord {
        UnifiedSiloRecord(contentID: id, title: title, year: year, poster: nil, payload: Data("{\"contentId\":\"\(id)\"}".utf8))
    }

    private func importIPTV(_ provider: UUID, _ items: [(Int, String)]) async throws {
        let generation = UUID().uuidString
        let rows = items.map {
            XtreamVODItem(providerID: provider, kind: .movie, remoteID: $0.0, title: $0.1, category: "All",
                          poster: nil, fileExtension: "mp4", summary: nil, genre: nil, rating: nil)
        }
        try await store.stage(rows, generation: generation)
        try await store.buildPageAnchors(providerID: provider, kind: .movie, generation: generation)
        try await store.buildUnifiedKeys(providerID: provider, kind: .movie, generation: generation)
        try await store.promote(providerID: provider, kind: .movie, generation: generation)
    }

    private func scope(silo: String? = nil, libraries: [Int] = [], iptv: [UUID] = [],
                       sources: [UnifiedProviderSource] = [], siloAccount: String? = nil,
                       kind: XtreamVODKind = .movie) -> UnifiedIndexScope {
        UnifiedIndexScope(kind: kind, siloScope: silo, siloLibraryIDs: libraries, providerIDs: iptv,
                          providerSources: sources, siloAccount: siloAccount)
    }

    private func all(_ scope: UnifiedIndexScope) async -> [UnifiedIndexRow] {
        await store.unifiedPage(scope, direction: .forward(after: nil), limit: 500).rows
    }

    private func counts() async -> (Int, Int, Int) {
        let c = await store.unifiedRowCounts()
        return (c.siloItems, c.siloActive, c.iptvKeys)
    }

    // MARK: Migration

    func testUnifiedSearchWorksWithJellyfinOnlyAndAccountIsolation() async throws {
        try await importProvider(jellyA, [record("m1", "Arrival", 2016), record("m2", "Heat", 1995)])
        try await importProvider(jellyB, [record("m1", "Arrival", 2016)])
        let onlyA = scope(sources: [.init(account: jellyA)])
        let results = await store.unifiedSearch(onlyA, query: "arri")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.primary.account, jellyA)
        let aHeat = await store.unifiedSearch(onlyA, query: "heat")
        let bHeat = await store.unifiedSearch(scope(sources: [.init(account: jellyB)]), query: "heat")
        let disconnected = await store.unifiedSearch(scope(), query: "arrival")
        XCTAssertEqual(aHeat.count, 1)
        XCTAssertTrue(bHeat.isEmpty)
        XCTAssertTrue(disconnected.isEmpty)
    }

    func testMigrationIsAdditiveAndLegacyCatalogsReadIdenticallyAfterwards() async throws {
        let version = await store.providerCatalogSchemaVersion()
        XCTAssertEqual(version, XtreamVODCatalogStore.providerCatalogVersion)
        try await importIPTV(p1, [(1, "Arrival (2016)"), (2, "Zodiac (2007)")])
        try await importSilo([siloRecord("s1", "Arrival", 2016), siloRecord("s2", "Blade Runner", 1982)])
        let legacy = scope(silo: "scope-a", libraries: [1], iptv: [p1])
        let before = await all(legacy)
        let beforeCounts = await counts()
        XCTAssertEqual(before.count, 4)

        // A version 1 database is exactly Build 110's: no schema record, no provider tables.
        try await store.rollbackProviderCatalog()
        let rolledBack = await store.providerCatalogSchemaVersion()
        XCTAssertNil(rolledBack)
        let after1 = await all(legacy)
        XCTAssertEqual(after1.map(\.cursor), before.map(\.cursor), "rollback leaves Silo and IPTV rows readable and identical")
        await store.close()

        // Opening it with this build migrates in place.
        store = try XtreamVODCatalogStore(directory: directory)
        let migrated = await store.providerCatalogSchemaVersion()
        XCTAssertEqual(migrated, XtreamVODCatalogStore.providerCatalogVersion)
        let after2 = await all(legacy)
        XCTAssertEqual(after2.map(\.cursor), before.map(\.cursor))
        XCTAssertEqual(after2.map(\.title), before.map(\.title))
        let afterCounts = await counts()
        XCTAssertTrue(afterCounts == beforeCounts, "no legacy row was added, moved or removed")
    }

    func testMigrationIsIdempotentAcrossReopens() async throws {
        try await importProvider(jellyA, [record("1", "Arrival", 2016)])
        await store.close()
        for _ in 0..<3 {
            store = try XtreamVODCatalogStore(directory: directory)
            let version = await store.providerCatalogSchemaVersion()
            XCTAssertEqual(version, XtreamVODCatalogStore.providerCatalogVersion)
            await store.close()
        }
        store = try XtreamVODCatalogStore(directory: directory)
        let rows = await all(scope(sources: [.init(account: jellyA)]))
        XCTAssertEqual(rows.map(\.title), ["Arrival"], "provider data survives reopening")
    }

    func testBuild110CodeOpeningAVersion2DatabaseLeavesProviderDataAlone() async throws {
        try await importProvider(jellyA, [record("1", "Arrival", 2016)])
        // What an earlier build runs on open: its own CREATE IF NOT EXISTS statements only.
        try await store.execute(XtreamVODCatalogStore.unifiedCatalogSchema)
        let counts = await store.providerRowCounts()
        XCTAssertEqual(counts.items, 1)
        XCTAssertEqual(counts.active, 1)
    }

    func testRollbackRemovesOnlyTheProviderTables() async throws {
        try await importProvider(jellyA, [record("1", "Arrival", 2016)])
        try await importSilo([siloRecord("s1", "Arrival", 2016)])
        try await store.rollbackProviderCatalog()
        let providerRows = await store.providerRowCounts()
        XCTAssertEqual(providerRows.items, -1, "the provider tables are gone")
        let silo = await counts()
        XCTAssertEqual(silo.0, 1)
        XCTAssertEqual(silo.1, 1)
        // Running the migration again restores an empty provider arm.
        try await store.execute(XtreamVODCatalogStore.providerCatalogMigrationSQL)
        let restored = await store.providerRowCounts()
        XCTAssertEqual(restored.items, 0)
    }

    func testBackfillRecordsLegacyIdentitiesOnceAndNeverRewritesABinding() async throws {
        try await importIPTV(p1, [(1, "Arrival (2016)")])
        try await importSilo([siloRecord("s1", "Arrival", 2016)], scope: "scope-a")
        let first = try await store.backfillLegacySourceIdentities()
        XCTAssertEqual(first, 2)
        let second = try await store.backfillLegacySourceIdentities()
        XCTAssertEqual(second, 0, "idempotent")
        let xtream = UnifiedCatalogKeys.iptvAccount(providerID: p1)
        let iptvKeys = await store.legacySources(account: xtream)
        XCTAssertEqual(iptvKeys, ["iptv:" + p1.uuidString.lowercased()])
        let unbound = await store.legacySources(account: siloAccount)
        XCTAssertTrue(unbound.isEmpty, "a Silo scope is unbound until the app names its account")

        try await store.bindSiloScope("scope-a", to: siloAccount)
        let bound = await store.legacySources(account: siloAccount)
        XCTAssertEqual(bound, ["silo-scope:scope-a"])
        try await store.bindSiloScope("scope-a", to: "silo:00000000-0000-0000-0000-0000000000ee")
        let still = await store.legacySources(account: siloAccount)
        XCTAssertEqual(still, ["silo-scope:scope-a"], "a scope keeps the account it was first bound to")
        let rebackfill = try await store.backfillLegacySourceIdentities()
        XCTAssertEqual(rebackfill, 0)
        let afterBackfill = await store.legacySources(account: siloAccount)
        XCTAssertEqual(afterBackfill, ["silo-scope:scope-a"], "backfill never unbinds")
    }

    // MARK: Silo signed out

    func testProviderTitlesBrowseWithNoSiloScopeAndSurviveTheSiloPurge() async throws {
        try await importProvider(jellyA, [record("1", "Arrival", 2016), record("2", "Zodiac", 2007)])
        try await importSilo([siloRecord("s1", "Blade Runner", 1982)])
        let signedOut = scope(silo: nil, libraries: [], sources: [.init(account: jellyA)])
        let rows = await all(signedOut)
        XCTAssertEqual(rows.map(\.title), ["Arrival", "Zodiac"], "no Silo scope: only provider titles, no Silo row leaks")
        // The grid purges Silo rows of other identities (all of them when signed out). That never
        // reaches the provider tables.
        try await store.purgeSilo(keepingScope: nil)
        let afterPurge = await all(signedOut)
        XCTAssertEqual(afterPurge.map(\.title), ["Arrival", "Zodiac"])
        let providerRows = await store.providerRowCounts()
        XCTAssertEqual(providerRows.items, 2)
    }

    func testSilo_SignedInAndProviderTitlesShareOneGrid() async throws {
        try await importProvider(jellyA, [record("1", "Arrival", 2016)])
        try await importSilo([siloRecord("s1", "Arrival", 2016), siloRecord("s2", "Blade Runner", 1982)])
        let mixed = scope(silo: "scope-a", libraries: [1], sources: [.init(account: jellyA)], siloAccount: siloAccount)
        let cards = UnifiedCatalogGrouping.cards(from: await all(mixed))
        XCTAssertEqual(cards.map(\.title), ["Arrival", "Blade Runner"])
        XCTAssertEqual(cards[0].members.count, 2, "the same film on Silo and a media server is one card")
        XCTAssertTrue(cards[0].hasSilo, "Silo stays the primary source of a matched title")
        XCTAssertEqual(cards[0].accounts, [siloAccount, jellyA])
    }

    // MARK: Identity and isolation

    func testSameRemoteIDOnDifferentAccountsNeverCollides() async throws {
        try await importProvider(jellyA, library: "1", [record("42", "Arrival", 2016)])
        try await importProvider(jellyB, library: "1", [record("42", "Arrival", 2016)])
        let rows = await all(scope(sources: [.init(account: jellyA), .init(account: jellyB)]))
        XCTAssertEqual(rows.count, 2, "two accounts, one remote ID: two rows")
        XCTAssertEqual(Set(rows.map(\.cursor.entryKey)).count, 2)
        XCTAssertEqual(Set(rows.map(\.account)), [jellyA, jellyB])
        let cards = UnifiedCatalogGrouping.cards(from: rows)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].members.count, 2, "two servers with the same film merge into one card with both sources")
        for row in rows {
            guard case let .provider(account, library, content, _) = row.source else { return XCTFail("provider row expected") }
            XCTAssertEqual(account, row.account)
            XCTAssertEqual(library, "1")
            XCTAssertEqual(content, "42")
        }

        // Each account only ever sees itself.
        let onlyA = await all(scope(sources: [.init(account: jellyA)]))
        XCTAssertEqual(onlyA.map(\.account), [jellyA])
        let none = await all(scope(sources: [.init(account: plex)]))
        XCTAssertTrue(none.isEmpty)
    }

    func testDifferentTitlesWithTheSameRemoteIDStaySeparateCards() async throws {
        try await importProvider(jellyA, [record("42", "Arrival", 2016)])
        try await importProvider(jellyB, [record("42", "Zodiac", 2007)])
        let cards = UnifiedCatalogGrouping.cards(from: await all(scope(sources: [.init(account: jellyA), .init(account: jellyB)])))
        XCTAssertEqual(cards.map(\.title), ["Arrival", "Zodiac"])
        XCTAssertEqual(Set(cards.map(\.id)).count, 2)
    }

    func testOneAccountsDuplicateTitlesAreNotMerged() async throws {
        // Two cuts of one film in one account stay two cards, as two Silo records do.
        try await importProvider(jellyA, [record("1", "Arrival", 2016), record("2", "Arrival", 2016)])
        let cards = UnifiedCatalogGrouping.cards(from: await all(scope(sources: [.init(account: jellyA)])))
        XCTAssertEqual(cards.count, 2)
    }

    func testRemovingAnAccountLeavesEveryOtherSourceUntouched() async throws {
        let iptv = UUID()
        try await importProvider(jellyA, [record("1", "Arrival", 2016)])
        try await importProvider(jellyB, [record("1", "Zodiac", 2007)])
        try await importSilo([siloRecord("s1", "Blade Runner", 1982)])
        try await importIPTV(iptv, [(9, "Heat (1995)")])
        try await store.purgeProvider(account: jellyA)
        let rows = await all(scope(silo: "scope-a", libraries: [1], iptv: [iptv],
                                   sources: [.init(account: jellyA), .init(account: jellyB)]))
        XCTAssertEqual(rows.map(\.title).sorted(), ["Blade Runner", "Heat (1995)", "Zodiac"])
    }

    func testLibraryAndAccountFilters() async throws {
        try await importProvider(jellyA, library: "movies", [record("1", "Arrival", 2016)])
        try await importProvider(jellyA, library: "kids", [record("2", "Coco", 2017)])
        try await importProvider(jellyB, library: "movies", [record("3", "Zodiac", 2007)])
        let titles: ([UnifiedProviderSource]) async -> [String] = { sources in
            await self.all(self.scope(sources: sources)).map(\.title)
        }
        let whole = await titles([.init(account: jellyA)])
        XCTAssertEqual(whole, ["Arrival", "Coco"])
        let one = await titles([.init(account: jellyA, libraries: ["kids"])])
        XCTAssertEqual(one, ["Coco"])
        let empty = await titles([.init(account: jellyA, libraries: [])])
        XCTAssertTrue(empty.isEmpty, "an empty library list reads nothing")
        let both = await titles([.init(account: jellyA, libraries: ["movies"]), .init(account: jellyB)])
        XCTAssertEqual(both, ["Arrival", "Zodiac"])
        let hostile = await titles([.init(account: jellyA, libraries: ["x') OR 1=1 --"])])
        XCTAssertTrue(hostile.isEmpty, "library text is data, never SQL")
    }

    func testKindsAreSeparatedPerAccount() async throws {
        try await importProvider(jellyA, kind: .movie, [record("1", "Arrival", 2016)])
        try await importProvider(jellyA, kind: .series, [record("2", "Severance", 2022)])
        let movies = await all(scope(sources: [.init(account: jellyA)], kind: .movie))
        let series = await all(scope(sources: [.init(account: jellyA)], kind: .series))
        XCTAssertEqual(movies.map(\.title), ["Arrival"])
        XCTAssertEqual(series.map(\.title), ["Severance"])
    }

    func testProviderEntryKeysAreInjective() {
        let triples = [("a", "b", "c"), ("a:b", "c", ""), ("a", "b:c", ""), ("a\u{1F}b", "c", "d"), ("a", "b\u{1F}c", "d"),
                       ("a%1Fb", "c", "d"), ("a", "b", "c\u{1F}"), ("", "", "x")]
        let keys = triples.map { UnifiedCatalogKeys.providerEntryKey(account: $0.0, library: $0.1, contentID: $0.2) }
        XCTAssertEqual(Set(keys).count, triples.count)
    }

    // MARK: Multiple providers

    func testCardsListSiloThenMediaServersThenIPTVAndPickAPrimary() async throws {
        let iptv = UUID()
        try await importIPTV(iptv, [(1, "Arrival (2016)")])
        try await importProvider(jellyB, [record("b", "Arrival", 2016)])
        try await importProvider(jellyA, [record("a", "Arrival", 2016)])
        let withoutSilo = UnifiedCatalogGrouping.cards(from: await all(
            scope(iptv: [iptv], sources: [.init(account: jellyA), .init(account: jellyB)])))
        XCTAssertEqual(withoutSilo.count, 1)
        XCTAssertEqual(withoutSilo[0].members.map(\.sourceRank), [1, 1, 2], "media servers before IPTV")
        guard case let .provider(account, _, contentID, _, alternates) = UnifiedDetailTarget(card: withoutSilo[0]),
              case let .provider(_, _, primaryID, _) = withoutSilo[0].members[0].source else {
            return XCTFail("a media-server title is the primary detail when there is no Silo record")
        }
        XCTAssertEqual(account, withoutSilo[0].members[0].account)
        XCTAssertEqual(contentID, primaryID)
        XCTAssertEqual(alternates.map(\.remoteID), [1], "IPTV stays reachable as an alternate")

        try await importSilo([siloRecord("s1", "Arrival", 2016)])
        let withSilo = UnifiedCatalogGrouping.cards(from: await all(
            scope(silo: "scope-a", libraries: [1], iptv: [iptv], sources: [.init(account: jellyA)])))
        guard case .silo = UnifiedDetailTarget(card: withSilo[0]) else { return XCTFail("Silo keeps the primary detail") }
        XCTAssertEqual(withSilo[0].members.map(\.sourceRank), [0, 1, 2])
    }

    func testIPTVOnlyAndZeroProviderGridsAreUnchanged() async throws {
        let iptv = UUID()
        try await importIPTV(iptv, [(1, "Arrival (2016)")])
        let iptvOnly = UnifiedCatalogGrouping.cards(from: await all(scope(iptv: [iptv])))
        XCTAssertEqual(iptvOnly.count, 1)
        guard case .iptv = UnifiedDetailTarget(card: iptvOnly[0]) else { return XCTFail("IPTV-only keeps the IPTV detail") }
        XCTAssertEqual(iptvOnly[0].accounts, [UnifiedCatalogKeys.iptvAccount(providerID: iptv)])
        let none = await all(scope())
        XCTAssertTrue(none.isEmpty, "zero providers: an empty grid, no error")
    }

    func testRowsCarryProviderQualifiedAccountsForEverySource() async throws {
        let iptv = UUID()
        try await importIPTV(iptv, [(1, "Heat (1995)")])
        try await importSilo([siloRecord("s1", "Alien", 1979)])
        try await importProvider(plex, [record("9", "Zodiac", 2007)])
        let rows = await all(scope(silo: "scope-a", libraries: [1], iptv: [iptv], sources: [.init(account: plex)],
                                   siloAccount: siloAccount))
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.account) })
        XCTAssertEqual(byTitle["Alien"], siloAccount)
        XCTAssertEqual(byTitle["Heat (1995)"], "xtream:" + iptv.uuidString.lowercased())
        XCTAssertEqual(byTitle["Zodiac"], plex)
        let unlabeled = await all(scope(silo: "scope-a", libraries: [1]))
        XCTAssertEqual(unlabeled.map(\.account), ["silo"], "a scope with no bound account keeps the legacy label")
    }

    func testPagingAcrossAllThreeArmsNeverSkipsOrRepeats() async throws {
        let iptv = UUID()
        try await importIPTV(iptv, (0..<120).map { ($0, String(format: "Alpha %03d (2001)", $0)) })
        try await importSilo((0..<120).map { siloRecord("s\($0)", String(format: "Bravo %03d", $0), 2002) })
        try await importProvider(jellyA, (0..<120).map { record("a\($0)", String(format: "Charlie %03d", $0), 2003) })
        try await importProvider(jellyB, (0..<120).map { record("a\($0)", String(format: "Charlie %03d", $0), 2003) })
        let grid = scope(silo: "scope-a", libraries: [1], iptv: [iptv],
                         sources: [.init(account: jellyA), .init(account: jellyB)])
        var cursor: UnifiedIndexCursor?
        var forward: [UnifiedIndexRow] = []
        while true {
            let page = await store.unifiedPage(grid, direction: .forward(after: cursor), limit: 50)
            forward.append(contentsOf: page.rows)
            cursor = page.rows.last?.cursor
            if page.reachedEdge || page.rows.isEmpty { break }
        }
        XCTAssertEqual(forward.count, 480)
        XCTAssertEqual(Set(forward.map(\.cursor)).count, 480, "no row repeats")
        func precedes(_ l: UnifiedIndexCursor, _ r: UnifiedIndexCursor) -> Bool {
            for (a, b) in [(l.sortKey, r.sortKey), (l.matchKey, r.matchKey), (l.entryKey, r.entryKey)] where a != b {
                return a.utf8.lexicographicallyPrecedes(b.utf8)
            }
            return false
        }
        XCTAssertTrue(zip(forward, forward.dropFirst()).allSatisfy { precedes($0.cursor, $1.cursor) },
                      "reads are in strict index order")

        var backward: [UnifiedIndexRow] = []
        var before: UnifiedIndexCursor? = forward.last?.cursor
        while let boundary = before {
            let page = await store.unifiedPage(grid, direction: .backward(before: boundary), limit: 50)
            backward.insert(contentsOf: page.rows, at: 0)
            before = page.rows.first?.cursor
            if page.reachedEdge || page.rows.isEmpty { break }
        }
        XCTAssertEqual(backward.map(\.cursor), Array(forward.dropLast()).map(\.cursor), "backward reads mirror forward reads")
    }

    // MARK: Snapshots and sync

    func testASnapshotIsInvisibleUntilPromotedAndReplacedAtomically() async throws {
        let sources = [UnifiedProviderSource(account: jellyA)]
        let first = try await importProvider(jellyA, [record("1", "Arrival", 2016)], promote: false)
        var visible = await all(scope(sources: sources))
        XCTAssertTrue(visible.isEmpty)
        try await store.promoteProvider(account: jellyA, library: "1", kind: .movie, snapshot: first, itemCount: 1, syncedAt: Date())
        let second = try await importProvider(jellyA, [record("1", "Arrival", 2016), record("2", "Zodiac", 2007)], promote: false)
        visible = await all(scope(sources: sources))
        XCTAssertEqual(visible.map(\.title), ["Arrival"], "the staged replacement is not shown")
        await store.discardProvider(account: jellyA, library: "1", kind: .movie, snapshot: second)
        await store.discardProvider(account: jellyA, library: "1", kind: .movie, snapshot: first)
        visible = await all(scope(sources: sources))
        XCTAssertEqual(visible.map(\.title), ["Arrival"], "discard never removes the active snapshot")
        try await importProvider(jellyA, [record("2", "Zodiac", 2007)])
        visible = await all(scope(sources: sources))
        XCTAssertEqual(visible.map(\.title), ["Zodiac"], "a completed sync replaces the old snapshot")
        let counts = await store.providerRowCounts()
        XCTAssertEqual(counts.items, 1)
    }

    func testFirstSyncPublishesWhileWalkingAndALaterFailureKeepsTheLastSnapshot() async throws {
        let sources = [UnifiedProviderSource(account: jellyA)]
        let pagesOf: (Int, Int) -> UnifiedProviderSyncPage<Int> = { index, last in
            UnifiedProviderSyncPage(
                records: (0..<3).map { self.record("p\(index)-\($0)", "Title \(index)-\($0)", 2000) },
                next: index < last ? index + 1 : nil, startsOver: false)
        }
        let seenMidWalk = SeenCount()
        let outcome = await UnifiedProviderSyncEngine.sync(
            store: store, account: jellyA, library: "1", kind: .movie, freshness: nil,
            isCurrent: { true },
            onProgress: { await seenMidWalk.record(await self.all(self.scope(sources: sources)).count) },
            first: { pagesOf(0, 3) }, next: { pagesOf($0, 3) })
        XCTAssertEqual(outcome, .synced(count: 12))
        let midWalk = await seenMidWalk.values
        XCTAssertFalse(midWalk.isEmpty)
        XCTAssertTrue(midWalk[0] < 12, "the grid showed titles before the walk finished")
        let finished = await all(scope(sources: sources)).count
        XCTAssertEqual(finished, 12)

        // A later walk that fails keeps the snapshot it did not finish replacing.
        struct Boom: Error {}
        let failed = await UnifiedProviderSyncEngine.sync(
            store: store, account: jellyA, library: "1", kind: .movie, freshness: nil, isCurrent: { true },
            first: { pagesOf(0, 3) }, next: { (_: Int) -> UnifiedProviderSyncPage<Int> in throw Boom() })
        XCTAssertEqual(failed, .failed)
        let kept = await all(scope(sources: sources)).count
        XCTAssertEqual(kept, 12)
        let rows = await store.providerRowCounts()
        XCTAssertEqual(rows.items, 12, "the failed walk's partial snapshot was discarded")
    }

    func testAccountRemovedMidFirstWalkRetractsWhatItPublished() async throws {
        let sources = [UnifiedProviderSource(account: jellyA)]
        let current = FlagBox(true)
        let outcome = await UnifiedProviderSyncEngine.sync(
            store: store, account: jellyA, library: "1", kind: .movie, freshness: nil,
            isCurrent: { await current.value },
            onProgress: { await current.set(false) },
            first: { UnifiedProviderSyncPage(records: [self.record("1", "Arrival", 2016)], next: 1, startsOver: false) },
            next: { (_: Int) in UnifiedProviderSyncPage(records: [self.record("2", "Zodiac", 2007)], next: nil, startsOver: false) })
        XCTAssertEqual(outcome, .identityChanged)
        let left = await all(scope(sources: sources))
        XCTAssertTrue(left.isEmpty, "nothing of a lost account stays visible")
    }

    func testFreshSnapshotsAreSkippedAndStaleOnesResync() async throws {
        try await importProvider(jellyA, [record("1", "Arrival", 2016)])
        let skipped = await UnifiedProviderSyncEngine.sync(
            store: store, account: jellyA, library: "1", kind: .movie, freshness: 3600, isCurrent: { true },
            first: { UnifiedProviderSyncPage<Int>(records: [], next: nil, startsOver: false) },
            next: { (_: Int) in UnifiedProviderSyncPage<Int>(records: [], next: nil, startsOver: false) })
        XCTAssertEqual(skipped, .skippedFresh)
        let at = await store.providerSyncedAt(account: jellyA, library: "1", kind: .movie)
        XCTAssertNotNil(at)
        let other = await store.providerSyncedAt(account: jellyB, library: "1", kind: .movie)
        XCTAssertNil(other, "freshness is per account")
    }

    func testSyncAccountPrunesDroppedLibrariesButKeepsEverythingOnAListingFailure() async throws {
        try await importProvider(jellyA, library: "keep", [record("1", "Arrival", 2016)])
        try await importProvider(jellyA, library: "gone", [record("2", "Zodiac", 2007)])
        try await importProvider(jellyB, library: "gone", [record("3", "Heat", 1995)])
        let page = { (id: String) in
            UnifiedProviderSyncPage<String>(records: [self.record(id, "New \(id)", 2020)], next: nil, startsOver: false)
        }
        // The library listing fails: nothing changes.
        struct Down: Error {}
        let failedListing = await UnifiedProviderSyncEngine.syncAccount(
            store: store, account: jellyA, kind: .movie, freshness: nil, isCurrent: { true },
            libraries: { throw Down() }, first: { page($0) }, next: { _, _ in page("x") })
        XCTAssertTrue(failedListing)
        let intact = await all(scope(sources: [.init(account: jellyA)])).map(\.title).sorted()
        XCTAssertEqual(intact, ["Arrival", "Zodiac"])

        // An empty listing is transient, not a revocation.
        let emptyListing = await UnifiedProviderSyncEngine.syncAccount(
            store: store, account: jellyA, kind: .movie, freshness: nil, isCurrent: { true },
            libraries: { [] }, first: { page($0) }, next: { _, _ in page("x") })
        XCTAssertFalse(emptyListing)
        let stillThere = await all(scope(sources: [.init(account: jellyA)])).count
        XCTAssertEqual(stillThere, 2)

        // A real listing replaces what it lists and prunes what it no longer lists, for that account only.
        let ok = await UnifiedProviderSyncEngine.syncAccount(
            store: store, account: jellyA, kind: .movie, freshness: nil, isCurrent: { true },
            libraries: { ["keep"] }, first: { page("fresh-\($0)") }, next: { _, _ in page("x") })
        XCTAssertFalse(ok)
        let titles = await all(scope(sources: [.init(account: jellyA), .init(account: jellyB)])).map(\.title).sorted()
        XCTAssertEqual(titles, ["Heat", "New fresh-keep"], "account A was pruned and replaced; account B was not touched")
    }

    // MARK: Search

    func testProviderSearchKeepsSourceIdentityAndIsolatesAccounts() async throws {
        try await importProvider(jellyA, library: "m", [record("1", "The Arrival", 2016), record("2", "Zodiac", 2007)])
        try await importProvider(jellyB, library: "m", [record("1", "Arrival of a Train", 1896)])
        try await importProvider(jellyA, library: "s", kind: .series, [record("9", "Arrival Series", 2020)])
        let both = [UnifiedProviderSource(account: jellyA), UnifiedProviderSource(account: jellyB)]
        let hits = await store.providerSearch(both, kind: nil, query: "arrival")
        XCTAssertEqual(hits.count, 3)
        for hit in hits {
            guard case let .provider(account, _, _, _) = hit.row.source else { return XCTFail("provider rows only") }
            XCTAssertEqual(hit.row.account, account)
        }
        let a1 = hits.first { $0.row.title == "The Arrival" }
        let b1 = hits.first { $0.row.title == "Arrival of a Train" }
        guard case let .provider(accountA, _, idA, _)? = a1?.row.source, case let .provider(accountB, _, idB, _)? = b1?.row.source else {
            return XCTFail("both hits expected")
        }
        XCTAssertEqual(idA, idB, "the same remote ID on two accounts")
        XCTAssertNotEqual(accountA, accountB, "…is told apart by account")

        let movies = await store.providerSearch(both, kind: .movie, query: "arrival")
        XCTAssertEqual(movies.count, 2)
        XCTAssertTrue(movies.allSatisfy { $0.kind == .movie })
        let onlyB = await store.providerSearch([.init(account: jellyB)], kind: nil, query: "arrival")
        XCTAssertEqual(onlyB.map(\.row.title), ["Arrival of a Train"])
        let none = await store.providerSearch([], kind: nil, query: "arrival")
        XCTAssertTrue(none.isEmpty)
        let blank = await store.providerSearch(both, kind: nil, query: "   ")
        XCTAssertTrue(blank.isEmpty)
        let quoted = await store.providerSearch([.init(account: "x' OR '1'='1")], kind: nil, query: "arrival")
        XCTAssertTrue(quoted.isEmpty, "account text is data, never SQL")
    }
}

private actor SeenCount {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

private actor FlagBox {
    private(set) var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { self.value = value }
}
#endif
