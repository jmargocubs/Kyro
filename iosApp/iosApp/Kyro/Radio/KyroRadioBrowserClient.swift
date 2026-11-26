#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

/// Errors Discover can show and retry.
enum KyroRadioBrowserError: Error, Equatable, Sendable {
    /// No mirror answered (offline, or every mirror failed).
    case unavailable
    /// A mirror answered with something Kyro can't use.
    case badResponse
    /// The station's playlist had no playable stream.
    case emptyPlaylist
}

/// Radio Browser access, following its integration guidance
/// (https://api.radio-browser.info): find mirrors from
/// `all.api.radio-browser.info/json/servers`, pick one at random, fail over to
/// the others, and send an identifying User-Agent. One request per distinct
/// URL at a time (coalesced); responses are bounded; nothing loads at launch.
actor KyroRadioBrowserClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let shared = KyroRadioBrowserClient()

    /// The documented discovery host; also the last resort for requests
    /// (round-robin DNS across every mirror).
    static let discoveryHost = "all.api.radio-browser.info"
    static let mirrorSuffix = ".api.radio-browser.info"
    static let maxResponseBytes = 3_000_000
    static let maxStationsPerResponse = 500
    static let requestTimeout: TimeInterval = 12
    /// Mirrors tried for one request before giving up.
    static let maxAttempts = 3
    /// A mirror that failed or rate-limited is skipped for this long.
    static let failedMirrorCooldown: TimeInterval = 300
    static let mirrorListLifetime: TimeInterval = 86_400
    static let responseLifetime: TimeInterval = 600
    static let facetLifetime: TimeInterval = 7 * 86_400
    static let maxMemoryResponses = 64
    /// Radio Browser counts one click per station per day; Kyro sends at most that.
    static let clickInterval: TimeInterval = 86_400

    private let transport: Transport
    private let defaults: UserDefaults
    private let cacheDirectory: URL?
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let shuffle: @Sendable ([String]) -> [String]
    private var mirrors: [String] = []
    private var mirrorsLoadedAt: Date?
    private var mirrorDiscovery: Task<[String], Never>?
    private var preferredMirror: String?
    private var failedMirrors: [String: Date] = [:]
    private var inFlight: [String: SharedRequest] = [:]
    private var memory: [String: (data: Data, date: Date)] = [:]
    private var memoryOrder: [String] = []
    private var clicks: [String: Date] = [:]
    /// Requests actually sent, for tests and diagnostics.
    private(set) var sentRequests: [URL] = []

    static let mirrorsKey = "kyrox.radio.mirrors.v1"

    init(transport: Transport? = nil, defaults: UserDefaults = .standard, cacheDirectory: URL? = KyroRadioBrowserClient.defaultCacheDirectory(),
         userAgent: String = KyroRadioBrowserClient.defaultUserAgent(), now: @escaping @Sendable () -> Date = { Date() },
         shuffle: @escaping @Sendable ([String]) -> [String] = { $0.shuffled() }) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory
        self.userAgent = userAgent
        self.now = now
        self.shuffle = shuffle
        if let saved = defaults.dictionary(forKey: Self.mirrorsKey),
           let hosts = saved["hosts"] as? [String], let date = saved["date"] as? Date {
            mirrors = hosts.filter(Self.isMirrorHost)
            mirrorsLoadedAt = date
        }
    }

    /// "KyroX/<version>", as the API asks: a name that identifies the app,
    /// with no personal details.
    static func defaultUserAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "KyroX/\(version)"
    }

    static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KyroRadio", isDirectory: true)
    }

    static func isMirrorHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasSuffix(mirrorSuffix) && host.count <= 64
            && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    // MARK: Public API

    func stations(_ query: KyroRadioQuery, offset: Int, limit: Int = KyroRadioQuery.pageSize) async throws -> [KyroRadioStation] {
        let data = try await get("/json/stations/search", query.queryItems(offset: offset, limit: limit),
                                 lifetime: Self.responseLifetime)
        return try Self.decodeStations(data)
    }

    /// Fresh details for saved stations (at most 100 per call).
    func stations(uuids: [String]) async throws -> [KyroRadioStation] {
        let ids = Array(Set(uuids.filter { UUID(uuidString: $0) != nil })).sorted().prefix(100)
        guard !ids.isEmpty else { return [] }
        let data = try await get("/json/stations/byuuid", [.init(name: "uuids", value: ids.joined(separator: ","))],
                                 lifetime: Self.responseLifetime)
        return try Self.decodeStations(data)
    }

    /// Countries, languages and genres, most stations first. Cached on disk for
    /// a week and served stale when no mirror answers.
    func facets(_ kind: KyroRadioFacet.Kind, country: String? = nil, limit: Int = 200) async throws -> [KyroRadioFacet] {
        var items: [URLQueryItem] = [.init(name: "order", value: "stationcount"), .init(name: "reverse", value: "true"),
                                     .init(name: "hidebroken", value: "true"), .init(name: "limit", value: String(min(limit, 500)))]
        let path: String
        switch kind {
        case .country: path = "/json/countries"
        case .language: path = "/json/languages"
        case .tag: path = "/json/tags"
        case .state:
            path = "/json/states"
            if let country, !country.isEmpty { items.append(.init(name: "country", value: country)) }
        }
        let data = try await get(path, items, lifetime: Self.facetLifetime, persistent: true)
        guard let decoded = try? JSONDecoder().decode(KyroRadioLossyArray<KyroRadioFacet.Payload>.self, from: data) else {
            throw KyroRadioBrowserError.badResponse
        }
        var seen = Set<String>()
        return decoded.elements.compactMap { KyroRadioFacet(payload: $0, kind: kind) }
            .filter { seen.insert($0.value.lowercased()).inserted }
    }

    /// Tells Radio Browser a listener started this station
    /// (`/json/url/{stationuuid}`), at most once a day per station. Failures
    /// are ignored: playback never waits for it.
    func reportClick(_ stationID: String) async {
        guard UUID(uuidString: stationID) != nil else { return }
        if let last = clicks[stationID], now().timeIntervalSince(last) < Self.clickInterval { return }
        clicks[stationID] = now()
        _ = try? await get("/json/url/\(stationID.lowercased())", [], lifetime: 0)
    }

    /// The first stream in a `.pls`/`.m3u` playlist. Only the station's own
    /// server is contacted, with a small size limit.
    func resolvePlaylist(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        sentRequests.append(url)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode), data.count <= KyroRadioPlaylist.maxBytes,
              let first = KyroRadioPlaylist.entries(data).first,
              !KyroRadioPlaylist.isPlaylist(first) else { throw KyroRadioBrowserError.emptyPlaylist }
        return first
    }

    static func decodeStations(_ data: Data) throws -> [KyroRadioStation] {
        guard let decoded = try? JSONDecoder().decode(KyroRadioLossyArray<KyroRadioStationPayload>.self, from: data) else {
            throw KyroRadioBrowserError.badResponse
        }
        var seen = Set<String>()
        return decoded.elements.prefix(maxStationsPerResponse)
            .compactMap(KyroRadioStation.init(payload:))
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: Requests

    private func get(_ path: String, _ items: [URLQueryItem], lifetime: TimeInterval, persistent: Bool = false) async throws -> Data {
        var components = URLComponents()
        components.path = path
        components.queryItems = items.isEmpty ? nil : items
        let key = components.string ?? path
        if lifetime > 0, let cached = memory[key], now().timeIntervalSince(cached.date) < lifetime { return cached.data }
        if lifetime > 0, persistent, let disk = readDisk(key), now().timeIntervalSince(disk.date) < lifetime {
            remember(key, disk.data, date: disk.date)
            return disk.data
        }
        let shared: SharedRequest
        if let running = inFlight[key] {
            shared = running
        } else {
            shared = SharedRequest(Task { try await self.fetch(components) })
            inFlight[key] = shared
        }
        shared.join()
        defer { if inFlight[key] === shared, shared.isFinished { inFlight[key] = nil } }
        do {
            // A caller that goes away (a superseded search) leaves; the request
            // itself is cancelled only when nobody is waiting for it any more.
            let data = try await withTaskCancellationHandler {
                try await shared.task.value
            } onCancel: {
                shared.leave()
            }
            shared.finish()
            if lifetime > 0 {
                remember(key, data, date: now())
                if persistent { writeDisk(key, data) }
            }
            return data
        } catch {
            shared.finish()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Offline or every mirror failed: a stale saved copy still helps.
            if persistent, let disk = readDisk(key) { return disk.data }
            throw error
        }
    }

    private func fetch(_ components: URLComponents) async throws -> Data {
        let hosts = await candidateHosts()
        var lastError: Error = KyroRadioBrowserError.unavailable
        for host in hosts.prefix(Self.maxAttempts) {
            try Task.checkCancellation()
            var parts = components
            parts.scheme = "https"
            parts.host = host
            guard let url = parts.url else { throw KyroRadioBrowserError.badResponse }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            sentRequests.append(url)
            do {
                let (data, response) = try await transport(request)
                switch response.statusCode {
                case 200..<300:
                    guard data.count <= Self.maxResponseBytes else { throw KyroRadioBrowserError.badResponse }
                    preferredMirror = host
                    failedMirrors[host] = nil
                    return data
                case 429, 500...599:
                    // Rate limited or down: rest this mirror and try another.
                    failedMirrors[host] = now()
                    lastError = KyroRadioBrowserError.unavailable
                default:
                    throw KyroRadioBrowserError.badResponse
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch KyroRadioBrowserError.badResponse {
                throw KyroRadioBrowserError.badResponse
            } catch {
                failedMirrors[host] = now()
                lastError = KyroRadioBrowserError.unavailable
            }
        }
        throw lastError
    }

    /// The preferred mirror first, then the others in random order, mirrors
    /// that recently failed last, and the round-robin discovery host at the end.
    private func candidateHosts() async -> [String] {
        let known = await discoveredMirrors()
        let clock = now()
        let healthy = known.filter { failedMirrors[$0].map { clock.timeIntervalSince($0) >= Self.failedMirrorCooldown } ?? true }
        let resting = known.filter { !healthy.contains($0) }
        // A random mirror spreads load, as the API asks.
        var ordered = shuffle(healthy)
        if let preferred = preferredMirror, let index = ordered.firstIndex(of: preferred) {
            ordered.remove(at: index)
            ordered.insert(preferred, at: 0)
        }
        return ordered + resting + [Self.discoveryHost]
    }

    private func discoveredMirrors() async -> [String] {
        if let loaded = mirrorsLoadedAt, !mirrors.isEmpty, now().timeIntervalSince(loaded) < Self.mirrorListLifetime {
            return mirrors
        }
        if let running = mirrorDiscovery { return await running.value }
        let task = Task { await self.loadMirrors() }
        mirrorDiscovery = task
        let result = await task.value
        mirrorDiscovery = nil
        return result
    }

    private func loadMirrors() async -> [String] {
        guard let url = URL(string: "https://\(Self.discoveryHost)/json/servers") else { return mirrors }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        sentRequests.append(url)
        struct Server: Decodable { var name: String? }
        guard let (data, response) = try? await transport(request), response.statusCode == 200, data.count <= 100_000,
              let servers = try? JSONDecoder().decode(KyroRadioLossyArray<Server>.self, from: data) else {
            // Keep the previous list; requests fall back to the discovery host.
            return mirrors
        }
        var seen = Set<String>()
        let hosts = servers.elements.compactMap { $0.name?.lowercased() }
            .filter { Self.isMirrorHost($0) && seen.insert($0).inserted }
            .prefix(20).map { $0 }
        guard !hosts.isEmpty else { return mirrors }
        mirrors = hosts
        mirrorsLoadedAt = now()
        defaults.set(["hosts": hosts, "date": now()], forKey: Self.mirrorsKey)
        return hosts
    }

    /// One network request shared by every caller asking for the same URL.
    final class SharedRequest: @unchecked Sendable {
        let task: Task<Data, Error>
        private let lock = NSLock()
        private var waiting = 0
        private var finished = false

        init(_ task: Task<Data, Error>) { self.task = task }

        var isFinished: Bool { lock.withLock { finished } }
        func join() { lock.withLock { waiting += 1 } }
        func finish() { lock.withLock { finished = true } }
        func leave() {
            let abandoned = lock.withLock { () -> Bool in
                waiting -= 1
                return waiting <= 0 && !finished
            }
            if abandoned { task.cancel() }
        }
    }

    // MARK: Caches

    private func remember(_ key: String, _ data: Data, date: Date) {
        memory[key] = (data, date)
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > Self.maxMemoryResponses {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private func diskURL(_ key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return cacheDirectory.appendingPathComponent(String(name.prefix(150)) + ".json")
    }

    private func readDisk(_ key: String) -> (data: Data, date: Date)? {
        guard let url = diskURL(key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= Self.maxResponseBytes,
              let date = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, date)
    }

    private func writeDisk(_ key: String, _ data: Data) {
        guard let url = diskURL(key) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
#endif
