#if os(tvOS)
import Foundation
import Observation
import OSLog

enum XtreamVODHTTP {
    /// Enforces the cap while receiving bytes, before a provider can fill memory without bound.
    /// `timeout` is the idle interval between bytes; large panels can take minutes to start a catalog body.
    static func fetch(_ url: URL, session: URLSession, maximumBytes: Int,
                      timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw XtreamVODError.network }
        guard let http = response as? HTTPURLResponse else { throw XtreamVODError.network }
        if http.statusCode == 401 || http.statusCode == 403 { throw XtreamVODError.authentication }
        if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 501 { throw XtreamVODError.unsupported }
        guard (200..<300).contains(http.statusCode) else { throw XtreamVODError.httpStatus(http.statusCode) }
        guard http.expectedContentLength <= 0 || http.expectedContentLength <= maximumBytes else {
            throw XtreamVODError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(Int(max(0, http.expectedContentLength)), maximumBytes))
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        var received = 0
        do {
            for try await byte in bytes {
                received += 1
                if received > maximumBytes { throw XtreamVODError.responseTooLarge }
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                }
            }
        } catch let error as XtreamVODError {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw XtreamVODError.network
        }
        data.append(contentsOf: chunk)
        return data
    }
}

/// Sanitized VOD diagnostics: stage, category, and HTTP status only. Never URLs or credentials.
enum XtreamVODDiagnostics {
    private static let logger = Logger(subsystem: "com.cubbiestream.kyro.tvos", category: "XtreamVOD")

    static func failure(_ stage: XtreamVODPipelineStage, kind: XtreamVODKind?, error: Error) {
        let category = error is CancellationError ? "cancelled" : (XtreamVODError.from(error)?.category ?? "unknown")
        var status = "none"
        if case .httpStatus(let code)? = error as? XtreamVODError { status = String(code) }
        if case .authentication? = error as? XtreamVODError { status = "401_or_403_or_auth_0" }
        logger.error("vod_refresh_failed stage=\(stage.rawValue, privacy: .public) kind=\(kind?.rawValue ?? "all", privacy: .public) category=\(category, privacy: .public) http=\(status, privacy: .public)")
    }

    static func event(_ name: String, kind: XtreamVODKind? = nil, count: Int? = nil) {
        logger.info("vod_refresh \(name, privacy: .public) kind=\(kind?.rawValue ?? "all", privacy: .public) count=\(count ?? -1, privacy: .public)")
    }
}

struct XtreamVODWatchState: Codable, Equatable {
    var position: Double = 0
    var duration: Double = 0
    var updatedAt = Date()
    var favorite = false
    var completed = false
}

@MainActor
@Observable
final class XtreamVODService {
    static let shared = XtreamVODService()
    private(set) var progress: XtreamVODImportProgress?
    private(set) var revision = 0
    private(set) var activeProviderID: UUID?
    /// Opened lazily and retried on every refresh, so one storage failure never disables VOD for
    /// the rest of the app session (Build 93 held a nil store until relaunch).
    private var store: XtreamVODCatalogStore?
    private let makeStore: () throws -> XtreamVODCatalogStore
    private let session: URLSession
    private let defaults: UserDefaults
    private var work: Task<Void, Never>?
    private var cachedDetails: [String: (Date, XtreamVODDetail)] = [:]
    private(set) var lastSuccessfulRefresh: [UUID: Date] = [:]
    /// Number of refresh pipelines actually started; lets tests prove a button triggered work.
    private(set) var startedRefreshCount = 0
    var isRefreshing: Bool { work != nil }

    init(store: XtreamVODCatalogStore? = nil,
         session: URLSession = .shared, defaults: UserDefaults = .standard,
         makeStore: @escaping () throws -> XtreamVODCatalogStore = { try XtreamVODCatalogStore() }) {
        self.store = store
        self.makeStore = makeStore
        self.session = session
        self.defaults = defaults
    }

    private func openStore() throws -> XtreamVODCatalogStore {
        if let store { return store }
        let opened = try makeStore()
        store = opened
        return opened
    }

    private var readableStore: XtreamVODCatalogStore? { try? openStore() }

    /// Starts one refresh of the provider's selected catalogs and waits for it. Every outcome other
    /// than `.alreadyRunning` publishes visible `progress` before returning.
    @discardableResult
    func refresh(providerID: UUID, liveTV: LiveTVService? = nil) async -> XtreamVODRefreshStart {
        let liveTV = liveTV ?? .shared
        guard work == nil else { return .alreadyRunning }
        guard let provider = liveTV.providers.first(where: { $0.id == providerID }) else { return .providerMissing }
        let enabledKinds = XtreamVODKind.allCases.filter { $0 == .movie ? provider.vodMoviesEnabled : provider.vodSeriesEnabled }
        guard provider.kind == .xtream, !enabledKinds.isEmpty else {
            progress = XtreamVODImportProgress(providerID: providerID)
            progress?.stage = .failed
            progress?.message = provider.kind == .xtream
                ? "Movies and Series are both turned off for this provider. Enable Movies or Series, then refresh."
                : "Movies and Series are available only for Xtream Codes providers."
            return .noCatalogsSelected
        }
        startedRefreshCount += 1
        activeProviderID = providerID
        progress = XtreamVODImportProgress(providerID: providerID)
        progress?.movieResult = enabledKinds.contains(.movie) ? .waiting : .notSelected
        progress?.seriesResult = enabledKinds.contains(.series) ? .waiting : .notSelected
        XtreamVODDiagnostics.event("started")
        let source = liveTV.xtreamVODConfiguration(for: providerID)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(providerID: providerID, source: source, enabledKinds: enabledKinds)
        }
        work = task
        await task.value
        if activeProviderID == providerID { activeProviderID = nil; work = nil }
        return .started
    }

    func cancel() { work?.cancel() }

    private func failBeforeDownload(_ error: XtreamVODError, stage: XtreamVODPipelineStage,
                                    enabledKinds: [XtreamVODKind]) {
        XtreamVODDiagnostics.failure(stage, kind: nil, error: error)
        for kind in enabledKinds { setResult(result(for: error), kind: kind) }
        progress?.stage = .failed
        progress?.failure = error
        progress?.failedStage = stage
        progress?.message = error.errorDescription
    }

    private func performRefresh(providerID: UUID, source: LiveTVSourceConfiguration?, enabledKinds: [XtreamVODKind]) async {
        guard let source, let server = source.serverURL, let user = source.username, let password = source.password,
              !server.isEmpty, !user.isEmpty, !password.isEmpty else {
            failBeforeDownload(.configuration, stage: .configuration, enabledKinds: enabledKinds)
            return
        }
        let store: XtreamVODCatalogStore
        do { store = try openStore() }
        catch {
            failBeforeDownload(.storage, stage: .storage, enabledKinds: enabledKinds)
            return
        }
        let secrets = LiveTVSnapshotSecrets(source: source)
        func safe(_ raw: String?, limit: Int) -> String? {
            guard let text = XtreamVODParser.clean(raw, limit: limit),
                  LiveTVSnapshotRedaction.isSafe(text, maximumBytes: limit * 4, secrets: secrets) else { return nil }
            return text
        }
        var firstError: Error?
        var succeeded = 0
        var stage = XtreamVODPipelineStage.authentication
        do {
            let authURL: URL
            do { authURL = try XtreamURLBuilder.apiURL(server: server, username: user, password: password) }
            catch { stage = .configuration; throw XtreamVODError.configuration }
            let authData = try await XtreamVODHTTP.fetch(authURL, session: session, maximumBytes: 1 * 1024 * 1024)
            try XtreamResponseParser.account(from: authData)
            XtreamVODDiagnostics.event("authenticated")
            for kind in enabledKinds {
                try Task.checkCancellation()
                setResult(.loading, kind: kind)
                let generation = UUID().uuidString
                do {
                progress?.stage = .downloading(kind)
                stage = .categories
                let categories = await categoryNames(kind: kind, server: server, user: user, password: password)
                stage = .download
                let url = try XtreamURLBuilder.vodAPIURL(server: server, username: user, password: password,
                                                         action: kind.catalogAction)
                // Panels often build the whole catalog before sending the first byte.
                let data = try await XtreamVODHTTP.fetch(url, session: session, maximumBytes: 96 * 1024 * 1024,
                                                         timeout: 180)
                stage = .parsing
                let decode = Task.detached(priority: .utility) { try XtreamVODParser.records(data) }
                let records = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
                let maximumRecords = kind == .movie ? 100_000 : 50_000
                guard records.count <= maximumRecords else { throw XtreamVODError.responseTooLarge }
                XtreamVODDiagnostics.event("decoded", kind: kind, count: records.count)
                stage = .persistence
                progress?.stage = .importing(kind)
                var accepted = 0, malformed = 0, duplicate = 0
                var seen = Set<Int>()
                var batch: [XtreamVODItem] = []
                batch.reserveCapacity(512)
                setCount(.init(processed: 0, total: records.count, accepted: 0, malformed: 0, duplicate: 0), kind: kind)
                for (index, record) in records.enumerated() {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    guard let id = record.remoteID, id > 0,
                          let title = safe(record.title, limit: 256) else {
                        malformed += 1
                        continueCount(index: index, total: records.count, accepted: accepted,
                                      malformed: malformed, duplicate: duplicate, kind: kind)
                        continue
                    }
                    guard seen.insert(id).inserted else {
                        duplicate += 1
                        continueCount(index: index, total: records.count, accepted: accepted,
                                      malformed: malformed, duplicate: duplicate, kind: kind)
                        continue
                    }
                    batch.append(.init(providerID: providerID, kind: kind, remoteID: id, title: title,
                                       category: safe(categories[record.categoryID ?? ""], limit: 128) ?? "Other",
                                       poster: XtreamVODParser.safeArtwork(record.poster, username: user, password: password),
                                       fileExtension: safe(record.fileExtension, limit: 8),
                                       summary: safe(record.summary, limit: 1000),
                                       genre: safe(record.genre, limit: 128),
                                       rating: safe(record.rating, limit: 16)))
                    if batch.count == 512 {
                        try await store.stage(batch, generation: generation)
                        accepted += batch.count
                        batch.removeAll(keepingCapacity: true)
                    }
                    continueCount(index: index, total: records.count, accepted: accepted,
                                  malformed: malformed, duplicate: duplicate, kind: kind)
                }
                if !batch.isEmpty { try await store.stage(batch, generation: generation); accepted += batch.count }
                setCount(.init(processed: records.count, total: records.count, accepted: accepted,
                               malformed: malformed, duplicate: duplicate), kind: kind)
                try Task.checkCancellation()
                if accepted == 0 {
                    // An empty answer never replaces a previously imported catalog.
                    await store.discard(providerID: providerID, kind: kind, generation: generation)
                    XtreamVODDiagnostics.failure(.download, kind: kind, error: XtreamVODError.emptyCatalog)
                    setResult(.empty, kind: kind)
                    continue
                }
                stage = .promotion
                try await store.promote(providerID: providerID, kind: kind, generation: generation)
                revision &+= 1
                succeeded += 1
                XtreamVODDiagnostics.event("promoted", kind: kind, count: accepted)
                setResult(.ready, kind: kind)
                } catch {
                    await store.discard(providerID: providerID, kind: kind, generation: generation)
                    XtreamVODDiagnostics.failure(stage, kind: kind, error: error)
                    setResult(result(for: error), kind: kind)
                    if firstError == nil {
                        firstError = error
                        progress?.failedStage = error is CancellationError ? nil : stage
                    }
                    if error is CancellationError { throw error }
                }
            }
            if succeeded > 0 {
                let refreshed = Date()
                lastSuccessfulRefresh[providerID] = refreshed
                defaults.set(refreshed, forKey: "kyro.iptvvod.lastRefresh.\(providerID.uuidString)")
            }
            let importedMovies = progress?.movies.accepted ?? 0
            let importedSeries = progress?.series.accepted ?? 0
            progress?.stage = firstError == nil ? .ready : .failed
            progress?.failure = firstError.flatMap(XtreamVODError.from)
            if let firstError {
                let reason = XtreamVODError.from(firstError)?.errorDescription ?? "The catalog could not be imported."
                progress?.message = succeeded > 0
                    ? "Some catalogs could not be imported: \(reason) Successful catalogs are available; previous catalogs are unchanged."
                    : reason
            } else {
                progress?.message = "\(importedMovies.formatted()) movies and \(importedSeries.formatted()) series imported."
            }
        } catch {
            if !(error is CancellationError), progress?.failedStage == nil {
                XtreamVODDiagnostics.failure(stage, kind: nil, error: error)
                progress?.failedStage = stage
            }
            let vodError = XtreamVODError.from(error)
            for kind in enabledKinds where catalogResult(kind) == .waiting || catalogResult(kind) == .loading {
                setResult(result(for: vodError ?? error), kind: kind)
            }
            progress?.stage = error is CancellationError ? .cancelled : .failed
            progress?.failure = vodError
            progress?.message = error is CancellationError ? "VOD import cancelled. Completed catalogs remain available."
                : vodError?.errorDescription ?? (error as? LocalizedError)?.errorDescription
                    ?? "VOD import failed. Previous catalogs are unchanged."
        }
    }

    private func catalogResult(_ kind: XtreamVODKind) -> XtreamVODCatalogResult {
        kind == .movie ? (progress?.movieResult ?? .notSelected) : (progress?.seriesResult ?? .notSelected)
    }

    private func setResult(_ result: XtreamVODCatalogResult, kind: XtreamVODKind) {
        if kind == .movie { progress?.movieResult = result } else { progress?.seriesResult = result }
    }

    private func result(for error: Error) -> XtreamVODCatalogResult {
        if error is CancellationError { return .cancelled }
        switch XtreamVODError.from(error) {
        case .unsupported: return .unsupported
        case .authentication: return .authentication
        default: return .failed
        }
    }

    private func continueCount(index: Int, total: Int, accepted: Int, malformed: Int,
                               duplicate: Int, kind: XtreamVODKind) {
        let processed = index + 1
        if processed % 256 == 0 || processed == total {
            setCount(.init(processed: processed, total: total, accepted: accepted,
                           malformed: malformed, duplicate: duplicate), kind: kind)
        }
    }

    private func setCount(_ count: XtreamVODImportCount, kind: XtreamVODKind) {
        if kind == .movie { progress?.movies = count } else { progress?.series = count }
    }

    private func categoryNames(kind: XtreamVODKind, server: String, user: String, password: String) async -> [String: String] {
        guard let url = try? XtreamURLBuilder.vodAPIURL(server: server, username: user, password: password,
                                                        action: kind.categoriesAction),
              let data = try? await XtreamVODHTTP.fetch(url, session: session, maximumBytes: 4 * 1024 * 1024),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            let id = (row["category_id"] as? String) ?? (row["category_id"] as? NSNumber)?.stringValue
            if let id, let name = XtreamVODParser.clean(row["category_name"] as? String, limit: 128) { result[id] = name }
        }
        return result
    }

    func page(providerID: UUID, kind: XtreamVODKind, query: String = "", offset: Int = 0) async -> [XtreamVODItem] {
        await readableStore?.page(providerID: providerID, kind: kind, query: query, offset: offset) ?? []
    }

    func count(providerID: UUID, kind: XtreamVODKind) async -> Int {
        await readableStore?.count(providerID: providerID, kind: kind) ?? 0
    }

    func refreshedAt(providerID: UUID) -> Date? {
        lastSuccessfulRefresh[providerID] ?? defaults.object(forKey: "kyro.iptvvod.lastRefresh.\(providerID.uuidString)") as? Date
    }

    /// Clearing cached VOD never deletes a provider or its keychain credentials.
    func clearCache(providerID: UUID) async {
        guard activeProviderID != providerID else { return }
        await readableStore?.remove(providerID: providerID)
        defaults.removeObject(forKey: "kyro.iptvvod.lastRefresh.\(providerID.uuidString)")
        lastSuccessfulRefresh[providerID] = nil
        cachedDetails = cachedDetails.filter { !$0.key.hasPrefix(providerID.uuidString) }
        revision &+= 1
    }

    func personalItems(providerID: UUID, kind: XtreamVODKind, favorites: Bool) async -> [XtreamVODItem] {
        let profile = AuthService.shared.profileId ?? "local"
        let prefix = "kyro.iptvvod.\(profile).\(providerID.uuidString):\(kind.rawValue):"
        var saved: [(Int, XtreamVODWatchState)] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let data = value as? Data,
                  let state = try? JSONDecoder().decode(XtreamVODWatchState.self, from: data),
                  favorites ? state.favorite : (state.position > 0 && !state.completed),
                  let id = Int(key.dropFirst(prefix.count).split(separator: ".").first ?? "") else { continue }
            saved.append((id, state))
        }
        saved.sort { $0.1.updatedAt > $1.1.updatedAt }
        var seen = Set<Int>()
        var result: [XtreamVODItem] = []
        for (id, _) in saved where seen.insert(id).inserted {
            if let item = await readableStore?.item(providerID: providerID, kind: kind, remoteID: id) { result.append(item) }
            if result.count == 100 { break }
        }
        return result
    }

    func detail(for item: XtreamVODItem, liveTV: LiveTVService? = nil) async throws -> XtreamVODDetail {
        let liveTV = liveTV ?? .shared
        if let cached = cachedDetails[item.id], Date().timeIntervalSince(cached.0) < 3600 { return cached.1 }
        guard let source = liveTV.xtreamVODConfiguration(for: item.providerID),
              let server = source.serverURL, let user = source.username, let password = source.password else {
            throw XtreamVODError.configuration
        }
        let url = try XtreamURLBuilder.vodAPIURL(server: server, username: user, password: password,
                                                 action: item.kind == .movie ? "get_vod_info" : "get_series_info",
                                                 itemID: item.remoteID)
        let data = try await XtreamVODHTTP.fetch(url, session: session, maximumBytes: 8 * 1024 * 1024)
        let detail = try await Task.detached(priority: .utility) { try XtreamVODParser.detail(data, kind: item.kind) }.value
        if cachedDetails.count > 100 { cachedDetails.removeAll() }
        cachedDetails[item.id] = (Date(), detail)
        return detail
    }

    func playbackURL(for item: XtreamVODItem, episode: XtreamVODEpisode? = nil,
                     liveTV: LiveTVService? = nil) throws -> URL {
        let liveTV = liveTV ?? .shared
        guard let source = liveTV.xtreamVODConfiguration(for: item.providerID),
              let server = source.serverURL, let user = source.username, let password = source.password else {
            throw XtreamVODError.configuration
        }
        return try XtreamURLBuilder.vodPlaybackURL(server: server, username: user, password: password,
                                                   kind: item.kind, itemID: episode?.remoteID ?? item.remoteID,
                                                   fileExtension: episode?.fileExtension ?? item.fileExtension)
    }

    private func stateKey(_ item: XtreamVODItem, episode: XtreamVODEpisode? = nil) -> String {
        let profile = AuthService.shared.profileId ?? "local"
        return "kyro.iptvvod.\(profile).\(item.id).\(episode?.remoteID ?? 0)"
    }

    func watchState(for item: XtreamVODItem, episode: XtreamVODEpisode? = nil) -> XtreamVODWatchState {
        guard let data = defaults.data(forKey: stateKey(item, episode: episode)),
              let state = try? JSONDecoder().decode(XtreamVODWatchState.self, from: data) else { return .init() }
        return state
    }

    func setFavorite(_ favorite: Bool, for item: XtreamVODItem) {
        var state = watchState(for: item)
        state.favorite = favorite
        state.updatedAt = .now
        save(state, for: item)
    }

    func saveProgress(position: Double, duration: Double, item: XtreamVODItem,
                      episode: XtreamVODEpisode? = nil) {
        guard position.isFinite, duration.isFinite, position >= 0, duration >= 0 else { return }
        var state = watchState(for: item, episode: episode)
        state.position = min(position, duration > 0 ? duration : position)
        state.duration = duration
        state.completed = duration > 0 && state.position / duration >= 0.95
        state.updatedAt = .now
        save(state, for: item, episode: episode)
    }

    private func save(_ state: XtreamVODWatchState, for item: XtreamVODItem, episode: XtreamVODEpisode? = nil) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey(item, episode: episode))
        revision &+= 1
    }

    func remove(providerID: UUID) async {
        if activeProviderID == providerID {
            work?.cancel()
            await work?.value
            work = nil
            activeProviderID = nil
        }
        await readableStore?.remove(providerID: providerID)
        defaults.removeObject(forKey: "kyro.iptvvod.lastRefresh.\(providerID.uuidString)")
        lastSuccessfulRefresh[providerID] = nil
        cachedDetails = cachedDetails.filter { !$0.key.hasPrefix(providerID.uuidString) }
        revision &+= 1
    }
}
#endif
