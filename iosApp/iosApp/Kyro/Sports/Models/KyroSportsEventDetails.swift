import Foundation

/// A provider-verified detail record for the exact event selected in Sports Hub.
/// Detail records never participate in playback; a failed request only changes
/// the Game/Stats/News content below the pinned player.
struct KyroSportsEventDetails: Equatable, Sendable {
    let gameID: KyroGameID
    let providerEventID: String
    let teamStatistics: [KyroSportsTeamBoxScore]
    let playerBoxScores: [KyroSportsPlayerTeamBoxScore]
    let matchEvents: [KyroSportsMatchEvent]
    let news: [KyroSportsNewsItem]

    var hasStatistics: Bool {
        teamStatistics.contains { !$0.statistics.isEmpty }
            || playerBoxScores.contains { $0.groups.contains { !$0.athletes.isEmpty } }
    }
}

struct KyroSportsMatchEvent: Identifiable, Equatable, Sendable {
    let id: String
    let clock: String?
    let kind: String
    let teamID: String?
    let playerNames: [String]
}

struct KyroSportsStatistic: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String { label }
}

struct KyroSportsTeamBoxScore: Identifiable, Equatable, Sendable {
    let providerTeamID: String
    let abbreviation: String
    let displayName: String
    let homeAway: String?
    let statistics: [KyroSportsStatistic]

    var id: String { providerTeamID }
}

struct KyroSportsPlayerTeamBoxScore: Identifiable, Equatable, Sendable {
    let providerTeamID: String
    let abbreviation: String
    let displayName: String
    let groups: [KyroSportsPlayerStatGroup]

    var id: String { providerTeamID }
}

struct KyroSportsPlayerStatGroup: Identifiable, Equatable, Sendable {
    let name: String
    let labels: [String]
    let athletes: [KyroSportsPlayerStatLine]

    var id: String { name }
}

struct KyroSportsPlayerStatLine: Identifiable, Equatable, Sendable {
    let providerAthleteID: String
    let displayName: String
    let shortName: String?
    let position: String?
    let starter: Bool
    let values: [String]

    var id: String { providerAthleteID }
}

struct KyroSportsNewsItem: Identifiable, Equatable, Sendable {
    enum Relevance: Int, Equatable, Sendable {
        case team = 1
        case matchup = 2
        case event = 3
    }

    let id: String
    let headline: String
    let publishedAt: Date?
    let url: URL
    let source: String
    let relevance: Relevance
}

enum KyroSportsEventDetailError: Error, Equatable, Sendable {
    case unsupportedLeague
    case eventNotMatched
    case unavailable
    case malformedResponse
    case cancelled

    var userMessage: String {
        switch self {
        case .unsupportedLeague:
            "Detailed box scores are not available for this sport yet."
        case .eventNotMatched:
            "Kyro could not safely match details to this event."
        case .unavailable:
            "Event details are unavailable right now."
        case .malformedResponse:
            "The event details could not be read."
        case .cancelled:
            ""
        }
    }
}
