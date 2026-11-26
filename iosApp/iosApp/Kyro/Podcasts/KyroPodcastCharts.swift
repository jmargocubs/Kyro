#if os(iOS) || KYRO_PODCAST_HOST_TESTS
import Foundation

/// Build 135: Apple Podcasts top charts for Discover.
///
/// Source: Apple's public iTunes RSS generator
/// (`https://itunes.apple.com/<storefront>/rss/toppodcasts/limit=<n>[/genre=<id>]/json`).
/// It is free and needs no key, and it returns Apple's own top-podcast chart overall
/// and per Apple Podcasts genre, with show name, creator, summary and artwork.
/// It has no feed addresses; those come from Apple's lookup API
/// (`https://itunes.apple.com/lookup?id=<id>&entity=podcast`) only when a listener
/// opens a show.
///
/// Requests are on demand (Discover open, a category chosen, See All), at least
/// `PodcastCharts.spacing` seconds apart, coalesced, and cached on disk for
/// `PodcastCharts.maxAge`. Nothing refreshes in the background.
enum PodcastCategory: String, CaseIterable, Identifiable, Sendable {
    case comedy, sports, news, trueCrime, religion, society, business, technology, health, music, history, education, tvFilm

    var id: String { rawValue }

    /// Apple Podcasts genre identifier.
    var genreID: Int {
        switch self {
        case .comedy: 1303
        case .sports: 1545
        case .news: 1489
        case .trueCrime: 1488
        case .religion: 1314
        case .society: 1324
        case .business: 1321
        case .technology: 1318
        case .health: 1512
        case .music: 1310
        case .history: 1487
        case .education: 1304
        case .tvFilm: 1309
        }
    }

    var title: String {
        switch self {
        case .comedy: "Comedy"
        case .sports: "Sports"
        case .news: "News"
        case .trueCrime: "True Crime"
        case .religion: "Religion & Spirituality"
        case .society: "Society & Culture"
        case .business: "Business"
        case .technology: "Technology"
        case .health: "Health & Fitness"
        case .music: "Music"
        case .history: "History"
        case .education: "Education"
        case .tvFilm: "TV & Film"
        }
    }

    var symbol: String {
        switch self {
        case .comedy: "face.smiling"
        case .sports: "sportscourt"
        case .news: "newspaper"
        case .trueCrime: "magnifyingglass"
        case .religion: "sparkles"
        case .society: "person.3"
        case .business: "chart.line.uptrend.xyaxis"
        case .technology: "cpu"
        case .health: "heart.text.square"
        case .music: "music.note"
        case .history: "building.columns"
        case .education: "graduationcap"
        case .tvFilm: "film"
        }
    }
}

/// One show on an Apple Podcasts chart.
struct PodcastChartEntry: Codable, Identifiable, Hashable, Sendable {
    /// Apple Podcasts collection identifier.
    let appleID: String
    let title: String
    let creator: String
    let summary: String
    let artwork: URL?
    let genre: String
    var id: String { appleID }
}

/// A chart as fetched: which chart, when, and its shows in rank order.
struct PodcastChart: Codable, Equatable, Sendable {
    let key: String
    let fetched: Date
    let entries: [PodcastChartEntry]

    func isFresh(maxAge: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(fetched) >= 0 && now.timeIntervalSince(fetched) < maxAge
    }
}

enum PodcastChartFeed {
    static let maxLimit = 100

    /// nil category is the overall Top Podcasts chart.
    static func key(category: PodcastCategory?, limit: Int, country: String) -> String {
        "\(storefront(country))-\(category?.genreID ?? 0)-\(clamp(limit))"
    }

    static func request(category: PodcastCategory?, limit: Int, country: String) -> URLRequest {
        var path = "https://itunes.apple.com/\(storefront(country))/rss/toppodcasts/limit=\(clamp(limit))"
        if let category { path += "/genre=\(category.genreID)" }
        var request = URLRequest(url: URL(string: path + "/json")!)
        request.timeoutInterval = 20
        return request
    }

    static func lookupRequest(appleID: String, country: String) -> URLRequest? {
        guard !appleID.isEmpty, appleID.count <= 20, appleID.allSatisfy(\.isNumber) else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: appleID), .init(name: "entity", value: "podcast"),
                                 .init(name: "country", value: storefront(country))]
        return components.url.map { URLRequest(url: $0) }
    }

    static func storefront(_ country: String) -> String {
        let code = country.lowercased()
        return code.count == 2 && code.allSatisfy(\.isLetter) ? code : "us"
    }

    static func clamp(_ limit: Int) -> Int { min(max(limit, 1), maxLimit) }

    /// Apple serves chart art at 170 px; the same image is available larger by
    /// changing the size segment.
    static func largeArtwork(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let text = url.absoluteString
        guard let range = text.range(of: #"/\d{2,4}x\d{2,4}bb\.(png|jpg|jpeg|webp)$"#, options: .regularExpression) else { return url }
        return URL(string: text.replacingCharacters(in: range, with: "/600x600bb.jpg"))
    }

    private struct Label: Decodable { let label: String }
    private struct Attributes<T: Decodable>: Decodable { let attributes: T }
    private struct IDAttributes: Decodable {
        let id: String
        enum CodingKeys: String, CodingKey { case id = "im:id" }
    }
    private struct CategoryAttributes: Decodable { let label: String? }
    private struct Entry: Decodable {
        let name: Label
        let artist: Label?
        let summary: Label?
        let image: [Label]?
        let id: Attributes<IDAttributes>
        let category: Attributes<CategoryAttributes>?
        enum CodingKeys: String, CodingKey {
            case name = "im:name", artist = "im:artist", summary, image = "im:image", id, category
        }
    }
    private struct Envelope: Decodable {
        struct Feed: Decodable {
            let entry: [Entry]?
            enum CodingKeys: String, CodingKey { case entry }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                // A one-entry chart arrives as an object rather than an array.
                if let list = try? values.decodeIfPresent([Entry].self, forKey: .entry) {
                    entry = list
                } else {
                    entry = (try? values.decodeIfPresent(Entry.self, forKey: .entry)).flatMap { $0.map { [$0] } }
                }
            }
        }
        let feed: Feed
    }

    static func decode(_ data: Data) throws -> [PodcastChartEntry] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var seen = Set<String>()
        return (envelope.feed.entry ?? []).prefix(maxLimit).compactMap { entry in
            let id = entry.id.attributes.id
            let title = entry.name.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, id.allSatisfy(\.isNumber), !id.isEmpty, seen.insert(id).inserted else { return nil }
            let art = entry.image?.last.flatMap { PodcastAddress.url($0.label) }
            return PodcastChartEntry(appleID: id, title: String(title.prefix(200)),
                                     creator: String((entry.artist?.label ?? "").prefix(200)),
                                     summary: String((entry.summary?.label ?? "").prefix(1200)),
                                     artwork: largeArtwork(art), genre: entry.category?.attributes.label ?? "")
        }
    }

    private struct Lookup: Decodable {
        struct Item: Decodable { let feedUrl: String?; let collectionId: Int? }
        let results: [Item]
    }

    /// The public RSS address of an Apple Podcasts show, when it has one.
    static func decodeFeed(_ data: Data, appleID: String) throws -> URL? {
        let results = try JSONDecoder().decode(Lookup.self, from: data).results
        let match = results.first { $0.collectionId.map(String.init) == appleID } ?? results.first
        return PodcastAddress.url(match?.feedUrl)
    }
}

/// How the Podcast Library orders subscribed shows.
enum PodcastLibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recentlyUpdated = "Recently Updated", recentlyAdded = "Recently Added", alphabetical = "A–Z"
    var id: String { rawValue }

    /// `shows` is in subscription order (oldest first); `latest` maps a show ID to
    /// its newest cached episode date. Shows without episodes sort last when
    /// ordering by update.
    static func sorted(_ shows: [PodcastShow], by sort: Self, latest: [String: Date], matching query: String = "") -> [PodcastShow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = shows.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
            || $0.publisher.localizedCaseInsensitiveContains(term) }
        switch sort {
        case .recentlyAdded:
            return matches.reversed()
        case .alphabetical:
            return matches.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyUpdated:
            let order = Dictionary(uniqueKeysWithValues: matches.enumerated().map { ($1.id, $0) })
            return matches.sorted { a, b in
                let da = latest[a.id] ?? .distantPast, db = latest[b.id] ?? .distantPast
                return da != db ? da > db : (order[a.id] ?? 0) > (order[b.id] ?? 0)
            }
        }
    }
}

/// Fetches and caches charts and feed lookups. Injected `fetch` and `directory`
/// keep it testable on the host.
actor PodcastCharts {
    static let shared = PodcastCharts()
    static let maxAge: TimeInterval = 6 * 3600
    static let spacing: TimeInterval = 3.2

    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let fetch: Fetch
    private let directory: URL?
    private let now: @Sendable () -> Date
    private var memory: [String: PodcastChart] = [:]
    private var feeds: [String: URL] = [:]
    private var lastRequest: Date?
    private let jobs = PodcastRequests<String, PodcastChart>()
    private let lookups = PodcastRequests<String, URL?>()
    /// Network requests made, for checks and diagnostics.
    private(set) var requestCount = 0

    init(fetch: Fetch? = nil, directory: URL? = PodcastCharts.defaultDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch ?? { request in try await PodcastHTTP.shared.get(request, limit: 1_024 * 1_024).0 }
        self.directory = directory
        self.now = now
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KyroPodcastCharts", isDirectory: true)
    }

    /// A cached chart, even a stale one, without any network request.
    func cached(category: PodcastCategory?, limit: Int, country: String) -> PodcastChart? {
        let key = PodcastChartFeed.key(category: category, limit: limit, country: country)
        if let chart = memory[key] { return chart }
        guard let chart = readDisk(key) else { return nil }
        memory[key] = chart
        return chart
    }

    /// The chart, from cache when fresh, otherwise from Apple. A failed refresh
    /// returns the stale copy when there is one.
    func chart(category: PodcastCategory?, limit: Int, country: String) async throws -> PodcastChart {
        let key = PodcastChartFeed.key(category: category, limit: limit, country: country)
        if let chart = cached(category: category, limit: limit, country: country),
           chart.isFresh(maxAge: Self.maxAge, now: now()) { return chart }
        let request = PodcastChartFeed.request(category: category, limit: limit, country: country)
        do {
            return try await jobs.run(key) { [self] in try await load(request, key: key) }
        } catch {
            if !(error is CancellationError), let stale = memory[key] { return stale }
            throw error
        }
    }

    /// The show's public feed address, looked up once and remembered.
    func feed(appleID: String, country: String) async throws -> URL? {
        if let known = feeds[appleID] { return known }
        guard let request = PodcastChartFeed.lookupRequest(appleID: appleID, country: country) else { return nil }
        let url = try await lookups.run(appleID) { [self] in
            let data = try await paced(request)
            return try PodcastChartFeed.decodeFeed(data, appleID: appleID)
        }
        if let url {
            if feeds.count >= 200 { feeds.removeAll() }
            feeds[appleID] = url
        }
        return url
    }

    private func load(_ request: URLRequest, key: String) async throws -> PodcastChart {
        let data = try await paced(request)
        let chart = PodcastChart(key: key, fetched: now(), entries: try PodcastChartFeed.decode(data))
        memory[key] = chart
        writeDisk(chart)
        return chart
    }

    /// Keeps Apple requests at least `spacing` seconds apart.
    private func paced(_ request: URLRequest) async throws -> Data {
        while let lastRequest, now().timeIntervalSince(lastRequest) < Self.spacing {
            try await Task.sleep(for: .seconds(max(0.05, Self.spacing - now().timeIntervalSince(lastRequest))))
        }
        try Task.checkCancellation()
        lastRequest = now()
        requestCount += 1
        return try await fetch(request)
    }

    private func file(_ key: String) -> URL? {
        directory?.appendingPathComponent("chart-\(key).json")
    }

    private func readDisk(_ key: String) -> PodcastChart? {
        guard let file = file(key), let data = try? Data(contentsOf: file), data.count < 2_000_000 else { return nil }
        return try? JSONDecoder().decode(PodcastChart.self, from: data)
    }

    private func writeDisk(_ chart: PodcastChart) {
        guard let directory, let file = file(chart.key), let data = try? JSONEncoder().encode(chart) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
#endif
