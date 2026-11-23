import Foundation

/// Identifies this client to a Jellyfin server in the MediaBrowser authorization header.
public struct JellyfinClientInfo: Sendable, Equatable {
  public let client: String
  public let device: String
  public let deviceID: String
  public let version: String
  public init(client: String, device: String, deviceID: String, version: String) {
    self.client = client
    self.device = device
    self.deviceID = deviceID
    self.version = version
  }
  /// `MediaBrowser Client="…", Device="…", DeviceId="…", Version="…"[, Token="…"]`.
  func authorizationHeader(token: String?) -> String {
    func q(_ v: String) -> String {
      v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    var value =
      "MediaBrowser Client=\"\(q(client))\", Device=\"\(q(device))\", DeviceId=\"\(q(deviceID))\", Version=\"\(q(version))\""
    if let token { value += ", Token=\"\(q(token))\"" }
    return value
  }
}

/// Authenticated Jellyfin session. Persisted only through a `CredentialStore`.
public struct JellyfinSession: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let serverID: String
  public let userID: String
  public let userName: String
  public let accessToken: String
  public var description: String { "JellyfinSession(server: \(serverID), user: \(userID))" }
  public var debugDescription: String { description }
}

public enum JellyfinError: LocalizedError, Equatable, Sendable {
  case invalidServerURL
  case invalidRequest
  /// Wrong credentials (on sign-in) or an expired/revoked token (on any other call).
  case unauthorized
  case forbidden
  case notFound
  case notSignedIn
  case serverUnavailable
  case http(Int)
  case malformedResponse
  case responseTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidServerURL: "Enter a valid Jellyfin server URL."
    case .invalidRequest: "Enter a Jellyfin username and password."
    case .unauthorized: "The Jellyfin credentials or session were rejected."
    case .forbidden: "This Jellyfin account cannot access that content."
    case .notFound: "This Jellyfin item is no longer available."
    case .notSignedIn: "Reconnect this Jellyfin server."
    case .serverUnavailable: "Jellyfin is unreachable. Check the server URL and connection."
    case .http: "Jellyfin could not complete this request."
    case .malformedResponse: "Jellyfin returned an invalid response."
    case .responseTooLarge: "Jellyfin returned too much data."
    }
  }
}

public enum JellyfinItemKind: String, Sendable, Equatable {
  case movie, series, season, episode, library, other
  init(jellyfinType: String?) {
    switch jellyfinType {
    case "Movie": self = .movie
    case "Series": self = .series
    case "Season": self = .season
    case "Episode": self = .episode
    case "CollectionFolder", "UserView": self = .library
    default: self = .other
    }
  }
  var apiName: String? {
    switch self {
    case .movie: "Movie"
    case .series: "Series"
    case .season: "Season"
    case .episode: "Episode"
    default: nil
    }
  }
}

public enum JellyfinImageKind: String, Sendable {
  case primary = "Primary"
  case backdrop = "Backdrop"
  case logo = "Logo"
  case thumb = "Thumb"
}

/// Stable remote identifier. `rawValue` is `jellyfin:<serverID>:<itemID>`; never use the
/// server URL because it can change while the server identity stays constant.
public struct JellyfinContentID: Hashable, Sendable, CustomStringConvertible {
  public let serverID: String
  public let itemID: String
  public init(serverID: String, itemID: String) {
    self.serverID = serverID
    self.itemID = itemID
  }
  public var rawValue: String { "jellyfin:\(serverID):\(itemID)" }
  public var description: String { rawValue }
  public init?(rawValue: String) {
    let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "jellyfin", !parts[1].isEmpty, !parts[2].isEmpty else {
      return nil
    }
    self.init(serverID: String(parts[1]), itemID: String(parts[2]))
  }
}

public struct JellyfinArtwork: Sendable, Equatable {
  public let primaryTag: String?
  public let backdropTag: String?
  public let logoTag: String?
  public let thumbTag: String?
}

public struct JellyfinUserState: Sendable, Equatable {
  public let isWatched: Bool
  public let playCount: Int
  public let isFavorite: Bool
  /// Resume position in seconds; 0 when none.
  public let resumePositionSeconds: Double
  public let lastPlayedAt: Date?
}

public struct JellyfinMediaItem: Sendable, Equatable {
  public let contentID: JellyfinContentID
  public let kind: JellyfinItemKind
  public let title: String
  public let overview: String?
  public let year: Int?
  public let premiereDate: Date?
  public let runtimeSeconds: Double?
  public let providerIDs: [String: String]
  /// Library kind for `.library` items (`movies`, `tvshows`, …).
  public let collectionType: String?
  public let parentID: String?
  public let seriesID: String?
  public let seasonID: String?
  /// Episode number, or season number for seasons.
  public let indexNumber: Int?
  /// Season number for episodes.
  public let parentIndexNumber: Int?
  public let childCount: Int?
  public let artwork: JellyfinArtwork
  public let userState: JellyfinUserState?
}

public struct JellyfinPage<Element: Sendable>: Sendable {
  public let items: [Element]
  public let startIndex: Int
  public let totalCount: Int
  /// `nil` when this is the last page.
  public let nextStartIndex: Int?
}

public struct JellyfinPageRequest: Sendable {
  public var parentID: String?
  public var kinds: [JellyfinItemKind]
  public var startIndex: Int
  public var limit: Int
  public var recursive: Bool
  public init(
    parentID: String? = nil, kinds: [JellyfinItemKind] = [], startIndex: Int = 0, limit: Int = 100,
    recursive: Bool = true
  ) {
    self.parentID = parentID
    self.kinds = kinds
    self.startIndex = startIndex
    self.limit = limit
    self.recursive = recursive
  }
}

// MARK: - Wire DTOs

/// Ephemeral playback negotiation; never persist or log its authenticated headers.
public struct JellyfinPlaybackPlan: Sendable {
  public let serverID: String
  public let userID: String
  public let itemID: String
  public let mediaSourceID: String
  public let playSessionID: String
  public let directURL: URL?
  public let transcodingURL: URL?
  public let headers: [String: String]
  public let resumePositionSeconds: Double

  public init(serverID: String, userID: String, itemID: String, mediaSourceID: String, playSessionID: String,
              directURL: URL?, transcodingURL: URL?, headers: [String: String],
              resumePositionSeconds: Double) {
    self.serverID = serverID
    self.userID = userID
    self.itemID = itemID
    self.mediaSourceID = mediaSourceID
    self.playSessionID = playSessionID
    self.directURL = directURL
    self.transcodingURL = transcodingURL
    self.headers = headers
    self.resumePositionSeconds = resumePositionSeconds
  }
}

public enum JellyfinPlaybackPhase: Sendable {
  case start, progress, stopped
  var path: String {
    switch self {
    case .start: "Sessions/Playing"
    case .progress: "Sessions/Playing/Progress"
    case .stopped: "Sessions/Playing/Stopped"
    }
  }
}

public enum JellyfinPlayMethod: String, Sendable {
  case directPlay = "DirectPlay"
  case transcode = "Transcode"
}

struct JFPlaybackInfo: Decodable {
  struct MediaSource: Decodable {
    let id: String
    let supportsDirectPlay: Bool?
    let supportsTranscoding: Bool?
    let transcodingURL: String?
    enum CodingKeys: String, CodingKey {
      case id = "Id", supportsDirectPlay = "SupportsDirectPlay"
      case supportsTranscoding = "SupportsTranscoding", transcodingURL = "TranscodingUrl"
    }
  }
  let mediaSources: [MediaSource]
  let playSessionID: String?
  enum CodingKeys: String, CodingKey {
    case mediaSources = "MediaSources", playSessionID = "PlaySessionId"
  }
}

struct JFAuthResult: Decodable {
  struct User: Decodable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
  }
  let user: User
  let accessToken: String
  let serverId: String
  enum CodingKeys: String, CodingKey {
    case user = "User", accessToken = "AccessToken", serverId = "ServerId"
  }
}

struct JFItem: Decodable {
  struct UserData: Decodable {
    let playbackPositionTicks: Int64?
    let playCount: Int?
    let isFavorite: Bool?
    let played: Bool?
    let lastPlayedDate: String?
    enum CodingKeys: String, CodingKey {
      case playbackPositionTicks = "PlaybackPositionTicks", playCount = "PlayCount"
      case isFavorite = "IsFavorite", played = "Played", lastPlayedDate = "LastPlayedDate"
    }
  }
  let id: String
  let name: String?
  let type: String?
  let serverId: String?
  let overview: String?
  let productionYear: Int?
  let premiereDate: String?
  let runTimeTicks: Int64?
  let providerIds: [String: String]?
  let collectionType: String?
  let parentId: String?
  let seriesId: String?
  let seasonId: String?
  let indexNumber: Int?
  let parentIndexNumber: Int?
  let childCount: Int?
  let imageTags: [String: String]?
  let backdropImageTags: [String]?
  let userData: UserData?
  enum CodingKeys: String, CodingKey {
    case id = "Id", name = "Name", type = "Type", serverId = "ServerId", overview = "Overview"
    case productionYear = "ProductionYear", premiereDate = "PremiereDate"
    case runTimeTicks = "RunTimeTicks", providerIds = "ProviderIds"
    case collectionType = "CollectionType", parentId = "ParentId", seriesId = "SeriesId"
    case seasonId = "SeasonId", indexNumber = "IndexNumber"
    case parentIndexNumber = "ParentIndexNumber", childCount = "ChildCount"
    case imageTags = "ImageTags", backdropImageTags = "BackdropImageTags", userData = "UserData"
  }
}

struct JFItemsEnvelope: Decodable {
  let items: [JFItem]
  let totalRecordCount: Int?
  let startIndex: Int?
  enum CodingKeys: String, CodingKey {
    case items = "Items", totalRecordCount = "TotalRecordCount", startIndex = "StartIndex"
  }
}
