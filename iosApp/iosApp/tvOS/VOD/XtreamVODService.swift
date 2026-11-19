#if os(tvOS)
import Foundation
import Observation

enum XtreamVODHTTP {
    /// Enforces the cap while receiving bytes, before a provider can fill memory without bound.
    static func fetch(_ url: URL, session: URLSession, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw XtreamVODError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw XtreamVODError.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw XtreamVODError.authentication }
        if http.statusCode == 404 || http.statusCode == 405 { throw XtreamVODError.unsupported }
        guard (200..<300).contains(http.statusCode) else { throw XtreamVODError.unavailable }
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
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        data.append(contentsOf: chunk)
        return data
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
    private let store: XtreamVODCatalogStore?
    private let session: URLSession
    private let defaults: UserDefaults
    private var work: Task<Void, Never>?
    private var cachedDetails: [String: (Date, XtreamVODDetail)] = [:]
    private(set) var lastSuccessfulRefresh: [UUID: Date] = [:]

    init(store: XtreamVODCatalogStore? = try? XtreamVODCatalogStore(),
         session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.session = session
        self.defaults = defaults
    }

    func refresh(providerID: UUID, liveTV: LiveTVService? = nil) async {
        let liveTV = liveTV ?? .shared
        guard work == nil, let provider = liveTV.providers.first(where: { $0.id == providerID }) else { return }
        let enabledKinds = XtreamVODKind.allCases.filter { $0 == .movie ? provider.vodMoviesEnabled : provider.vodSeriesEnabled }
        guard !enabledKinds.isEmpty else { return }
        guard let source = liveTV.xtreamVODConfiguration(for: providerID), store != nil else {
            progress = XtreamVODImportProgress(providerID: providerID)
            progress?.stage = .failed
            progress?.failure = .unavailable
            progress?.message = "The selected VOD catalogs could not be opened. Check provider credentials and storage, then retry."
            progress?.movieResult = enabledKinds.contains(.movie) ? .failed : .notSelected
            progress?.seriesResult = enabledKinds.contains(.series) ? .failed : .notSelected
            return
        }
        activeProviderID = providerID
        progress = XtreamVODImportProgress(providerID: providerID)
        progress?.movieResult = enabledKinds.contains(.movie) ? .waiting : .notSelected
        progress?.seriesResult = enabledKinds.contains(.series) ? .waiting : .notSelected
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(providerID: providerID, source: source, enabledKinds: enabledKinds)
        }
        work = task
        await task.value
        if activeProviderID == providerID { activeProviderID = nil; work = nil }
    }

    func cancel() { work?.cancel() }

    private func performRefresh(providerID: UUID, source: LiveTVSourceConfiguration, enabledKinds: [XtreamVODKind]) async {
        guard let store, let server = source.serverURL, let user = source.username, let password = source.password else { return }
        let secrets = LiveTVSnapshotSecrets(source: source)
        func safe(_ raw: String?, limit: Int) -> String? {
            guard let text = XtreamVODParser.clean(raw, limit: limit),
                  LiveTVSnapshotRedaction.isSafe(text, maximumBytes: limit * 4, secrets: secrets) else { return nil }
            return text
        }
        var firstError: Error?
        var succeeded = 0
        do {
            let authURL = try XtreamURLBuilder.apiURL(server: server, username: user, password: password)
            let authData = try await XtreamVODHTTP.fetch(authURL, session: session, maximumBytes: 1 * 1024 * 1024)
            try XtreamResponseParser.account(from: authData)
            for kind in enabledKinds {
                try Task.checkCancellation()
                setResult(.loading, kind: kind)
                let generation = UUID().uuidString
                do {
                progress?.stage = .downloading(kind)
                let categories = await categoryNames(kind: kind, server: server, user: user, password: password)
                let url = try XtreamURLBuilder.vodAPIURL(server: server, username: user, password: password,
                                                         action: kind.catalogAction)
                let data = try await XtreamVODHTTP.fetch(url, session: session, maximumBytes: 96 * 1024 * 1024)
                let decode = Task.detached(priority: .utility) { try XtreamVODParser.records(data) }
                let records = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
                let maximumRecords = kind == .movie ? 100_000 : 50_000
                guard records.count <= maximumRecords else { throw XtreamVODError.responseTooLarge }
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
                try await store.promote(providerID: providerID, kind: kind, generation: generation)
                revision &+= 1
                succeeded += 1
                setResult(accepted > 0 ? .ready : .empty, kind: kind)
                } catch {
                    await store.discard(providerID: providerID, kind: kind, generation: generation)
                    setResult(result(for: error), kind: kind)
                    if firstError == nil { firstError = error }
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
            progress?.failure = firstError as? XtreamVODError
            progress?.message = firstError == nil
                ? "\(importedMovies) movies and \(importedSeries) series imported."
                : "Some selected catalogs could not be imported. Successful catalogs are available; previous catalogs are unchanged for failed imports."
        } catch {
            for kind in enabledKinds where catalogResult(kind) == .waiting || catalogResult(kind) == .loading {
                setResult(result(for: error), kind: kind)
            }
            progress?.stage = error is CancellationError ? .cancelled : .failed
            progress?.failure = error as? XtreamVODError
            progress?.message = error is CancellationError ? "VOD import cancelled. Completed catalogs remain available."
                : (error as? LocalizedError)?.errorDescription ?? "VOD import failed. Previous catalogs are unchanged."
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
        switch error as? XtreamVODError {
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
        await store?.page(providerID: providerID, kind: kind, query: query, offset: offset) ?? []
    }

    func count(providerID: UUID, kind: XtreamVODKind) async -> Int {
        await store?.count(providerID: providerID, kind: kind) ?? 0
    }

    func refreshedAt(providerID: UUID) -> Date? {
        lastSuccessfulRefresh[providerID] ?? defaults.object(forKey: "kyro.iptvvod.lastRefresh.\(providerID.uuidString)") as? Date
    }

    /// Clearing cached VOD never deletes a provider or its keychain credentials.
    func clearCache(providerID: UUID) async {
        guard activeProviderID != providerID else { return }
        await store?.remove(providerID: providerID)
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
            if let item = await store?.item(providerID: providerID, kind: kind, remoteID: id) { result.append(item) }
            if result.count == 100 { break }
        }
        return result
    }

    func detail(for item: XtreamVODItem, liveTV: LiveTVService? = nil) async throws -> XtreamVODDetail {
        let liveTV = liveTV ?? .shared
        if let cached = cachedDetails[item.id], Date().timeIntervalSince(cached.0) < 3600 { return cached.1 }
        guard let source = liveTV.xtreamVODConfiguration(for: item.providerID),
              let server = source.serverURL, let user = source.username, let password = source.password else {
            throw XtreamVODError.unavailable
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
            throw XtreamVODError.unavailable
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
        await store?.remove(providerID: providerID)
        defaults.removeObject(forKey: "kyro.iptvvod.lastRefresh.\(providerID.uuidString)")
        lastSuccessfulRefresh[providerID] = nil
        cachedDetails = cachedDetails.filter { !$0.key.hasPrefix(providerID.uuidString) }
        revision &+= 1
    }
}
#endif
