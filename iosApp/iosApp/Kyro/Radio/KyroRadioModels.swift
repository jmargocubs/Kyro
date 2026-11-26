#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

// Build 128: Internet radio from the free Radio Browser directory
// (https://api.radio-browser.info). Field names below are the API's own,
// confirmed against live responses on 2026-11-25.

/// One Radio Browser station: only the fields Kyro shows or plays.
/// `id` is Radio Browser's `stationuuid`, the station's stable identity.
struct KyroRadioStation: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var streamURL: URL?
    var resolvedURL: URL?
    var homepage: URL?
    var favicon: URL?
    var tags: [String]
    var country: String
    var countryCode: String
    var state: String
    var language: String
    var codec: String
    var bitrate: Int
    var isHLS: Bool
    var lastCheckOK: Bool

    /// Longest name, tag or place Kyro keeps from a directory row.
    static let maxTextLength = 200

    init(id: String, name: String, streamURL: URL?, resolvedURL: URL? = nil, homepage: URL? = nil,
         favicon: URL? = nil, tags: [String] = [], country: String = "", countryCode: String = "",
         state: String = "", language: String = "", codec: String = "", bitrate: Int = 0,
         isHLS: Bool = false, lastCheckOK: Bool = true) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.resolvedURL = resolvedURL
        self.homepage = homepage
        self.favicon = favicon
        self.tags = tags
        self.country = country
        self.countryCode = countryCode
        self.state = state
        self.language = language
        self.codec = codec
        self.bitrate = bitrate
        self.isHLS = isHLS
        self.lastCheckOK = lastCheckOK
    }

    /// A directory row, or nil when it has no stable UUID, no name or no
    /// usable http(s) stream.
    init?(payload: KyroRadioStationPayload) {
        guard let rawID = payload.stationuuid, let uuid = UUID(uuidString: rawID) else { return nil }
        let name = Self.clean(payload.name)
        guard !name.isEmpty else { return nil }
        let stream = Self.webURL(payload.url)
        let resolved = Self.webURL(payload.url_resolved)
        guard stream != nil || resolved != nil else { return nil }
        self.init(
            id: uuid.uuidString.lowercased(), name: name, streamURL: stream, resolvedURL: resolved,
            homepage: Self.webURL(payload.homepage), favicon: Self.webURL(payload.favicon),
            tags: Self.tags(payload.tags), country: Self.clean(payload.country),
            countryCode: Self.clean(payload.countrycode).uppercased(), state: Self.clean(payload.state),
            language: Self.clean(payload.language), codec: Self.clean(payload.codec),
            bitrate: max(0, min(payload.bitrate ?? 0, 10_000)), isHLS: payload.hls == 1,
            lastCheckOK: payload.lastcheckok.map { $0 == 1 } ?? true)
    }

    /// Streams to try, best first: Radio Browser's resolved URL is preferred
    /// (its integration guidance), and an https address before http.
    var playbackCandidates: [URL] {
        var seen = Set<String>()
        let ordered = [resolvedURL, streamURL].compactMap { $0 }
        return (ordered.filter { $0.scheme == "https" } + ordered.filter { $0.scheme == "http" })
            .filter { seen.insert($0.absoluteString).inserted }
    }

    /// Formats the iOS audio stack plays: MP3, AAC and HLS. Streams the
    /// directory labels as unknown are tried; Ogg, Opus, FLAC and WMA are not.
    var isPlayable: Bool {
        guard !playbackCandidates.isEmpty else { return false }
        if isHLS { return true }
        let codec = codec.uppercased()
        if codec.isEmpty || codec == "UNKNOWN" { return true }
        return codec.contains("MP3") || codec.contains("AAC")
    }

    var location: String {
        let parts = [state, country.isEmpty ? countryCode : country].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    /// Format and quality, e.g. "MP3 · 128 kbps" or "HLS".
    var formatLine: String? {
        var parts: [String] = []
        if isHLS { parts.append("HLS") } else if !codec.isEmpty, codec.uppercased() != "UNKNOWN" { parts.append(codec.uppercased()) }
        if bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Search across a saved station's own fields (Library search).
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([name, state, country, language] + tags).contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func clean(_ value: String?) -> String {
        String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength))
    }

    /// An http(s) URL with a host, or nil. Every other scheme (file, rtsp,
    /// mms, javascript, data) is refused.
    static func webURL(_ raw: String?) -> URL? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func tags(_ raw: String?) -> [String] {
        var seen = Set<String>()
        return (raw ?? "").split(separator: ",")
            .map { clean(String($0)).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }
}

/// Radio Browser's station JSON. Every field is optional so one odd row never
/// fails a whole page.
struct KyroRadioStationPayload: Decodable, Sendable {
    var stationuuid: String?
    var name: String?
    var url: String?
    var url_resolved: String?
    var homepage: String?
    var favicon: String?
    var tags: String?
    var country: String?
    var countrycode: String?
    var state: String?
    var language: String?
    var codec: String?
    var bitrate: Int?
    var hls: Int?
    var lastcheckok: Int?
}

/// Decodes each array element on its own, skipping the ones that don't fit.
struct KyroRadioLossyArray<Element: Decodable>: Decodable {
    var elements: [Element]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(KyroRadioSkip.self)
            }
        }
        elements = result
    }
}

private struct KyroRadioSkip: Decodable {}

/// A country, state, language or genre with its station count, for filters
/// and browsing.
struct KyroRadioFacet: Codable, Hashable, Identifiable, Sendable {
    /// What the API filters on: a country's ISO code, a state's name, a
    /// language's name, a tag.
    let value: String
    let title: String
    let stationCount: Int
    var id: String { value }

    struct Payload: Decodable, Sendable {
        var name: String?
        var iso_3166_1: String?
        var iso_639: String?
        var stationcount: Int?
    }

    enum Kind: String, Sendable { case country, state, language, tag }

    init(value: String, title: String, stationCount: Int) {
        self.value = value
        self.title = title
        self.stationCount = stationCount
    }

    init?(payload: Payload, kind: Kind) {
        let name = KyroRadioStation.clean(payload.name)
        guard !name.isEmpty, (payload.stationcount ?? 0) > 0 else { return nil }
        switch kind {
        case .country:
            let code = KyroRadioStation.clean(payload.iso_3166_1).uppercased()
            guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
            self.init(value: code, title: name, stationCount: payload.stationcount ?? 0)
        case .language:
            self.init(value: name.lowercased(), title: name.capitalized, stationCount: payload.stationcount ?? 0)
        case .state, .tag:
            self.init(value: name, title: kind == .tag ? name.capitalized : name, stationCount: payload.stationcount ?? 0)
        }
    }
}

/// One Discover request. Filters combine; the API matches `name`, `state` and
/// `tag` as substrings and `countrycode`/`language` exactly.
struct KyroRadioQuery: Hashable, Sendable {
    enum Field: String, CaseIterable, Hashable, Sendable {
        /// Station names; call signs are part of the name ("WGN 720").
        case name
        case genre
        case location

        var title: String {
            switch self {
            case .name: "Name"
            case .genre: "Genre"
            case .location: "Location"
            }
        }
    }

    var text = ""
    var field: Field = .name
    /// ISO 3166-1 code, nil for worldwide.
    var countryCode: String?
    var state: String?
    var language: String?
    var tag: String?

    static let pageSize = 40
    static let maxTextLength = 100

    var trimmedText: String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTextLength))
    }

    /// Popular stations first; broken streams left out by the server.
    func queryItems(offset: Int, limit: Int = pageSize) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        let text = trimmedText
        var state = state
        var tag = tag
        var name: String?
        if !text.isEmpty {
            switch field {
            case .name: name = text
            case .genre: tag = text.lowercased()
            case .location: state = text
            }
        }
        if let name { items.append(.init(name: "name", value: name)) }
        if let tag, !tag.isEmpty { items.append(.init(name: "tag", value: tag)) }
        if let countryCode, !countryCode.isEmpty { items.append(.init(name: "countrycode", value: countryCode)) }
        if let state, !state.isEmpty { items.append(.init(name: "state", value: state)) }
        if let language, !language.isEmpty { items.append(.init(name: "language", value: language)) }
        items += [
            .init(name: "hidebroken", value: "true"),
            .init(name: "order", value: "clickcount"),
            .init(name: "reverse", value: "true"),
            .init(name: "offset", value: String(max(0, offset))),
            .init(name: "limit", value: String(max(1, min(limit, 100)))),
        ]
        return items
    }

    /// The usual starting points, without location permission.
    static func unitedStates() -> Self { .init(countryCode: "US") }
    static func illinois() -> Self { .init(countryCode: "US", state: "Illinois") }
    static func worldwide() -> Self { .init() }
}

/// `.pls` and `.m3u` playlists that some stations list instead of a stream.
enum KyroRadioPlaylist {
    static let maxBytes = 64 * 1024

    static func isPlaylist(_ url: URL) -> Bool {
        ["pls", "m3u"].contains(url.pathExtension.lowercased())
    }

    /// Stream URLs from a playlist, in order (http/https only, at most ten).
    static func entries(_ data: Data) -> [URL] {
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var result: [URL] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("[") else { continue }
            var candidate = line
            if let equals = line.firstIndex(of: "="), line.lowercased().hasPrefix("file") {
                candidate = String(line[line.index(after: equals)...])
            } else if line.contains("=") {
                continue
            }
            if let url = KyroRadioStation.webURL(candidate), !result.contains(url) {
                result.append(url)
            }
            if result.count == 10 { break }
        }
        return result
    }
}

/// Song and artist from a stream's ICY `StreamTitle`, which stations send as
/// "Artist - Title". Nothing is invented: an empty value, the station's own
/// name, or a value that looks like an address is dropped.
struct KyroRadioTrack: Equatable, Sendable {
    let title: String
    let artist: String?

    init(title: String, artist: String?) {
        self.title = title
        self.artist = artist
    }

    init?(streamTitle raw: String?, stationName: String) {
        let value = KyroRadioStation.clean(raw)
        guard !value.isEmpty, value.compare(stationName, options: [.caseInsensitive]) != .orderedSame,
              !value.lowercased().hasPrefix("http"), value.count >= 2 else { return nil }
        let parts = value.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty {
                self.init(title: title, artist: artist)
                return
            }
        }
        self.init(title: value, artist: nil)
    }
}
#endif
