import Foundation
import KyroCredentials
import KyroSources

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct JellyfinRequest: Sendable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data?
}

/// Minimal transport seam. `KyroSources.HTTPClient` is GET-only, and sign-in needs POST.
public protocol JellyfinTransport: Sendable {
  func send(_ request: JellyfinRequest) async throws -> HTTPResponse
}

public struct URLSessionJellyfinTransport: JellyfinTransport {
  private let session: URLSession
  public init(timeout: TimeInterval = 15) {
    let c = URLSessionConfiguration.ephemeral
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.timeoutIntervalForRequest = timeout
    c.timeoutIntervalForResource = timeout * 2
    session = URLSession(configuration: c, delegate: SameHostRedirects(), delegateQueue: nil)
  }
  public func send(_ request: JellyfinRequest) async throws -> HTTPResponse {
    var r = URLRequest(url: request.url)
    r.httpMethod = request.method
    r.httpBody = request.body
    r.allHTTPHeaderFields = request.headers
    do {
      let (data, response) = try await session.data(for: r)
      guard let http = response as? HTTPURLResponse else { throw JellyfinError.malformedResponse }
      return HTTPResponse(status: http.statusCode, body: data)
    } catch let e as JellyfinError {
      throw e
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw JellyfinError.serverUnavailable
    }
  }
}

private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let a = task.originalRequest?.url
    let b = request.url
    let same = a?.host == b?.host && a?.port == b?.port && a?.scheme == b?.scheme
    completionHandler(same ? request : nil)
  }
}

/// Authenticated Jellyfin catalog and playback client.
///
/// Passwords are used once for `AuthenticateByName` and never stored. The access token is
/// persisted as JSON in the injected `CredentialStore` (use `AppleKeychainCredentialStore`
/// in the app), under a key unrelated to Silo's token storage.
public actor JellyfinClient {
  public static let maxPageSize = 500
  public static let maxResponseBytes = 8 * 1_024 * 1_024

  private let baseURL: URL
  private let info: JellyfinClientInfo
  private let transport: any JellyfinTransport
  private let store: any CredentialStore
  private let credentialKey: String
  private var session: JellyfinSession?

  /// `credentialKey` should be unique per configured server, e.g. `"kyro.jellyfin.<accountID>"`.
  public init(
    baseURL: URL, clientInfo: JellyfinClientInfo, credentialStore: any CredentialStore,
    credentialKey: String, transport: any JellyfinTransport = URLSessionJellyfinTransport()
  ) throws {
    guard let endpoint = try? SourceEndpoint(baseURL), !credentialKey.isEmpty else {
      throw JellyfinError.invalidServerURL
    }
    _ = endpoint
    self.baseURL = baseURL
    self.info = clientInfo
    self.transport = transport
    self.store = credentialStore
    self.credentialKey = credentialKey
  }

  public var currentSession: JellyfinSession? { session }

  // MARK: Authentication

  public func authenticate(username: String, password: String) async throws -> JellyfinSession {
    guard !username.isEmpty else { throw JellyfinError.invalidRequest }
    let body = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
    let data = try await perform("POST", "Users/AuthenticateByName", body: body, authed: false)
    let result: JFAuthResult = try decode(data)
    guard !result.accessToken.isEmpty, !result.user.id.isEmpty, !result.serverId.isEmpty else {
      throw JellyfinError.malformedResponse
    }
    let s = JellyfinSession(
      serverID: result.serverId, userID: result.user.id, userName: result.user.name,
      accessToken: result.accessToken)
    try await store.write(try JSONEncoder().encode(s), for: credentialKey)
    session = s
    return s
  }

  /// Loads a previously stored session without contacting the server.
  @discardableResult
  public func restoreSession() async throws -> JellyfinSession? {
    guard let data = try await store.read(credentialKey) else { return nil }
    guard let s = try? JSONDecoder().decode(JellyfinSession.self, from: data) else {
      try await store.remove(credentialKey)
      return nil
    }
    session = s
    return s
  }

  /// Best-effort server logout, then always clears local credentials.
  public func signOut() async throws {
    if session != nil { _ = try? await perform("POST", "Sessions/Logout", body: nil) }
    session = nil
    try await store.remove(credentialKey)
  }

  // MARK: Catalog

  public func libraries() async throws -> [JellyfinMediaItem] {
    let s = try requireSession()
    let data = try await perform("GET", "Users/\(s.userID)/Views", query: [])
    let env: JFItemsEnvelope = try decode(data)
    return env.items.map { map($0, s) }
  }

  public func items(_ request: JellyfinPageRequest) async throws -> JellyfinPage<JellyfinMediaItem>
  {
    let s = try requireSession()
    guard request.startIndex >= 0, (1...Self.maxPageSize).contains(request.limit) else {
      throw JellyfinError.invalidRequest
    }
    var q = [
      URLQueryItem(name: "Recursive", value: request.recursive ? "true" : "false"),
      URLQueryItem(name: "Fields", value: Self.fields),
      URLQueryItem(name: "SortBy", value: "SortName"),
      URLQueryItem(name: "StartIndex", value: String(request.startIndex)),
      URLQueryItem(name: "Limit", value: String(request.limit)),
    ]
    let kinds = request.kinds.compactMap(\.apiName)
    if !kinds.isEmpty { q.append(URLQueryItem(name: "IncludeItemTypes", value: kinds.joined(separator: ","))) }
    if let p = request.parentID { q.append(URLQueryItem(name: "ParentId", value: p)) }
    let data = try await perform("GET", "Users/\(s.userID)/Items", query: q)
    let env: JFItemsEnvelope = try decode(data)
    return try page(env, request: request, session: s)
  }

  public func movie(id: String) async throws -> JellyfinMediaItem { try await detail(id, .movie) }
  public func series(id: String) async throws -> JellyfinMediaItem { try await detail(id, .series) }
  public func season(id: String) async throws -> JellyfinMediaItem { try await detail(id, .season) }
  public func episode(id: String) async throws -> JellyfinMediaItem {
    try await detail(id, .episode)
  }

  public func seasons(seriesID: String, startIndex: Int = 0, limit: Int = 100) async throws
    -> JellyfinPage<JellyfinMediaItem>
  {
    try await showChildren("Shows/\(try segment(seriesID))/Seasons", extra: [], startIndex, limit)
  }

  public func episodes(
    seriesID: String, seasonID: String? = nil, startIndex: Int = 0, limit: Int = 100
  ) async throws -> JellyfinPage<JellyfinMediaItem> {
    let extra = try seasonID.map { [URLQueryItem(name: "SeasonId", value: try segment($0))] } ?? []
    return try await showChildren(
      "Shows/\(try segment(seriesID))/Episodes", extra: extra, startIndex, limit)
  }

  /// Negotiates one movie or episode. A server-supplied HLS URL is the direct-play fallback.
  public func playback(itemID: String, resumePositionSeconds: Double = 0) async throws -> JellyfinPlaybackPlan {
    let s = try requireSession()
    let id = try segment(itemID)
    guard resumePositionSeconds.isFinite, resumePositionSeconds >= 0 else { throw JellyfinError.invalidRequest }
    let ticks = Int64(min(resumePositionSeconds * 10_000_000, Double(Int64.max)))
    let q = [URLQueryItem(name: "UserId", value: s.userID),
             URLQueryItem(name: "StartTimeTicks", value: String(ticks)),
             URLQueryItem(name: "IsPlayback", value: "true"),
             URLQueryItem(name: "EnableDirectPlay", value: "true"),
             URLQueryItem(name: "EnableDirectStream", value: "false"),
             URLQueryItem(name: "EnableTranscoding", value: "true")]
    // Advertise only paths the shared Aether player can consume. Jellyfin chooses an HLS URL
    // for unsupported containers/codecs; no unsupported raw stream is optimistically opened.
    let profile: [String: Any] = [
      "Name": "Kyro iOS", "MaxStreamingBitrate": 40_000_000,
      "DirectPlayProfiles": [["Type": "Video", "Container": "mp4,m4v,mov",
                              "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3"]],
      "TranscodingProfiles": [["Type": "Video", "Container": "ts", "Protocol": "hls",
                               "VideoCodec": "h264", "AudioCodec": "aac",
                               "Context": "Streaming", "MaxAudioChannels": "2"]]
    ]
    let body = try JSONSerialization.data(withJSONObject: ["DeviceProfile": profile])
    let response: JFPlaybackInfo = try decode(try await perform("POST", "Items/\(id)/PlaybackInfo", query: q, body: body))
    guard let source = response.mediaSources.first(where: { $0.supportsDirectPlay == true || $0.supportsTranscoding == true }),
          !source.id.isEmpty, let playSessionID = response.playSessionID, !playSessionID.isEmpty else {
      throw JellyfinError.malformedResponse
    }
    var direct: URL?
    if source.supportsDirectPlay == true {
      var components = URLComponents(url: baseURL.appendingPathComponent("Videos/\(id)/stream"), resolvingAgainstBaseURL: false)
      components?.queryItems = [URLQueryItem(name: "Static", value: "true"),
                                URLQueryItem(name: "MediaSourceId", value: source.id),
                                URLQueryItem(name: "PlaySessionId", value: playSessionID)]
      direct = components?.url
    }
    let transcoding = source.supportsTranscoding == true
      ? source.transcodingURL.flatMap(sameOriginURL) : nil
    guard direct != nil || transcoding != nil else { throw JellyfinError.malformedResponse }
    return JellyfinPlaybackPlan(serverID: s.serverID, userID: s.userID, itemID: id, mediaSourceID: source.id,
      playSessionID: playSessionID, directURL: direct, transcodingURL: transcoding,
      headers: ["Authorization": info.authorizationHeader(token: s.accessToken)],
      resumePositionSeconds: resumePositionSeconds)
  }

  public func reportPlayback(_ phase: JellyfinPlaybackPhase, plan: JellyfinPlaybackPlan,
                             positionSeconds: Double, paused: Bool = false,
                             method: JellyfinPlayMethod = .directPlay) async throws {
    let s = try requireSession()
    guard positionSeconds.isFinite, positionSeconds >= 0 else { throw JellyfinError.invalidRequest }
    guard s.serverID == plan.serverID, s.userID == plan.userID else { throw JellyfinError.unauthorized }
    let ticks = Int64(min(positionSeconds * 10_000_000, Double(Int64.max)))
    let body = try JSONSerialization.data(withJSONObject: [
      "ItemId": plan.itemID, "MediaSourceId": plan.mediaSourceID,
      "PlaySessionId": plan.playSessionID, "PositionTicks": ticks,
      "IsPaused": paused, "PlayMethod": method.rawValue, "UserId": s.userID
    ])
    _ = try await perform("POST", phase.path, body: body)
  }

  public func resumeItems(limit: Int = 30) async throws -> [JellyfinMediaItem] {
    let s = try requireSession()
    guard (1...100).contains(limit) else { throw JellyfinError.invalidRequest }
    let data = try await perform("GET", "Users/\(s.userID)/Items/Resume", query: [
      URLQueryItem(name: "Limit", value: String(limit)),
      URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
      URLQueryItem(name: "Fields", value: Self.fields)
    ])
    let env: JFItemsEnvelope = try decode(data)
    return env.items.map { map($0, s) }.filter { $0.kind == .movie || $0.kind == .episode }
  }

  private func sameOriginURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
          url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
          url.user == nil, url.password == nil else { return nil }
    return url
  }

  /// Image URL for an item. Jellyfin serves images without auth, so no token is embedded.
  public nonisolated func imageURL(
    itemID: String, kind: JellyfinImageKind, tag: String?, maxWidth: Int = 600
  ) -> URL? {
    guard itemID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !itemID.isEmpty,
      var c = URLComponents(
        url: baseURL.appendingPathComponent("Items/\(itemID)/Images/\(kind.rawValue)"),
        resolvingAgainstBaseURL: false)
    else { return nil }
    var q = [URLQueryItem(name: "maxWidth", value: String(max(1, min(maxWidth, 4_000))))]
    if let tag { q.append(URLQueryItem(name: "tag", value: tag)) }
    c.queryItems = q
    return c.url
  }

  // MARK: Internals

  static let fields = "Overview,ProviderIds,PremiereDate,ChildCount,ParentId,SeriesId,SeasonId"

  private func detail(_ id: String, _ expected: JellyfinItemKind) async throws -> JellyfinMediaItem {
    let s = try requireSession()
    let data = try await perform(
      "GET", "Users/\(s.userID)/Items/\(try segment(id))",
      query: [URLQueryItem(name: "Fields", value: Self.fields)])
    let item = map(try decode(data) as JFItem, s)
    guard item.kind == expected else { throw JellyfinError.notFound }
    return item
  }

  private func showChildren(
    _ path: String, extra: [URLQueryItem], _ start: Int, _ limit: Int
  ) async throws -> JellyfinPage<JellyfinMediaItem> {
    let s = try requireSession()
    guard start >= 0, (1...Self.maxPageSize).contains(limit) else { throw JellyfinError.invalidRequest }
    let q =
      [
        URLQueryItem(name: "UserId", value: s.userID),
        URLQueryItem(name: "Fields", value: Self.fields),
        URLQueryItem(name: "StartIndex", value: String(start)),
        URLQueryItem(name: "Limit", value: String(limit)),
      ] + extra
    let env: JFItemsEnvelope = try decode(try await perform("GET", path, query: q))
    return try page(env, request: JellyfinPageRequest(startIndex: start, limit: limit), session: s)
  }

  private func page(_ env: JFItemsEnvelope, request: JellyfinPageRequest, session s: JellyfinSession)
    throws -> JellyfinPage<JellyfinMediaItem>
  {
    let count = env.items.count
    guard count <= request.limit else { throw JellyfinError.malformedResponse }
    let total = env.totalRecordCount ?? (request.startIndex + count)
    let next = request.startIndex + count
    // A non-empty-total server that returns nothing mid-stream would loop forever.
    if count == 0, next < total { throw JellyfinError.malformedResponse }
    return JellyfinPage(
      items: env.items.map { map($0, s) }, startIndex: request.startIndex, totalCount: total,
      nextStartIndex: next < total ? next : nil)
  }

  private func segment(_ id: String) throws -> String {
    guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
      throw JellyfinError.invalidRequest
    }
    return id
  }

  private func requireSession() throws -> JellyfinSession {
    guard let session else { throw JellyfinError.notSignedIn }
    return session
  }

  private func perform(
    _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
    authed: Bool = true
  ) async throws -> Data {
    guard
      var c = URLComponents(
        url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    else { throw JellyfinError.invalidServerURL }
    c.queryItems = query.isEmpty ? nil : query
    guard let url = c.url else { throw JellyfinError.invalidServerURL }
    var headers = [
      "Authorization": info.authorizationHeader(token: authed ? session?.accessToken : nil),
      "Accept": "application/json",
    ]
    if body != nil { headers["Content-Type"] = "application/json" }
    let response: HTTPResponse
    do {
      response = try await transport.send(
        JellyfinRequest(method: method, url: url, headers: headers, body: body))
    } catch let e as CancellationError {
      throw e
    } catch let e as JellyfinError {
      throw e
    } catch {
      throw JellyfinError.serverUnavailable
    }
    switch response.status {
    case 200..<300: break
    case 401:
      if authed {
        session = nil
        try? await store.remove(credentialKey)
      }
      throw JellyfinError.unauthorized
    case 403: throw JellyfinError.forbidden
    case 404: throw JellyfinError.notFound
    case 502, 503, 504: throw JellyfinError.serverUnavailable
    default: throw JellyfinError.http(response.status)
    }
    guard response.body.count <= Self.maxResponseBytes else { throw JellyfinError.responseTooLarge }
    return response.body
  }

  private func decode<T: Decodable>(_ data: Data) throws -> T {
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw JellyfinError.malformedResponse
    }
  }

  private func map(_ i: JFItem, _ s: JellyfinSession) -> JellyfinMediaItem {
    let kind = JellyfinItemKind(jellyfinType: i.type)
    let ud = i.userData.map {
      JellyfinUserState(
        isWatched: $0.played ?? false, playCount: $0.playCount ?? 0,
        isFavorite: $0.isFavorite ?? false,
        resumePositionSeconds: Double($0.playbackPositionTicks ?? 0) / 10_000_000,
        lastPlayedAt: $0.lastPlayedDate.flatMap(Self.date))
    }
    return JellyfinMediaItem(
      contentID: JellyfinContentID(serverID: i.serverId ?? s.serverID, itemID: i.id), kind: kind,
      title: i.name ?? "", overview: i.overview, year: i.productionYear,
      premiereDate: i.premiereDate.flatMap(Self.date),
      runtimeSeconds: i.runTimeTicks.map { Double($0) / 10_000_000 },
      providerIDs: i.providerIds ?? [:], collectionType: i.collectionType, parentID: i.parentId,
      seriesID: i.seriesId, seasonID: i.seasonId, indexNumber: i.indexNumber,
      parentIndexNumber: i.parentIndexNumber, childCount: i.childCount,
      artwork: JellyfinArtwork(
        primaryTag: i.imageTags?["Primary"], backdropTag: i.backdropImageTags?.first,
        logoTag: i.imageTags?["Logo"], thumbTag: i.imageTags?["Thumb"]),
      userState: ud)
  }

  /// Jellyfin emits 7-digit fractional seconds, which `ISO8601DateFormatter` rejects.
  private static func date(_ raw: String) -> Date? {
    let trimmed = raw.replacingOccurrences(
      of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
  }
}
