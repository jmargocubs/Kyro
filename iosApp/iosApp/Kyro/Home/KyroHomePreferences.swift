#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// Kyro's six local Home shelves. Their placement among Silo's sections is
/// `KyroHomeArrangement`; Silo's server feed is never stored or edited here.
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

    var isLiveTV: Bool { self == .recentLiveTV || self == .favoriteLiveTV }
    var isFavoriteSports: Bool { self == .myTeams || self == .myLeagues }
}

/// Sports team and league favorites, shared by Sports Hub (touch and hold an
/// event) and Home (My Teams, My Leagues, and Customize Home). These are the
/// only sports favorites the app keeps; the keys are unchanged from Build 120.
/// Never stores channel or provider identities.
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

    /// Leagues whose events My Teams and My Leagues need: favorite leagues and
    /// the leagues of favorite teams, in the app's league order.
    var relevantLeagues: [KyroSportLeague] {
        let teamLeagues = Set(teams.compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) })
        return KyroSportLeague.allCases.filter { leagues.contains($0.rawValue) || teamLeagues.contains($0.rawValue) }
    }

    /// Exact key first. Providers name some teams differently (Sleeper's NFL
    /// feed can omit the city ESPN sends), so a pro team also matches on its
    /// nickname when one side has no location. College nicknames repeat
    /// across schools ("Knights"), so college teams need the full name.
    func includes(_ team: KyroSportsTeam) -> Bool {
        if teams.contains(Self.teamKey(team.fullName, league: team.league)) { return true }
        let prefix = team.league.rawValue + "|"
        let names = teams.filter { $0.hasPrefix(prefix) }.map { Self.normalized(String($0.dropFirst(prefix.count))) }
        guard !names.isEmpty else { return false }
        let full = Self.normalized(team.fullName)
        if names.contains(full) { return true }
        if team.alternateNames.map(Self.normalized).contains(where: names.contains) { return true }
        guard Self.nicknameLeagues.contains(team.league) else { return false }
        let nickname = Self.normalized(team.nickname)
        guard !nickname.isEmpty else { return false }
        return names.contains { name in
            name == nickname || (team.location?.isEmpty ?? true) && name.hasSuffix(" " + nickname)
        }
    }

    static let nicknameLeagues: Set<KyroSportLeague> = [.nfl, .nba, .mlb, .nhl]

    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func save(to defaults: UserDefaults) {
        defaults.set(leagues.sorted(), forKey: Self.leaguesKey)
        defaults.set(teams.sorted(), forKey: Self.teamsKey)
    }
}

/// Pure selection over original Sports Hub models, not a universal catalog.
enum KyroHomeSportsSelection {
    static let maximumCards = 40

    /// - Sports Today: live now, or starting today.
    /// - Upcoming Sports: scheduled after now.
    /// - My Teams / My Leagues: the favorites' live, upcoming and today's
    ///   finished events, live first, then by start time; older results and
    ///   canceled or postponed events are left out.
    static func games(_ games: [KyroSportsGame], for shelf: KyroHomeShelf,
                      favorites: KyroSportsFavorites, now: Date, calendar: Calendar = .current) -> [KyroSportsGame] {
        var seen = Set<KyroGameID>()
        let unique = games.filter { seen.insert($0.id).inserted }
        func isToday(_ game: KyroSportsGame) -> Bool {
            game.startTime.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        func isUpcoming(_ game: KyroSportsGame) -> Bool {
            game.status == .scheduled && (game.startTime ?? .distantPast) > now
        }
        let selected: [KyroSportsGame]
        switch shelf {
        case .sportsToday:
            selected = unique.filter { $0.status.isLive || (isToday($0) && !Self.isCalledOff($0)) }
        case .upcomingSports:
            selected = unique.filter(isUpcoming)
        case .myTeams, .myLeagues:
            selected = unique.filter { game in
                let matches = shelf == .myTeams
                    ? favorites.includes(game.home.team) || favorites.includes(game.away.team)
                    : favorites.leagues.contains(game.league.rawValue)
                guard matches else { return false }
                return game.status.isLive || isUpcoming(game) || (game.status.isFinal && isToday(game))
            }
        case .recentLiveTV, .favoriteLiveTV:
            selected = []
        }
        return Array(selected.sorted(by: order).prefix(maximumCards))
    }

    private static func isCalledOff(_ game: KyroSportsGame) -> Bool {
        game.status == .canceled || game.status == .postponed
    }

    /// Live first, then upcoming by start, then finished.
    private static func order(_ lhs: KyroSportsGame, _ rhs: KyroSportsGame) -> Bool {
        func rank(_ game: KyroSportsGame) -> Int {
            if game.status.isLive { return 0 }
            if game.status.isFinal { return 2 }
            return 1
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        let left = lhs.startTime ?? .distantFuture, right = rhs.startTime ?? .distantFuture
        return left == right ? lhs.id.stringValue < rhs.id.stringValue : left < right
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
    func reload() {
        let stored = KyroSportsFavorites(defaults: defaults)
        if stored != preferences { preferences = stored }
    }
    func toggle(_ league: KyroSportLeague) {
        if !preferences.leagues.insert(league.rawValue).inserted { preferences.leagues.remove(league.rawValue) }
    }
    func toggle(_ team: KyroSportsTeam) {
        let key = KyroSportsFavorites.teamKey(team.fullName, league: team.league)
        if preferences.includes(team) {
            // Remove the stored spelling too, not only today's provider spelling.
            let matching = preferences.teams.filter { stored in
                var probe = preferences
                probe.teams = [stored]
                return probe.includes(team)
            }
            preferences.teams.subtract(matching)
            return
        }
        guard preferences.teams.count < 64, key.count <= 64 else { return }
        preferences.teams.insert(key)
    }
}
#endif
