import Foundation
import XCTest
import KyroFoundation
import KyroIdentity
import KyroCredentials
import KyroSources
import KyroSourceJellyfin
import KyroCapabilities
@testable import KyroProviders

// MARK: - Deterministic Mock Transport & Fixtures

private final class DeterministicJellyfinTransport: JellyfinTransport, @unchecked Sendable {
  enum FailureMode: Sendable {
    case none
    case expiredToken
    case serverUnavailable(Int)
    case networkError
    case malformedJSON
    case oversizedPayload
    case stalledPagination
    case overflowPagination
  }

  private let lock = NSLock()
  private var _requests: [JellyfinRequest] = []
  private var _failureMode: FailureMode = .none

  var requests: [JellyfinRequest] { lock.withLock { _requests } }

  var failureMode: FailureMode {
    get { lock.withLock { _failureMode } }
    set { lock.withLock { _failureMode = newValue } }
  }

  var customHandler: (@Sendable (JellyfinRequest) throws -> HTTPResponse)?

  init(failureMode: FailureMode = .none, customHandler: (@Sendable (JellyfinRequest) throws -> HTTPResponse)? = nil) {
    self._failureMode = failureMode
    self.customHandler = customHandler
  }

  func send(_ request: JellyfinRequest) async throws -> HTTPResponse {
    lock.withLock { _requests.append(request) }

    let mode = lock.withLock { _failureMode }
    switch mode {
    case .none:
      break
    case .expiredToken:
      if let auth = request.headers["Authorization"], auth.contains("Token=") {
        return HTTPResponse(status: 401, body: Data(#"{"message":"Token expired or revoked"}"#.utf8))
      }
    case .serverUnavailable(let code):
      return HTTPResponse(status: code, body: Data(#"{"message":"Service unavailable"}"#.utf8))
    case .networkError:
      throw URLError(.cannotConnectToHost)
    case .malformedJSON:
      return HTTPResponse(status: 200, body: Data("<!DOCTYPE html><html><body>502 Bad Gateway</body></html>".utf8))
    case .oversizedPayload:
      // Return 9MB payload (exceeding JellyfinClient.maxResponseBytes of 8MB)
      let largeData = Data(repeating: 0x41, count: 9 * 1024 * 1024)
      return HTTPResponse(status: 200, body: largeData)
    case .stalledPagination:
      // Server returns empty items while TotalRecordCount claims 10
      let body = #"{"Items":[],"TotalRecordCount":10,"StartIndex":0}"#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    case .overflowPagination:
      // Server returns more items (105) than the requested limit (100)
      let items = (1...105).map { #"{"Id":"item-\#($0)","Type":"Movie"}"# }.joined(separator: ",")
      let body = #"{"Items":[\#(items)],"TotalRecordCount":105,"StartIndex":0}"#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    }

    if let custom = customHandler {
      return try custom(request)
    }

    return defaultRoute(request)
  }

  private func defaultRoute(_ request: JellyfinRequest) -> HTTPResponse {
    let path = request.url.path
    if path.hasSuffix("AuthenticateByName") {
      let body = #"""
      {"User":{"Id":"jf-user-1","Name":"Alex"},"AccessToken":"tok-secret-123","ServerId":"jf-srv-alpha"}
      """#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    } else if path.hasSuffix("/Views") {
      let body = #"""
      {"Items":[
        {"Id":"lib-movies","Name":"Films","Type":"CollectionFolder","CollectionType":"movies"},
        {"Id":"lib-shows","Name":"Television","Type":"CollectionFolder","CollectionType":"tvshows"},
        {"Id":"lib-mixed","Name":"Videos","Type":"CollectionFolder","CollectionType":"mixed"},
        {"Id":"lib-music","Name":"Tunes","Type":"CollectionFolder","CollectionType":"music"},
        {"Id":"lib-photos","Name":"Pictures","Type":"CollectionFolder","CollectionType":"photos"}
      ],"TotalRecordCount":5}
      """#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    } else if path.hasSuffix("/Items") {
      let body = #"""
      {"Items":[
        {
          "Id":"film-arrival",
          "Name":"Arrival",
          "Type":"Movie",
          "ServerId":"jf-srv-alpha",
          "Overview":"A linguist works with the military to communicate with alien lifeforms.",
          "ProductionYear":2016,
          "PremiereDate":"2016-11-11T00:00:00.0000000Z",
          "RunTimeTicks":69600000000,
          "ProviderIds":{"Imdb":"tt2543164"},
          "ImageTags":{"Primary":"poster-arrival-tag"},
          "BackdropImageTags":["backdrop-arrival-tag"],
          "UserData":{
            "PlaybackPositionTicks":18000000000,
            "PlayCount":1,
            "IsFavorite":true,
            "Played":false,
            "LastPlayedDate":"2026-11-20T14:30:00.0000000Z"
          }
        }
      ],"TotalRecordCount":1,"StartIndex":0}
      """#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    } else if path.contains("/Items/film-arrival") {
      let body = #"""
      {
        "Id":"film-arrival",
        "Name":"Arrival",
        "Type":"Movie",
        "ServerId":"jf-srv-alpha",
        "Overview":"A linguist works with the military to communicate with alien lifeforms.",
        "ProductionYear":2016,
        "RunTimeTicks":69600000000,
        "ProviderIds":{"Imdb":"tt2543164"},
        "ImageTags":{"Primary":"poster-arrival-tag"},
        "BackdropImageTags":["backdrop-arrival-tag"],
        "UserData":{
          "PlaybackPositionTicks":18000000000,
          "PlayCount":1,
          "IsFavorite":true,
          "Played":false
        }
      }
      """#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    } else if path.contains("/Seasons") {
      let body = #"""
      {"Items":[{"Id":"season-1","Name":"Season 1","Type":"Season","IndexNumber":1,"SeriesId":"series-dark"}],"TotalRecordCount":1}
      """#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    } else if path.contains("/Episodes") {
      let body = #"""
      {"Items":[{
        "Id":"ep-secrets",
        "Name":"Secrets",
        "Type":"Episode",
        "IndexNumber":1,
        "ParentIndexNumber":1,
        "SeriesId":"series-dark",
        "SeasonId":"season-1",
        "RunTimeTicks":31200000000,
        "UserData":{"PlaybackPositionTicks":0,"Played":true,"PlayCount":1}
      }],"TotalRecordCount":1}
      """#
      return HTTPResponse(status: 200, body: Data(body.utf8))
    } else if path.hasSuffix("Sessions/Logout") {
      return HTTPResponse(status: 204, body: Data())
    }

    return HTTPResponse(status: 404, body: Data(#"{"message":"Not found"}"#.utf8))
  }
}

// MARK: - Acceptance & Regression Test Suite

@MainActor
final class JellyfinAcceptanceRegressionTests: XCTestCase {
  private let defaultClientInfo = JellyfinClientInfo(
    client: "Kyro Labs",
    device: "iPhone Testbed",
    deviceID: "iphone-acceptance-01",
    version: "1.0.113"
  )

  private func makeIsolatedDatabase() throws -> (SQLiteDatabase, URL, HouseholdID, IdentityStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let dbURL = directory.appendingPathComponent("identity.sqlite")
    let db = try SQLiteDatabase(path: dbURL)
    let household = HouseholdID()
    let store = IdentityStore(database: db, household: household)
    return (db, dbURL, household, store)
  }

  // MARK: 1. Account Isolation & Multi-Account Independence

  func testAccountIsolation_IndependentCredentialsAndTokens() async throws {
    let store = MemoryCredentialStore()
    let transportA = DeterministicJellyfinTransport()
    let transportB = DeterministicJellyfinTransport(customHandler: { req in
      if req.url.path.hasSuffix("AuthenticateByName") {
        let body = #"""
        {"User":{"Id":"jf-user-beta","Name":"Bob"},"AccessToken":"tok-secret-beta","ServerId":"jf-srv-beta"}
        """#
        return HTTPResponse(status: 200, body: Data(body.utf8))
      }
      if req.url.path.hasSuffix("/Views") {
        let body = #"""
        {"Items":[{"Id":"lib-b","Name":"Bob Movies","Type":"CollectionFolder","CollectionType":"movies"}],"TotalRecordCount":1}
        """#
        return HTTPResponse(status: 200, body: Data(body.utf8))
      }
      return HTTPResponse(status: 404, body: Data())
    })

    // Server A: Alice on Home Jellyfin
    let clientA = try JellyfinClient(
      baseURL: URL(string: "https://home.jellyfin.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.server-a",
      transport: transportA
    )

    // Server B: Bob on Remote Jellyfin
    let clientB = try JellyfinClient(
      baseURL: URL(string: "https://remote.jellyfin.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.server-b",
      transport: transportB
    )

    _ = try await clientA.authenticate(username: "Alice", password: "alice-password")
    _ = try await clientB.authenticate(username: "Bob", password: "bob-password")

    // Both sessions must exist with distinct server endpoints and tokens
    let sessionA = await clientA.currentSession
    let sessionB = await clientB.currentSession
    XCTAssertNotNil(sessionA)
    XCTAssertNotNil(sessionB)
    XCTAssertEqual(sessionA?.userName, "Alex")
    XCTAssertEqual(sessionA?.accessToken, "tok-secret-123")
    XCTAssertEqual(sessionB?.userName, "Bob")
    XCTAssertEqual(sessionB?.accessToken, "tok-secret-beta")

    // Verify independent keys in credential store
    let dataA = await store.read("kyro.jellyfin.server-a")
    let dataB = await store.read("kyro.jellyfin.server-b")
    XCTAssertNotNil(dataA)
    XCTAssertNotNil(dataB)
    XCTAssertNotEqual(dataA, dataB)

    // Signing out Server A must clear Server A only
    try await clientA.signOut()
    let sessionAfterA = await clientA.currentSession
    let storeAfterA = await store.read("kyro.jellyfin.server-a")
    XCTAssertNil(sessionAfterA)
    XCTAssertNil(storeAfterA)

    // Server B remains fully intact and operational
    let sessionAfterB = await clientB.currentSession
    let storeAfterB = await store.read("kyro.jellyfin.server-b")
    XCTAssertNotNil(sessionAfterB)
    XCTAssertNotNil(storeAfterB)
    let bLibraries = try await clientB.libraries()
    XCTAssertEqual(bLibraries.count, 1)
  }

  func testAccountIsolation_AdapterEnforcesAccountBoundaryOnCatalogPages() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jellyfin.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.acc-boundary",
      transport: transport
    )
    _ = try await client.authenticate(username: "User", password: "pass")

    let accountA = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let accountB = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapterA = try JellyfinProviderAdapter(account: accountA, client: client)

    let libA = try LibraryRef(account: accountA, remoteID: "lib-movies")
    let libB = try LibraryRef(account: accountB, remoteID: "lib-movies")

    // Reading with own library ref succeeds
    let page = try await adapterA.catalogPage(library: libA, kind: .movie, cursor: nil)
    XCTAssertEqual(page.records.count, 1)
    XCTAssertEqual(page.records.first?.ref.account, accountA)

    // Reading with foreign account's library ref MUST throw accountMismatch
    do {
      _ = try await adapterA.catalogPage(library: libB, kind: .movie, cursor: nil)
      XCTFail("Adapter A must reject catalogPage request for Account B library")
    } catch let error as ProviderError {
      XCTAssertEqual(error, .accountMismatch)
    }
  }

  func testAccountIsolation_ProviderCatalogRecordEnforcesAccountMatching() throws {
    let accountA = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let accountB = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)

    let contentA = try ContentRef(account: accountA, remoteID: "item-1")
    let libraryA = try LibraryRef(account: accountA, remoteID: "lib-1")
    let libraryB = try LibraryRef(account: accountB, remoteID: "lib-1")

    // Matching account succeeds
    let record = try ProviderCatalogRecord(
      ref: contentA, library: libraryA, kind: .movie, title: "Title", year: 2026
    )
    XCTAssertEqual(record.ref.account, accountA)

    // Mismatched account throws accountMismatch
    XCTAssertThrowsError(
      try ProviderCatalogRecord(ref: contentA, library: libraryB, kind: .movie, title: "Title")
    ) { error in
      XCTAssertEqual(error as? ProviderError, .accountMismatch)
    }
  }

  func testAccountIsolation_ProfileLinkIndependenceAndSafeAccountRemoval() async throws {
    let (db, _, _, identity) = try makeIsolatedDatabase()
    defer { Task { try? await db.close() } }

    let profileParent = KyroProfile(name: "Parent", kind: .standard)
    let profileChild = KyroProfile(name: "Child", kind: .kids)
    try await identity.create(profileParent)
    try await identity.create(profileChild)

    let registry = ProviderRegistry(identity: identity)
    let accountA = try await registry.register(kind: .jellyfin, label: "Jellyfin Server A")
    let accountB = try await registry.register(kind: .jellyfin, label: "Jellyfin Server B")

    let links = ProfileLinkRegistry(identity: identity)
    let available = try await registry.accounts()

    // Link Parent to remote users on both servers; Child to Server A only
    try await links.link(profile: profileParent.id, to: accountA, remoteUserID: "user-a1", availableAccounts: available)
    try await links.link(profile: profileParent.id, to: accountB, remoteUserID: "user-b1", availableAccounts: available)
    try await links.link(profile: profileChild.id, to: accountA, remoteUserID: "user-a2", availableAccounts: available)

    // Unlinking Parent from Server A must leave Child's link to Server A and Parent's link to Server B intact
    try await links.unlink(profile: profileParent.id, from: accountA)
    let parentLinksAfter = try await links.links(for: profileParent.id)
    let childLinksAfter = try await links.links(for: profileChild.id)

    XCTAssertEqual(parentLinksAfter.count, 1)
    XCTAssertEqual(parentLinksAfter.first?.account, accountB.id)
    XCTAssertEqual(childLinksAfter.count, 1)
    XCTAssertEqual(childLinksAfter.first?.account, accountA.id)

    // Safe account removal: removing Account A from registry does NOT delete local Kyro profiles
    try await registry.remove(accountA)
    let storedAccounts = try await registry.accounts()
    XCTAssertEqual(storedAccounts.count, 1)
    XCTAssertEqual(storedAccounts.first?.ref, accountB)

    // Both local Kyro profiles still exist in identity store
    let survivingProfiles = try await identity.profiles()
    XCTAssertEqual(survivingProfiles.count, 2)
  }

  // MARK: 2. Expired Credentials & Invalidation

  func testExpiredCredentials_401PurgesSessionAndCredentialsImmediately() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.exp-test",
      transport: transport
    )

    _ = try await client.authenticate(username: "User", password: "pwd")
    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapter = try JellyfinProviderAdapter(account: account, client: client)

    // Capabilities initially connected (unprobed reachable state is .unknown, not .requiresAuthentication)
    let initialCaps = await adapter.capabilities()
    XCTAssertNotEqual(ProviderCapabilities.state(of: .browse, in: initialCaps), .requiresAuthentication)
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: initialCaps), .unknown)

    // Server token expires (returns 401)
    transport.failureMode = .expiredToken

    do {
      _ = try await adapter.libraries()
      XCTFail("Should throw unauthorized on 401")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .unauthorized)
    }

    // Client session and store must be immediately cleared
    let sessionAfterPurge = await client.currentSession
    let storeAfterPurge = await store.read("kyro.jellyfin.exp-test")
    XCTAssertNil(sessionAfterPurge)
    XCTAssertNil(storeAfterPurge)

    // Capabilities drop to requiresAuthentication
    let droppedCaps = await adapter.capabilities()
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: droppedCaps), .requiresAuthentication)

    // Any subsequent call without re-auth fails with notSignedIn
    do {
      _ = try await adapter.libraries()
      XCTFail("Should throw notSignedIn after 401 purge")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .notSignedIn)
    }

    // Re-authenticating with valid credentials restores connectivity
    transport.failureMode = .none
    _ = try await client.authenticate(username: "User", password: "new-pwd")
    let recoveredCaps = await adapter.capabilities()
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: recoveredCaps), .unknown)
    let recoveredLibs = try await adapter.libraries()
    XCTAssertFalse(recoveredLibs.isEmpty)
  }

  // MARK: 3. Session Restoration & Offline Behavior

  func testSessionRestoration_LoadsOfflineWithoutNetworkHits() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let clientA = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.persist",
      transport: transport
    )

    let originalSession = try await clientA.authenticate(username: "User", password: "pwd")

    // Cold launch simulation: create brand new client instance pointing to same credential key
    let coldTransport = DeterministicJellyfinTransport()
    let coldClient = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.persist",
      transport: coldTransport
    )

    let restored = try await coldClient.restoreSession()
    XCTAssertEqual(restored, originalSession)
    XCTAssertEqual(coldTransport.requests.count, 0, "Session restoration must not contact server")

    let adapter = try JellyfinProviderAdapter(
      account: ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin),
      client: coldClient
    )
    let caps = await adapter.capabilities()
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: caps), .unknown)
    XCTAssertNotEqual(ProviderCapabilities.state(of: .browse, in: caps), .requiresAuthentication)
  }

  func testSessionRestoration_CorruptedKeychainDataPurgesGracefully() async throws {
    let store = MemoryCredentialStore()
    await store.write(Data("corrupt-garbage-bytes".utf8), for: "kyro.jellyfin.corrupted")

    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.corrupted",
      transport: DeterministicJellyfinTransport()
    )

    let session = try await client.restoreSession()
    XCTAssertNil(session, "Corrupted session data must return nil")
    let storeAfterCorrupt = await store.read("kyro.jellyfin.corrupted")
    XCTAssertNil(storeAfterCorrupt, "Corrupted data must be purged from store")
  }

  // MARK: 4. Failed Catalog Synchronization & Boundaries

  func testFailedCatalogSync_ServerUnavailablePreservesStoredCredentials() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.outage",
      transport: transport
    )
    _ = try await client.authenticate(username: "User", password: "pwd")

    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapter = try JellyfinProviderAdapter(account: account, client: client)

    // 503 outage
    transport.failureMode = .serverUnavailable(503)
    do {
      _ = try await adapter.libraries()
      XCTFail("Should throw serverUnavailable")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .serverUnavailable)
    }

    // Temporary server outages must NOT delete user credentials or session
    let sessionOutage = await client.currentSession
    let storeOutage = await store.read("kyro.jellyfin.outage")
    XCTAssertNotNil(sessionOutage)
    XCTAssertNotNil(storeOutage)

    // Network disconnection (URLError)
    transport.failureMode = .networkError
    do {
      _ = try await adapter.libraries()
      XCTFail("Should throw serverUnavailable on network error")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .serverUnavailable)
    }

    let sessionNetError = await client.currentSession
    XCTAssertNotNil(sessionNetError)
  }

  func testFailedCatalogSync_MalformedResponseAndPaginationAnomalies() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.malformed",
      transport: transport
    )
    _ = try await client.authenticate(username: "User", password: "pwd")

    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapter = try JellyfinProviderAdapter(account: account, client: client)
    let lib = try LibraryRef(account: account, remoteID: "lib-movies")

    // HTML / non-JSON response
    transport.failureMode = .malformedJSON
    do {
      _ = try await adapter.catalogPage(library: lib, kind: .movie, cursor: nil)
      XCTFail("Should throw malformedResponse")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .malformedResponse)
    }

    // Infinite loop protection: 0 items returned while TotalRecordCount > 0
    transport.failureMode = .stalledPagination
    do {
      _ = try await adapter.catalogPage(library: lib, kind: .movie, cursor: nil)
      XCTFail("Should throw malformedResponse on stalled pagination")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .malformedResponse)
    }

    // Overflow protection: items returned > limit
    transport.failureMode = .overflowPagination
    do {
      _ = try await adapter.catalogPage(library: lib, kind: .movie, cursor: nil)
      XCTFail("Should throw malformedResponse on limit overflow")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .malformedResponse)
    }

    // Payload size protection: > 8MB
    transport.failureMode = .oversizedPayload
    do {
      _ = try await adapter.catalogPage(library: lib, kind: .movie, cursor: nil)
      XCTFail("Should throw responseTooLarge on >8MB payload")
    } catch let error as JellyfinError {
      XCTAssertEqual(error, .responseTooLarge)
    }
  }

  func testFailedCatalogSync_InvalidCursorAndUnsupportedKinds() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.cursor-test",
      transport: transport
    )
    _ = try await client.authenticate(username: "User", password: "pwd")

    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapter = try JellyfinProviderAdapter(account: account, client: client)
    let lib = try LibraryRef(account: account, remoteID: "lib-movies")

    // Negative cursor
    do {
      _ = try await adapter.catalogPage(library: lib, kind: .movie, cursor: "-5")
      XCTFail("Should throw invalidCursor")
    } catch let error as ProviderError {
      XCTAssertEqual(error, .invalidCursor)
    }

    // Non-numeric cursor
    do {
      _ = try await adapter.catalogPage(library: lib, kind: .movie, cursor: "not-a-number")
      XCTFail("Should throw invalidCursor")
    } catch let error as ProviderError {
      XCTAssertEqual(error, .invalidCursor)
    }
  }

  // MARK: 5. Media Detail Hierarchy & Metadata Fidelity

  func testMediaDetailAndHierarchy_MovieSeriesSeasonEpisodeFidelity() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.detail",
      transport: transport
    )
    _ = try await client.authenticate(username: "User", password: "pwd")

    // Movie detail
    let movie = try await client.movie(id: "film-arrival")
    XCTAssertEqual(movie.title, "Arrival")
    XCTAssertEqual(movie.year, 2016)
    XCTAssertEqual(movie.runtimeSeconds, 6960) // 69600000000 ticks / 10,000,000 = 6960 s
    XCTAssertEqual(movie.providerIDs["Imdb"], "tt2543164")
    XCTAssertEqual(movie.artwork.primaryTag, "poster-arrival-tag")
    XCTAssertEqual(movie.artwork.backdropTag, "backdrop-arrival-tag")
    XCTAssertEqual(movie.userState?.isWatched, false)
    XCTAssertEqual(movie.userState?.isFavorite, true)
    XCTAssertEqual(movie.userState?.resumePositionSeconds, 1800) // 18000000000 ticks / 10,000,000 = 1800 s

    // Season children
    let seasonsPage = try await client.seasons(seriesID: "series-dark")
    XCTAssertEqual(seasonsPage.items.count, 1)
    let season = seasonsPage.items[0]
    XCTAssertEqual(season.kind, .season)
    XCTAssertEqual(season.indexNumber, 1)

    // Episode children
    let episodesPage = try await client.episodes(seriesID: "series-dark", seasonID: "season-1")
    XCTAssertEqual(episodesPage.items.count, 1)
    let episode = episodesPage.items[0]
    XCTAssertEqual(episode.kind, .episode)
    XCTAssertEqual(episode.indexNumber, 1) // Episode 1
    XCTAssertEqual(episode.parentIndexNumber, 1) // Season 1
    XCTAssertEqual(episode.runtimeSeconds, 3120)
    XCTAssertEqual(episode.userState?.isWatched, true)
  }

  // MARK: 6. Collection Filtering & Image URLs

  func testLibraries_FiltersNonVideoCollections() async throws {
    let store = MemoryCredentialStore()
    let transport = DeterministicJellyfinTransport()
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jf.example")!,
      clientInfo: defaultClientInfo,
      credentialStore: store,
      credentialKey: "kyro.jellyfin.collections",
      transport: transport
    )
    _ = try await client.authenticate(username: "User", password: "pwd")

    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapter = try JellyfinProviderAdapter(account: account, client: client)

    let libs = try await adapter.libraries()
    // Transport returns movies, tvshows, mixed, music, photos.
    // Adapter must keep movies, tvshows, and mixed, and filter out music and photos.
    XCTAssertEqual(libs.count, 3)
    XCTAssertEqual(libs.map(\.name), ["Films", "Television", "Videos"])
    XCTAssertEqual(libs[0].kinds, [.movie])
    XCTAssertEqual(libs[1].kinds, [.series])
    XCTAssertEqual(libs[2].kinds, [.movie, .series])
  }

  func testImageURL_NeverEmbedsAuthTokens() throws {
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jellyfin.example:8096")!,
      clientInfo: defaultClientInfo,
      credentialStore: MemoryCredentialStore(),
      credentialKey: "kyro.jellyfin.img",
      transport: DeterministicJellyfinTransport()
    )

    let url = try XCTUnwrap(client.imageURL(itemID: "item-123", kind: .primary, tag: "hash-tag", maxWidth: 800))
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "jellyfin.example")
    XCTAssertEqual(url.port, 8096)
    XCTAssertEqual(url.path, "/Items/item-123/Images/Primary")
    XCTAssertEqual(url.query, "maxWidth=800&tag=hash-tag")

    // Sensitive data check
    XCTAssertFalse(url.absoluteString.lowercased().contains("token"))
    XCTAssertFalse(url.absoluteString.lowercased().contains("auth"))
    XCTAssertFalse(url.absoluteString.lowercased().contains("secret"))
  }
}
