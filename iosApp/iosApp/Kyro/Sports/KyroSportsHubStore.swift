import Foundation

// The hub's view model: loads a bounded, provider-normalized NFL window and
// exposes mutually exclusive, render-ready sections plus explicit page state.
//
// Concurrency: `@MainActor` and `@Observable`, matching `AICapabilities` and
// `RequestsFeatureStore`. Networking and decoding run off the main actor in
// the client; date mapping, sorting and grouping are explicitly detached so
// the actor is reserved for small state assignments.
//
// Polling is deliberately conservative. The hub refreshes scores only while
// the page is visible, and only when a game is live or about to start, at the
// interval `refreshInterval(for:)` returns. A page with no live games does not
// poll at all.

@MainActor
@Observable
final class KyroSportsHubStore {
    // MARK: Page state

    enum Phase: Equatable {
        /// Nothing attempted yet.
        case idle
        /// First load in flight and nothing cached to draw.
        case loading
        /// Games are present.
        case loaded
        /// Load failed and there is nothing on screen.
        case failed(KyroSportsDataError)
        /// Device reports no network.
        case offline
    }

    private(set) var phase: Phase = .idle
    private(set) var sections: [KyroSportsGameSection] = []
    private(set) var featuredEvent: KyroSportsGame?
    private(set) var selectedDashboardMode: KyroSportsDashboardMode = .upcoming
    private(set) var showsFutureSchedule = false
    /// True when the rendered games came from cache after a failed refresh.
    private(set) var isShowingStaleData = false
    /// Set when a refresh failed but earlier data is still on screen, so the
    /// page can show a quiet notice without blanking.
    private(set) var lastRefreshError: KyroSportsDataError?

    var selectedLeague: KyroSportLeague = .nfl {
        didSet {
            guard oldValue != selectedLeague else { return }
            // Only NFL has a decoder in S2A. Switching to another league
            // clears the page rather than leaving NFL rows under an NBA chip.
            sections = []
            featuredEvent = nil
            selectedDashboardMode = .upcoming
            showsFutureSchedule = false
            hasResolvedInitialDashboardMode = false
            phase = .idle
            isShowingStaleData = false
            lastRefreshError = nil
            generation += 1
        }
    }

    var availableLeagues: [KyroSportLeague] { KyroSportLeague.allCases }

    var visibleSections: [KyroSportsGameSection] {
        KyroSportsDashboard.visibleSections(
            from: sections,
            mode: selectedDashboardMode,
            includesFuture: showsFutureSchedule
        )
    }

    var dashboardEmptyState: KyroSportsDashboardEmptyState? {
        KyroSportsDashboard.emptyState(
            for: selectedDashboardMode,
            in: sections,
            includesFuture: showsFutureSchedule
        )
    }

    var hasFutureSchedule: Bool {
        KyroSportsDashboard.hasFutureGames(in: sections)
    }

    // MARK: Dependencies

    private let providerChain: KyroSportsProviderChain
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// Bumped on every load so a slow response cannot overwrite a newer one.
    private var generation = 0
    private var hasResolvedInitialDashboardMode = false

    init(
        espnClient: ESPNAPIClient = ESPNAPIClient(),
        sleeperClient: SleeperAPIClient = SleeperAPIClient(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providerChain = KyroSportsProviderChain(providers: [
            ESPNSportsProvider(client: espnClient, calendar: calendar),
            SleeperSportsProvider(client: sleeperClient, calendar: calendar)
        ])
        self.calendar = calendar
        self.now = now
    }

    /// Sleeper-only initializer retained for isolated fallback tests.
    init(
        client: SleeperAPIClient,
        season: String? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providerChain = KyroSportsProviderChain(providers: [
            SleeperSportsProvider(
                client: client,
                seasonOverride: season.flatMap(Int.init),
                calendar: calendar
            )
        ])
        self.calendar = calendar
        self.now = now
    }

    init(
        providers: [any KyroSportsProviding],
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providerChain = KyroSportsProviderChain(providers: providers)
        self.calendar = calendar
        self.now = now
    }

    // MARK: Loading

    func selectDashboardMode(_ mode: KyroSportsDashboardMode) {
        guard selectedDashboardMode != mode else { return }
        selectedDashboardMode = mode
    }

    func toggleFutureSchedule() {
        guard hasFutureSchedule else { return }
        showsFutureSchedule.toggle()
    }

    /// Load or refresh the hub for the selected league.
    ///
    /// - Parameter force: bypasses the cached section data and refetches, used
    ///   by pull-to-refresh and by the live poll.
    func load(force: Bool = false) async {
        guard selectedLeague == .nfl else {
            // S2A ships NFL only. Other chips remain visible but inert.
            sections = []
            featuredEvent = nil
            phase = .idle
            return
        }
        guard !isRefreshInFlight else { return }

        generation += 1
        let generation = generation
        isRefreshInFlight = true
        defer { isRefreshInFlight = false }

        if sections.isEmpty {
            phase = .loading
        }

        do {
            let groupingDate = now()
            let result = try await providerChain.fetchNFLWindow(now: groupingDate, force: force)
            guard generation == self.generation, !Task.isCancelled else { return }
            let games = result.games
            let groupingCalendar = calendar
            let grouped = try await sportsDetachedValue {
                KyroSportsSectioning.sections(from: games, now: groupingDate, calendar: groupingCalendar)
            }
            guard generation == self.generation, !Task.isCancelled else { return }

            let featured = KyroSportsDashboard.featuredEvent(from: grouped, now: groupingDate)
            let initialMode = KyroSportsDashboard.defaultMode(for: grouped)

            // A 304 or an unchanged live response should not invalidate every
            // visible card. Observation reports writes, not semantic changes,
            // so guard all render-facing assignments explicitly.
            if sections != grouped { sections = grouped }
            if featuredEvent != featured { featuredEvent = featured }
            if !hasResolvedInitialDashboardMode {
                if selectedDashboardMode != initialMode { selectedDashboardMode = initialMode }
                hasResolvedInitialDashboardMode = true
            }
            if showsFutureSchedule, !KyroSportsDashboard.hasFutureGames(in: grouped) {
                showsFutureSchedule = false
            }
            if phase != .loaded { phase = .loaded }
            if isShowingStaleData != result.isStale { isShowingStaleData = result.isStale }
            if lastRefreshError != result.refreshError { lastRefreshError = result.refreshError }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            let apiError = error as? KyroSportsDataError ?? .offline
            if apiError == .cancelled { return }
            if sections.isEmpty {
                phase = apiError == .offline ? .offline : .failed(apiError)
            } else {
                // Keep the games on screen and surface a quiet notice.
                if lastRefreshError != apiError { lastRefreshError = apiError }
                if !isShowingStaleData { isShowingStaleData = true }
            }
        }
    }

    private var isRefreshInFlight = false

    // MARK: Polling

    /// True when the page should keep a refresh timer running.
    var shouldPoll: Bool {
        guard selectedLeague == .nfl else { return false }
        return sections.contains { section in
            section.games.contains { game in
                game.status.isLive || isStartingSoon(game)
            }
        }
    }

    /// Seconds until the next score refresh. Live games refresh fast; a game
    /// within an hour of kickoff refreshes slowly so the status flips promptly
    /// without hammering Sleeper.
    var refreshInterval: TimeInterval? {
        guard selectedLeague == .nfl else { return nil }
        let games = sections.flatMap(\.games)
        if games.contains(where: { $0.status.isLive }) { return 20 }
        if games.contains(where: isStartingSoon) { return 120 }
        return nil
    }

    private func isStartingSoon(_ game: KyroSportsGame) -> Bool {
        guard game.status.isScheduled, let start = game.startTime else { return false }
        let delta = start.timeIntervalSince(now())
        return delta <= 3600 && delta > -1800
    }
}

/// A detached transform must not outlive a cancelled page load. Detached tasks
/// do not inherit cancellation, so bridge it explicitly and check on both
/// sides of the short synchronous transform.
private func sportsDetachedValue<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let task = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
