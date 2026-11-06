import Foundation
import Observation

struct UnifiedSiloIdentity: Equatable, Sendable {
    let serverID: String
    let accountID: String
    let profileID: String

    init(serverID: String, accountID: String, profileID: String) {
        self.serverID = serverID
        self.accountID = accountID
        self.profileID = profileID
    }

    init?(_ owner: SessionOwner?) {
        guard let owner else { return nil }
        self.init(serverID: owner.serverID, accountID: owner.accountID, profileID: owner.profileID)
    }
}

enum UnifiedSearchSourcePhase: Equatable, Sendable {
    case idle
    case debouncing
    case loading
    case loaded
    case failed
    case partialFailure
    case unavailable
}

struct UnifiedSearchSourceStatus: Equatable, Sendable {
    var phase: UnifiedSearchSourcePhase
    var resultCount: Int = 0
    var message: String? = nil

    static let idle = Self(phase: .idle)
}

enum UnifiedSearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case moviesAndTV
    case liveTV

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .moviesAndTV: "Movies & TV"
        case .liveTV: "Live TV"
        }
    }

    var showsMoviesAndTV: Bool { self != .liveTV }
    var showsLiveTV: Bool { self != .moviesAndTV }

    func seeAllFilter(for section: UnifiedSearchResultsSection) -> Self {
        switch section {
        case .moviesAndTV: .moviesAndTV
        case .liveTV: .liveTV
        }
    }
}

enum UnifiedSearchResultsSection: Sendable {
    case moviesAndTV
    case liveTV

    static let combinedPreviewLimit = 6
    static let liveTVPageSize = 60

    static func hasAdditionalResults(total: Int, visible: Int) -> Bool {
        max(0, total) > max(0, visible)
    }

    static func nextVisibleLimit(current: Int, total: Int) -> Int {
        min(max(0, total), max(0, current) + liveTVPageSize)
    }
}

/// Metadata safe to publish from the IPTV source. Rows are resolved against the catalog snapshot
/// that produced them; stream/logo URLs and provider credentials are intentionally omitted.
struct UnifiedLiveTVSearchResult: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let category: String
    let ordinal: Int
    let logoURL: URL?
}

struct UnifiedSearchIPTVCatalogSnapshot: Sendable {
    let providerID: UUID?
    let catalogRevision: Int
    let hasProvider: Bool
    let isLoading: Bool
    let errorMessage: String?
    let channels: [LiveTVChannel]

    var identity: LiveTVChannelSearchIndex.Identity? {
        providerID.map { LiveTVChannelSearchIndex.Identity(providerID: $0, catalogRevision: catalogRevision) }
    }
}

@MainActor
protocol UnifiedSearchSiloServing: AnyObject {
    var titleResults: [BrowseItem] { get }
    var peopleResults: [Person] { get }
    var requestResults: [RequestMediaResult] { get }
    var isLoading: Bool { get }
    var hasSearched: Bool { get }
    var errorMessage: String? { get }

    func performSearch(query: String) async
    func loadMore() async
    func cancelForQueryChange()
    func resetForIdentityChange()
}

/// Adapter around the existing catalog, people, episode, and request-search models. It does not
/// issue a second catalog request; the existing SearchViewModel remains the Silo API owner.
@MainActor
final class UnifiedSearchSiloAdapter: UnifiedSearchSiloServing {
    let searchModel: SearchViewModel
    let requestSearchModel: RequestSearchSectionViewModel

    init(searchModel: SearchViewModel,
         requestSearchModel: RequestSearchSectionViewModel) {
        self.searchModel = searchModel
        self.requestSearchModel = requestSearchModel
    }

    var titleResults: [BrowseItem] { searchModel.results }
    var peopleResults: [Person] { searchModel.people }
    var requestResults: [RequestMediaResult] { requestSearchModel.results }
    var isLoading: Bool {
        searchModel.isSearching || searchModel.isSearchingPeople || requestSearchModel.isLoading
    }
    var hasSearched: Bool { searchModel.hasSearched }
    var errorMessage: String? { searchModel.error?.message }

    func performSearch(query: String) async {
        async let catalog: Void = searchModel.performCoordinatedSearch(query: query)
        async let discovery: Void = requestSearchModel.performCoordinatedSearch(query)
        _ = await (catalog, discovery)
        await searchModel.waitForCoordinatedPeopleSearch()
    }

    func loadMore() async { await searchModel.loadMore() }

    func cancelForQueryChange() {
        searchModel.cancelCoordinatedSearch()
        requestSearchModel.resetForCoordinatedIdentityChange()
    }

    func resetForIdentityChange() {
        searchModel.resetForCoordinatedIdentityChange()
        requestSearchModel.resetForCoordinatedIdentityChange()
    }
}

extension LiveTVService {
    func unifiedSearchCatalogSnapshot() -> UnifiedSearchIPTVCatalogSnapshot {
        UnifiedSearchIPTVCatalogSnapshot(
            providerID: selectedProviderID,
            catalogRevision: channelCatalogRevision,
            hasProvider: !providers.isEmpty,
            isLoading: isLoading,
            errorMessage: errorMessage,
            channels: channels
        )
    }
}

/// Owns the shared query debounce and independent source lifecycles. Results/status are transient;
/// this type has no persistence and does not combine channel rows with Silo catalog rows.
@MainActor
@Observable
final class UnifiedSearchCoordinator {
    private(set) var query = ""
    private(set) var siloState: UnifiedSearchSourceStatus = .idle
    private(set) var liveTVState: UnifiedSearchSourceStatus = .idle
    private(set) var liveTVResults: [UnifiedLiveTVSearchResult] = []

    let silo: any UnifiedSearchSiloServing

    @ObservationIgnored private let indexStore: LiveTVChannelSearchIndexStore
    @ObservationIgnored private let catalogSnapshot: @MainActor () -> UnifiedSearchIPTVCatalogSnapshot
    @ObservationIgnored private let siloIdentityProvider: @MainActor () -> UnifiedSiloIdentity?
    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private let waitForDebounce: @MainActor (Duration) async -> Void

    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var siloGeneration = 0
    @ObservationIgnored private var liveTVGeneration = 0
    @ObservationIgnored private var siloIdentity: UnifiedSiloIdentity?
    @ObservationIgnored private var observedCatalogIdentity: LiveTVChannelSearchIndex.Identity?
    @ObservationIgnored private var observedHasProvider = false
    @ObservationIgnored private var indexedCatalogIdentity: LiveTVChannelSearchIndex.Identity?
    @ObservationIgnored private var buildingCatalogIdentity: LiveTVChannelSearchIndex.Identity?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var siloTask: Task<Void, Never>?
    @ObservationIgnored private var liveTVTask: Task<Void, Never>?
    @ObservationIgnored private var indexBuildTask: Task<Bool, Never>?
    @ObservationIgnored private var resumeAfterDismissal = false

    init(
        silo: any UnifiedSearchSiloServing,
        indexStore: LiveTVChannelSearchIndexStore = .shared,
        catalogSnapshot: @escaping @MainActor () -> UnifiedSearchIPTVCatalogSnapshot = {
            LiveTVService.shared.unifiedSearchCatalogSnapshot()
        },
        siloIdentityProvider: @escaping @MainActor () -> UnifiedSiloIdentity? = {
            UnifiedSiloIdentity(SessionOwner.current())
        },
        debounceDuration: Duration = .milliseconds(300),
        waitForDebounce: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.silo = silo
        self.indexStore = indexStore
        self.catalogSnapshot = catalogSnapshot
        self.siloIdentityProvider = siloIdentityProvider
        self.debounceDuration = debounceDuration
        self.waitForDebounce = waitForDebounce
        siloIdentity = siloIdentityProvider()
        if siloIdentity == nil {
            siloState = UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
        }
        let initialCatalog = catalogSnapshot()
        observedCatalogIdentity = initialCatalog.identity
        observedHasProvider = initialCatalog.hasProvider
        updateLiveTVAvailability(initialCatalog)
    }

    /// Call for every text edit. Both sources are cancelled/cleared immediately; one debounce then
    /// fans the query out to Silo and IPTV. This replaces the two existing per-screen debounce
    /// waits during Phase 3 integration.
    func onQueryChanged(_ newQuery: String) {
        query = newQuery
        synchronizeSiloIdentity(restartSearch: false)
        queryGeneration &+= 1
        siloGeneration &+= 1
        liveTVGeneration &+= 1
        let generation = queryGeneration
        debounceTask?.cancel()
        siloTask?.cancel()
        liveTVTask?.cancel()
        silo.cancelForQueryChange()
        liveTVResults = []

        guard !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debounceTask = nil
            siloState = siloIdentity == nil
                ? UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
                : .idle
            updateLiveTVAvailability(catalogSnapshot())
            return
        }

        siloState = siloIdentity == nil
            ? UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
            : UnifiedSearchSourceStatus(phase: .debouncing)
        liveTVState = UnifiedSearchSourceStatus(phase: .debouncing)
        debounceTask = Task { [weak self] in
            guard let self else { return }
            await waitForDebounce(debounceDuration)
            guard !Task.isCancelled, generation == queryGeneration else { return }
            debounceTask = nil
            startSearch(query: newQuery, generation: generation)
        }
    }

    /// Explicit identity synchronization hook for the Search view lifecycle. It also runs
    /// before dispatch and before publishing any Silo result, so an identity switch during I/O is
    /// rejected even if the UI has not yet delivered its change notification.
    func synchronizeSiloIdentity(restartSearch: Bool = true) {
        let nextIdentity = siloIdentityProvider()
        guard nextIdentity != siloIdentity else { return }
        siloIdentity = nextIdentity
        siloGeneration &+= 1
        siloTask?.cancel()
        siloTask = nil
        silo.resetForIdentityChange()
        if let nextIdentity {
            siloState = .idle
            if restartSearch, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                launchSiloSearch(query: query, queryToken: queryGeneration,
                                 identity: nextIdentity, siloToken: siloGeneration)
            }
        } else {
            siloState = UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
        }
    }

    var isSiloIdentityCurrent: Bool { siloIdentity == siloIdentityProvider() }

    func isLiveTVCatalogCurrent(providerID: UUID?, revision: Int) -> Bool {
        observedCatalogIdentity == providerID.map {
            LiveTVChannelSearchIndex.Identity(providerID: $0, catalogRevision: revision)
        }
    }

    /// Stops source work when Search leaves the active navigation surface. Completed results stay
    /// available when a detail presentation returns; an interrupted search is restarted on reentry.
    func cancelForDismissal() {
        let wasPending = [siloState.phase, liveTVState.phase].contains { phase in
            phase == .loading || phase == .debouncing
        }
        guard wasPending else { return }
        resumeAfterDismissal = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        queryGeneration &+= 1
        siloGeneration &+= 1
        liveTVGeneration &+= 1
        debounceTask?.cancel()
        siloTask?.cancel()
        liveTVTask?.cancel()
        indexBuildTask?.cancel()
        debounceTask = nil
        siloTask = nil
        liveTVTask = nil
        indexBuildTask = nil
        buildingCatalogIdentity = nil
        silo.cancelForQueryChange()
        liveTVResults = []
        siloState = siloIdentity == nil
            ? UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
            : .idle
        updateLiveTVAvailability(catalogSnapshot())
    }

    func resumeAfterDismissalIfNeeded() {
        guard resumeAfterDismissal else { return }
        resumeAfterDismissal = false
        onQueryChanged(query)
    }

    /// Resolves a displayed safe row to a fresh channel record only at tap time. The full record
    /// (including its stream URL) remains a local result of this method, never stored in search state.
    func resolveChannel(for result: UnifiedLiveTVSearchResult) async -> LiveTVChannel? {
        guard liveTVResults.contains(where: { $0.id == result.id }) else { return nil }
        let snapshot = catalogSnapshot()
        guard let identity = snapshot.identity, identity == observedCatalogIdentity,
              let providerID = snapshot.providerID else { return nil }
        let channels = snapshot.channels
        let worker = Task.detached(priority: .userInitiated) { () -> LiveTVChannel? in
            for (offset, channel) in channels.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard channel.id == result.id,
                      LiveTVRecentChannel.belongs(channel.id, to: providerID) else { continue }
                return channel
            }
            return nil
        }
        let resolved = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, catalogSnapshot().identity == identity,
              liveTVResults.contains(where: { $0.id == result.id }) else { return nil }
        return resolved
    }

    /// Call when the active IPTV provider/catalog changes. A same-identity snapshot reuses the
    /// existing index. A new revision/provider cancels the old query, rebuilds once, then searches
    /// the still-current query without adding a second text debounce.
    func catalogDidChange() async {
        let snapshot = catalogSnapshot()
        guard snapshot.identity != observedCatalogIdentity || snapshot.hasProvider != observedHasProvider else {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateLiveTVAvailability(snapshot)
            }
            return
        }
        let previousIdentity = observedCatalogIdentity
        observedCatalogIdentity = snapshot.identity
        observedHasProvider = snapshot.hasProvider
        liveTVGeneration &+= 1
        let token = liveTVGeneration
        liveTVTask?.cancel()
        liveTVTask = nil
        if buildingCatalogIdentity != snapshot.identity {
            indexBuildTask?.cancel()
            indexBuildTask = nil
            buildingCatalogIdentity = nil
        }
        if previousIdentity != snapshot.identity {
            indexedCatalogIdentity = nil
            await indexStore.invalidate(providerID: previousIdentity?.providerID)
        }
        liveTVResults = []
        updateLiveTVAvailability(snapshot)

        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let queryToken = queryGeneration
            let currentQuery = query
            liveTVTask = Task { [weak self] in
                guard let self else { return }
                await runLiveTVSearch(query: currentQuery, queryToken: queryToken,
                                      liveToken: token, expected: snapshot.identity)
            }
        }
    }

    /// Optional retry entry point for source-local retry buttons.
    func retrySilo() {
        synchronizeSiloIdentity(restartSearch: false)
        guard let siloIdentity,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        siloGeneration &+= 1
        launchSiloSearch(query: query, queryToken: queryGeneration,
                         identity: siloIdentity, siloToken: siloGeneration)
    }

    func retryLiveTV() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        liveTVGeneration &+= 1
        let snapshot = catalogSnapshot()
        observedCatalogIdentity = snapshot.identity
        observedHasProvider = snapshot.hasProvider
        liveTVTask?.cancel()
        let token = liveTVGeneration
        liveTVTask = Task { [weak self] in
            guard let self else { return }
            await runLiveTVSearch(query: query, queryToken: queryGeneration,
                                  liveToken: token, expected: snapshot.identity)
        }
    }

    /// Keeps the catalog source's existing continuation/paging behavior available to the
    /// Movies & TV section. Paging never starts another request for the current query while a new
    /// query or Silo identity is pending.
    func loadMoreSilo() async {
        guard let identity = siloIdentity,
              identity == siloIdentityProvider(),
              !silo.isLoading else { return }
        let queryToken = queryGeneration
        let siloToken = siloGeneration
        await silo.loadMore()
        guard queryToken == queryGeneration, siloToken == siloGeneration,
              identity == siloIdentityProvider(), identity == siloIdentity else { return }
        refreshSiloStatus()
    }

    private func startSearch(query: String, generation: Int) {
        synchronizeSiloIdentity(restartSearch: false)
        guard generation == queryGeneration else { return }
        let snapshot = catalogSnapshot()
        if snapshot.identity != observedCatalogIdentity {
            observedCatalogIdentity = snapshot.identity
            observedHasProvider = snapshot.hasProvider
            liveTVGeneration &+= 1
        }
        let liveToken = liveTVGeneration
        if let siloIdentity {
            launchSiloSearch(query: query, queryToken: generation,
                             identity: siloIdentity, siloToken: siloGeneration)
        } else {
            siloState = UnifiedSearchSourceStatus(phase: .unavailable, message: "Sign in to search Silo.")
        }
        liveTVTask?.cancel()
        liveTVState = UnifiedSearchSourceStatus(phase: .loading)
        liveTVTask = Task { [weak self] in
            guard let self else { return }
            await runLiveTVSearch(query: query, queryToken: generation,
                                  liveToken: liveToken, expected: snapshot.identity)
        }
    }

    private func launchSiloSearch(query: String, queryToken: Int,
                                  identity: UnifiedSiloIdentity, siloToken: Int) {
        siloTask?.cancel()
        siloState = UnifiedSearchSourceStatus(phase: .loading)
        siloTask = Task { [weak self] in
            guard let self else { return }
            await silo.performSearch(query: query)
            guard !Task.isCancelled, queryToken == queryGeneration,
                  siloToken == siloGeneration, identity == siloIdentity,
                  identity == siloIdentityProvider() else {
                synchronizeSiloIdentity(restartSearch: true)
                return
            }
            refreshSiloStatus()
        }
    }

    private func refreshSiloStatus() {
        let count = silo.titleResults.count + silo.peopleResults.count + silo.requestResults.count
        if silo.isLoading {
            siloState = UnifiedSearchSourceStatus(phase: .loading, resultCount: count)
        } else if let message = silo.errorMessage {
            siloState = UnifiedSearchSourceStatus(phase: count > 0 ? .partialFailure : .failed,
                                                  resultCount: count, message: message)
        } else if silo.hasSearched || count > 0 {
            siloState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: count)
        } else {
            siloState = .idle
        }
    }

    private func runLiveTVSearch(query: String, queryToken: Int, liveToken: Int,
                                 expected: LiveTVChannelSearchIndex.Identity?) async {
        guard queryToken == queryGeneration, liveToken == liveTVGeneration else { return }
        let snapshot = catalogSnapshot()
        guard snapshot.identity == expected else {
            rejectChangedCatalog(snapshot, queryToken: queryToken)
            return
        }
        guard let expected, let providerID = snapshot.providerID else {
            updateLiveTVAvailability(snapshot)
            return
        }
        guard !snapshot.channels.isEmpty else {
            updateLiveTVAvailability(snapshot)
            return
        }

        liveTVState = UnifiedSearchSourceStatus(phase: .loading)
        guard await installIndex(for: snapshot, identity: expected),
              !Task.isCancelled, queryToken == queryGeneration,
              liveToken == liveTVGeneration else { return }
        let matches = await indexStore.search(query: query, providerID: providerID,
                                              catalogRevision: expected.catalogRevision)
        guard !Task.isCancelled, queryToken == queryGeneration,
              liveToken == liveTVGeneration else { return }
        let current = catalogSnapshot()
        guard current.identity == expected else {
            rejectChangedCatalog(current, queryToken: queryToken)
            return
        }
        guard let matches else {
            liveTVState = UnifiedSearchSourceStatus(phase: .failed,
                                                   message: "Live TV search was canceled or became outdated.")
            return
        }

        // Validate IDs against the same provider/catalog snapshot off-main. The snapshot holds
        // full channel records only for this task; only safe display metadata crosses back.
        let resolutionWorker = Task.detached(priority: .userInitiated) {
            () -> [UnifiedLiveTVSearchResult]? in
            var channelsByID: [String: LiveTVChannel] = [:]
            channelsByID.reserveCapacity(current.channels.count)
            for (offset, channel) in current.channels.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard LiveTVRecentChannel.belongs(channel.id, to: providerID) else { continue }
                if channelsByID[channel.id] == nil { channelsByID[channel.id] = channel }
            }
            var resolved: [UnifiedLiveTVSearchResult] = []
            resolved.reserveCapacity(matches.count)
            for (offset, match) in matches.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard let channel = channelsByID[match.channelID] else { continue }
                resolved.append(UnifiedLiveTVSearchResult(id: channel.id, name: channel.name,
                                                          category: channel.category,
                                                          ordinal: match.ordinal,
                                                          logoURL: Self.safeLogoURL(channel.logoURL)))
            }
            return Task.isCancelled ? nil : resolved
        }
        let resolved = await withTaskCancellationHandler {
            await resolutionWorker.value
        } onCancel: {
            resolutionWorker.cancel()
        }
        guard !Task.isCancelled, queryToken == queryGeneration,
              liveToken == liveTVGeneration, let resolved else { return }
        guard resolved.count == matches.count else {
            liveTVResults = []
            liveTVState = UnifiedSearchSourceStatus(phase: .failed,
                                                   message: "The Live TV catalog changed; search again.")
            return
        }
        liveTVResults = resolved
        liveTVState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: resolved.count)
    }

    private func installIndex(for snapshot: UnifiedSearchIPTVCatalogSnapshot,
                              identity: LiveTVChannelSearchIndex.Identity) async -> Bool {
        if indexedCatalogIdentity == identity { return true }
        if buildingCatalogIdentity == identity, let indexBuildTask {
            return await indexBuildTask.value && indexedCatalogIdentity == identity
        }
        indexBuildTask?.cancel()
        buildingCatalogIdentity = identity
        let worker = Task { [indexStore] in
            await indexStore.replaceCatalog(providerID: identity.providerID,
                                            catalogRevision: identity.catalogRevision,
                                            channels: snapshot.channels)
        }
        indexBuildTask = worker
        let built = await worker.value
        guard built, !Task.isCancelled, catalogSnapshot().identity == identity,
              buildingCatalogIdentity == identity else { return false }
        indexedCatalogIdentity = identity
        buildingCatalogIdentity = nil
        indexBuildTask = nil
        return true
    }

    private func rejectChangedCatalog(_ snapshot: UnifiedSearchIPTVCatalogSnapshot,
                                      queryToken: Int) {
        guard queryToken == queryGeneration else { return }
        observedCatalogIdentity = snapshot.identity
        observedHasProvider = snapshot.hasProvider
        liveTVGeneration &+= 1
        liveTVResults = []
        updateLiveTVAvailability(snapshot)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = liveTVGeneration
            liveTVTask = Task { [weak self] in
                guard let self else { return }
                await runLiveTVSearch(query: query, queryToken: queryToken,
                                      liveToken: token, expected: snapshot.identity)
            }
        }
    }

    private func updateLiveTVAvailability(_ snapshot: UnifiedSearchIPTVCatalogSnapshot) {
        if !snapshot.hasProvider {
            liveTVState = UnifiedSearchSourceStatus(phase: .unavailable,
                                                   message: "No Live TV provider is configured.")
        } else if let error = snapshot.errorMessage, snapshot.channels.isEmpty {
            liveTVState = UnifiedSearchSourceStatus(phase: .failed, message: error)
        } else if snapshot.isLoading && snapshot.channels.isEmpty {
            liveTVState = UnifiedSearchSourceStatus(phase: .loading)
        } else {
            liveTVState = UnifiedSearchSourceStatus(phase: .loaded, resultCount: 0)
        }
    }

    nonisolated private static func safeLogoURL(_ url: URL?) -> URL? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        // Strip embedded userinfo and likely credential/signature query values before keeping a
        // logo URL in transient UI state. Plain paths and benign query values remain usable.
        components.user = nil
        components.password = nil
        let credentialMarkers = ["token", "auth", "key", "password", "secret", "credential", "signature", "sig"]
        if let queryItems = components.queryItems,
           queryItems.contains(where: { item in
               let key = item.name.lowercased()
               return credentialMarkers.contains(where: { key.contains($0) })
           }) {
            components.queryItems = nil
        }
        components.fragment = nil
        return components.url
    }
}
