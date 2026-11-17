#if os(tvOS)
import XCTest
@testable import Silo

/// A provider received through phone pairing is saved by the same path as a typed one.
@MainActor
final class KyroTVPairingTransferTests: XCTestCase {
    private final class MemorySecretStore: LiveTVSecretStore {
        var values: [String: String] = [:]
        func read(account: String) -> String? { values[account] }
        func save(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func remove(account: String) -> Bool { values[account] = nil; return true }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "kyro.tv.pairing.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = MemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeService() -> LiveTVService {
        LiveTVService(defaults: defaults, secretStore: secrets)
    }

    func testXtreamProviderIsSavedWithCredentialsOnlyInTheSecretStore() throws {
        let service = makeService()
        let payload = LiveTVPairingPayload(name: "Paired IPTV", kind: .xtream, playlistURL: nil, xmltvURL: nil,
                                           serverURL: "http://iptv.example:8080", username: "viewer1", password: "s3cret-pass")
        let id = try service.savePairedProvider(payload)

        XCTAssertEqual(service.providers.map(\.id), [id])
        XCTAssertEqual(service.providers.first?.kind, .xtream)
        XCTAssertEqual(service.selectedProviderID, id)
        // Credentials are in the keychain-backed store...
        let stored = try XCTUnwrap(secrets.values.values.first)
        XCTAssertTrue(stored.contains("s3cret-pass"))
        // ...and never in UserDefaults.
        let persisted = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(persisted.contains { $0.contains("s3cret-pass") || $0.contains("viewer1") })
        XCTAssertTrue(persisted.contains { $0.contains("Paired IPTV") })
    }

    func testM3UProviderIsSaved() throws {
        let service = makeService()
        let id = try service.savePairedProvider(LiveTVPairingPayload(
            name: "Playlist", kind: .m3u, playlistURL: "https://example.com/list.m3u", xmltvURL: "https://example.com/guide.xml",
            serverURL: nil, username: nil, password: nil))
        XCTAssertEqual(service.providers.first?.id, id)
        XCTAssertEqual(service.providers.first?.kind, .m3u)
    }

    func testInvalidProviderThrowsAndSavesNothing() {
        let service = makeService()
        let bad = LiveTVPairingPayload(name: "Bad", kind: .m3u, playlistURL: "ftp://example.com/list.m3u", xmltvURL: nil,
                                       serverURL: nil, username: nil, password: nil)
        XCTAssertThrowsError(try service.savePairedProvider(bad))
        XCTAssertTrue(service.providers.isEmpty)
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testSavingTwiceCreatesIndependentProvidersAndDoesNotOverwriteSecrets() throws {
        let service = makeService()
        let first = try service.savePairedProvider(LiveTVPairingPayload(
            name: "A", kind: .xtream, playlistURL: nil, xmltvURL: nil, serverURL: "https://a.example", username: "u1", password: "p1"))
        let second = try service.savePairedProvider(LiveTVPairingPayload(
            name: "B", kind: .xtream, playlistURL: nil, xmltvURL: nil, serverURL: "https://b.example", username: "u2", password: "p2"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(secrets.values.count, 2)
        XCTAssertEqual(service.providers.count, 2)
    }

    func testReceiverStartsIdleAndPairingScreenMetadataIsFormatted() {
        let receiver = TVLiveTVPairingReceiver(service: makeService())
        XCTAssertEqual(receiver.status, .idle)
        XCTAssertNil(receiver.link)
        XCTAssertEqual(TVLiveTVPairingView.clock(300), "5:00")
        XCTAssertEqual(TVLiveTVPairingView.clock(59.2), "1:00")
        XCTAssertEqual(TVLiveTVPairingView.clock(0), "0:00")
        XCTAssertNotNil(TVLiveTVPairingView.qrImage(for: "kyro://livetv-pair?v=1"))
    }
}
#endif
