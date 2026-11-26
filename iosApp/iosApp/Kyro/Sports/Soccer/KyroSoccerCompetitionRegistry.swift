import Foundation

/// A verified ESPN soccer scoreboard route. A route is only listed here after
/// returning a valid ESPN league payload; unsupported or rejected slugs stay
/// out of the working registry rather than producing fabricated competitions.
struct KyroSoccerCompetition: Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let region: String
    let gender: Gender
    let group: Group
    enum Group: String, CaseIterable, Sendable {
        case england, northAmerica, continental, women
        var title: String {
            switch self {
            case .england: "England"
            case .northAmerica: "North America"
            case .continental: "UEFA"
            case .women: "Women's Leagues"
            }
        }
    }

    enum Gender: String, Sendable {
        case men
        case women
        case mixed
    }

    var id: String { key }
}

enum KyroSoccerCompetitionRegistry {
    /// Only England, North America and retained UEFA club competitions are
    /// active. Slugs are ESPN competition IDs, verified before inclusion.
    static let verified: [KyroSoccerCompetition] = [
        .init(key: "eng.1", name: "English Premier League", region: "England", gender: .men, group: .england),
        .init(key: "eng.2", name: "EFL Championship", region: "England", gender: .men, group: .england),
        .init(key: "eng.3", name: "EFL League One", region: "England", gender: .men, group: .england),
        .init(key: "eng.4", name: "EFL League Two", region: "England", gender: .men, group: .england),
        .init(key: "eng.5", name: "National League", region: "England", gender: .men, group: .england),
        .init(key: "eng.fa", name: "FA Cup", region: "England", gender: .men, group: .england),
        .init(key: "eng.w.1", name: "Women’s Super League", region: "England", gender: .women, group: .women),
        // North America: include only competition IDs verified against ESPN endpoints.
        .init(key: "usa.1", name: "Major League Soccer", region: "United States / Canada", gender: .men, group: .northAmerica),
        .init(key: "mex.1", name: "Liga MX", region: "Mexico", gender: .men, group: .northAmerica),
        .init(key: "usa.nwsl", name: "NWSL", region: "United States", gender: .women, group: .women),
        .init(key: "uefa.champions", name: "UEFA Champions League", region: "Europe", gender: .men, group: .continental),
        .init(key: "uefa.europa", name: "UEFA Europa League", region: "Europe", gender: .men, group: .continental),
        .init(key: "uefa.europa.conf", name: "UEFA Conference League", region: "Europe", gender: .men, group: .continental),
        // No verified ESPN IDs found during bounded live verification for cups and lower
        // professional circuits beyond the four English EFL/FA routes above.
    ]

    static func competition(for key: String?) -> KyroSoccerCompetition? {
        guard let key else { return nil }
        return verified.first { $0.key == key }
    }
}
