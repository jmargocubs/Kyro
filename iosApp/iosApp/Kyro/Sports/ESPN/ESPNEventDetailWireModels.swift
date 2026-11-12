import Foundation

/// The small, defensive subset of ESPN's event-summary and news payloads used
/// by Sports Hub. Optional fields keep one missing statistic from rejecting an
/// otherwise useful box score.
struct ESPNEventSummaryResponse: Decodable, Sendable {
    let header: Header?
    let boxscore: Boxscore?
    let article: Article?
    let news: News?
    let keyEvents: [KeyEvent]?
    let rosters: [Roster]?

    struct Header: Decodable, Sendable {
        let id: String?
        let competitions: [Competition]?
    }

    struct Competition: Decodable, Sendable {
        let id: String?
        let date: String?
        let competitors: [Competitor]?
    }

    struct Competitor: Decodable, Sendable {
        let id: String?
        let homeAway: String?
        let team: Team?
    }

    struct Team: Decodable, Sendable {
        let id: String?
        let abbreviation: String?
        let displayName: String?
        let shortDisplayName: String?
    }

    struct Boxscore: Decodable, Sendable {
        let teams: [TeamStatistics]?
        let players: [PlayerTeam]?
    }

    struct KeyEvent: Decodable, Sendable {
        let id: String?
        let type: EventType?
        let clock: EventClock?
        let team: EventTeam?
        let athletesInvolved: [EventAthlete]?
    }

    struct EventType: Decodable, Sendable { let text: String? }
    struct EventClock: Decodable, Sendable { let displayValue: String? }
    struct EventTeam: Decodable, Sendable { let id: String? }
    struct EventAthlete: Decodable, Sendable {
        let id: String?
        let displayName: String?
    }

    struct Roster: Decodable, Sendable {
        let team: Team?
        let roster: [RosterAthlete]?
    }

    struct RosterAthlete: Decodable, Sendable {
        let active: Bool?
        let starter: Bool?
        let didNotPlay: Bool?
        let athlete: Athlete?
        let position: Position?
        let stats: [RosterStatistic]?
    }

    struct RosterStatistic: Decodable, Sendable {
        let name: String?
        let displayName: String?
        let displayValue: String?
    }

    struct TeamStatistics: Decodable, Sendable {
        let team: Team?
        let homeAway: String?
        let statistics: [Statistic]?
    }

    struct Statistic: Decodable, Sendable {
        let name: String?
        let label: String?
        let displayName: String?
        let displayValue: ESPNScalar?
        /// MLB groups its team statistics (`batting`, `pitching`, `fielding`), each with its own
        /// list. Football, basketball, hockey and soccer use flat label/value entries.
        let stats: [NestedStatistic]?
    }

    struct NestedStatistic: Decodable, Sendable {
        let name: String?
        let abbreviation: String?
        let displayName: String?
        let displayValue: ESPNScalar?
    }

    struct PlayerTeam: Decodable, Sendable {
        let team: Team?
        let statistics: [PlayerStatGroup]?
    }

    struct PlayerStatGroup: Decodable, Sendable {
        let name: String?
        /// MLB names its player groups here (`batting`, `pitching`) and leaves `name` empty.
        let type: String?
        let displayName: String?
        let labels: [String]?
        let athletes: [PlayerLine]?
    }

    struct PlayerLine: Decodable, Sendable {
        let active: Bool?
        let athlete: Athlete?
        let starter: Bool?
        let didNotPlay: Bool?
        let stats: [ESPNScalar]?
    }

    struct Athlete: Decodable, Sendable {
        let id: String?
        let displayName: String?
        let shortName: String?
        let position: Position?
    }

    struct Position: Decodable, Sendable {
        let abbreviation: String?
        let displayName: String?
    }

    struct News: Decodable, Sendable {
        let articles: [Article]?
    }

    struct Article: Decodable, Sendable {
        let id: Int?
        let headline: String?
        let published: String?
        let links: ArticleLinks?
        let categories: [Category]?
    }

    struct ArticleLinks: Decodable, Sendable {
        let web: WebLink?
    }

    struct WebLink: Decodable, Sendable {
        let href: String?
    }

    struct Category: Decodable, Sendable {
        let type: String?
        let team: CategoryTeam?
        /// Tennis articles are tagged with the players instead of teams.
        let athleteId: ESPNScalar?
    }

    struct CategoryTeam: Decodable, Sendable {
        // Header IDs are strings, but real article-category team IDs are numbers.
        let id: ESPNScalar?
    }
}

struct ESPNTeamNewsResponse: Decodable, Sendable {
    let articles: [ESPNEventSummaryResponse.Article]?
}
