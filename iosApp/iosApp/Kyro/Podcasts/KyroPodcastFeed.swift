#if os(iOS) || KYRO_PODCAST_HOST_TESTS
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum PodcastError: LocalizedError {
    case invalidURL, invalidFeed, invalidOPML, tooLarge, unavailable, capacity

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a public HTTP or HTTPS address without a username or password."
        case .invalidFeed: "This address did not return a valid podcast RSS feed."
        case .invalidOPML: "This file is not a valid podcast OPML document."
        case .tooLarge: "This podcast file exceeds the size limit."
        case .unavailable: "The publisher or discovery service could not be reached. Try again."
        case .capacity: "Your podcast library is full."
        }
    }
}

enum PodcastAddress {
    static func url(_ text: String?, relativeTo base: URL? = nil) -> URL? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.count <= 4096,
              let absolute = URL(string: raw, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: absolute, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), isDomain(host),
              ![".local", ".localhost", ".internal", ".lan", ".home", ".test", ".invalid"].contains(where: host.hasSuffix),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else { return nil }
        parts.scheme = scheme
        parts.host = host
        parts.port = nil
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }

    private static func isDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, host.utf8.count <= 253, let suffix = labels.last,
              (suffix.utf8.allSatisfy { (97...122).contains($0) } || suffix.hasPrefix("xn--")) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    /// Only directory-discovered feeds are eligible for portable Settings Backup;
    /// manually entered and imported addresses may be private even without userinfo.
    static func portable(_ url: URL) -> Bool {
        guard url.scheme == "https", url.query == nil, url.absoluteString.count <= 256,
              self.url(url.absoluteString) == url else { return false }
        let path = url.path.lowercased()
        return !["..", "token", "secret", "private", "password", "auth", "premium", "subscriber", "access_key"]
            .contains(where: path.contains)
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct PodcastShow: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var feed: URL
    var title: String
    var publisher = ""
    var summary = ""
    var artwork: URL?
    var portableFeed: URL?
}

struct PodcastEpisode: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var showID: String
    var guid: String?
    var title: String
    var summary: String
    var media: URL
    var published: Date?
    var duration: Double?
    var artwork: URL?
    var season: Int?
    var number: Int?
    var explicit: Bool
    var chaptersURL: URL?
}

struct PodcastFeed: Sendable {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
    let migration: URL?

    static let byteLimit = 8 * 1024 * 1024
    static let episodeLimit = 300

    static func parse(_ data: Data, at url: URL, showID: String) throws -> Self {
        guard data.count <= byteLimit else { throw PodcastError.tooLarge }
        let reader = PodcastXML(mode: .rss, base: url, showID: showID)
        guard reader.parse(data), reader.foundChannel, !reader.show.title.isEmpty else {
            throw PodcastError.invalidFeed
        }
        return .init(show: reader.show, episodes: reader.episodes, migration: reader.migration)
    }
}

enum PodcastOPML {
    static let byteLimit = 512 * 1024
    static func read(_ data: Data) throws -> [URL] {
        guard data.count <= byteLimit else { throw PodcastError.tooLarge }
        let reader = PodcastXML(mode: .opml)
        guard reader.parse(data), reader.validRoot else { throw PodcastError.invalidOPML }
        return reader.feeds
    }

    static func write(_ shows: [PodcastShow]) -> Data {
        func escape(_ input: String) -> String {
            input.unicodeScalars.filter { $0.value >= 32 }.map(String.init).joined()
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let outlines = shows.map {
            "    <outline type=\"rss\" text=\"\(escape($0.title))\" xmlUrl=\"\(escape($0.feed.absoluteString))\" />"
        }.joined(separator: "\n")
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>Kyro Podcasts</title></head><body>
        \(outlines)
        </body></opml>
        """.utf8)
    }
}

private final class PodcastXML: NSObject, XMLParserDelegate {
    enum Mode { case rss, opml }
    struct Element {
        let name: String
        var text = ""
    }

    let mode: Mode
    let base: URL?
    var show: PodcastShow
    var validRoot = false
    var foundChannel = false
    var migration: URL?
    var feeds: [URL] = []
    var episodes: [PodcastEpisode] = []
    private var seenFeeds = Set<URL>()
    private var seenIDs = Set<String>()
    private var seenMedia = Set<URL>()
    private var stack: [Element] = []
    private var fields: [String: String] = [:]
    private var media: URL?
    private var episodeArtwork: URL?
    private var chapters: URL?
    private let date = DateFormatter()
    private let isoDate = ISO8601DateFormatter()

    init(mode: Mode, base: URL? = nil, showID: String = "") {
        self.mode = mode
        self.base = base
        show = .init(id: showID, feed: base ?? URL(fileURLWithPath: "/"), title: "")
        date.locale = Locale(identifier: "en_US_POSIX")
    }

    func parse(_ data: Data) -> Bool {
        // Reject DTDs, including internal entity definitions. Only UTF-8 feeds
        // are accepted; this makes the preflight unambiguous.
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { return false }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        return parser.parse() && validRoot && stack.isEmpty
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        if stack.isEmpty { validRoot = name == (mode == .rss ? "rss" : "opml") }
        guard validRoot, stack.count < 48 else { parser.abortParsing(); return }
        stack.append(.init(name: name))
        if mode == .opml {
            if name == "outline", stack.dropLast().contains(where: { $0.name == "body" }),
               feeds.count < 150, let url = PodcastAddress.url(attributes["xmlUrl"] ?? attributes["xmlurl"]),
               seenFeeds.insert(url).inserted { feeds.append(url) }
            return
        }
        if name == "channel", stack.count == 2 { foundChannel = true }
        if name == "item", stack.count == 3 {
            fields = [:]; media = nil; episodeArtwork = nil; chapters = nil
        }
        let parent = stack.dropLast().last?.name
        if stack.count == 4, parent == "item" {
            if name == "enclosure", media == nil,
               attributes["type"].map({ $0.isEmpty || $0.hasPrefix("audio/") || $0 == "application/octet-stream" ||
                   $0 == "application/ogg" || $0 == "video/mp4" }) != false {
                media = PodcastAddress.url(attributes["url"], relativeTo: base)
            }
            if name == "itunes:image" { episodeArtwork = PodcastAddress.url(attributes["href"], relativeTo: base) }
            if name == "podcast:chapters", attributes["type"] == nil || attributes["type"] == "application/json+chapters" {
                chapters = PodcastAddress.url(attributes["url"], relativeTo: base)
            }
        }
        if stack.count == 3, parent == "channel", name == "itunes:image" {
            show.artwork = PodcastAddress.url(attributes["href"], relativeTo: base) ?? show.artwork
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { append(text) }
    }
    private func append(_ text: String) {
        guard let index = stack.indices.last, stack[index].text.utf8.count < 12_000 else { return }
        stack[index].text += String(text.prefix(12_000 - min(12_000, stack[index].text.count)))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let entry = stack.popLast(), mode == .rss else { return }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.last?.name
        if parent == "item", stack.count == 3, !text.isEmpty {
            fields[entry.name] = text
        } else if parent == "channel", stack.count == 2, !text.isEmpty {
            switch entry.name {
            case "title": show.title = String(text.prefix(300))
            case "itunes:author", "dc:creator", "author": show.publisher = String(text.prefix(300))
            case "description", "itunes:summary": if show.summary.isEmpty { show.summary = Self.plain(text) }
            case "itunes:new-feed-url": migration = PodcastAddress.url(text, relativeTo: base)
            default: break
            }
        } else if stack.count == 3, parent == "image", entry.name == "url" {
            show.artwork = show.artwork ?? PodcastAddress.url(text, relativeTo: base)
        } else if parent == "channel", stack.count == 2, entry.name == "item" {
            finishEpisode()
        } else if stack.count > 3, !text.isEmpty {
            append(" " + text)
        }
    }

    private func finishEpisode() {
        guard episodes.count < PodcastFeed.episodeLimit, let media else { return }
        let guid = fields["guid"]
        let id = show.id + ":" + PodcastAddress.fingerprint(guid ?? media.absoluteString)
        guard !seenIDs.contains(id), seenMedia.insert(media).inserted else { return }
        seenIDs.insert(id)
        episodes.append(.init(id: id, showID: show.id, guid: guid.map { String($0.prefix(1024)) },
            title: String((fields["title"] ?? "Untitled episode").prefix(300)),
            summary: Self.plain(fields["content:encoded"] ?? fields["description"] ?? fields["itunes:summary"] ?? ""),
            media: media, published: parseDate(fields["pubdate"]),
            duration: Self.duration(fields["itunes:duration"]), artwork: episodeArtwork,
            season: fields["itunes:season"].flatMap(Int.init), number: fields["itunes:episode"].flatMap(Int.init),
            explicit: ["true", "yes", "explicit", "1"].contains(fields["itunes:explicit"]?.lowercased() ?? ""),
            chaptersURL: chapters))
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, raw.count < 100 else { return nil }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            date.dateFormat = format
            if let value = date.date(from: raw) { return value }
        }
        return isoDate.date(from: raw)
    }

    private static func duration(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let total = values.reduce(0.0) { $0 * 60 + $1 }
        return total > 0 && total <= 604_800 ? total : nil
    }

    private static func plain(_ raw: String) -> String {
        String(raw.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }
}
#endif
