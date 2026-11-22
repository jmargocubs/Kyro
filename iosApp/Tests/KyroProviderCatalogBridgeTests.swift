#if os(iOS)
import Foundation
import KyroProviders
import XCTest
@testable import Silo

/// Kyro Labs M2: how provider accounts reach the Movies/Series catalog on iOS. The index itself
/// is covered by `UnifiedProviderCatalogTests` (also runnable on the Mac without a simulator).
@MainActor
final class KyroProviderCatalogBridgeTests: XCTestCase {
    private struct FakeProvider: CatalogProviding {
        let account: ProviderAccountRef
        let libraryRows: [ProviderLibrary]
        let records: [String: [ProviderCatalogRecord]]
        func capabilities() async -> [Capability] { [] }
        func libraries() async throws -> [ProviderLibrary] { libraryRows }
        func catalogPage(library: LibraryRef, kind: MediaKind, cursor: String?) async throws -> ProviderCatalogPage {
            ProviderCatalogPage(records: (records[library.remoteID] ?? []).filter { $0.kind == kind }, next: nil)
        }
    }

    private var directory: URL!
    private var store: XtreamVODCatalogStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-bridge-\(UUID().uuidString)")
        store = try XtreamVODCatalogStore(directory: directory)
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: KyroProviderCatalogBridge.enabledDefaultsKey)
    }

    private func makeRuntime() throws -> KyroLocalIdentityRuntime {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("provider-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let suite = "KyroProviderCatalogBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return KyroLocalIdentityRuntime(databaseURL: folder.appendingPathComponent("identity.sqlite"), defaults: defaults)
    }

    private func provider(_ account: ProviderAccountRef, titles: [(String, String, Int)], kind: MediaKind = .movie,
                          library: String = "lib") throws -> FakeProvider {
        let libraryRef = try LibraryRef(account: account, remoteID: library)
        let rows = [ProviderLibrary(ref: libraryRef, name: "Library", kinds: [kind], sortOrder: nil),
                    ProviderLibrary(ref: try LibraryRef(account: account, remoteID: "music"), name: "Music", kinds: [], sortOrder: nil)]
        let records = try titles.map {
            try ProviderCatalogRecord(ref: ContentRef(account: account, remoteID: $0.0), library: libraryRef, kind: kind,
                                      title: $0.1, year: $0.2, payload: Data("{}".utf8))
        }
        return FakeProvider(account: account, libraryRows: rows, records: [library: records, "music": records])
    }

    private func titles(_ sources: [UnifiedProviderSource], kind: XtreamVODKind = .movie) async -> [String] {
        let scope = UnifiedIndexScope(kind: kind, siloScope: nil, siloLibraryIDs: [], providerIDs: [], providerSources: sources)
        return await store.unifiedPage(scope, direction: .forward(after: nil), limit: 100).rows.map(\.title)
    }

    // MARK: Accounts

    func testRegisteredMediaServerAccountsFeedTheCatalogWithoutASiloSession() async throws {
        let runtime = try makeRuntime()
        let registry = try XCTUnwrap(runtime.providerRegistry())
        let jellyfin = try await registry.register(kind: .jellyfin, label: "Den")
        let plex = try await registry.register(kind: .plex, label: "Plex")
        let accounts = await KyroProviderCatalogBridge.registeredAccounts(runtime: runtime)
        XCTAssertEqual(Set(accounts), [jellyfin, plex])
        XCTAssertEqual(
            Set(KyroProviderCatalogBridge.sources(accounts).map(\.account)), [jellyfin.description, plex.description])
    }

    func testTurningTheProviderCatalogOffRestoresTheBuild110Path() async throws {
        let runtime = try makeRuntime()
        try await runtime.providerRegistry()?.register(kind: .jellyfin, label: "Den")
        UserDefaults.standard.set(false, forKey: KyroProviderCatalogBridge.enabledDefaultsKey)
        let off = await KyroProviderCatalogBridge.registeredAccounts(runtime: runtime)
        XCTAssertTrue(off.isEmpty, "no provider arm in any grid or sync")
        UserDefaults.standard.removeObject(forKey: KyroProviderCatalogBridge.enabledDefaultsKey)
        let on = await KyroProviderCatalogBridge.registeredAccounts(runtime: runtime)
        XCTAssertEqual(on.count, 1, "the registered account was never touched")
    }

    // MARK: Sync

    func testTwoServersWithTheSameRemoteIDsSyncIntoSeparateRows() async throws {
        let a = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
        let b = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
        let mirror = ProviderCatalogMirror.shared
        mirror.register(try provider(a, titles: [("1", "Arrival", 2016), ("2", "Zodiac", 2007)]))
        mirror.register(try provider(b, titles: [("1", "Heat", 1995)]))
        defer { Task { await mirror.remove(a, store: store); await mirror.remove(b, store: store) } }

        let failed = await mirror.sync(kind: .movie, accounts: [a.description, b.description], force: true, store: store)
        XCTAssertFalse(failed)
        let both = await titles([.init(account: a.description), .init(account: b.description)])
        XCTAssertEqual(both, ["Arrival", "Heat", "Zodiac"])
        let onlyB = await titles([.init(account: b.description)])
        XCTAssertEqual(onlyB, ["Heat"])
        let series = await titles([.init(account: a.description)], kind: .series)
        XCTAssertTrue(series.isEmpty, "a movie library never fills the Series grid")
        let counts = await store.providerRowCounts()
        XCTAssertEqual(counts.active, 2, "the Music library lists no movies, so it is not synced")
    }

    func testRemovingAnAccountPurgesOnlyThatAccount() async throws {
        let a = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
        let b = ProviderAccountRef(id: ProviderAccountID(), kind: .plex)
        let mirror = ProviderCatalogMirror.shared
        mirror.register(try provider(a, titles: [("1", "Arrival", 2016)]))
        mirror.register(try provider(b, titles: [("1", "Heat", 1995)]))
        defer { Task { await mirror.remove(b, store: store) } }
        _ = await mirror.sync(kind: .movie, accounts: [a.description, b.description], force: true, store: store)

        await mirror.remove(a, store: store)
        let left = await titles([.init(account: a.description), .init(account: b.description)])
        XCTAssertEqual(left, ["Heat"])
        let skipped = await mirror.sync(kind: .movie, accounts: [a.description], force: true, store: store)
        XCTAssertFalse(skipped, "an account with no provider is skipped, not an error")
    }

    func testAProviderCannotWriteIntoAnotherAccountsRows() async throws {
        let a = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
        let b = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
        // Account A's provider returns a record that belongs to B.
        let stray = try ProviderCatalogRecord(
            ref: ContentRef(account: b, remoteID: "9"), library: LibraryRef(account: b, remoteID: "lib"),
            kind: .movie, title: "Intruder", year: 2000)
        let own = try provider(a, titles: [("1", "Arrival", 2016)])
        let hostile = FakeProvider(account: a, libraryRows: own.libraryRows, records: ["lib": own.records["lib"]! + [stray]])
        let mirror = ProviderCatalogMirror.shared
        mirror.register(hostile)
        defer { Task { await mirror.remove(a, store: store) } }
        _ = await mirror.sync(kind: .movie, accounts: [a.description], force: true, store: store)
        let seenByB = await titles([.init(account: b.description)])
        XCTAssertTrue(seenByB.isEmpty)
        let seenByA = await titles([.init(account: a.description)])
        XCTAssertEqual(seenByA, ["Arrival"], "the stray record was dropped")
    }
}
#endif
