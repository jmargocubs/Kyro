import Foundation

/// Where a provider's guide comes from.
enum EPGFeedSource: Sendable, Equatable {
    case xmltv(URL)
    case xtream(server: String, username: String, password: String)

    func feedURL() throws -> URL {
        switch self {
        case .xmltv(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw EPGError.invalidSource
            }
            return url
        case let .xtream(server, username, password):
            return try XtreamEPG.xmltvURL(server: server, username: username, password: password)
        }
    }
}

/// Downloads a guide feed. Implementations must honor task cancellation and never surface the URL.
protocol EPGFeedLoading: Sendable {
    func load(_ url: URL, maximumBytes: Int) async throws -> Data
}

struct URLSessionEPGFeedLoader: EPGFeedLoading {
    let session: URLSession
    var onAcceptedBytes: (@Sendable (Int) -> Void)? = nil

    /// Guides are larger and slower than playlists, so they get their own longer resource timeout.
    static func makeDefault() -> URLSessionEPGFeedLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        return URLSessionEPGFeedLoader(session: URLSession(configuration: configuration))
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/xml, text/xml, application/gzip, application/x-xz, */*",
                         forHTTPHeaderField: "Accept")
        let delegate = BoundedEPGDownload(maximumBytes: maximumBytes, onAcceptedBytes: onAcceptedBytes)
        let boundedSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(request, session: boundedSession, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Owns one URLSession data task and stops it as soon as the actual body exceeds its cap.
private final class BoundedEPGDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let onAcceptedBytes: (@Sendable (Int) -> Void)?
    private var continuation: CheckedContinuation<Data, Error>?
    private var responseError: Error?
    private var body = Data()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false
    private var cancelled = false

    init(maximumBytes: Int, onAcceptedBytes: (@Sendable (Int) -> Void)?) {
        self.maximumBytes = maximumBytes
        self.onAcceptedBytes = onAcceptedBytes
    }

    func start(_ request: URLRequest, session: URLSession, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        self.session = session
        let shouldCancel = cancelled
        lock.unlock()
        guard !shouldCancel else { finish(.failure(CancellationError())); return }
        let task = session.dataTask(with: request)
        lock.lock()
        self.task = task
        let cancelledBeforeResume = cancelled
        lock.unlock()
        if cancelledBeforeResume { task.cancel() } else { task.resume() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            responseError = EPGError.providerRejected
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maximumBytes) {
            responseError = EPGError.responseTooLarge
            completionHandler(.cancel)
        } else if !(response is HTTPURLResponse) {
            responseError = EPGError.providerRejected
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count <= maximumBytes - data.count else {
            responseError = EPGError.responseTooLarge
            dataTask.cancel()
            return
        }
        body.append(data)
        onAcceptedBytes?(body.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let responseError { finish(.failure(responseError)); return }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled || (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())); return }
        if error != nil { finish(.failure(EPGError.providerRejected)); return }
        finish(.success(body))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}

/// Owns every provider's guide: loads it from cache, refreshes it from the feed, and answers
/// freshness questions.
///
/// - One refresh runs per provider; concurrent callers share it. The shared work is cancelled
///   only when every caller waiting on it has been cancelled.
/// - Downloading, decompression, parsing, indexing and cache I/O run in nonisolated async
///   functions, so they leave the actor free for lookups without detaching from the caller's task.
/// - A failed or cancelled refresh never replaces a usable guide or the cache.
/// - Removing a provider discards any refresh still in flight for it.
actor EPGService {
    private struct Flight {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<EPGIndex, Error>] = [:]
    }

    private let cache: EPGCacheStore?
    private let loader: any EPGFeedLoading
    nonisolated let policy: EPGRefreshPolicy
    nonisolated let limits: EPGLimits
    private let now: @Sendable () -> Date

    private var indexes: [UUID: EPGIndex] = [:]
    private var flights: [UUID: Flight] = [:]
    private var failures: [UUID: (count: Int, last: Date)] = [:]
    private var pendingWrites: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var checkedCache = Set<UUID>()
    /// Bumped on removal so work that started before it cannot restore the provider's guide.
    private var generations: [UUID: Int] = [:]

    init(cache: EPGCacheStore?, loader: any EPGFeedLoading, policy: EPGRefreshPolicy = EPGRefreshPolicy(),
         limits: EPGLimits = EPGLimits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.loader = loader
        self.policy = policy
        self.limits = limits
        self.now = now
    }

    /// The guide in memory, else the cached one, if it is still usable.
    func index(for providerID: UUID) async -> EPGIndex? {
        if indexes[providerID] == nil { await loadCached(providerID) }
        guard let index = indexes[providerID], policy.freshness(of: index, now: now()).isUsable else { return nil }
        return index
    }

    /// Callers currently waiting on the provider's refresh. For diagnostics and tests.
    func waiterCount(for providerID: UUID) -> Int {
        flights[providerID]?.waiters.count ?? 0
    }

    func freshness(for providerID: UUID) -> EPGFreshness {
        indexes[providerID].map { policy.freshness(of: $0, now: now()) } ?? .missing
    }

    /// A fresh guide for the provider, downloading it only when the policy says it is due.
    ///
    /// - Parameters:
    ///   - channels: the playlist's channels, so only listings the playlist can show are kept.
    ///   - force: refresh even when the guide is fresh or a recent failure is backing off.
    func refresh(providerID: UUID, source: EPGFeedSource, channels: EPGChannelFilter? = nil,
                 force: Bool = false) async throws -> EPGIndex {
        if indexes[providerID] == nil { await loadCached(providerID) }
        if !force, flights[providerID] == nil {
            let current = indexes[providerID]
            let freshness = current.map { policy.freshness(of: $0, now: now()) } ?? .missing
            if freshness == .fresh, let current { return current }
            // A feed that just failed is not refetched on every visit, whatever the guide's state.
            if isBackingOff(providerID) {
                if freshness.isUsable, let current { return current }
                throw EPGError.providerRejected
            }
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                join(providerID, waiterID: waiterID, continuation: continuation, source: source, channels: channels)
            }
        } onCancel: {
            Task { await self.leave(providerID, waiterID: waiterID) }
        }
    }

    /// Replaces one channel's listings with newer ones (Xtream short EPG). Not persisted: the next
    /// full refresh supersedes it.
    func replacePrograms(_ programs: [EPGProgram], guideID: String, providerID: UUID) -> EPGIndex {
        // An expired guide is not a base: newer listings would otherwise stay hidden behind its age.
        let base = indexes[providerID].flatMap { policy.freshness(of: $0, now: now()).isUsable ? $0 : nil }
            ?? .empty(fetchedAt: now())
        let updated = base.replacingPrograms(programs, guideID: guideID, now: now(), limits: limits)
        indexes[providerID] = updated
        return updated
    }

    /// Forgets the provider's guide, cancels its refresh and deletes its cache file.
    func remove(providerID: UUID) async {
        if let flight = flights.removeValue(forKey: providerID) {
            flight.task?.cancel()
            for continuation in flight.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
        indexes[providerID] = nil
        failures[providerID] = nil
        checkedCache.insert(providerID)
        generations[providerID, default: 0] += 1
        if let write = pendingWrites.removeValue(forKey: providerID) { await write.task.value }
        if let cache { await Self.removeCache(cache, providerID: providerID) }
    }

    // MARK: - Refresh flights

    private func join(_ providerID: UUID, waiterID: UUID, continuation: CheckedContinuation<EPGIndex, Error>,
                      source: EPGFeedSource, channels: EPGChannelFilter?) {
        if flights[providerID] != nil {
            flights[providerID]?.waiters[waiterID] = continuation
            return
        }
        let flightID = UUID()
        flights[providerID] = Flight(id: flightID, waiters: [waiterID: continuation])
        let loader = loader, limits = limits, fetchedAt = now()
        flights[providerID]?.task = Task {
            let result: Result<EPGIndex, Error>
            do {
                result = .success(try await Self.build(source: source, channels: channels, loader: loader,
                                                       limits: limits, fetchedAt: fetchedAt))
            } catch {
                result = .failure(error)
            }
            self.complete(providerID, flightID: flightID, result: result)
        }
    }

    private func complete(_ providerID: UUID, flightID: UUID, result: Result<EPGIndex, Error>) {
        // A removed provider or superseded flight must not publish late results.
        guard let flight = flights[providerID], flight.id == flightID else { return }
        flights[providerID] = nil
        switch result {
        case .success(let index):
            indexes[providerID] = index
            failures[providerID] = nil
            persist(index, providerID: providerID)
            for continuation in flight.waiters.values { continuation.resume(returning: index) }
        case .failure(let error):
            if !(error is CancellationError) {
                failures[providerID] = ((failures[providerID]?.count ?? 0) + 1, now())
            }
            for continuation in flight.waiters.values { continuation.resume(throwing: error) }
        }
    }

    private func leave(_ providerID: UUID, waiterID: UUID) {
        guard var flight = flights[providerID], let continuation = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights[providerID] = nil
        } else {
            flights[providerID] = flight
        }
    }

    private func isBackingOff(_ providerID: UUID) -> Bool {
        guard let failure = failures[providerID] else { return false }
        return now().timeIntervalSince(failure.last) < policy.retryDelay(afterFailures: failure.count)
    }

    // MARK: - Cache

    private func loadCached(_ providerID: UUID) async {
        guard let cache, checkedCache.insert(providerID).inserted else { return }
        let generation = generations[providerID, default: 0]
        guard let cached = await Self.readCache(cache, providerID: providerID) else { return }
        // A refresh may have finished, or the provider been removed, while the file was read.
        guard indexes[providerID] == nil, generations[providerID, default: 0] == generation else { return }
        indexes[providerID] = cached
    }

    private func persist(_ index: EPGIndex, providerID: UUID) {
        guard let cache else { return }
        let previous = pendingWrites[providerID]?.task
        let writeID = UUID()
        // Writes for one provider run in order, so an older guide never lands on top of a newer one.
        pendingWrites[providerID] = (writeID, Task {
            await previous?.value
            await Self.writeCache(cache, index: index, providerID: providerID)
            self.finishWrite(providerID, writeID: writeID)
        })
    }

    private func finishWrite(_ providerID: UUID, writeID: UUID) {
        if pendingWrites[providerID]?.id == writeID { pendingWrites[providerID] = nil }
    }

    // MARK: - Off-actor work

    private nonisolated static func build(source: EPGFeedSource, channels: EPGChannelFilter?,
                                          loader: any EPGFeedLoading, limits: EPGLimits,
                                          fetchedAt: Date) async throws -> EPGIndex {
        let url = try source.feedURL()
        let download = try await loader.load(url, maximumBytes: limits.maximumDownloadBytes)
        try Task.checkCancellation()
        let xml = try EPGPayloadDecoder.xmlData(from: download, maximumBytes: limits.maximumXMLBytes)
        try Task.checkCancellation()
        let window = DateInterval(start: fetchedAt.addingTimeInterval(-limits.pastRetention),
                                  end: fetchedAt.addingTimeInterval(limits.futureHorizon))
        let document = try XMLTVParser.parse(xml, filter: channels, window: window, limits: limits)
        try Task.checkCancellation()
        return try EPGIndex(document: document, fetchedAt: fetchedAt, now: fetchedAt, limits: limits)
    }

    private nonisolated static func readCache(_ cache: EPGCacheStore, providerID: UUID) async -> EPGIndex? {
        cache.load(providerID: providerID)
    }

    private nonisolated static func writeCache(_ cache: EPGCacheStore, index: EPGIndex, providerID: UUID) async {
        try? cache.save(index, providerID: providerID)
    }

    private nonisolated static func removeCache(_ cache: EPGCacheStore, providerID: UUID) async {
        cache.remove(providerID: providerID)
    }
}
