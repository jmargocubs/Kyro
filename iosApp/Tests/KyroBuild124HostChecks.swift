#if KYRO_STANDALONE_TESTS
import Foundation

private actor RequestCounter {
    var calls = 0
    func record() { calls += 1 }
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
        let data = Data(#"{"sports":[{"leagues":[{"teams":[{"team":{"id":"3","displayName":"Chicago Bears","abbreviation":"CHI","shortDisplayName":"Bears","logos":[{"href":"https://example.com/bears.png"}]}},{"team":{"id":"3","displayName":"Chicago Bears"}},{"team":{"displayName":"Broken"}}]}]}]}"#.utf8)
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
        let womenDecoded = try KyroSportsDirectory.decode(data, route: women)
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
        check(KyroSportsDirectoryRoute.all.count == 52, "seven team routes plus 45 soccer routes")
        print("Build 124: \(count) production-path fixture checks passed.")
        if CommandLine.arguments.contains("--live-samples") {
            for (routeID, file) in [("football/nfl", "nfl"), ("basketball/womens-college-basketball", "ncaaw"), ("soccer/eng.1", "soccer")] {
                let sample = try Data(contentsOf: URL(fileURLWithPath: "artifacts/build124/\(file).json"))
                let liveRoute = KyroSportsDirectoryRoute.all.first { $0.id == routeID }!
                let teams = try KyroSportsDirectory.decode(sample, route: liveRoute)
                check(!teams.isEmpty, "live provider payload decodes through production directory path")
                print("Live sample \(routeID): \(teams.count) decoded entries")
            }
        }
    }
}
#endif
