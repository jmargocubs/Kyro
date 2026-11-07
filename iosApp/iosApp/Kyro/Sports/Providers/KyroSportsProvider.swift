import Foundation

/// Errors every sports adapter translates into. Provider-specific response
/// shapes never escape into the store or SwiftUI layer.
enum KyroSportsDataError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case httpStatus(Int)
    case malformedResponse
    case cancelled
    case unsupportedSeasonPhase(KyroSportsSeasonType)

    var userMessage: String {
        switch self {
        case .offline: "You're offline."
        case .timedOut: "Scores are taking too long to load."
        case .httpStatus: "Scores are unavailable right now."
        case .malformedResponse: "Scores couldn't be read."
        case .cancelled: ""
        case .unsupportedSeasonPhase: "NFL regular-season games aren't active right now."
        }
    }
}

struct KyroSportsProviderOutput: Sendable {
    let provider: String
    let games: [KyroSportsGame]
    let season: Int
    let week: Int
    let refreshError: KyroSportsDataError?

    var isStale: Bool { refreshError != nil }
}

/// Small boundary for NFL schedule/score sources. ESPN and Sleeper conform
/// without exposing their response shapes to the store or views.
protocol KyroSportsProviding: Sendable {
    var providerID: String { get }
    func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput
}

/// Ordered outage fallback. A lower-priority provider is used only when the
/// higher-priority provider fails; records are never silently blended.
struct KyroSportsProviderChain: Sendable {
    let providers: [any KyroSportsProviding]

    func fetchNFLWindow(now: Date, force: Bool) async throws -> KyroSportsProviderOutput {
        var lastError: KyroSportsDataError = .offline
        for provider in providers {
            do {
                return try await provider.fetchNFLWindow(now: now, force: force)
            } catch let error as KyroSportsDataError {
                if error == .cancelled { throw error }
                lastError = error
            } catch is CancellationError {
                throw KyroSportsDataError.cancelled
            } catch {
                lastError = .offline
            }
        }
        throw lastError
    }
}

// MARK: - Cross-provider reconciliation

enum KyroSportsReconciliationConflict: Equatable, Sendable {
    case kickoff(primary: Date, fallback: Date, key: String)
    case status(primary: KyroGameStatus, fallback: KyroGameStatus, key: String)
}

struct KyroSportsReconciliationResult: Sendable {
    let games: [KyroSportsGame]
    let conflicts: [KyroSportsReconciliationConflict]
}

/// Deterministic matching for independently fetched provider records. Raw IDs
/// and display names are deliberately absent from the key.
enum KyroSportsReconciler {
    static func canonicalTeam(_ abbreviation: String) -> String {
        switch abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "JAC": "JAX"
        case "WSH": "WAS"
        case "LA", "STL": "LAR"
        case "OAK": "LV"
        case "SD": "LAC"
        default: abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }

    static func matchKey(for game: KyroSportsGame) -> String? {
        guard let season = game.season, let week = game.week else { return nil }
        return [
            game.league.rawValue,
            String(season),
            game.seasonType.rawValue,
            String(week),
            canonicalTeam(game.away.team.abbreviation),
            canonicalTeam(game.home.team.abbreviation)
        ].joined(separator: "|")
    }

    /// Primary wins status conflicts, which are reported explicitly. A kickoff
    /// conflict is treated as a possible reschedule: records remain separate
    /// and are never silently merged.
    static func reconcile(
        primary: [KyroSportsGame],
        fallback: [KyroSportsGame],
        kickoffTolerance: TimeInterval = 15 * 60
    ) -> KyroSportsReconciliationResult {
        var fallbackByKey: [String: KyroSportsGame] = [:]
        for game in fallback.sorted(by: deterministicOrder) {
            guard let key = matchKey(for: game), fallbackByKey[key] == nil else { continue }
            fallbackByKey[key] = game
        }

        var games: [KyroSportsGame] = []
        var conflicts: [KyroSportsReconciliationConflict] = []
        var consumed = Set<String>()

        for game in primary.sorted(by: deterministicOrder) {
            guard let key = matchKey(for: game), let other = fallbackByKey[key] else {
                games.append(game)
                continue
            }
            if let first = game.startTime, let second = other.startTime,
               abs(first.timeIntervalSince(second)) > kickoffTolerance {
                conflicts.append(.kickoff(primary: first, fallback: second, key: key))
                games.append(game)
                continue
            }
            consumed.insert(key)
            if game.status != other.status {
                conflicts.append(.status(primary: game.status, fallback: other.status, key: key))
            }
            games.append(copy(game, provenance: mergedProvenance(game.provenance, other.provenance)))
        }

        var emittedFallbackKeys = Set<String>()
        for game in fallback.sorted(by: deterministicOrder) {
            guard let key = matchKey(for: game) else {
                games.append(game)
                continue
            }
            if !consumed.contains(key), emittedFallbackKeys.insert(key).inserted {
                games.append(game)
            }
        }

        return KyroSportsReconciliationResult(
            games: deduplicated(games).sorted(by: deterministicOrder),
            conflicts: conflicts
        )
    }

    static func deduplicated(_ games: [KyroSportsGame]) -> [KyroSportsGame] {
        var accepted: [KyroSportsGame] = []
        for game in games.sorted(by: deterministicOrder) {
            let isDuplicate = accepted.contains { existing in
                if existing.id == game.id { return true }
                guard matchKey(for: existing) == matchKey(for: game),
                      matchKey(for: game) != nil else { return false }
                switch (existing.startTime, game.startTime) {
                case let (first?, second?):
                    return abs(first.timeIntervalSince(second)) <= 15 * 60
                case (nil, nil):
                    return true
                default:
                    return false
                }
            }
            if !isDuplicate { accepted.append(game) }
        }
        return accepted
    }

    static func deterministicOrder(_ lhs: KyroSportsGame, _ rhs: KyroSportsGame) -> Bool {
        let leftDate = lhs.startTime ?? .distantFuture
        let rightDate = rhs.startTime ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        let leftKey = matchKey(for: lhs) ?? lhs.id.stringValue
        let rightKey = matchKey(for: rhs) ?? rhs.id.stringValue
        if leftKey != rightKey { return leftKey < rightKey }
        return lhs.id.stringValue < rhs.id.stringValue
    }

    private static func mergedProvenance(
        _ primary: [KyroGameProvenance],
        _ fallback: [KyroGameProvenance]
    ) -> [KyroGameProvenance] {
        Array(Set(primary + fallback)).sorted {
            ($0.provider, $0.rawID) < ($1.provider, $1.rawID)
        }
    }

    private static func copy(
        _ game: KyroSportsGame,
        provenance: [KyroGameProvenance]
    ) -> KyroSportsGame {
        KyroSportsGame(
            id: game.id,
            league: game.league,
            season: game.season,
            seasonType: game.seasonType,
            week: game.week,
            startTime: game.startTime,
            status: game.status,
            statusDetail: game.statusDetail,
            home: game.home,
            away: game.away,
            periods: game.periods,
            venue: game.venue,
            broadcast: game.broadcast,
            provenance: provenance
        )
    }
}

// MARK: - Provider-independent sectioning

enum KyroSportsSectioning {
    static let recentDayCount = 7
    static let upcomingDayCount = 14
    static let recentGameLimit = 12

    static func sections(
        from input: [KyroSportsGame],
        now: Date,
        calendar: Calendar = .current
    ) -> [KyroSportsGameSection] {
        let games = KyroSportsReconciler.deduplicated(input)
        let startOfToday = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -recentDayCount, to: startOfToday)
            ?? now.addingTimeInterval(-Double(recentDayCount) * 86_400)
        let upcomingEnd = calendar.date(byAdding: .day, value: upcomingDayCount + 1, to: startOfToday)
            ?? now.addingTimeInterval(Double(upcomingDayCount + 1) * 86_400)

        let live = games.filter { $0.status.isLive }
            .sorted(by: KyroSportsReconciler.deterministicOrder)

        let recent = games.filter { game in
            guard game.status.isFinal, let start = game.startTime else { return false }
            return start >= recentStart && start <= now
        }
        .sorted {
            let left = $0.startTime ?? .distantPast
            let right = $1.startTime ?? .distantPast
            if left != right { return left > right }
            return KyroSportsReconciler.deterministicOrder($0, $1)
        }
        .prefix(recentGameLimit)

        let today = games.filter { game in
            guard !game.status.isLive, !game.status.isFinal, let start = game.startTime else {
                return false
            }
            guard calendar.isDate(start, inSameDayAs: now) else { return false }
            if (game.status.isScheduled || isUnknown(game.status)), start < now.addingTimeInterval(-5 * 3600) {
                return false
            }
            return true
        }
        .sorted(by: KyroSportsReconciler.deterministicOrder)

        let upcoming = games.filter { game in
            guard !game.status.isLive, !game.status.isFinal, let start = game.startTime else {
                return false
            }
            return !calendar.isDate(start, inSameDayAs: now)
                && start > now
                && start < upcomingEnd
        }
        .sorted(by: KyroSportsReconciler.deterministicOrder)

        // Keep known dates beyond the initial 14-day window available behind
        // an explicit expansion instead of silently throwing them away.
        let future = games.filter { game in
            guard !game.status.isLive, !game.status.isFinal, let start = game.startTime else {
                return false
            }
            return start >= upcomingEnd
        }
        .sorted(by: KyroSportsReconciler.deterministicOrder)

        var sections: [KyroSportsGameSection] = []
        if !live.isEmpty {
            sections.append(KyroSportsGameSection(bucket: .liveNow, games: live))
        }
        if !today.isEmpty {
            sections.append(KyroSportsGameSection(bucket: .today, games: today))
        }
        sections.append(contentsOf: dateSections(for: upcoming, bucket: .upcoming, calendar: calendar))
        if !recent.isEmpty {
            sections.append(KyroSportsGameSection(bucket: .recent, games: Array(recent)))
        }
        sections.append(contentsOf: dateSections(for: future, bucket: .future, calendar: calendar))
        return sections
    }

    private static func dateSections(
        for games: [KyroSportsGame],
        bucket: KyroSportsGameBucket,
        calendar: Calendar
    ) -> [KyroSportsGameSection] {
        var byDay: [Date: [KyroSportsGame]] = [:]
        for game in games {
            guard let start = game.startTime else { continue }
            byDay[calendar.startOfDay(for: start), default: []].append(game)
        }
        return byDay.keys.sorted().enumerated().map { index, day in
            KyroSportsGameSection(
                bucket: bucket,
                localDay: day,
                isFirstInBucket: index == 0,
                games: (byDay[day] ?? []).sorted(by: KyroSportsReconciler.deterministicOrder)
            )
        }
    }

    private static func isUnknown(_ status: KyroGameStatus) -> Bool {
        status.isUnknown
    }
}
