#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// Only additive, device-local shelves. Silo's server feed is never stored or reordered here.
enum KyroHomeShelf: String, CaseIterable, Codable, Identifiable, Sendable {
    case recentLiveTV, favoriteLiveTV, sportsToday, myTeams, myLeagues, upcomingSports
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentLiveTV: "Recently Watched Live TV"
        case .favoriteLiveTV: "Favorite Live TV Channels"
        case .sportsToday: "Sports Today"
        case .myTeams: "My Teams"
        case .myLeagues: "My Leagues"
        case .upcomingSports: "Upcoming Sports"
        }
    }
}

/// Adapted from independent Kyro X's UniversalHomePreferences, scoped strictly
/// to the six local additions. Emptiness and load errors never mutate these preferences.
struct KyroHomePreferences: Codable, Equatable {
    static let key = "kyrox.home.localShelves.v1"
    var order: [KyroHomeShelf] = KyroHomeShelf.allCases
    var hidden: Set<KyroHomeShelf> = []

    init() {}
    init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        var seen = Set<KyroHomeShelf>()
        order = (order + KyroHomeShelf.allCases).filter { seen.insert($0).inserted }
    }
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    var enabled: [KyroHomeShelf] { order.filter { !hidden.contains($0) } }
    static func load(from defaults: UserDefaults) -> Self { .init(data: defaults.data(forKey: key)) }
    func save(to defaults: UserDefaults) { defaults.set(data, forKey: Self.key) }
}

/// The independent SportsHubStore's durable favorites pattern, shared by
/// Sports Hub and Home. Keep the established keys; never export channel/provider identities.
struct KyroSportsFavorites: Equatable {
    static let leaguesKey = "kyrox.sports.leagues"
    static let teamsKey = "kyrox.sports.teams"
    var leagues: Set<String> = []
    var teams: Set<String> = []
    static func teamKey(_ name: String, league: KyroSportLeague) -> String { "\(league.rawValue)|\(name)" }
    init(defaults: UserDefaults) {
        leagues = Set(defaults.stringArray(forKey: Self.leaguesKey) ?? [])
        teams = Set(defaults.stringArray(forKey: Self.teamsKey) ?? [])
    }
    func includes(_ team: KyroSportsTeam) -> Bool {
        teams.contains(Self.teamKey(team.fullName, league: team.league))
    }
    func save(to defaults: UserDefaults) {
        defaults.set(leagues.sorted(), forKey: Self.leaguesKey)
        defaults.set(teams.sorted(), forKey: Self.teamsKey)
    }
}

/// Pure selection over original Sports Hub models, not a universal catalog.
enum KyroHomeSportsSelection {
    static func games(_ games: [KyroSportsGame], for shelf: KyroHomeShelf,
                      favorites: KyroSportsFavorites, now: Date, calendar: Calendar = .current) -> [KyroSportsGame] {
        var seen = Set<KyroGameID>()
        let relevant = games.filter { game in
            guard seen.insert(game.id).inserted else { return false }
            if game.status.isLive { return true }
            guard let start = game.startTime else { return false }
            return calendar.isDate(start, inSameDayAs: now) || start > now
        }.sorted {
            let lhs = $0.startTime ?? .distantFuture, rhs = $1.startTime ?? .distantFuture
            return lhs == rhs ? $0.id.stringValue < $1.id.stringValue : lhs < rhs
        }
        return Array(relevant.filter { game in
            switch shelf {
            case .sportsToday: return game.startTime.map { calendar.isDate($0, inSameDayAs: now) } == true || game.status.isLive
            case .myTeams: return favorites.includes(game.home.team) || favorites.includes(game.away.team)
            case .myLeagues: return favorites.leagues.contains(game.league.rawValue)
            case .upcomingSports: return game.status == .scheduled && (game.startTime ?? .distantPast) > now
            case .recentLiveTV, .favoriteLiveTV: return false
            }
        }.prefix(40))
    }
}

@MainActor @Observable
final class KyroSportsFavoritesStore {
    static let shared = KyroSportsFavoritesStore()
    private let defaults: UserDefaults
    var preferences: KyroSportsFavorites {
        didSet { preferences.save(to: defaults) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = .init(defaults: defaults)
    }
    func reload() { preferences = .init(defaults: defaults) }
    func toggle(_ league: KyroSportLeague) {
        if !preferences.leagues.insert(league.rawValue).inserted { preferences.leagues.remove(league.rawValue) }
    }
    func toggle(_ team: KyroSportsTeam) {
        let key = KyroSportsFavorites.teamKey(team.fullName, league: team.league)
        guard preferences.teams.contains(key) || (preferences.teams.count < 64 && key.count <= 64) else { return }
        if !preferences.teams.insert(key).inserted { preferences.teams.remove(key) }
    }
}
#endif
