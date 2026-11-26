#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

struct KyroSportsDashboardPreferences: Codable, Equatable {
    static let key = "kyrox.sports.dashboard.v124"
    var order: [KyroSportLeague] = [.nfl, .collegeFootball, .collegeBasketballMen,
                                  .collegeBasketballWomen, .nba, .nhl, .mlb, .soccer, .atp, .wta]
    var hidden: Set<KyroSportLeague> = []
    var showLive = true
    var showUpcoming = true
    var showCompleted = true
    var defaultLeague: String = "lastUsed"
    /// Disabled competition slugs; unknown saved slugs are retained for future versions.
    var disabledSoccerCompetitions: Set<String> = []
    enum CodingKeys: String, CodingKey { case order, hidden, showLive, showUpcoming, showCompleted, defaultLeague, disabledSoccerCompetitions }
    init(order: [KyroSportLeague] = [.nfl, .collegeFootball, .collegeBasketballMen, .collegeBasketballWomen, .nba, .nhl, .mlb, .soccer, .atp, .wta],
         hidden: Set<KyroSportLeague> = [], showLive: Bool = true, showUpcoming: Bool = true,
         showCompleted: Bool = true, defaultLeague: String = "lastUsed", disabledSoccerCompetitions: Set<String> = []) {
        self.order = order; self.hidden = hidden; self.showLive = showLive; self.showUpcoming = showUpcoming
        self.showCompleted = showCompleted; self.defaultLeague = defaultLeague
        self.disabledSoccerCompetitions = disabledSoccerCompetitions
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(order: try values.decode([KyroSportLeague].self, forKey: .order),
                  hidden: try values.decode(Set<KyroSportLeague>.self, forKey: .hidden),
                  showLive: try values.decode(Bool.self, forKey: .showLive),
                  showUpcoming: try values.decode(Bool.self, forKey: .showUpcoming),
                  showCompleted: try values.decode(Bool.self, forKey: .showCompleted),
                  defaultLeague: try values.decode(String.self, forKey: .defaultLeague),
                  disabledSoccerCompetitions: try values.decodeIfPresent(Set<String>.self, forKey: .disabledSoccerCompetitions) ?? [])
    }
    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data),
              Set(value.order) == Set(KyroSportLeague.allCases), value.order.count == KyroSportLeague.allCases.count,
              ["all", "lastUsed"].contains(value.defaultLeague) || KyroSportLeague(rawValue: value.defaultLeague) != nil else { return Self() }
        return value
    }
    func includes(_ game: KyroSportsGame) -> Bool {
        !hidden.contains(game.league) && (game.competitionKey.map { !disabledSoccerCompetitions.contains($0) } ?? true)
            && (game.status.isLive ? showLive : game.status.isFinal ? showCompleted : showUpcoming)
    }
}

@MainActor @Observable
final class KyroSportsDashboardSettings {
    static let shared = KyroSportsDashboardSettings()
    private let defaults: UserDefaults
    var value: KyroSportsDashboardPreferences {
        didSet { if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: KyroSportsDashboardPreferences.key) } }
    }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; value = .load(defaults) }
    func reload() { value = .load(defaults) }
}

/// Kyro's local Home shelves. Their placement among Silo's sections is
/// `KyroHomeArrangement`; Silo's server feed is never stored or edited here.
/// Build 128 adds the two radio shelves, which are opt-in (see
/// `KyroHomeArrangement.shownOptIn`).
enum KyroHomeShelf: String, CaseIterable, Codable, Identifiable, Sendable {
    case recentLiveTV, favoriteLiveTV, sportsToday, myTeams, myLeagues, upcomingSports
    case favoriteRadio, recentRadio
    var id: String { rawValue }
    /// The shelves before Build 128; Build 120 backups list exactly these.
    static let legacyCases: [Self] = [.recentLiveTV, .favoriteLiveTV, .sportsToday, .myTeams, .myLeagues, .upcomingSports]
    /// Off until the user turns them on in Customize Home, so an existing Home
    /// layout does not change.
    var isOptIn: Bool { isRadio }
    var isRadio: Bool { self == .favoriteRadio || self == .recentRadio }
    var title: String {
        switch self {
        case .recentLiveTV: "Recently Watched Live TV"
        case .favoriteLiveTV: "Favorite Live TV Channels"
        case .sportsToday: "Sports Today"
        case .myTeams: "My Teams"
        case .myLeagues: "My Leagues"
        case .upcomingSports: "Upcoming Sports"
        case .favoriteRadio: "Favorite Radio Stations"
        case .recentRadio: "Recently Played Radio"
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
    /// New ESPN selections carry identity and a bounded readable fallback. Existing
    /// name-only favorites remain untouched; never guess a migration from a nickname.
    static func favoriteKey(_ team: KyroSportsTeam) -> String {
        guard team.id.hasPrefix("espn.\(team.league.rawValue).") else { return teamKey(team.fullName, league: team.league) }
        let prefix = "\(team.league.rawValue)|@\(team.id.split(separator: ".").last ?? "")~"
        return prefix + team.fullName.prefix(max(0, 64 - prefix.count))
    }
    static func storedName(_ key: String) -> String {
        let value = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
        return value.hasPrefix("@") ? value.split(separator: "~", maxSplits: 1).last.map(String.init) ?? value : value
    }
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
        let stablePrefix = "\(team.league.rawValue)|@\(team.id.split(separator: ".").last ?? "")~"
        if team.id.hasPrefix("espn.\(team.league.rawValue)."), teams.contains(where: { $0.hasPrefix(stablePrefix) }) { return true }
        if teams.contains(Self.teamKey(team.fullName, league: team.league)) { return true }
        let prefix = team.league.rawValue + "|"
        let names = teams.filter {
            guard $0.hasPrefix(prefix) else { return false }
            // Different ESPN IDs must never merge just because names match.
            return !team.id.hasPrefix("espn.") || !$0.hasPrefix(prefix + "@")
        }.map { Self.normalized(Self.storedName($0)) }
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
        case .recentLiveTV, .favoriteLiveTV, .favoriteRadio, .recentRadio:
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

/// Home's Add Team and Add League cards. They use `KyroSportsFavoritesStore`
/// and never a second favorites list. A shelf that Customize Home has hidden
/// stays hidden, including its card.
enum KyroHomeQuickAdd {
    struct TeamChoice: Equatable, Identifiable {
        let team: KyroSportsTeam
        var id: String { KyroSportsFavorites.teamKey(team.fullName, league: team.league) }
    }

    static func title(for shelf: KyroHomeShelf) -> String {
        switch shelf {
        case .myTeams: "Add Team"
        case .myLeagues: "Add League"
        default: ""
        }
    }

    static func isAvailable(for shelf: KyroHomeShelf, hidden: Set<KyroHomeShelf>) -> Bool {
        shelf.isFavoriteSports && !hidden.contains(shelf)
    }

    /// Favorite shelves stay on Home for the card when they have no events.
    /// Every other shelf still disappears when it has nothing to show.
    static func drawsRail(gameCount: Int, shelf: KyroHomeShelf, hidden: Set<KyroHomeShelf>) -> Bool {
        guard !hidden.contains(shelf) else { return false }
        return gameCount > 0 || isAvailable(for: shelf, hidden: hidden)
    }

    static func leagues(matching query: String) -> [KyroSportLeague] {
        let needle = KyroSportsFavorites.normalized(query)
        guard !needle.isEmpty else { return KyroSportLeague.allCases }
        return KyroSportLeague.allCases.filter { league in
            KyroSportsFavorites.normalized(league.displayName).contains(needle)
                || KyroSportsFavorites.normalized(league.shortName).contains(needle)
        }
    }

    /// Teams already on a loaded schedule, one row per favorite key.
    static func teams(in games: [KyroSportsGame], matching query: String) -> [TeamChoice] {
        var seen = Set<String>()
        var choices: [TeamChoice] = []
        for game in games {
            for team in [game.away.team, game.home.team] {
                let choice = TeamChoice(team: team)
                guard seen.insert(choice.id).inserted else { continue }
                choices.append(choice)
            }
        }
        choices.sort { lhs, rhs in
            let order = lhs.team.fullName.localizedCaseInsensitiveCompare(rhs.team.fullName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        let needle = KyroSportsFavorites.normalized(query)
        guard !needle.isEmpty else { return choices }
        return choices.filter { choice in
            let team = choice.team
            let fields = [team.fullName, team.nickname, team.abbreviation, team.location ?? "", team.league.displayName, team.league.shortName]
            return fields.contains { KyroSportsFavorites.normalized($0).contains(needle) }
        }
    }

    /// Turns a favorite on or off through the shared store. Asking for a team
    /// or league that is already stored does nothing, so a second tap cannot
    /// write another key.
    @MainActor
    static func select(_ league: KyroSportLeague, favorites: KyroSportsFavoritesStore, wants: Bool) {
        let has = favorites.preferences.leagues.contains(league.rawValue)
        guard wants != has else { return }
        favorites.toggle(league)
    }

    @MainActor
    static func select(_ team: KyroSportsTeam, favorites: KyroSportsFavoritesStore, wants: Bool) {
        let has = favorites.preferences.includes(team)
        guard wants != has else { return }
        favorites.toggle(team)
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
        let key = KyroSportsFavorites.favoriteKey(team)
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
