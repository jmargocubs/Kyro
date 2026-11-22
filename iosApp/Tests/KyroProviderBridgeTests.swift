import Foundation
import KyroProviders
import XCTest
@testable import Silo

/// M1 of the universal-provider migration: Kyro's provider types read the existing Silo and
/// Live TV stores without writing to them, and the Silo adapter keeps using the existing read.
@MainActor
final class KyroProviderBridgeTests: XCTestCase {
    private func entry(_ id: String, _ url: String, name: String?) -> ServerEntry {
        ServerEntry(id: id, url: url, fetchedName: name, lastUsedAt: Date(timeIntervalSince1970: 0))
    }

    func testSiloServerListProjectsWithoutTokensForSignedInAndSignedOutStates() {
        let entries = [entry("a", "https://a.example", name: "Cubbiehub"), entry("b", "https://b.example", name: nil)]
        let signedIn = ProviderProjection.silo(
            KyroProviderBridge.siloSnapshot(entries: entries, activeServerID: "a", isActiveServerSignedIn: true))
        XCTAssertEqual(signedIn.map(\.label), ["Cubbiehub", "https://b.example"], "the registry's display name")
        XCTAssertEqual(signedIn.map(\.connection), [.connected, .saved])

        let signedOut = ProviderProjection.silo(
            KyroProviderBridge.siloSnapshot(entries: entries, activeServerID: "a", isActiveServerSignedIn: false))
        XCTAssertEqual(signedOut.map(\.connection), [.signedOut, .saved])
        XCTAssertEqual(signedOut.map(\.ref), signedIn.map(\.ref))
    }

    func testLiveTVProvidersProjectWithTheirOwnIdentity() {
        let xtream = LiveTVProvider(id: UUID(), name: "X", channelCount: 3, lastRefreshed: nil, kind: .xtream)
        let m3u = LiveTVProvider(id: UUID(), name: "M", channelCount: 5, lastRefreshed: nil, kind: .m3u)
        let records = ProviderProjection.iptv(KyroProviderBridge.iptvSnapshot([xtream, m3u]))
        XCTAssertEqual(records.map(\.ref.id.rawValue), [xtream.id, m3u.id])
        XCTAssertEqual(records.map(\.ref.kind), [.xtream, .m3u])
    }

    func testSiloLibrariesKeepIDOrderAndKinds() {
        let rows = KyroProviderBridge.siloRows([
            Library(id: 4, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil),
            Library(id: 2, name: "TV", type: "series", sortOrder: 1, posterUrl: nil),
            Library(id: 9, name: "Mixed", type: "mixed", sortOrder: nil, posterUrl: nil),
            Library(id: 7, name: "Books", type: "audiobooks", sortOrder: 3, posterUrl: nil),
        ])
        XCTAssertEqual(rows.map(\.id), [4, 2, 9, 7])
        XCTAssertEqual(rows.map(\.kinds), [[.movie], [.series], [.movie, .series], []])
    }

    func testAdapterOverTheBridgeReadsOnlyWhileConnected() async throws {
        struct Stub: SiloLibraryReading {
            func readLibraries() async throws -> [SiloLibraryRow] {
                KyroProviderBridge.siloRows([Library(id: 4, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)])
            }
        }
        let account = ProviderAccountRef.derived(kind: .silo, key: "a")
        let signedOut = try SiloProviderAdapter(account: account, reader: Stub(), connection: { .signedOut })
        do {
            _ = try await signedOut.libraries()
            XCTFail("a signed-out server must not be read")
        } catch ProviderError.notConnected {}
        let connected = try SiloProviderAdapter(account: account, reader: Stub(), connection: { .connected })
        let libraries = try await connected.libraries()
        XCTAssertEqual(libraries.compactMap { $0.ref.siloLibraryID }, [4])
    }

    func testReadingTheLiveAccountsChangesNoSiloStateAndMatchesTheRegistry() {
        let registry = ServerRegistry.shared
        let before = (registry.entries.map(\.id), registry.activeServerId, AuthService.shared.isLoggedIn)
        let accounts = KyroProviderBridge.accounts
        let after = (registry.entries.map(\.id), registry.activeServerId, AuthService.shared.isLoggedIn)
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(before.2, after.2)
        XCTAssertEqual(
            accounts.filter { $0.ref.kind == .silo }.count, registry.entries.count,
            "one Silo account per saved server")
        let connected = accounts.filter { $0.connection == .connected && $0.ref.kind == .silo }
        XCTAssertEqual(connected.count, AuthService.shared.isLoggedIn && registry.activeServerId != nil ? 1 : 0)
    }
}
