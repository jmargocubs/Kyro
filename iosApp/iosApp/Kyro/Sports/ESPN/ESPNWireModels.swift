import Foundation

/// The subset of ESPN's public scoreboard JSON that Kyro consumes. These
/// wire types stay inside the ESPN adapter so an undocumented field change
/// cannot leak into the shared sports models or SwiftUI.
struct ESPNScoreboardResponse: Decodable, Sendable {
    let leagues: [League]?
    let events: [Event]

    struct League: Decodable, Sendable {
        let season: Season?
    }

    struct Event: Decodable, Sendable {
        let id: String?
        let date: String?
        let season: Season?
        let week: Week?
        let status: Status?
        let competitions: [Competition]?
    }

    struct Season: Decodable, Sendable {
        let year: Int?
        let type: Int?
        let slug: String?
    }

    struct Week: Decodable, Sendable {
        let number: Int?
    }

    struct Competition: Decodable, Sendable {
        let id: String?
        let date: String?
        let status: Status?
        let competitors: [Competitor]?
        let venue: Venue?
        let broadcasts: [Broadcast]?
    }

    struct Status: Decodable, Sendable {
        let clock: Double?
        let displayClock: String?
        let period: Int?
        let type: StatusType?
    }

    struct StatusType: Decodable, Sendable {
        let id: String?
        let name: String?
        let state: String?
        let completed: Bool?
        let description: String?
        let detail: String?
        let shortDetail: String?
    }

    struct Competitor: Decodable, Sendable {
        let id: String?
        let homeAway: String?
        let team: Team?
        let score: ESPNScalar?
        let records: [Record]?
        let linescores: [LineScore]?
        let curatedRank: Rank?
    }

    struct Team: Decodable, Sendable {
        let id: String?
        let location: String?
        let name: String?
        let abbreviation: String?
        let displayName: String?
        let shortDisplayName: String?
        let color: String?
        let logo: String?
    }

    struct Record: Decodable, Sendable {
        let name: String?
        let type: String?
        let summary: String?
    }

    struct LineScore: Decodable, Sendable {
        let value: Double?
        let displayValue: String?
        let period: Int?
    }

    struct Rank: Decodable, Sendable {
        let current: Int?
    }

    struct Venue: Decodable, Sendable {
        let fullName: String?
    }

    struct Broadcast: Decodable, Sendable {
        let names: [String]?
    }
}

/// ESPN normally encodes scores as strings, but older and league-specific
/// payloads sometimes use a JSON number. Accept both without weakening the
/// rest of the response validation.
struct ESPNScalar: Decodable, Sendable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            stringValue = value
        } else if let value = try? container.decode(Int.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Double.self) {
            stringValue = String(value)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string or numeric ESPN scalar"
                )
            )
        }
    }
}
