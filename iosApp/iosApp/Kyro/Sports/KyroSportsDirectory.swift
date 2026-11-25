#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

struct KyroSportsDirectoryRoute: Identifiable, Sendable {
    let league: KyroSportLeague
    let path: String
    let title: String
    var id: String { path }
    static var all: [Self] {
        let core: [(KyroSportLeague, String)] = [(.nfl, "football/nfl"), (.nba, "basketball/nba"),
            (.mlb, "baseball/mlb"), (.nhl, "hockey/nhl"), (.collegeFootball, "football/college-football"),
            (.collegeBasketballMen, "basketball/mens-college-basketball"),
            (.collegeBasketballWomen, "basketball/womens-college-basketball")]
        return core.map { Self(league: $0.0, path: $0.1, title: $0.0.displayName) }
            + KyroSoccerCompetitionRegistry.verified.map { Self(league: .soccer, path: "soccer/" + $0.key, title: $0.name) }
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
/// explicit refresh throttled to one minute. Failed responses never replace durable data.
@MainActor @Observable
final class KyroSportsDirectory {
    static let shared = KyroSportsDirectory()
    private(set) var entries: [String: [KyroSportsDirectoryEntry]] = [:]
    private(set) var loading: Set<String> = []
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
    private func cached(_ route: KyroSportsDirectoryRoute) -> Cache? {
        guard let data = defaults.data(forKey: "kyrox.directory." + route.id), data.count <= 2_000_000 else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }
    var allEntries: [KyroSportsDirectoryEntry] {
        var unique: [String: KyroSportsDirectoryEntry] = [:]
        for entry in entries.keys.sorted().flatMap({ entries[$0] ?? [] }) {
            if let previous = unique[entry.id] {
                unique[entry.id] = .init(id: entry.id, league: entry.league, name: entry.name,
                    abbreviation: entry.abbreviation, aliases: entry.aliases, logo: entry.logo ?? previous.logo,
                    affiliation: previous.affiliation + " · " + entry.affiliation)
            } else { unique[entry.id] = entry }
        }
        return unique.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
    func load(_ route: KyroSportsDirectoryRoute, force: Bool = false) async {
        guard !loading.contains(route.id) else { return }
        let now = Date()
        if let attempt = attempts[route.id], now.timeIntervalSince(attempt) < 60 { return }
        if !force, let cache = cached(route), now.timeIntervalSince(cache.date) < 86400 { return }
        attempts[route.id] = now
        loading.insert(route.id)
        defer { loading.remove(route.id) }
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
            defaults.set(encoded, forKey: "kyrox.directory." + route.id)
            entries[route.id] = decoded
            failures.remove(route.id)
        } catch {
            if Task.isCancelled { attempts.removeValue(forKey: route.id) }
            else { failures.insert(route.id) }
        }
    }
    nonisolated static func decode(_ data: Data, route: KyroSportsDirectoryRoute) throws -> [KyroSportsDirectoryEntry] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sports = root?["sports"] as? [[String: Any]] ?? []
        var result: [KyroSportsDirectoryEntry] = []
        var seen = Set<String>()
        for sport in sports {
            for league in sport["leagues"] as? [[String: Any]] ?? [] {
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
