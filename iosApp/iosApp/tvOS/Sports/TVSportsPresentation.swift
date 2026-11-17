#if os(tvOS)
import Foundation

// Pure presentation rules for the Apple TV Sports Hub. No SwiftUI here, so the
// feed filtering, playback banner and focus restoration are unit-testable. Data,
// provider fallback, caching, stream matching and playback stay in the shared
// `KyroSportsHubStore`, `KyroSportsStreamMatcher` and `KyroSportsPlaybackCoordinator`.

/// The three feeds of the TV Sports Hub.
enum TVSportsMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case upcoming
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .upcoming: "Upcoming"
        case .recent: "Recent"
        }
    }

    /// Live is not tied to a day; the other two browse days.
    var usesDayStrip: Bool { self != .live }
}

enum TVSportsFeed {
    /// Games for a feed. `live` comes from the store's cross-day live list; the rest are
    /// filtered from the selected day's schedule, in the store's order.
    static func games(mode: TVSportsMode, live: [KyroSportsGame], schedule: [KyroSportsGame]) -> [KyroSportsGame] {
        switch mode {
        case .live:
            return live
        case .upcoming:
            return schedule.filter { $0.status.isScheduled || $0.status == .postponed || $0.status == .suspended }
        case .recent:
            return schedule.filter { $0.status.isFinal }
        }
    }

    /// Days offered by the strip. Upcoming looks forward from today, Recent looks back,
    /// newest first. Live has no strip.
    static func days(mode: TVSportsMode, browseDays: [Date], now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        switch mode {
        case .live:
            return []
        case .upcoming:
            return browseDays.filter { $0 >= today }.sorted()
        case .recent:
            return browseDays.filter { $0 <= today }.sorted(by: >)
        }
    }

    /// The day a feed opens on.
    static func defaultDay(now: Date, calendar: Calendar) -> Date { calendar.startOfDay(for: now) }

    /// A live event starts playback on select. Everything else opens its details.
    static func selectionAction(for game: KyroSportsGame) -> SelectionAction {
        KyroSportsPlaybackEligibility.isInProgress(game) ? .play : .openDetails
    }

    enum SelectionAction: Equatable { case play, openDetails }
}

/// What the feed shows above the grid while a Sports event is being tuned.
struct TVSportsPlaybackBanner: Equatable {
    let message: String
    let isError: Bool
    /// Cancel is offered while a search or attempt is running; Retry once it has failed.
    let showsCancel: Bool
    let showsRetry: Bool

    static func make(for phase: KyroSportsPlaybackCoordinator.Phase) -> TVSportsPlaybackBanner? {
        switch phase {
        case .idle, .presented:
            return nil
        case .searching:
            return TVSportsPlaybackBanner(message: "Finding a stream…", isError: false, showsCancel: true, showsRetry: false)
        case .connecting(let channelName, let attempt, let total):
            let progress = total > 1 ? " (\(attempt) of \(total))" : ""
            return TVSportsPlaybackBanner(message: "Connecting to \(channelName)\(progress)…", isError: false,
                                          showsCancel: true, showsRetry: false)
        case .exhausted:
            return TVSportsPlaybackBanner(
                message: "None of the matching streams played. Open event details to choose another.",
                isError: true, showsCancel: false, showsRetry: true)
        case .unavailable(_, _, let message):
            return TVSportsPlaybackBanner(
                message: message.isEmpty ? "No matching stream is available for this event." : message,
                isError: true, showsCancel: false, showsRetry: true)
        }
    }
}

/// Remembers the focused event so returning from details or the player lands on the same card.
struct TVSportsFocusMemory: Equatable {
    private(set) var lastGameID: KyroGameID?

    mutating func remember(_ id: KyroGameID) { lastGameID = id }

    /// The remembered card if it is still in the list, otherwise the first.
    func restoreTarget(visible: [KyroGameID]) -> KyroGameID? {
        if let lastGameID, visible.contains(lastGameID) { return lastGameID }
        return visible.first
    }
}

/// Poll scheduling: score refreshes follow the shared refresh policy, pause while a player is
/// on screen, and never run from focus changes.
enum TVSportsPolling {
    static let idleCheckSeconds: TimeInterval = 60

    static func delay(storeInterval: TimeInterval?) -> TimeInterval {
        storeInterval.map { max($0, 10) } ?? idleCheckSeconds
    }

    static func shouldRefresh(playerIsPresented: Bool, isRefreshing: Bool) -> Bool {
        !playerIsPresented && !isRefreshing
    }
}
#endif
