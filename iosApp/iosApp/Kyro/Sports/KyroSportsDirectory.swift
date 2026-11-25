#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

enum KyroSportsDirectorySport: String, CaseIterable, Sendable {
    case football, basketball, baseball, hockey, soccer, tennis
    var title: String { rawValue.capitalized }
}

struct KyroSportsDirectoryRoute: Identifiable, Hashable, Sendable {
    let league: KyroSportLeague
    let path: String
    let title: String
    var id: String { "espn/" + path }
    var sport: KyroSportsDirectorySport {
        KyroSportsDirectorySport(rawValue: String(path.split(separator: "/")[0]))!
    }
    var slug: String { String(path.split(separator: "/")[1]) }
    var hasTeamDirectory: Bool { sport != .tennis }

    func contains(_ game: KyroSportsGame) -> Bool {
        league == game.league && (league != .soccer || game.competitionKey == slug)
    }

    static var all: [Self] {
        let core: [(KyroSportLeague, String)] = [(.nfl, "football/nfl"), (.nba, "basketball/nba"),
            (.mlb, "baseball/mlb"), (.nhl, "hockey/nhl"), (.collegeFootball, "football/college-football"),
            (.collegeBasketballMen, "basketball/mens-college-basketball"),
            (.collegeBasketballWomen, "basketball/womens-college-basketball")]
        return core.map { Self(league: $0.0, path: $0.1, title: $0.0.displayName) }
            // Directory-only: do not expand the Hub's soccer scoreboard fan-out.
            + [Self(league: .soccer, path: "soccer/eng.2", title: "EFL Championship")]
            + KyroSoccerCompetitionRegistry.verified.map { Self(league: .soccer, path: "soccer/" + $0.key, title: $0.name) }
            + [Self(league: .atp, path: "tennis/atp", title: "ATP"),
               Self(league: .wta, path: "tennis/wta", title: "WTA")]
    }
}

struct KyroSportsDirectoryScope: Hashable, Sendable {
    var sport: KyroSportsDirectorySport?
    var routeID: String?
    var routes: [KyroSportsDirectoryRoute] {
        KyroSportsDirectoryRoute.all.filter {
            (sport == nil || $0.sport == sport) && (routeID == nil || $0.id == routeID)
        }
    }
}

struct KyroSportsDirectoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let league: KyroSportLeague
    let name: String
    let abbreviation: String
    let aliases: [String]
    let logo: URL?
    let affiliation: String
    var team: KyroSportsTeam {
        .init(id: id, league: league, abbreviation: abbreviation, nickname: name,
              logoURL: logo, alternateNames: aliases)
    }
    func matches(_ query: String) -> Bool {
        let needle = KyroSportsFavorites.normalized(query)
        return needle.isEmpty || ([name, abbreviation, affiliation, league.displayName] + aliases)
            .contains { KyroSportsFavorites.normalized($0).contains(needle) }
    }
}

/// User-opened directories only: one request per route, at most once a day automatically,
/// explicit refresh throttled to one minute (five seconds after a failure).
/// Failed responses never replace durable data.
@MainActor @Observable
final class KyroSportsDirectory {
    static let shared = KyroSportsDirectory()
    private(set) var entries: [String: [KyroSportsDirectoryEntry]] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    var loading: Set<String> { Set(requests.keys) }
    private(set) var failures: Set<String> = []
    private var attempts: [String: Date] = [:]
    private let defaults: UserDefaults
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct Cache: Codable { let date: Date; let entries: [KyroSportsDirectoryEntry] }
    init(defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
             return (data, http)
         }) {
        self.defaults = defaults
        self.fetch = fetch
        for route in KyroSportsDirectoryRoute.all {
            if let cache = cached(route) { entries[route.id] = cache.entries }
        }
    }
    // Build 124 did not verify response sport/league metadata. Don't trust its
    // snapshots as current membership; favorites use independent, unchanged IDs.
    private func cacheKey(_ route: KyroSportsDirectoryRoute) -> String { "kyrox.directory.v2." + route.id }

    private func cached(_ route: KyroSportsDirectoryRoute) -> Cache? {
        guard let data = defaults.data(forKey: cacheKey(route)), data.count <= 2_000_000 else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    var allEntries: [KyroSportsDirectoryEntry] {
        results(in: .init(), matching: "", schedules: [])
    }

    func results(in scope: KyroSportsDirectoryScope, matching query: String,
                 schedules: [KyroSportsGame]) -> [KyroSportsDirectoryEntry] {
        let routes = scope.routes
        var candidates: [KyroSportsDirectoryEntry] = []
        for route in routes {
            if let roster = entries[route.id] {
                candidates += roster
            } else {
                for game in schedules where route.contains(game) {
                    for team in [game.away.team, game.home.team] where team.league == route.league {
                        candidates.append(.init(id: team.id, league: team.league, name: team.fullName,
                            abbreviation: team.abbreviation, aliases: team.alternateNames + [team.nickname, team.location ?? ""],
                            logo: team.logoURL ?? team.flagURL, affiliation: route.title))
                    }
                }
            }
        }
        // Scope first; a soccer club can belong to several competitions without
        // inheriting the other competition labels in a single-league search.
        var unique: [String: KyroSportsDirectoryEntry] = [:]
        var affiliations: [String: Set<String>] = [:]
        for entry in candidates {
            guard affiliations[entry.id, default: []].insert(entry.affiliation).inserted else { continue }
            if let previous = unique[entry.id] {
                unique[entry.id] = .init(id: previous.id, league: previous.league, name: previous.name,
                    abbreviation: previous.abbreviation,
                    aliases: previous.aliases + entry.aliases + [entry.name, entry.abbreviation],
                    logo: previous.logo ?? entry.logo,
                    affiliation: previous.affiliation + " · " + entry.affiliation)
            } else { unique[entry.id] = entry }
        }
        return unique.values.filter { $0.matches(query) }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func undiscovered(in scope: KyroSportsDirectoryScope) -> [KyroSportsDirectoryRoute] {
        scope.routes.filter {
            $0.hasTeamDirectory && entries[$0.id] == nil && !failures.contains($0.id) && !loading.contains($0.id)
        }
    }

    func load(_ route: KyroSportsDirectoryRoute, force: Bool = false) async {
        guard route.hasTeamDirectory, !Task.isCancelled else { return }
        if let request = requests[route.id] { return await request.value }
        if requests.count >= 3, let pending = requests.values.first {
            await pending.value
            return await load(route, force: force)
        }
        let now = Date()
        if let attempt = attempts[route.id], now.timeIntervalSince(attempt) < (failures.contains(route.id) ? 5 : 60) { return }
        if !force, let cache = cached(route), now.timeIntervalSince(cache.date) < 86400 { return }
        attempts[route.id] = now
        // Keep a started request reusable if the user switches away and back.
        // Its only write is to the original route, never to the active picker.
        let request = Task { await fetchDirectory(route, at: now) }
        requests[route.id] = request
        await request.value
    }

    private func fetchDirectory(_ route: KyroSportsDirectoryRoute, at now: Date) async {
        defer { requests.removeValue(forKey: route.id) }
        do {
            let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(route.path)/teams?limit=1000")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard response.statusCode == 200, data.count <= 4_000_000 else { throw URLError(.badServerResponse) }
            let decoded = try Self.decode(data, route: route)
            guard !decoded.isEmpty else { throw URLError(.cannotParseResponse) }
            let encoded = try JSONEncoder().encode(Cache(date: now, entries: decoded))
            guard encoded.count <= 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            defaults.set(encoded, forKey: cacheKey(route))
            entries[route.id] = decoded
            failures.remove(route.id)
        } catch {
            failures.insert(route.id)
        }
    }
    nonisolated static func decode(_ data: Data, route: KyroSportsDirectoryRoute) throws -> [KyroSportsDirectoryEntry] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sports = root?["sports"] as? [[String: Any]] ?? []
        var result: [KyroSportsDirectoryEntry] = []
        var seen = Set<String>()
        for sport in sports where sport["slug"] as? String == route.sport.rawValue {
            for league in sport["leagues"] as? [[String: Any]] ?? [] where league["slug"] as? String == route.slug {
                for row in league["teams"] as? [[String: Any]] ?? [] {
                    guard let team = row["team"] as? [String: Any], let id = team["id"] as? String,
                          let name = team["displayName"] as? String, !name.isEmpty, !id.isEmpty else { continue }
                    let key = "espn.\(route.league.rawValue).\(id)"
                    guard seen.insert(key).inserted else { continue }
                    let logos = team["logos"] as? [[String: Any]]
                    let logo = (logos?.first?["href"] as? String).flatMap(URL.init(string:))
                    result.append(.init(id: key, league: route.league, name: name,
                        abbreviation: team["abbreviation"] as? String ?? "",
                        aliases: ["shortDisplayName", "location", "name"].compactMap { team[$0] as? String },
                        logo: logo?.scheme == "https" ? logo : nil, affiliation: route.title))
                }
            }
        }
        return Array(result.prefix(1000))
    }
}
#endif
