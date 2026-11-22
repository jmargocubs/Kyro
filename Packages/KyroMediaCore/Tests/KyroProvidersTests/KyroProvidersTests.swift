import Foundation
import KyroIdentity
import XCTest

@testable import KyroProviders

private struct StubSiloReader: SiloLibraryReading {
  let rows: [SiloLibraryRow]
  let counter: CallCounter
  func readLibraries() async throws -> [SiloLibraryRow] {
    await counter.bump()
    return rows
  }
}
private actor CallCounter {
  private(set) var count = 0
  func bump() { count += 1 }
}
private actor Switch {
  var value: ProviderConnection
  init(_ value: ProviderConnection) { self.value = value }
  func set(_ new: ProviderConnection) { value = new }
}

@MainActor final class KyroProvidersTests: XCTestCase {
  private func makeDatabase() throws -> (SQLiteDatabase, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("identity.sqlite")
    return (try SQLiteDatabase(path: url), url)
  }

  // MARK: Content references

  func testSameRemoteIDOnDifferentProvidersNeverCollides() throws {
    let silo = ProviderAccountRef.derived(kind: .silo, key: "server-a")
    let jellyfin = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let plex = ProviderAccountRef(id: ProviderAccountID(), kind: .plex)
    let refs = try [silo, jellyfin, plex].map { try ContentRef(account: $0, remoteID: "42") }
    XCTAssertEqual(Set(refs).count, 3)
    XCTAssertEqual(Set(refs.map(\.encoded)).count, 3)
    // The same ID on two accounts of one kind is also distinct.
    let other = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    XCTAssertNotEqual(
      try ContentRef(account: jellyfin, remoteID: "42"), try ContentRef(account: other, remoteID: "42"))
  }

  func testContentAndLibraryReferencesRoundTripAndDoNotCrossDecode() throws {
    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .plex)
    for id in ["1", "a:b/c d%", "ünï-çødé", "x:y:z:w:v"] {
      let content = try ContentRef(account: account, remoteID: id)
      XCTAssertEqual(ContentRef(encoded: content.encoded), content, id)
      XCTAssertNil(LibraryRef(encoded: content.encoded), "a content reference is not a library")
      let library = try LibraryRef(account: account, remoteID: id)
      XCTAssertEqual(LibraryRef(encoded: library.encoded), library, id)
      XCTAssertNil(ContentRef(encoded: library.encoded))
    }
    for bad in ["", "kyro:ref:v1:content:plex:not-a-uuid:1", "kyro:ref:v2:content:plex:\(UUID()):1",
      "kyro:ref:v1:content:nope:\(UUID()):1", "kyro:ref:v1:content:plex:\(UUID().uuidString.uppercased()):1"]
    {
      XCTAssertNil(ContentRef(encoded: bad), bad)
    }
    XCTAssertThrowsError(try ContentRef(account: account, remoteID: ""))
  }

  func testSiloContentAndLibraryIDsRoundTripLosslessly() throws {
    let silo = ProviderAccountRef.derived(kind: .silo, key: "s")
    let item = try ContentRef(account: silo, remoteID: "abc-123")
    XCTAssertEqual(item.siloContentID, "abc-123")
    let library = try LibraryRef(account: silo, siloLibraryID: 7)
    XCTAssertEqual(library.siloLibraryID, 7)
    let foreign = try ContentRef(account: ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin), remoteID: "abc-123")
    XCTAssertNil(foreign.siloContentID, "only a Silo reference may be opened as a Silo item")
  }

  func testDerivedAccountIsStablePerServerAndKind() {
    XCTAssertEqual(ProviderAccountRef.derived(kind: .silo, key: "a"), .derived(kind: .silo, key: "a"))
    XCTAssertNotEqual(ProviderAccountRef.derived(kind: .silo, key: "a"), .derived(kind: .silo, key: "b"))
    XCTAssertNotEqual(
      ProviderAccountRef.derived(kind: .silo, key: "a").id, ProviderAccountRef.derived(kind: .jellyfin, key: "a").id)
  }

  func testAccountDescriptionRoundTripsOnlyInItsCanonicalForm() {
    for kind in ProviderKind.allCases {
      let ref = ProviderAccountRef(id: ProviderAccountID(), kind: kind)
      XCTAssertEqual(ProviderAccountRef(description: ref.description), ref)
    }
    let id = UUID()
    for bad in ["", "silo", "silo:", "nope:\(id)", "plex:not-a-uuid", "plex:\(id.uuidString)", "plex:\(id.uuidString.lowercased()):x"] {
      XCTAssertNil(ProviderAccountRef(description: bad), bad)
    }
  }

  func testCatalogRecordsStayOnOneAccountAndHoldOnlyMoviesAndSeries() throws {
    let a = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let b = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let content = try ContentRef(account: a, remoteID: "7")
    let record = try ProviderCatalogRecord(
      ref: content, library: LibraryRef(account: a, remoteID: "lib"), kind: .movie, title: "Arrival", year: 2016)
    XCTAssertEqual(record.ref.account, a)
    XCTAssertThrowsError(
      try ProviderCatalogRecord(ref: content, library: LibraryRef(account: b, remoteID: "lib"), kind: .movie, title: "x"))
    { XCTAssertEqual($0 as? ProviderError, .accountMismatch) }
    XCTAssertThrowsError(
      try ProviderCatalogRecord(ref: content, library: LibraryRef(account: a, remoteID: "lib"), kind: .episode, title: "x"))
    { XCTAssertEqual($0 as? ProviderError, .unsupportedCatalogKind) }
  }

  // MARK: Registry persistence and household isolation

  func testRegisteredAccountsPersistAcrossReopen() async throws {
    let (db, url) = try makeDatabase()
    let household = HouseholdID()
    let registry = ProviderRegistry(identity: IdentityStore(database: db, household: household))
    let jellyfin = try await registry.register(kind: .jellyfin, label: "Den")
    let plex = try await registry.register(kind: .plex, label: "Plex")
    try await db.close()

    let reopened = try SQLiteDatabase(path: url)
    let again = ProviderRegistry(identity: IdentityStore(database: reopened, household: household))
    let accounts = try await again.accounts()
    XCTAssertEqual(Set(accounts.map(\.ref)), [jellyfin, plex])
    XCTAssertEqual(accounts.first { $0.ref == jellyfin }?.label, "Den")
    try await reopened.close()
  }

  func testJellyfinEndpointMetadataRestoresPerAccountWithoutChangingLegacyAccounts() async throws {
    let (db, url) = try makeDatabase()
    let household = HouseholdID()
    let registry = ProviderRegistry(identity: IdentityStore(database: db, household: household))
    let first = try await registry.register(kind: .jellyfin, label: "Den",
                                            endpoint: "https://den.example:8096")
    let second = try await registry.register(kind: .jellyfin, label: "Cabin",
                                             endpoint: "https://cabin.example")
    let legacy = try await registry.register(kind: .plex, label: "Plex")
    try await db.close()

    let reopened = try SQLiteDatabase(path: url)
    let restored = ProviderRegistry(identity: IdentityStore(database: reopened, household: household))
    let accounts = try await restored.storedAccounts()
    XCTAssertEqual(accounts.first { $0.id == first.id }?.endpoint, "https://den.example:8096")
    XCTAssertEqual(accounts.first { $0.id == second.id }?.endpoint, "https://cabin.example")
    XCTAssertNil(accounts.first { $0.id == legacy.id }?.endpoint)
    try await restored.remove(first)
    let remaining = try await restored.storedAccounts()
    XCTAssertEqual(Set(remaining.map(\.id)), [second.id, legacy.id])
    try await reopened.close()
  }

  func testHouseholdsInOneDatabaseDoNotSeeEachOthersAccounts() async throws {
    let (db, _) = try makeDatabase()
    let first = ProviderRegistry(identity: IdentityStore(database: db, household: HouseholdID()))
    let second = ProviderRegistry(identity: IdentityStore(database: db, household: HouseholdID()))
    try await first.register(kind: .emby, label: "Mine")
    let seen = try await second.accounts()
    XCTAssertTrue(seen.isEmpty)
  }

  func testProjectedKindsCannotBeRegistered() async throws {
    let (db, _) = try makeDatabase()
    let registry = ProviderRegistry(identity: IdentityStore(database: db, household: HouseholdID()))
    for kind in [ProviderKind.silo, .xtream, .m3u] {
      do {
        try await registry.register(kind: kind, label: "x")
        XCTFail("\(kind) is a projection")
      } catch ProviderError.projectedKind {}
    }
  }

  func testRemovingAProviderKeepsProfilesAndOtherAccounts() async throws {
    let (db, _) = try makeDatabase()
    let identity = IdentityStore(database: db, household: HouseholdID())
    let profile = KyroProfile(name: "Alex", kind: .standard)
    try await identity.create(profile)
    let registry = ProviderRegistry(identity: identity)
    let keep = try await registry.register(kind: .plex, label: "Keep")
    let drop = try await registry.register(kind: .jellyfin, label: "Drop")
    try await identity.grant(SourceGrant(profile: profile.id, account: drop.id, subject: "u", writable: false))

    try await registry.remove(drop)

    let remaining = try await registry.accounts().map(\.ref)
    XCTAssertEqual(remaining, [keep])
    let profiles = try await identity.profiles()
    XCTAssertEqual(profiles.map(\.id), [profile.id], "the Kyro profile survives a provider being removed")
    let grants = try await identity.grants(for: profile.id)
    XCTAssertTrue(grants.isEmpty)
    do {
      try await registry.remove(drop)
      XCTFail("removing twice must fail")
    } catch ProviderError.missingAccount {}
  }

  func testAccountFromANewerBuildIsSkippedNotDeleted() async throws {
    let (db, _) = try makeDatabase()
    let identity = IdentityStore(database: db, household: HouseholdID())
    try await identity.register(ProviderAccount(provider: "somethingnew", label: "Future"))
    let registry = ProviderRegistry(identity: identity)
    let visible = try await registry.accounts()
    XCTAssertTrue(visible.isEmpty)
    let stored = try await identity.accounts()
    XCTAssertEqual(stored.count, 1)
  }

  // MARK: Silo and IPTV projections

  func testSiloProjectionSignedInSignedOutAndNoServer() {
    let servers = [
      SiloServerSnapshot.Server(id: "a", name: "Cubbiehub"), .init(id: "b", name: "Other"),
    ]
    let signedIn = ProviderProjection.silo(
      SiloServerSnapshot(servers: servers, activeServerID: "a", isActiveServerSignedIn: true))
    XCTAssertEqual(signedIn.map(\.connection), [.connected, .saved])
    XCTAssertEqual(signedIn.map(\.label), ["Cubbiehub", "Other"])
    XCTAssertTrue(signedIn.allSatisfy { $0.origin == .projected && $0.ref.kind == .silo })

    let signedOut = ProviderProjection.silo(
      SiloServerSnapshot(servers: servers, activeServerID: "a", isActiveServerSignedIn: false))
    XCTAssertEqual(signedOut.map(\.connection), [.signedOut, .saved], "a saved server is not a connection")
    XCTAssertEqual(signedOut.map(\.ref), signedIn.map(\.ref), "signing out never changes the account")

    XCTAssertTrue(
      ProviderProjection.silo(SiloServerSnapshot(servers: [], activeServerID: nil, isActiveServerSignedIn: false))
        .isEmpty)
    // No active server: nothing is connected even if the flag is set.
    let none = ProviderProjection.silo(
      SiloServerSnapshot(servers: servers, activeServerID: nil, isActiveServerSignedIn: true))
    XCTAssertEqual(none.map(\.connection), [.saved, .saved])
  }

  func testIPTVProjectionKeepsTheLiveTVProviderIdentity() {
    let xtream = UUID()
    let m3u = UUID()
    let records = ProviderProjection.iptv([
      IPTVProviderSnapshot(id: xtream, name: "X", isXtream: true),
      IPTVProviderSnapshot(id: m3u, name: "M", isXtream: false),
    ])
    XCTAssertEqual(records.map(\.ref.id.rawValue), [xtream, m3u])
    XCTAssertEqual(records.map(\.ref.kind), [.xtream, .m3u])
    XCTAssertTrue(records.allSatisfy { $0.connection == .connected && $0.origin == .projected })
  }

  func testCombinedListHasNoDuplicatesAndKeepsProjectionsReadOnly() async throws {
    let (db, _) = try makeDatabase()
    let registry = ProviderRegistry(identity: IdentityStore(database: db, household: HouseholdID()))
    try await registry.register(kind: .jellyfin, label: "J")
    let silo = ProviderProjection.silo(
      SiloServerSnapshot(servers: [.init(id: "a", name: "S")], activeServerID: "a", isActiveServerSignedIn: true))
    let all = try await registry.allAccounts(projected: silo + silo)
    XCTAssertEqual(all.map(\.ref.kind), [.jellyfin, .silo])
    let stored = try await registry.accounts()
    XCTAssertEqual(stored.count, 1, "projections are never written to the registry")
  }

  // MARK: Capabilities

  func testSiloCapabilitiesFollowTheConnectionState() {
    let account = ProviderAccountRef.derived(kind: .silo, key: "a")
    let connected = ProviderCapabilities.capabilities(for: account, connection: .connected, isReachable: true)
    XCTAssertEqual(ProviderCapabilities.state(of: .requests, in: connected), .available)
    XCTAssertEqual(ProviderCapabilities.state(of: .downloads, in: connected), .available)
    XCTAssertEqual(ProviderCapabilities.state(of: .liveTV, in: connected), .unsupported)
    XCTAssertEqual(connected.count, ProviderFeature.allCases.count)
    XCTAssertTrue(connected.allSatisfy { $0.account == account.id })

    let signedOut = ProviderCapabilities.capabilities(for: account, connection: .signedOut)
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: signedOut), .requiresAuthentication)
    XCTAssertEqual(ProviderCapabilities.state(of: .liveTV, in: signedOut), .unsupported)

    let unprobed = ProviderCapabilities.capabilities(for: account, connection: .connected)
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: unprobed), .unknown)
    let down = ProviderCapabilities.capabilities(for: account, connection: .connected, isReachable: false)
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: down), .unavailable)
  }

  func testFeaturesNotEveryServerSupportsAreUnsupportedNotMissing() {
    let plex = ProviderAccountRef(id: ProviderAccountID(), kind: .plex)
    let caps = ProviderCapabilities.capabilities(for: plex, connection: .connected, isReachable: true)
    XCTAssertEqual(ProviderCapabilities.state(of: .requests, in: caps), .unsupported)
    XCTAssertEqual(ProviderCapabilities.state(of: .favorites, in: caps), .unsupported)
    XCTAssertEqual(ProviderCapabilities.state(of: .watched, in: caps), .available)
  }

  func testIPTVNeedsNoSignInAndOffersLiveTV() {
    let m3u = ProviderAccountRef(id: ProviderAccountID(), kind: .m3u)
    let caps = ProviderCapabilities.capabilities(for: m3u, connection: .connected, isReachable: true)
    XCTAssertEqual(ProviderCapabilities.state(of: .liveTV, in: caps), .available)
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: caps), .unsupported)
    let xtream = ProviderAccountRef(id: ProviderAccountID(), kind: .xtream)
    let xcaps = ProviderCapabilities.capabilities(for: xtream, connection: .saved, isReachable: true)
    XCTAssertEqual(ProviderCapabilities.state(of: .liveTV, in: xcaps), .available)
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: xcaps), .available)
  }

  func testCapabilityIDsAreUnique() {
    XCTAssertEqual(Set(ProviderFeature.allCases.map(\.capabilityID)).count, ProviderFeature.allCases.count)
  }

  // MARK: Silo adapter delegation

  func testAdapterDelegatesToTheExistingSiloReadOnceAndQualifiesIDs() async throws {
    let counter = CallCounter()
    let rows = [
      SiloLibraryRow(id: 2, name: "Movies", kinds: [.movie], sortOrder: 1),
      SiloLibraryRow(id: 9, name: "Shows", kinds: [.series], sortOrder: nil),
      SiloLibraryRow(id: 5, name: "Mixed", kinds: [.movie, .series], sortOrder: 3),
    ]
    let account = ProviderAccountRef.derived(kind: .silo, key: "a")
    let adapter = try SiloProviderAdapter(
      account: account, reader: StubSiloReader(rows: rows, counter: counter), connection: { .connected })
    let libraries = try await adapter.libraries()
    let calls = await counter.count
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(libraries.map(\.name), ["Movies", "Shows", "Mixed"], "Silo's order is kept")
    XCTAssertEqual(libraries.compactMap { $0.ref.siloLibraryID }, [2, 9, 5])
    XCTAssertTrue(libraries.allSatisfy { $0.ref.account == account })
    XCTAssertEqual(libraries.map(\.kinds), [[.movie], [.series], [.movie, .series]])
    XCTAssertEqual(libraries.map(\.sortOrder), [1, nil, 3])
  }

  func testAdapterAsksSiloNothingWhileNotConnected() async throws {
    let counter = CallCounter()
    let state = Switch(.signedOut)
    let adapter = try SiloProviderAdapter(
      account: .derived(kind: .silo, key: "a"), reader: StubSiloReader(rows: [], counter: counter),
      connection: { await state.value })
    for connection in [ProviderConnection.signedOut, .saved] {
      await state.set(connection)
      do {
        _ = try await adapter.libraries()
        XCTFail("\(connection) must not read libraries")
      } catch ProviderError.notConnected {}
    }
    let calls = await counter.count
    XCTAssertEqual(calls, 0, "no Silo request is sent without a session")

    await state.set(.connected)
    _ = try await adapter.libraries()
    let after = await counter.count
    XCTAssertEqual(after, 1)
    let caps = await adapter.capabilities()
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: caps), .unknown)
  }

  func testAdapterRejectsNonSiloAccountsAndPropagatesSiloErrors() async throws {
    let counter = CallCounter()
    XCTAssertThrowsError(
      try SiloProviderAdapter(
        account: ProviderAccountRef(id: ProviderAccountID(), kind: .plex),
        reader: StubSiloReader(rows: [], counter: counter), connection: { .connected }))

    struct Failing: SiloLibraryReading {
      func readLibraries() async throws -> [SiloLibraryRow] { throw URLError(.notConnectedToInternet) }
    }
    let adapter = try SiloProviderAdapter(
      account: .derived(kind: .silo, key: "a"), reader: Failing(), connection: { .connected })
    do {
      _ = try await adapter.libraries()
      XCTFail("Silo's own error must reach the caller unchanged")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .notConnectedToInternet)
    }
  }
}
