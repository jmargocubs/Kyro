import Foundation

/// Display rules for TV program search results, kept free of SwiftUI so they can be tested.
/// Status always comes from the clock at render time; nothing here is stored on a result.
enum UnifiedProgramSearchPresentation {
    enum AiringState: Equatable, Sendable {
        case live
        case upcoming
        case ended
    }

    static func state(of result: UnifiedProgramSearchResult, at now: Date) -> AiringState {
        if result.isLive(at: now) { return .live }
        return result.end <= now ? .ended : .upcoming
    }

    /// Results still worth showing at `now`, in their search order. A program that ends while the
    /// list is on screen drops out at the next minute tick instead of showing as ended.
    static func visible(_ results: [UnifiedProgramSearchResult], at now: Date) -> [UnifiedProgramSearchResult] {
        results.filter { $0.end > now }
    }

    /// Badge text. Matches the Guide's "Live"/"Upcoming" vocabulary.
    static func badge(for state: AiringState) -> String {
        switch state {
        case .live: "LIVE NOW"
        case .upcoming: "UPCOMING"
        case .ended: "ENDED"
        }
    }

    /// Local start and end, with the weekday when the program does not start today.
    static func timeRange(_ result: UnifiedProgramSearchResult, now: Date,
                          calendar: Calendar = .current, locale: Locale = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.timeZone = calendar.timeZone
        time.locale = locale
        let start = result.start.formatted(time)
        let end = result.end.formatted(time)
        guard !calendar.isDate(result.start, inSameDayAs: now) else { return "\(start) – \(end)" }
        var day = Date.FormatStyle().weekday(.abbreviated)
        day.timeZone = calendar.timeZone
        day.locale = locale
        return "\(result.start.formatted(day)) \(start) – \(end)"
    }

    /// The Guide's spoken form ("Title, 8:00 PM to 9:00 PM, On now"), plus subtitle and channel.
    static func accessibilityLabel(_ result: UnifiedProgramSearchResult, now: Date,
                                   calendar: Calendar = .current, locale: Locale = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.timeZone = calendar.timeZone
        time.locale = locale
        let status = switch state(of: result, at: now) {
        case .ended: "Ended"
        case .live: "On now"
        case .upcoming: "Upcoming"
        }
        let title = [result.title, result.subtitle].compactMap { $0 }.joined(separator: ", ")
        return "\(title), \(result.channelName), \(result.start.formatted(time)) to \(result.end.formatted(time)), \(status)"
    }

    static func sectionTitle(_ section: UnifiedSearchResultsSection, filter: UnifiedSearchFilter) -> String {
        switch section {
        case .moviesAndTV: "Movies & TV"
        case .liveTV: "Live TV"
        case .programs: "TV Programs"
        }
    }

    /// Source-specific message for a program state with nothing to list, or nil when the section
    /// should show results (or nothing at all, for an idle empty query).
    static func emptyMessage(for status: UnifiedSearchSourceStatus) -> (text: String, symbol: String)? {
        switch status.phase {
        case .idle:
            return ("Type at least 2 characters to search TV programs.", "character.cursor.ibeam")
        case .debouncing, .loading:
            return (status.message ?? "Searching TV programs…", "clock")
        case .loaded:
            return ("No matching TV programs", "magnifyingglass")
        case .failed, .partialFailure:
            return (status.message ?? "TV program search failed.", "exclamationmark.triangle")
        case .unavailable:
            return (status.message ?? "TV program search is unavailable.", "calendar.badge.exclamationmark")
        }
    }
}
