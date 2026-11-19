#if os(tvOS)
import Foundation

enum XtreamVODKind: String, Codable, CaseIterable, Sendable {
    case movie, series
    var title: String { self == .movie ? "Movies" : "Series" }
    var catalogAction: String { self == .movie ? "get_vod_streams" : "get_series" }
    var categoriesAction: String { self == .movie ? "get_vod_categories" : "get_series_categories" }
}

struct XtreamVODItem: Identifiable, Codable, Hashable, Sendable {
    let providerID: UUID
    let kind: XtreamVODKind
    let remoteID: Int
    let title: String
    let category: String
    let poster: String?
    let fileExtension: String?
    let summary: String?
    let genre: String?
    let rating: String?
    var id: String { "\(providerID.uuidString):\(kind.rawValue):\(remoteID)" }
}

struct XtreamVODEpisode: Identifiable, Hashable, Sendable {
    let remoteID: Int
    let season: Int
    let number: Int
    let title: String
    let fileExtension: String?
    let summary: String?
    var id: Int { remoteID }
}

struct XtreamVODDetail: Sendable {
    let summary: String?
    let genre: String?
    let rating: String?
    let duration: TimeInterval?
    let episodes: [XtreamVODEpisode]
}

struct XtreamVODImportCount: Equatable, Sendable {
    let processed: Int
    let total: Int
    let accepted: Int
    let malformed: Int
    let duplicate: Int
    var fraction: Double? { total > 0 ? Double(min(processed, total)) / Double(total) : nil }
}

enum XtreamVODImportStage: Equatable {
    case connecting, downloading(XtreamVODKind), importing(XtreamVODKind), ready, failed, cancelled
}

enum XtreamVODCatalogResult: Equatable {
    case notSelected, waiting, loading, ready, empty, unsupported, authentication, failed, cancelled
}

struct XtreamVODImportProgress: Equatable {
    let providerID: UUID
    var stage: XtreamVODImportStage = .connecting
    var movies = XtreamVODImportCount(processed: 0, total: 0, accepted: 0, malformed: 0, duplicate: 0)
    var series = XtreamVODImportCount(processed: 0, total: 0, accepted: 0, malformed: 0, duplicate: 0)
    var movieResult: XtreamVODCatalogResult = .notSelected
    var seriesResult: XtreamVODCatalogResult = .notSelected
    var message: String?
    var failure: XtreamVODError?
    /// The pipeline step that failed first, for sanitized diagnostics and the compact status line.
    var failedStage: XtreamVODPipelineStage?
}

/// Where in the VOD pipeline a refresh stopped. Logged without URLs or credentials.
enum XtreamVODPipelineStage: String, Equatable, Sendable {
    case configuration, storage, authentication, categories, download, parsing, persistence, promotion
}

/// Why a refresh call did or did not start, so every entry point can give visible feedback.
enum XtreamVODRefreshStart: Equatable {
    case started, alreadyRunning, providerMissing, noCatalogsSelected
}

enum XtreamVODError: Error, LocalizedError, Equatable {
    case invalidResponse, unavailable, authentication, unsupported, responseTooLarge, unsupportedFormat
    /// The on-device catalog database could not be created or written.
    case storage
    /// No HTTP response: offline, DNS, TLS, or timeout.
    case network
    /// A non-success HTTP status other than the authentication and unsupported codes.
    case httpStatus(Int)
    /// The saved provider has no usable server, username, or password.
    case configuration
    /// The provider answered but returned zero catalog records.
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The provider returned an invalid Movies or Series catalog. Your previous catalog is unchanged."
        case .unavailable: "The VOD provider is unavailable. Check the connection or credentials and retry."
        case .authentication: "VOD authentication failed. Check the provider credentials and retry."
        case .unsupported: "This provider does not support the requested VOD catalog endpoint."
        case .responseTooLarge: "The VOD catalog exceeds the supported download limit. Your previous catalog is unchanged."
        case .unsupportedFormat: "This provider video format is not supported by the Apple TV player."
        case .storage: "Kyro could not open its on-device VOD catalog. Free some Apple TV storage, then retry."
        case .network: "The provider could not be reached. Check the network connection, then retry."
        case .httpStatus(let code): "The provider returned HTTP \(code) for the VOD catalog. Retry later."
        case .configuration: "This provider is missing its server, username, or password. Edit the provider, then retry."
        case .emptyCatalog: "The provider returned no titles for this catalog."
        }
    }

    /// Stable, non-sensitive label for logs and diagnostics.
    var category: String {
        switch self {
        case .invalidResponse: "invalid_response"
        case .unavailable: "unavailable"
        case .authentication: "authentication"
        case .unsupported: "unsupported_endpoint"
        case .responseTooLarge: "response_too_large"
        case .unsupportedFormat: "unsupported_format"
        case .storage: "storage"
        case .network: "network"
        case .httpStatus: "http_status"
        case .configuration: "configuration"
        case .emptyCatalog: "empty_catalog"
        }
    }

    /// Maps the Live TV account-handshake errors onto VOD categories.
    static func from(_ error: Error) -> XtreamVODError? {
        if let vod = error as? XtreamVODError { return vod }
        switch error as? LiveTVError {
        case .authenticationFailed?, .accountExpired?: return .authentication
        case .invalidXtreamResponse?: return .invalidResponse
        case .invalidConfiguration?: return .configuration
        case .responseTooLarge?: return .responseTooLarge
        default: return nil
        }
    }
}

/// Flexible decoding is limited to the fields Kyro uses. Unknown provider fields are ignored.
struct XtreamVODRecord: Decodable, Sendable {
    let remoteID: Int?
    let title: String?
    let categoryID: String?
    let poster: String?
    let fileExtension: String?
    let summary: String?
    let genre: String?
    let rating: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", seriesID = "series_id", name, categoryID = "category_id"
        case streamIcon = "stream_icon", cover, containerExtension = "container_extension"
        case plot, genre, rating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remoteID = Self.int(c, .streamID) ?? Self.int(c, .seriesID)
        title = try? c.decode(String.self, forKey: .name)
        categoryID = Self.string(c, .categoryID)
        poster = Self.string(c, .streamIcon) ?? Self.string(c, .cover)
        fileExtension = Self.string(c, .containerExtension)
        summary = Self.string(c, .plot)
        genre = Self.string(c, .genre)
        rating = Self.string(c, .rating)
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        (try? c.decode(Int.self, forKey: key)) ?? (try? c.decode(String.self, forKey: key)).flatMap(Int.init)
    }
    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? c.decode(String.self, forKey: key)) ?? (try? c.decode(Int.self, forKey: key)).map(String.init)
    }
}

enum XtreamVODParser {
    /// Accepts the shapes Xtream panels return in practice: a JSON array; an empty body, `null`, or
    /// `{}` for an empty catalog; an object keyed by ID whose values are records; and arrays that
    /// contain stray `null` or scalar elements. An account object with `auth: 0` is an
    /// authentication failure; HTML or other non-JSON bodies are invalid responses.
    static func records(_ data: Data) throws -> [XtreamVODRecord] {
        let trimmed = data.drop(while: { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF })
        guard let first = trimmed.first else { return [] }
        if first == UInt8(ascii: "n"), String(decoding: trimmed.prefix(4), as: UTF8.self) == "null" { return [] }
        if first == UInt8(ascii: "[") {
            guard let rows = try? JSONDecoder().decode([LossyRecord].self, from: Data(trimmed)) else {
                throw XtreamVODError.invalidResponse
            }
            return rows.compactMap(\.record)
        }
        if first == UInt8(ascii: "{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any] else {
                throw XtreamVODError.invalidResponse
            }
            if object.isEmpty { return [] }
            if let user = object["user_info"] as? [String: Any] {
                let auth = (user["auth"] as? NSNumber)?.intValue ?? (user["auth"] as? String).flatMap(Int.init)
                if auth == 0 { throw XtreamVODError.authentication }
                return []
            }
            let rows = object.keys.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
                .compactMap { object[$0] as? [String: Any] }
            guard !rows.isEmpty, let encoded = try? JSONSerialization.data(withJSONObject: rows),
                  let decoded = try? JSONDecoder().decode([LossyRecord].self, from: encoded) else {
                throw XtreamVODError.invalidResponse
            }
            return decoded.compactMap(\.record)
        }
        throw XtreamVODError.invalidResponse
    }

    /// One malformed element must not discard an otherwise valid catalog.
    private struct LossyRecord: Decodable {
        let record: XtreamVODRecord?
        init(from decoder: Decoder) throws { record = try? XtreamVODRecord(from: decoder) }
    }

    static func detail(_ data: Data, kind: XtreamVODKind) throws -> XtreamVODDetail {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XtreamVODError.invalidResponse
        }
        let info = root["info"] as? [String: Any] ?? [:]
        let duration = (info["duration_secs"] as? NSNumber)?.doubleValue
            ?? (info["duration_secs"] as? String).flatMap(Double.init)
        var episodes: [XtreamVODEpisode] = []
        if kind == .series, let seasons = root["episodes"] as? [String: Any] {
            for (seasonKey, value) in seasons {
                guard let season = Int(seasonKey), let rows = value as? [[String: Any]] else { continue }
                for row in rows {
                    let id = (row["id"] as? Int) ?? (row["id"] as? String).flatMap(Int.init)
                    guard let id, id > 0 else { continue }
                    let number = (row["episode_num"] as? Int) ?? (row["episode_num"] as? String).flatMap(Int.init) ?? 0
                    let episodeInfo = row["info"] as? [String: Any] ?? [:]
                    episodes.append(.init(remoteID: id, season: season, number: number,
                                          title: clean(row["title"] as? String) ?? "Episode \(number)",
                                          fileExtension: clean(row["container_extension"] as? String),
                                          summary: clean(episodeInfo["plot"] as? String)))
                }
            }
            episodes.sort { ($0.season, $0.number, $0.remoteID) < ($1.season, $1.number, $1.remoteID) }
        }
        return .init(summary: clean(info["plot"] as? String), genre: clean(info["genre"] as? String),
                     rating: (info["rating"] as? String) ?? (info["rating"] as? NSNumber)?.stringValue,
                     duration: duration, episodes: episodes)
    }

    static func clean(_ value: String?, limit: Int = 512) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    /// Never persist query-bearing artwork URLs or URLs embedding provider credentials.
    static func safeArtwork(_ raw: String?, username: String, password: String) -> String? {
        guard let raw, raw.utf8.count <= 2048,
              let url = URLComponents(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.query == nil, url.user == nil, url.password == nil,
              url.fragment == nil, !raw.contains(username), !raw.contains(password),
              !(raw.removingPercentEncoding ?? raw).contains(username),
              !(raw.removingPercentEncoding ?? raw).contains(password) else { return nil }
        return raw
    }
}

extension XtreamURLBuilder {
    static func vodAPIURL(server: String, username: String, password: String, action: String,
                          itemID: Int? = nil) throws -> URL {
        var url = try apiURL(server: server, username: username, password: password, action: action)
        if let itemID {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems?.append(URLQueryItem(name: action == "get_vod_info" ? "vod_id" : "series_id", value: String(itemID)))
            guard let built = components.url else { throw LiveTVError.invalidConfiguration }
            url = built
        }
        return url
    }

    static func vodPlaybackURL(server: String, username: String, password: String,
                               kind: XtreamVODKind, itemID: Int, fileExtension: String?) throws -> URL {
        guard itemID > 0, let ext = fileExtension?.lowercased(), ["mp4", "m3u8", "mov", "m4v"].contains(ext) else {
            throw XtreamVODError.unsupportedFormat
        }
        guard var components = URLComponents(string: server), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw LiveTVError.invalidConfiguration }
        let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        components.percentEncodedPath = "/" + [base, kind == .movie ? "movie" : "series", user, pass,
                                                  "\(itemID).\(ext)"].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw LiveTVError.invalidConfiguration }
        return url
    }
}
#endif
