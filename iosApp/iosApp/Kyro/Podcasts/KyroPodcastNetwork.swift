#if os(iOS) || KYRO_PODCAST_HOST_TESTS
import Foundation

final class PodcastRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let next = PodcastAddress.url(request.url?.absoluteString),
              response.url?.scheme != "https" || next.scheme == "https",
              task.countOfBytesReceived < 1024 * 1024 else {
            completionHandler(nil); return
        }
        var request = request
        request.url = next
        if response.url?.host != next.host {
            request.setValue(nil, forHTTPHeaderField: "If-None-Match")
            request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        }
        completionHandler(request)
    }

    static func configuration(wifiOnly: Bool = false) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.allowsCellularAccess = !wifiOnly
        return configuration
    }
}

struct PodcastHTTP: Sendable {
    static let shared = Self()
    private let session = URLSession(configuration: PodcastRedirects.configuration(), delegate: PodcastRedirects(), delegateQueue: nil)

    func get(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard PodcastAddress.url(request.url?.absoluteString) != nil else { throw PodcastError.invalidURL }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
              PodcastAddress.url(http.url?.absoluteString) != nil else { throw PodcastError.unavailable }
        if http.statusCode == 304 { return (Data(), http) }
        guard http.statusCode == 200 else { throw PodcastError.unavailable }
        guard response.expectedContentLength <= Int64(limit) else { throw PodcastError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), limit))
        for try await byte in bytes {
            guard data.count < limit else { throw PodcastError.tooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        return (data, http)
    }
}

struct PodcastDiscovery {
    struct Result: Identifiable, Sendable {
        var id: URL { feed }
        let feed: URL
        let title: String
        let publisher: String
        let artwork: URL?
        let appleLink: URL?
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let feedUrl, collectionName, artistName, artworkUrl100, collectionViewUrl: String?
        }
        let results: [Item]
    }

    static func request(term: String, country: String) -> URLRequest? {
        let term = String(term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard term.count >= 2 else { return nil }
        let storefront = country.uppercased()
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term), .init(name: "country", value: storefront.count == 2 ? storefront : "US"),
            .init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"),
            .init(name: "limit", value: "25"), .init(name: "explicit", value: "Yes")
        ]
        return components.url.map { URLRequest(url: $0) }
    }

    static func decode(_ data: Data) throws -> [Result] {
        var seen = Set<URL>()
        return try JSONDecoder().decode(Response.self, from: data).results.prefix(25).compactMap { item in
            guard let feed = PodcastAddress.url(item.feedUrl), seen.insert(feed).inserted,
                  let title = item.collectionName, !title.isEmpty else { return nil }
            let appleLink = PodcastAddress.url(item.collectionViewUrl).flatMap {
                $0.scheme == "https" && $0.host == "podcasts.apple.com" ? $0 : nil
            }
            return .init(feed: feed, title: title, publisher: item.artistName ?? "",
                         artwork: appleLink == nil ? nil : PodcastAddress.url(item.artworkUrl100), appleLink: appleLink)
        }
    }
}

/// Manual searches are cached and coalesced. No network traffic until submitted.
actor PodcastDirectory {
    static let shared = PodcastDirectory()
    private var cache: [URL: (Date, [PodcastDiscovery.Result])] = [:]
    private var lastRequest: Date?
    private var lastSlot: Date?
    private let jobs = PodcastRequests<URL, [PodcastDiscovery.Result]>()

    func search(_ term: String, country: String) async throws -> [PodcastDiscovery.Result] {
        guard let request = PodcastDiscovery.request(term: term, country: country), let url = request.url else { return [] }
        let now = Date()
        if let recent = cache[url], now.timeIntervalSince(recent.0) < 600 { return recent.1 }
        return try await jobs.run(url) { [self] in try await perform(request, key: url) }
    }

    private func perform(_ request: URLRequest, key: URL) async throws -> [PodcastDiscovery.Result] {
        let now = Date()
        let slot = max(now, (lastSlot ?? .distantPast).addingTimeInterval(3.2))
        guard slot.timeIntervalSince(now) < 10 else { throw PodcastError.unavailable }
        lastSlot = slot
        try await Task.sleep(for: .seconds(max(0, slot.timeIntervalSinceNow)))
        // Waking late must not make scheduled requests burst together.
        while let lastRequest, Date().timeIntervalSince(lastRequest) < 3.2 {
            try await Task.sleep(for: .seconds(max(0, 3.2 + lastRequest.timeIntervalSinceNow)))
        }
        try Task.checkCancellation()
        lastRequest = Date()
        let (data, _) = try await PodcastHTTP.shared.get(request, limit: 768 * 1024)
        let results = try PodcastDiscovery.decode(data)
        if cache.count >= 40, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[oldest] = nil }
        cache[key] = (Date(), results)
        return results
    }
}

/// A cancelled screen stops waiting immediately. Shared work is cancelled only
/// when its last waiter leaves; an old operation cannot complete a new one.
actor PodcastRequests<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var entries: [Key: Entry] = [:]

    func run(_ key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if entries[key] != nil {
                    entries[key]?.waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                let task = Task {
                    let result: Result<Value, Error>
                    do { result = .success(try await operation()) } catch { result = .failure(error) }
                    finish(key, id: id, with: result)
                }
                entries[key] = Entry(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
    }

    private func finish(_ key: Key, id: UUID, with result: Result<Value, Error>) {
        guard entries[key]?.id == id, let entry = entries.removeValue(forKey: key) else { return }
        for waiter in entry.waiters.values { waiter.resume(with: result) }
    }

    private func cancel(_ key: Key, waiter: UUID) {
        entries[key]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
        if entries[key]?.waiters.isEmpty == true { entries.removeValue(forKey: key)?.task.cancel() }
    }
}

struct PodcastFeedCache: Codable, Sendable {
    let address: URL
    let fetched: Date
    let etag: String?
    let modified: String?
    let show: PodcastShow
    let episodes: [PodcastEpisode]
    var documentAddress: URL? = nil

    func isFresh(for url: URL, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        address == url && (0..<maxAge).contains(now.timeIntervalSince(fetched))
    }
}

actor PodcastFeedService {
    static let shared = PodcastFeedService()
    private let requests = PodcastRequests<URL, Response>()
    struct Chapters: Decodable {
        struct Chapter: Decodable, Identifiable {
            let startTime: Double
            let title: String?
            var id: Double { startTime }
        }
        let chapters: [Chapter]
    }
    struct Response: Sendable {
        let data: Data
        let status: Int
        let address: URL
        let etag: String?
        let modified: String?
    }

    func load(_ show: PodcastShow, cached: PodcastFeedCache?, maxAge: TimeInterval) async throws -> PodcastFeedCache {
        if let cached, cached.isFresh(for: show.feed, maxAge: maxAge) { return cached }
        let response = try await request(show.feed, cache: cached)
        try Task.checkCancellation()
        if response.status == 304, let cached {
            return .init(address: cached.address, fetched: Date(), etag: cached.etag,
                         modified: cached.modified, show: cached.show, episodes: cached.episodes,
                         documentAddress: cached.documentAddress)
        }
        var feed = try PodcastFeed.parse(response.data, at: response.address, showID: show.id)
        var resolved = response
        var canonical = show.feed
        // Follow one explicit migration only after the target is verified to be
        // a related podcast. Unreachable or invalid targets leave the old feed intact.
        if let migration = feed.migration, migration != resolved.address,
           resolved.address.scheme != "https" || migration.scheme == "https",
           let next = try? await request(migration, cache: nil),
           let successor = try? PodcastFeed.parse(next.data, at: next.address, showID: show.id),
           successor.show.title.caseInsensitiveCompare(feed.show.title) == .orderedSame ||
                !Set(successor.episodes.map(\.id)).isDisjoint(with: feed.episodes.map(\.id)) {
            feed = successor
            resolved = next
            canonical = migration
        }
        try Task.checkCancellation()
        var current = feed.show
        // Redirects can be temporary and can return expiring CDN addresses.
        // Keep the subscribed URL until the publisher declares a migration.
        current.feed = canonical
        // Retain the original directory-discovered address, not a redirect or
        // a publisher's potentially personalized migration target.
        current.portableFeed = show.portableFeed
        let previous = Dictionary((cached?.episodes ?? []).map { ($0.media, $0.id) },
                                  uniquingKeysWith: { first, _ in first })
        let incoming = Set(feed.episodes.map(\.id))
        let episodes = feed.episodes.map { episode in
            guard let known = previous[episode.media], known != episode.id, !incoming.contains(known) else { return episode }
            var stable = episode
            stable.id = known
            return stable
        }
        return .init(address: canonical, fetched: Date(), etag: resolved.etag,
                     modified: resolved.modified, show: current, episodes: episodes,
                     documentAddress: resolved.address)
    }

    private func request(_ url: URL, cache: PodcastFeedCache?) async throws -> Response {
        try await requests.run(url) {
            var request = URLRequest(url: url)
            if let cache, cache.address == url {
                request.setValue(cache.etag, forHTTPHeaderField: "If-None-Match")
                request.setValue(cache.modified, forHTTPHeaderField: "If-Modified-Since")
            }
            let (data, response) = try await PodcastHTTP.shared.get(request, limit: PodcastFeed.byteLimit)
            guard let address = PodcastAddress.url(response.url?.absoluteString) else { throw PodcastError.invalidURL }
            return .init(data: data, status: response.statusCode, address: address,
                         etag: response.value(forHTTPHeaderField: "ETag"),
                         modified: response.value(forHTTPHeaderField: "Last-Modified"))
        }
    }

    func chapters(at url: URL) async throws -> [Chapters.Chapter] {
        let (data, _) = try await PodcastHTTP.shared.get(URLRequest(url: url), limit: 512 * 1024)
        var seen = Set<Double>()
        return try JSONDecoder().decode(Chapters.self, from: data).chapters.prefix(500)
            .filter { $0.startTime.isFinite && $0.startTime >= 0 && seen.insert($0.startTime).inserted }
            .sorted { $0.startTime < $1.startTime }
    }
}
#endif
