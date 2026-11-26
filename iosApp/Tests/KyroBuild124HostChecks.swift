#if KYRO_STANDALONE_TESTS
import Foundation

private actor RequestCounter {
    var calls = 0
    func record() { calls += 1 }
}

private actor RequestGate {
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func suspendRequest() async {
        await withCheckedContinuation { release = $0; started?.resume(); started = nil }
    }

    func waitUntilStarted() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() { release?.resume(); release = nil }
}

@main @MainActor
enum KyroBuild124HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) { precondition(condition, title); count += 1 }
    static func main() async throws {
        let suite = "kyro.build124.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = KyroSportsDirectoryRoute.all[0]
        let data = Data(#"{"sports":[{"slug":"football","leagues":[{"slug":"nfl","teams":[{"team":{"id":"3","displayName":"Chicago Bears","abbreviation":"CHI","shortDisplayName":"Bears","logos":[{"href":"https://example.com/bears.png"}]}},{"team":{"id":"3","displayName":"Chicago Bears"}},{"team":{"displayName":"Broken"}}]}]}]}"#.utf8)
        let decoded = try KyroSportsDirectory.decode(data, route: route)
        check(decoded.count == 1 && decoded[0].id == "espn.nfl.3", "decode stable ID and deduplicate")
        check(decoded[0].logo != nil && decoded[0].affiliation == "NFL", "logo and league")
        check(decoded[0].matches("chi") && decoded[0].matches("BEARS") && decoded[0].matches("NFL"), "abbreviations, aliases and league search without games")
        check(!decoded[0].matches("Packers"), "search excludes other teams")
        let counter = RequestCounter()
        let directory = KyroSportsDirectory(defaults: defaults, fetch: { request in
            await counter.record()
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await directory.load(route)
        check(directory.allEntries == decoded, "production load and cache")
        await directory.load(route, force: true)
        let calls = await counter.calls
        check(calls == 1, "explicit refresh is throttled and does not fan out")
        let failing = KyroSportsDirectory(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })
        check(failing.allEntries == decoded, "persistent cache on recreation")
        await failing.load(route)
        check(failing.failures.isEmpty, "fresh persistent cache avoids network requests")
        await failing.load(route, force: true)
        check(failing.failures.contains(route.id) && failing.allEntries == decoded, "failed refresh preserves cache")
        let malformed = KyroSportsDirectory(defaults: defaults, fetch: { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await malformed.load(route, force: true)
        check(malformed.allEntries == decoded && malformed.failures.contains(route.id), "empty payload cannot erase cache")
        let women = KyroSportsDirectoryRoute.all.first { $0.league == .collegeBasketballWomen }!
        let womenDecoded = try KyroSportsDirectory.decode(fixture(women, name: "Chicago Bears"), route: women)
        check(womenDecoded[0].id != decoded[0].id && womenDecoded[0].league == .collegeBasketballWomen, "same raw ID is namespaced across leagues")
        let favorites = KyroSportsFavoritesStore(defaults: defaults)
        let team = decoded[0].team
        favorites.preferences.teams.insert("nfl|Chicago Bears")
        KyroHomeQuickAdd.select(team, favorites: favorites, wants: true)
        check(favorites.preferences.teams == ["nfl|Chicago Bears"], "legacy favorite stays intact without duplicate migration")
        KyroHomeQuickAdd.select(team, favorites: favorites, wants: false)
        check(favorites.preferences.teams.isEmpty, "legacy removal without scheduled games")
        KyroHomeQuickAdd.select(team, favorites: favorites, wants: true)
        KyroHomeQuickAdd.select(team, favorites: favorites, wants: true)
        check(favorites.preferences.teams.count == 1 && favorites.preferences.includes(team), "stable add is idempotent")
        let other = KyroSportsTeam(id: "espn.nfl.999", league: .nfl, abbreviation: "CHI", nickname: team.fullName)
        check(!favorites.preferences.includes(other), "same name with different provider ID does not merge")
        let nba = KyroSportsTeam(id: "espn.nba.3", league: .nba, abbreviation: "CHI", nickname: team.fullName)
        check(!favorites.preferences.includes(nba), "different league does not merge")
        let renamed = KyroSportsTeam(id: team.id, league: team.league, abbreviation: "NEW", nickname: "Renamed")
        check(favorites.preferences.includes(renamed), "stable identity survives rename")
        let prefs = KyroSportsDashboardSettings(defaults: defaults)
        prefs.value.order.reverse(); prefs.value.hidden = [.nba]; prefs.value.showLive = false; prefs.value.defaultLeague = "mlb"
        check(KyroSportsDashboardPreferences.load(defaults) == prefs.value, "dashboard persistence")
        func game(_ status: KyroGameStatus, league: KyroSportLeague = .nfl) -> KyroSportsGame {
            .init(id: .init(provider: "fixture", league: league, rawID: "1"), league: league,
                  startTime: nil, status: status, home: .init(team: team), away: .init(team: team))
        }
        check(!prefs.value.includes(game(.live)) && prefs.value.includes(game(.scheduled)), "live and upcoming dashboard filters")
        check(!prefs.value.includes(game(.scheduled, league: .nba)), "disabled leagues filtered independently of favorites")
        prefs.value.showCompleted = false
        check(!prefs.value.includes(game(.final)), "completed visibility filter")
        check(KyroHomeBackupSettings.dashboard(KyroHomeBackupSettings.dashboardValue(prefs.value)) == prefs.value, "dashboard backup round trip")
        check(KyroHomeBackupSettings.dashboard(.record([:])) == nil, "invalid dashboard rejected")
        let registry = KyroHomeBackupSettings.make(defaults: defaults)
        let saved = registry.map { ($0, $0.read()!) }
        defaults.removeObject(forKey: KyroSportsFavorites.teamsKey)
        defaults.removeObject(forKey: KyroSportsDashboardPreferences.key)
        for (setting, value) in saved { try setting.write(value) }
        favorites.reload(); prefs.reload()
        check(favorites.preferences.includes(team) && prefs.value.defaultLeague == "mlb", "shared stores reload backup")
        favorites.toggle(renamed)
        check(favorites.preferences.teams.isEmpty, "remove renamed stable favorite")
        try await checkDirectoryScopes(defaults: defaults)
        print("Build 124/125: \(count) production-path fixture checks passed.")
        if CommandLine.arguments.contains("--live-samples") {
            for (routeID, file) in [("football/nfl", "nfl"), ("basketball/womens-college-basketball", "ncaaw"), ("soccer/eng.1", "soccer")] {
                let sample = try Data(contentsOf: URL(fileURLWithPath: "artifacts/build124/\(file).json"))
                let liveRoute = KyroSportsDirectoryRoute.all.first { $0.path == routeID }!
                let teams = try KyroSportsDirectory.decode(sample, route: liveRoute)
                check(!teams.isEmpty, "live provider payload decodes through production directory path")
                print("Live sample \(routeID): \(teams.count) decoded entries")
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--live-directory") {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            for route in KyroSportsDirectoryRoute.all where route.hasTeamDirectory {
                let file = folder.appendingPathComponent(route.slug + ".json")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let teams = try KyroSportsDirectory.decode(Data(contentsOf: file), route: route)
                check(!teams.isEmpty, "live payload decodes for \(route.path)")
                if route.slug == "eng.2" {
                    check(teams.contains { $0.id == "espn.soccer.352" && $0.matches("Wrexham") && $0.matches("WXM") },
                        "live Championship directory includes Wrexham via name, ID and abbreviation")
                } else if route.slug == "eng.1" {
                    check(!teams.contains { $0.id == "espn.soccer.352" }, "live Premier League directory excludes Wrexham")
                }
                print("Live ESPN \(route.path): \(teams.count) entries")
            }
        }
    }

    private static func fixture(_ route: KyroSportsDirectoryRoute, name: String, id: String = "3") -> Data {
        Data("""
        {"sports":[{"slug":"\(route.sport.rawValue)","leagues":[{"slug":"\(route.slug)","teams":[
          {"team":{"id":"\(id)","displayName":"\(name)","shortDisplayName":"Test Alias","abbreviation":"TST"}}
        ]}]}]}
        """.utf8)
    }

    private static func checkDirectoryScopes(defaults: UserDefaults) async throws {
        func route(_ slug: String) -> KyroSportsDirectoryRoute {
            KyroSportsDirectoryRoute.all.first { $0.slug == slug }!
        }
        let nfl = route("nfl"), nba = route("nba"), college = route("college-football")
        let women = route("womens-college-basketball"), men = route("mens-college-basketball")
        let premier = route("eng.1"), championship = route("eng.2"), cup = route("uefa.champions"), tennis = route("atp")
        let payloads = [nfl: fixture(nfl, name: "Chicago Bears"), nba: fixture(nba, name: "Chicago Bulls"),
            college: fixture(college, name: "Alabama Crimson Tide"),
            women: fixture(women, name: "Alabama Crimson Tide"), men: fixture(men, name: "Alabama Crimson Tide"),
            premier: fixture(premier, name: "Arsenal", id: "359"),
            championship: fixture(championship, name: "Wrexham", id: "352"),
            cup: fixture(cup, name: "Arsenal", id: "359")]
        let wrongLeague = try KyroSportsDirectory.decode(payloads[championship]!, route: premier)
        let wrongSport = try KyroSportsDirectory.decode(payloads[college]!, route: premier)
        check(wrongLeague.isEmpty && wrongSport.isEmpty, "provider metadata rejects wrong league and wrong sport")
        let directory = KyroSportsDirectory(defaults: defaults, fetch: { request in
            guard let payload = payloads.first(where: { request.url!.path.hasSuffix("/" + $0.key.path + "/teams") })?.value
            else { throw URLError(.badURL) }
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for route in [nfl, nba, college, women, men, premier, championship, cup] { await directory.load(route) }
        let cached = KyroSportsDirectory(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) })
        func schedule(_ league: KyroSportLeague, name: String, competition: String? = nil,
                      teamLeague: KyroSportLeague? = nil) -> KyroSportsGame {
            let team = KyroSportsTeam(id: "fixture.\(league.rawValue).\(name)", league: teamLeague ?? league,
                                      abbreviation: "FIX", nickname: name, alternateNames: ["Match alias"])
            return .init(id: .init(provider: "fixture", league: league, rawID: name), league: league,
                startTime: nil, status: .scheduled, home: .init(team: team), away: .init(team: team),
                competitionKey: competition)
        }
        let games = [schedule(.soccer, name: "Wrexham Cup", competition: "eng.league_cup"),
            schedule(.soccer, name: "MLS club", competition: "usa.1"), schedule(.soccer, name: "Unscoped"),
            schedule(.soccer, name: "Badly tagged Alabama", competition: "usa.1", teamLeague: .collegeFootball),
            schedule(.atp, name: "ATP player"), schedule(.wta, name: "WTA player"),
            schedule(.nhl, name: "Schedule-only club")]
        func search(_ route: KyroSportsDirectoryRoute, _ query: String = "") -> [KyroSportsDirectoryEntry] {
            cached.results(in: .init(sport: route.sport, routeID: route.id), matching: query, schedules: games)
        }
        check(search(nfl).map(\.name) == ["Chicago Bears"], "NFL-only with mixed cache and schedules")
        check(search(nba, "Chicago").map(\.name) == ["Chicago Bulls"], "NBA-only search despite similar names")
        check(search(women, "alabama").map(\.league) == [.collegeBasketballWomen] &&
              search(men, "alabama").map(\.league) == [.collegeBasketballMen], "college league separation")
        check(search(premier, "alabama").isEmpty && search(premier, "Wrexham").isEmpty, "Premier League search scoped")
        check(search(championship, "Wrexham").map(\.affiliation) == ["EFL Championship"], "offseason Championship discovery")
        check(search(premier, "Arsenal").map(\.affiliation) == ["English Premier League"], "single league shows only its affiliation")
        let arsenal = cached.results(in: .init(sport: .soccer), matching: "Arsenal", schedules: games)
        check(arsenal.count == 1 && arsenal[0].affiliation.contains(cup.title), "same club across leagues is one favorite")
        check(search(route("usa.1")).map(\.name) == ["MLS club"], "fallback uses competition and participant league")
        check(search(tennis, "match alias").map(\.name) == ["ATP player"], "tennis schedule alias and tour filtering")
        check(cached.results(in: .init(sport: .basketball), matching: "", schedules: games).count == 3,
              "sport selection excludes other sports")
        check(cached.results(in: .init(), matching: "alabama", schedules: games).count == 3, "All Sports search uses mixed cache")
        check(cached.results(in: .init(), matching: "Schedule-only", schedules: games).count == 1, "All Sports includes fallback")
        check(cached.results(in: .init(sport: .soccer, routeID: nba.id), matching: "", schedules: games).isEmpty,
              "incompatible sport and league cannot leak")

        let suite = "kyro.switch.\(UUID())"
        let fresh = UserDefaults(suiteName: suite)!
        defer { fresh.removePersistentDomain(forName: suite) }
        let gate = RequestGate()
        let requests = RequestCounter()
        let switching = KyroSportsDirectory(defaults: fresh, fetch: { request in
            let isNFL = request.url!.path.hasSuffix("/nfl/teams")
            await requests.record()
            if isNFL { await gate.suspendRequest() }
            return (isNFL ? payloads[nfl]! : payloads[nba]!,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let old = Task { await switching.load(nfl) }
        await gate.waitUntilStarted()
        old.cancel()
        await switching.load(nba)
        let nbaScope = KyroSportsDirectoryScope(sport: .basketball, routeID: nba.id)
        check(switching.results(in: nbaScope, matching: "", schedules: []).map(\.name) == ["Chicago Bulls"],
              "new selection completes while old request is pending")
        let back = Task { await switching.load(nfl) }
        await gate.finish()
        await old.value
        await back.value
        let calls = await requests.calls
        check(calls == 2 && switching.entries[nfl.id] != nil, "switch back reuses original request or its result")
        check(switching.results(in: nbaScope, matching: "", schedules: []).map(\.name) == ["Chicago Bulls"],
              "late old response does not overwrite new selection")
    }
}
#endif
