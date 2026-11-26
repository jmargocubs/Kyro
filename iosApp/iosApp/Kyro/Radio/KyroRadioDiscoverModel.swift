#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// Discover's results: one query, loaded a page at a time. Typing waits for
/// a pause (debounce); a new query cancels the previous request, and a late
/// response for an older query is dropped.
@MainActor @Observable
final class KyroRadioDiscoverModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var query = KyroRadioQuery()
    private(set) var stations: [KyroRadioStation] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = false
    private(set) var loadMoreFailed = false
    /// Genres for browsing, most stations first.
    private(set) var genres: [KyroRadioFacet] = []

    @ObservationIgnored private let client: KyroRadioBrowserClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var genresTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private let debounceNanoseconds: UInt64

    /// Discover never loads more than this many stations for one query.
    static let maxStations = 400

    init(client: KyroRadioBrowserClient = .shared, debounceNanoseconds: UInt64 = 350_000_000) {
        self.client = client
        self.debounceNanoseconds = debounceNanoseconds
    }

    var hasActiveFilters: Bool { query.countryCode != nil || query.state != nil || query.language != nil || query.tag != nil }

    /// A new query. Text changes wait for typing to pause; filter changes load now.
    func update(_ newQuery: KyroRadioQuery, debounce: Bool = false) {
        guard newQuery != query || phase == .idle else { return }
        query = newQuery
        start(debounce: debounce)
    }

    /// First load when Discover appears; later appearances keep the results.
    func loadIfNeeded(_ initial: KyroRadioQuery) {
        guard phase == .idle else { return }
        query = initial
        start(debounce: false)
    }

    func retry() { start(debounce: false) }

    func loadMore() {
        guard canLoadMore, !isLoadingMore, phase == .loaded, stations.count < Self.maxStations else { return }
        let generation = generation
        let offset = nextOffset
        isLoadingMore = true
        loadMoreFailed = false
        task = Task { [weak self] in
            await self?.fetch(offset: offset, generation: generation)
        }
    }

    /// Waits for the current load (tests).
    func waitForLoad() async { await task?.value }

    func loadGenresIfNeeded() {
        guard genres.isEmpty, genresTask == nil else { return }
        let client = client
        genresTask = Task { [weak self] in
            let tags = (try? await client.facets(.tag, limit: 40)) ?? []
            guard let self else { return }
            self.genres = tags
            self.genresTask = nil
        }
    }

    private func start(debounce: Bool) {
        task?.cancel()
        generation += 1
        let generation = generation
        nextOffset = 0
        canLoadMore = false
        isLoadingMore = false
        loadMoreFailed = false
        phase = .loading
        stations = []
        let delay = debounce ? debounceNanoseconds : 0
        task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.fetch(offset: 0, generation: generation)
        }
    }

    private func fetch(offset: Int, generation: Int) async {
        let query = query
        let result: Result<[KyroRadioStation], Error>
        do {
            result = .success(try await client.stations(query, offset: offset))
        } catch {
            result = .failure(error)
        }
        // A newer query owns the results now.
        guard generation == self.generation, !Task.isCancelled else { return }
        isLoadingMore = false
        switch result {
        case .success(let page):
            var seen = Set(stations.map(\.id))
            stations += page.filter { $0.isPlayable && seen.insert($0.id).inserted }
            nextOffset = offset + page.count
            canLoadMore = page.count == KyroRadioQuery.pageSize && stations.count < Self.maxStations
            phase = .loaded
        case .failure(let error):
            if offset == 0 {
                phase = .failed(Self.message(for: error))
            } else {
                loadMoreFailed = true
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error as? KyroRadioBrowserError {
        case .badResponse?: "Radio Browser sent a response Kyro couldn’t read. Try again in a moment."
        default: "Couldn’t reach Radio Browser. Check your connection and try again."
        }
    }
}
#endif
