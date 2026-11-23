import Foundation
import KyroCredentials
import KyroSources
import XCTest

@testable import KyroSourceJellyfin

private final class MockTransport: JellyfinTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [JellyfinRequest] = []
  var requests: [JellyfinRequest] { lock.withLock { _requests } }
  let handler: @Sendable (JellyfinRequest) throws -> HTTPResponse
  init(_ h: @escaping @Sendable (JellyfinRequest) throws -> HTTPResponse) { handler = h }
  func send(_ r: JellyfinRequest) async throws -> HTTPResponse {
    lock.withLock { _requests.append(r) }
    return try handler(r)
  }
}

private func json(_ s: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(s.utf8))
}

private let authJSON = #"""
{"User":{"Id":"u1","Name":"kim"},"AccessToken":"tok-secret","ServerId":"srv1"}
"""#

final class JellyfinClientTests: XCTestCase {
  let info = JellyfinClientInfo(client: "Kyro", device: "iPhone", deviceID: "dev-1", version: "1.0")
  let base = URL(string: "https://jf.example.com")!

  private func make(_ t: MockTransport, _ store: MemoryCredentialStore = MemoryCredentialStore())
    throws -> JellyfinClient
  {
    try JellyfinClient(
      baseURL: base, clientInfo: info, credentialStore: store, credentialKey: "k", transport: t)
  }

  func testAuthenticateUsesMediaBrowserHeaderAndStoresSessionNotPassword() async throws {
    let t = MockTransport { _ in json(authJSON) }
    let store = MemoryCredentialStore()
    let c = try make(t, store)
    let s = try await c.authenticate(username: "kim", password: "hunter2")
    XCTAssertEqual(s.serverID, "srv1")
    let r = try XCTUnwrap(t.requests.first)
    XCTAssertEqual(r.method, "POST")
    XCTAssertEqual(r.url.path, "/Users/AuthenticateByName")
    XCTAssertNil(r.headers["X-Emby-Token"])
    let auth = try XCTUnwrap(r.headers["Authorization"])
    XCTAssertTrue(auth.hasPrefix(#"MediaBrowser Client="Kyro", Device="iPhone", DeviceId="dev-1""#))
    XCTAssertFalse(auth.contains("Token="))
    let storedOpt = try await store.read("k")
    let stored = try XCTUnwrap(storedOpt)
    XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("hunter2"))
    XCTAssertFalse(s.description.contains("tok-secret"))
    // A new client restores the session from the store.
    let c2 = try make(MockTransport { _ in json("{}") }, store)
    let restored = try await c2.restoreSession()
    XCTAssertEqual(restored, s)
  }

  func testBadCredentialsAndOutage() async throws {
    let bad = try make(MockTransport { _ in json("", status: 401) })
    do {
      _ = try await bad.authenticate(username: "a", password: "b")
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .unauthorized) }
    let down = try make(MockTransport { _ in throw URLError(.cannotConnectToHost) })
    do {
      _ = try await down.authenticate(username: "a", password: "b")
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .serverUnavailable) }
    let unavailable = try make(MockTransport { _ in json("", status: 503) })
    do {
      _ = try await unavailable.authenticate(username: "a", password: "b")
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .serverUnavailable) }
  }

  func testRequiresSignIn() async throws {
    let c = try make(MockTransport { _ in json("{}") })
    do {
      _ = try await c.libraries()
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .notSignedIn) }
  }

  private func signedIn(_ items: @escaping @Sendable (JellyfinRequest) -> HTTPResponse) async throws
    -> (JellyfinClient, MockTransport, MemoryCredentialStore)
  {
    let t = MockTransport { r in r.url.path.hasSuffix("AuthenticateByName") ? json(authJSON) : items(r) }
    let store = MemoryCredentialStore()
    let c = try make(t, store)
    _ = try await c.authenticate(username: "kim", password: "pw")
    return (c, t, store)
  }

  func testMoviePageMapsMetadataAndPaginates() async throws {
    let body = #"""
    {"Items":[{"Id":"m1","Name":"Film","Type":"Movie","ServerId":"srv1","Overview":"Plot",
    "ProductionYear":2020,"PremiereDate":"2020-05-01T00:00:00.0000000Z","RunTimeTicks":72000000000,
    "ProviderIds":{"Imdb":"tt1"},"ImageTags":{"Primary":"pt"},"BackdropImageTags":["bt"],
    "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"PlayCount":0,"IsFavorite":true}},
    {"Id":"m2","Name":"Seen","Type":"Movie","UserData":{"Played":true,"PlayCount":2}}],
    "TotalRecordCount":5,"StartIndex":0}
    """#
    let (c, t, _) = try await signedIn { _ in json(body) }
    let page = try await c.items(JellyfinPageRequest(kinds: [.movie], limit: 2))
    XCTAssertEqual(page.nextStartIndex, 2)
    XCTAssertEqual(page.totalCount, 5)
    let m = page.items[0]
    XCTAssertEqual(m.contentID.rawValue, "jellyfin:srv1:m1")
    XCTAssertEqual(m.runtimeSeconds, 7200)
    XCTAssertEqual(m.userState?.resumePositionSeconds, 600)
    XCTAssertEqual(m.userState?.isFavorite, true)
    XCTAssertEqual(m.artwork.primaryTag, "pt")
    XCTAssertNotNil(m.premiereDate)
    XCTAssertEqual(page.items[1].contentID.serverID, "srv1")
    XCTAssertEqual(page.items[1].userState?.isWatched, true)
    let req = try XCTUnwrap(t.requests.last)
    XCTAssertTrue(req.url.absoluteString.contains("IncludeItemTypes=Movie"))
    XCTAssertTrue(req.headers["Authorization"]?.contains(#"Token="tok-secret""#) == true)
    XCTAssertEqual(JellyfinContentID(rawValue: m.contentID.rawValue), m.contentID)
  }

  func testShowHierarchyAndDetails() async throws {
    let (c, t, _) = try await signedIn { r in
      let p = r.url.path
      if p.hasSuffix("/Seasons") {
        return json(#"{"Items":[{"Id":"s1","Name":"Season 1","Type":"Season","IndexNumber":1,"SeriesId":"sr"}],"TotalRecordCount":1}"#)
      }
      if p.hasSuffix("/Episodes") {
        return json(#"{"Items":[{"Id":"e1","Name":"Pilot","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1,"SeriesId":"sr","SeasonId":"s1"}],"TotalRecordCount":1}"#)
      }
      if p.hasSuffix("/Views") {
        return json(#"{"Items":[{"Id":"l1","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies"}],"TotalRecordCount":1}"#)
      }
      return json(#"{"Id":"sr","Name":"Show","Type":"Series","ChildCount":3}"#)
    }
    let seasons = try await c.seasons(seriesID: "sr")
    XCTAssertEqual(seasons.items.first?.kind, .season)
    XCTAssertNil(seasons.nextStartIndex)
    let eps = try await c.episodes(seriesID: "sr", seasonID: "s1")
    XCTAssertEqual(eps.items.first?.parentIndexNumber, 1)
    XCTAssertTrue(t.requests.last!.url.absoluteString.contains("SeasonId=s1"))
    let libs = try await c.libraries()
    XCTAssertEqual(libs.first?.collectionType, "movies")
    let show = try await c.series(id: "sr")
    XCTAssertEqual(show.childCount, 3)
    do {
      _ = try await c.movie(id: "sr")
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .notFound) }
  }

  func testMalformedAndBoundsAndExpiredToken() async throws {
    let (c, _, _) = try await signedIn { _ in json("not json") }
    do {
      _ = try await c.libraries()
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .malformedResponse) }
    do {
      _ = try await c.items(JellyfinPageRequest(limit: 0))
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .invalidRequest) }
    do {
      _ = try await c.series(id: "../x")
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .invalidRequest) }

    let (over, _, _) = try await signedIn { _ in json(#"{"Items":[{"Id":"a"},{"Id":"b"}],"TotalRecordCount":2}"#) }
    do {
      _ = try await over.items(JellyfinPageRequest(limit: 1))
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .malformedResponse) }

    let (stall, _, _) = try await signedIn { _ in json(#"{"Items":[],"TotalRecordCount":9}"#) }
    do {
      _ = try await stall.items(JellyfinPageRequest(limit: 5))
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .malformedResponse) }

    let (expired, _, store) = try await signedIn { _ in json("", status: 401) }
    do {
      _ = try await expired.libraries()
      XCTFail()
    } catch { XCTAssertEqual(error as? JellyfinError, .unauthorized) }
    let left = try await store.read("k")
    XCTAssertNil(left)
    let after = await expired.currentSession
    XCTAssertNil(after)
  }

  func testSignOutClearsCredentials() async throws {
    let (c, t, store) = try await signedIn { _ in json("", status: 204) }
    try await c.signOut()
    XCTAssertEqual(t.requests.last?.url.path, "/Sessions/Logout")
    let left = try await store.read("k")
    XCTAssertNil(left)
  }

  func testImageURLCarriesNoToken() async throws {
    let c = try make(MockTransport { _ in json("{}") })
    let u = try XCTUnwrap(c.imageURL(itemID: "abc", kind: .primary, tag: "t"))
    XCTAssertEqual(u.path, "/Items/abc/Images/Primary")
    XCTAssertFalse(u.absoluteString.lowercased().contains("token"))
    XCTAssertNil(c.imageURL(itemID: "a/b", kind: .primary, tag: nil))
  }

  func testMovieAndEpisodePlaybackNegotiationAndProgress() async throws {
    let (client, transport, _) = try await signedIn { request in
      if request.url.path.hasSuffix("PlaybackInfo") {
        return json(#"{"PlaySessionId":"play1","MediaSources":[{"Id":"source1","SupportsDirectPlay":true,"SupportsTranscoding":true,"TranscodingUrl":"/Videos/m1/master.m3u8"}]}"#)
      }
      return json("", status: 204)
    }
    let movie = try await client.playback(itemID: "m1", resumePositionSeconds: 42)
    XCTAssertEqual(movie.serverID, "srv1")
    XCTAssertEqual(movie.userID, "u1")
    XCTAssertEqual(movie.directURL?.path, "/Videos/m1/stream")
    XCTAssertEqual(movie.transcodingURL?.path, "/Videos/m1/master.m3u8")
    XCTAssertEqual(movie.resumePositionSeconds, 42)
    XCTAssertTrue(movie.headers["Authorization"]?.contains("tok-secret") == true)
    XCTAssertTrue(transport.requests.last?.url.query?.contains("StartTimeTicks=420000000") == true)
    XCTAssertEqual(transport.requests.last?.method, "POST")
    let negotiation = try XCTUnwrap(transport.requests.last?.body)
    XCTAssertTrue(String(decoding: negotiation, as: UTF8.self).contains("TranscodingProfiles"))
    try await client.reportPlayback(.start, plan: movie, positionSeconds: 42)
    try await client.reportPlayback(.progress, plan: movie, positionSeconds: 54)
    try await client.reportPlayback(.stopped, plan: movie, positionSeconds: 60)
    XCTAssertEqual(transport.requests.suffix(3).map(\.url.path),
                   ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
    let body = try XCTUnwrap(transport.requests.last?.body)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(report["UserId"] as? String, "u1")
    XCTAssertEqual(report["PlaySessionId"] as? String, "play1")
    XCTAssertEqual(report["PositionTicks"] as? Int64, 600_000_000)
    let episode = try await client.playback(itemID: "e1")
    XCTAssertEqual(episode.directURL?.path, "/Videos/e1/stream")
  }

  func testPlaybackRejectsOtherAccountAndCrossOriginTranscode() async throws {
    let (client, transport, _) = try await signedIn { request in
      if request.url.path.hasSuffix("PlaybackInfo") {
        return json(#"{"PlaySessionId":"play1","MediaSources":[{"Id":"source1","SupportsDirectPlay":true,"SupportsTranscoding":true,"TranscodingUrl":"https://evil.example/steal"}]}"#)
      }
      return json("", status: 204)
    }
    let plan = try await client.playback(itemID: "m1")
    XCTAssertNil(plan.transcodingURL)
    let other = try JellyfinPlaybackPlan(serverID: "other", userID: "u2", itemID: plan.itemID,
      mediaSourceID: plan.mediaSourceID, playSessionID: plan.playSessionID,
      directURL: plan.directURL, transcodingURL: nil, headers: plan.headers,
      resumePositionSeconds: 0)
    do {
      try await client.reportPlayback(.progress, plan: other, positionSeconds: 10)
      XCTFail("Cross-account report must be rejected")
    } catch { XCTAssertEqual(error as? JellyfinError, .unauthorized) }
    XCTAssertEqual(transport.requests.filter { $0.url.path.contains("Sessions/Playing") }.count, 0)
  }

  func testResumeListUsesAuthenticatedUser() async throws {
    let (client, transport, _) = try await signedIn { _ in
      json(#"{"Items":[{"Id":"m1","Name":"Movie","Type":"Movie","UserData":{"PlaybackPositionTicks":100000000}},{"Id":"e1","Name":"Episode","Type":"Episode"},{"Id":"s1","Name":"Show","Type":"Series"}]}"#)
    }
    let items = try await client.resumeItems()
    XCTAssertEqual(items.map(\.kind), [.movie, .episode])
    XCTAssertEqual(items.first?.userState?.resumePositionSeconds, 10)
    XCTAssertEqual(transport.requests.last?.url.path, "/Users/u1/Items/Resume")
  }
}
