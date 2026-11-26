#if KYRO_STANDALONE_TESTS
import Foundation

/// Build 126: professional/college directory levels, league grouping and
/// search ranking, through the production `KyroSportsDirectory` paths.
@main @MainActor
enum KyroBuild126HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) { precondition(condition, title); count += 1 }

    private static func route(_ slug: String) -> KyroSportsDirectoryRoute {
        KyroSportsDirectoryRoute.all.first { $0.slug == slug }!
    }

    private static func payload(_ route: KyroSportsDirectoryRoute, _ teams: [(id: String, name: String, short: String, abbr: String)]) -> Data {
        let rows = teams.map {
            #"{"team":{"id":"\#($0.id)","displayName":"\#($0.name)","shortDisplayName":"\#($0.short)","name":"\#($0.short)","abbreviation":"\#($0.abbr)"}}"#
        }.joined(separator: ",")
        return Data(#"{"sports":[{"slug":"\#(route.sport.rawValue)","leagues":[{"slug":"\#(route.slug)","teams":[\#(rows)]}]}]}"#.utf8)
    }

    static func main() async throws {
        let suite = "kyro.build126.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let nfl = route("nfl"), nba = route("nba"), cfb = route("college-football")
        let men = route("mens-college-basketball"), women = route("womens-college-basketball")
        let championship = route("eng.2")
        let payloads: [KyroSportsDirectoryRoute: Data] = [
            nfl: payload(nfl, [("3", "Chicago Bears", "Bears", "CHI"), ("9", "Green Bay Packers", "Packers", "GB")]),
            nba: payload(nba, [("4", "Chicago Bulls", "Bulls", "CHI"), ("1", "Atlanta Hawks", "Hawks", "ATL")]),
            cfb: payload(cfb, [("239", "Baylor Bears", "Bears", "BAY"), ("25", "California Golden Bears", "Golden Bears", "CAL"),
                               ("333", "Alabama Crimson Tide", "Crimson Tide", "ALA")]),
            men: payload(men, [("2084", "Buffalo Bulls", "Bulls", "BUFF"), ("58", "South Florida Bulls", "Bulls", "USF")]),
            women: payload(women, [("2084", "Buffalo Bulls", "Bulls", "BUFF"), ("58", "South Florida Bulls", "Bulls", "USF")]),
            championship: payload(championship, [("352", "Wrexham", "Wrexham", "WXM")]),
        ]
        let loader = KyroSportsDirectory(defaults: defaults, fetch: { request in
            guard let data = payloads.first(where: { request.url!.path.hasSuffix("/" + $0.key.path + "/teams") })?.value
            else { throw URLError(.badURL) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for route in payloads.keys { await loader.load(route) }
        // Every check below reads the persisted cache with the network down.
        let directory = KyroSportsDirectory(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })

        // Defaults and level isolation
        let football = KyroSportsDirectoryScope.discovery(sport: .football)
        let basketball = KyroSportsDirectoryScope.discovery(sport: .basketball)
        check(football.level == .professional && basketball.level == .professional, "football and basketball default to Professional")
        check(KyroSportsDirectoryScope.discovery(sport: .soccer).level == nil &&
              KyroSportsDirectoryScope.discovery(sport: nil).level == nil, "levels only apply where both exist")
        check(football.routes.map(\.league) == [.nfl], "Professional Football is NFL only")
        check(basketball.routes.map(\.league) == [.nba], "Professional Basketball is NBA only")
        var collegeFootball = football; collegeFootball.level = .college
        var collegeBasketball = basketball; collegeBasketball.level = .college
        check(collegeFootball.routes.map(\.league) == [.collegeFootball], "College Football is NCAA football only")
        check(collegeBasketball.routes.map(\.league) == [.collegeBasketballMen, .collegeBasketballWomen],
              "College Basketball offers men's and women's separately")
        let bears = directory.results(in: football, matching: "Bears", schedules: [])
        check(bears.map(\.name) == ["Chicago Bears"], "Professional Football search for Bears returns no NCAA teams")
        let bulls = directory.results(in: basketball, matching: "Bulls", schedules: [])
        check(bulls.map(\.name) == ["Chicago Bulls"], "Professional Basketball search for Bulls returns no NCAA teams")
        check(directory.results(in: collegeFootball, matching: "Bears", schedules: []).allSatisfy { $0.league == .collegeFootball },
              "College Football search stays NCAA football")

        // Grouping by actual league
        let collegeGroups = directory.groupedResults(in: collegeBasketball, matching: "Bulls", schedules: [])
        check(collegeGroups.map(\.route.league) == [.collegeBasketballMen, .collegeBasketballWomen] &&
              collegeGroups.allSatisfy { $0.entries.count == 2 }, "college basketball results grouped by men's and women's")
        var allFootball = football; allFootball.level = .all
        let allGroups = directory.groupedResults(in: allFootball, matching: "Bears", schedules: [])
        check(allGroups.map(\.route.league) == [.nfl, .collegeFootball], "All Football groups NFL and NCAA separately, pro first")
        check(allGroups.allSatisfy { group in group.entries.allSatisfy { $0.league == group.route.league } },
              "no group mixes leagues")
        var allBasketball = basketball; allBasketball.level = .all
        check(directory.groupedResults(in: allBasketball, matching: "Bulls", schedules: []).map(\.route.league)
              == [.nba, .collegeBasketballMen, .collegeBasketballWomen], "All Basketball groups three leagues")
        let everything = directory.groupedResults(in: .init(), matching: "", schedules: [])
        check(Set(everything.map(\.route.id)).count == everything.count, "All Sports has one group per league")

        // Strict specific league, even when it disagrees with the level
        var strict = football; strict.routeID = cfb.id
        check(directory.results(in: strict, matching: "", schedules: []).allSatisfy { $0.league == .collegeFootball },
              "specific league selection stays strict")
        check(directory.results(in: .init(sport: .football, routeID: nba.id), matching: "", schedules: []).isEmpty,
              "league from another sport returns nothing")

        // Ranking: exact name/abbreviation, then exact alias, word prefix, partial
        let ranked = directory.results(in: allFootball, matching: "Bears", schedules: [])
        check(ranked.prefix(2).map(\.name).sorted() == ["Baylor Bears", "Chicago Bears"] &&
              ranked.last?.name == "California Golden Bears", "exact alias ranks above word-prefix match")
        check(directory.results(in: allBasketball, matching: "CHI", schedules: []).first?.name == "Chicago Bulls",
              "abbreviation exact match ranks first")
        check(directory.results(in: allFootball, matching: "Chicago Bears", schedules: []).first?.name == "Chicago Bears",
              "full-name exact match ranks first")
        let golden = directory.results(in: allFootball, matching: "gold", schedules: [])
        check(golden.map(\.name) == ["California Golden Bears"], "word prefix matches")
        check(directory.results(in: allFootball, matching: "NFL", schedules: []).map(\.league).allSatisfy { $0 == .nfl },
              "league-name search still works at lowest rank")

        // Wrexham and offseason discovery
        let wrexham = directory.results(in: .discovery(sport: .soccer), matching: "Wrexham", schedules: [])
        check(wrexham.map(\.id) == ["espn.soccer.352"], "Wrexham discovery unchanged")
        check(directory.results(in: .discovery(sport: nil), matching: "WXM", schedules: []).first?.id == "espn.soccer.352",
              "All Sports abbreviation search")

        // Existing favorites keep matching the same entries (stable-ID keys and
        // Build 120 name-only keys); level filters never touch the store.
        let bearsEntry = directory.results(in: football, matching: "Chicago Bears", schedules: [])[0]
        let buffaloWomen = collegeGroups.first { $0.route.league == .collegeBasketballWomen }!.entries.first { $0.name == "Buffalo Bulls" }!
        let buffaloMen = collegeGroups.first { $0.route.league == .collegeBasketballMen }!.entries.first { $0.name == "Buffalo Bulls" }!
        var favorites = KyroSportsFavorites(defaults: defaults)
        favorites.teams = [KyroSportsFavorites.favoriteKey(bearsEntry.team),
                           KyroSportsFavorites.favoriteKey(buffaloWomen.team),
                           KyroSportsFavorites.teamKey("Chicago Bulls", league: .nba)]
        let before = favorites
        check(favorites.includes(bearsEntry.team), "existing NFL stable-ID favorite still matches")
        check(favorites.includes(directory.results(in: basketball, matching: "Bulls", schedules: [])[0].team),
              "legacy name-only NBA favorite still matches")
        check(favorites.includes(buffaloWomen.team) && !favorites.includes(buffaloMen.team),
              "same-name women's favorite does not follow the men's team")
        _ = directory.groupedResults(in: allBasketball, matching: "Bulls", schedules: [])
        check(favorites == before, "searching never edits favorites")

        // Build 127 registry, dashboard selection and legacy preference decoding.
        let competitions = KyroSoccerCompetitionRegistry.verified
        let keys = competitions.map(\.key)
        check(keys.count == Set(keys).count && Set(["uefa.champions", "uefa.europa", "uefa.europa.conf"]).isSubset(of: Set(keys)),
              "unique soccer routes retain all three UEFA competitions")
        check(keys.allSatisfy { key in ["eng.", "usa.", "mex.", "uefa."].contains { key.hasPrefix($0) } },
              "worldwide soccer routes removed")
        check(Set(KyroSportsDirectoryRoute.all.filter { $0.league == .soccer }.map(\.slug)) == Set(keys),
              "team directory and scoreboard share the soccer registry")
        var soccerPrefs = KyroSportsDashboardPreferences()
        soccerPrefs.disabledSoccerCompetitions.insert("eng.2")
        defaults.set(try JSONEncoder().encode(soccerPrefs), forKey: KyroSportsDashboardPreferences.key)
        check(KyroSportsDashboardPreferences.load(defaults).disabledSoccerCompetitions == ["eng.2"],
              "soccer selection persists")
        check(KyroHomeBackupSettings.dashboard(KyroHomeBackupSettings.dashboardValue(soccerPrefs)) == soccerPrefs,
              "soccer selection survives Settings Backup round-trip")
        var oldBackup: [String: BackupValue] = [:]
        if case .record(let fields) = KyroHomeBackupSettings.dashboardValue(soccerPrefs) { oldBackup = fields }
        oldBackup.removeValue(forKey: "disabledSoccerCompetitions")
        check(KyroHomeBackupSettings.dashboard(.record(oldBackup))?.disabledSoccerCompetitions.isEmpty == true,
              "Build 126 Settings Backup keeps all soccer competitions enabled")
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(soccerPrefs)) as! [String: Any]
        var legacyFields = legacy; legacyFields.removeValue(forKey: "disabledSoccerCompetitions")
        let oldData = try JSONSerialization.data(withJSONObject: legacyFields)
        defaults.set(oldData, forKey: KyroSportsDashboardPreferences.key)
        check(KyroSportsDashboardPreferences.load(defaults).disabledSoccerCompetitions.isEmpty,
              "Build 126 dashboard preferences retain all competitions")

        print("Build 126: \(count) production-path fixture checks passed.")
    }
}
#endif
