import Foundation
import KyroCredentials
import KyroSourceJellyfin
import KyroSources
import XCTest
@testable import KyroProviders

private struct CatalogTransport: JellyfinTransport {
  func send(_ request: JellyfinRequest) async throws -> HTTPResponse {
    let path = request.url.path
    let body: String
    if path.hasSuffix("AuthenticateByName") {
      body = #"{"User":{"Id":"jf-user","Name":"Alex"},"AccessToken":"secret","ServerId":"jf-server"}"#
    } else if path.hasSuffix("/Views") {
      body = #"{"Items":[{"Id":"movies","Name":"Films","Type":"CollectionFolder","CollectionType":"movies"},{"Id":"shows","Name":"TV","Type":"CollectionFolder","CollectionType":"tvshows"}],"TotalRecordCount":2}"#
    } else {
      body = #"{"Items":[{"Id":"film-1","Name":"Arrival","Type":"Movie","ProductionYear":2016,"ImageTags":{"Primary":"art"}}],"TotalRecordCount":1}"#
    }
    return HTTPResponse(status: 200, body: Data(body.utf8))
  }
}

@MainActor final class JellyfinProviderAdapterTests: XCTestCase {
  func testAuthenticatedLibrariesPopulateProviderQualifiedCatalog() async throws {
    let client = try JellyfinClient(
      baseURL: URL(string: "https://jellyfin.example")!,
      clientInfo: .init(client: "Kyro", device: "Test", deviceID: "device", version: "1"),
      credentialStore: MemoryCredentialStore(), credentialKey: "kyro.jellyfin.account-a",
      transport: CatalogTransport())
    let account = ProviderAccountRef(id: ProviderAccountID(), kind: .jellyfin)
    let adapter = try JellyfinProviderAdapter(account: account, client: client)
    let signedOut = await adapter.capabilities()
    XCTAssertEqual(ProviderCapabilities.state(of: .browse, in: signedOut), .requiresAuthentication)
    _ = try await client.authenticate(username: "Alex", password: "password")
    let libraries = try await adapter.libraries()
    XCTAssertEqual(libraries.count, 2)
    XCTAssertEqual(libraries.map(\.kinds), [[.movie], [.series]])
    let page = try await adapter.catalogPage(library: libraries[0].ref, kind: .movie, cursor: nil)
    XCTAssertNil(page.next)
    XCTAssertEqual(page.records.map(\.ref.account), [account])
    XCTAssertEqual(page.records.map(\.ref.remoteID), ["film-1"])
    XCTAssertEqual(page.records.first?.posterURL,
                   "https://jellyfin.example/Items/film-1/Images/Primary?maxWidth=600&tag=art")
    do {
      _ = try await adapter.catalogPage(
        library: try LibraryRef(account: .init(id: ProviderAccountID(), kind: .jellyfin), remoteID: "movies"),
        kind: .movie, cursor: nil)
      XCTFail("Another account must not read this catalog")
    } catch ProviderError.accountMismatch {}
  }

  func testTwoJellyfinAccountsKeepCredentialsSeparate() async throws {
    let store = MemoryCredentialStore()
    let info = JellyfinClientInfo(client: "Kyro", device: "Test", deviceID: "device", version: "1")
    let first = try JellyfinClient(baseURL: URL(string: "https://first.example")!, clientInfo: info,
                                   credentialStore: store, credentialKey: "kyro.jellyfin.first",
                                   transport: CatalogTransport())
    let second = try JellyfinClient(baseURL: URL(string: "https://second.example")!, clientInfo: info,
                                    credentialStore: store, credentialKey: "kyro.jellyfin.second",
                                    transport: CatalogTransport())
    _ = try await first.authenticate(username: "Alex", password: "password")
    _ = try await second.authenticate(username: "Sam", password: "password")
    try await first.signOut()
    let firstCredential = try await store.read("kyro.jellyfin.first")
    let secondCredential = try await store.read("kyro.jellyfin.second")
    XCTAssertNil(firstCredential)
    XCTAssertNotNil(secondCredential)
    let secondLibraries = try await second.libraries()
    XCTAssertEqual(secondLibraries.count, 2)
  }
}
