#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// A saved station with the date it was saved or last played. The station's
/// details are kept, so Library and History work offline.
struct KyroRadioSavedStation: Codable, Equatable, Identifiable, Sendable {
    var station: KyroRadioStation
    var date: Date
    var id: String { station.id }
}

/// Discover's preferred starting point. Device-local and portable in backups.
struct KyroRadioPreferences: Codable, Equatable, Sendable {
    /// ISO 3166-1 code; nil is worldwide.
    var countryCode: String? = "US"
    var countryName: String? = "United States"
    var state: String?
    /// Radio Browser language name ("english"); nil is any language.
    var language: String?

    static let key = "kyrox.radio.preferences.v1"

    /// Codes are two letters; names stay short. Anything else becomes the default.
    var normalized: Self {
        var copy = self
        if let code = countryCode {
            let upper = code.uppercased()
            copy.countryCode = upper.count == 2 && upper.allSatisfy(\.isLetter) ? upper : nil
        }
        if copy.countryCode == nil { copy.countryName = nil; copy.state = nil }
        copy.countryName = copy.countryName.map { String($0.prefix(100)) }.flatMap { $0.isEmpty ? nil : $0 }
        copy.state = copy.state.map { String($0.prefix(100)) }.flatMap { $0.isEmpty ? nil : $0 }
        copy.language = copy.language.map { String($0.lowercased().prefix(60)) }.flatMap { $0.isEmpty ? nil : $0 }
        return copy
    }

    var discoveryQuery: KyroRadioQuery {
        KyroRadioQuery(countryCode: countryCode, state: state, language: language)
    }

    var regionTitle: String {
        guard countryCode != nil else { return "Worldwide" }
        return [state, countryName ?? countryCode].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Build 139: IPTV music channels keep their favorites in Live TV's favorite
/// store and their history as channel references (no stream addresses), so
/// Radio hands those stations to this owner instead of saving them itself.
@MainActor
protocol KyroRadioExternalStations: AnyObject {
    func isFavorite(_ id: String) -> Bool
    func toggleFavorite(_ station: KyroRadioStation)
    func recordPlay(_ station: KyroRadioStation)
}

/// Radio favorites, listening history and preferences. Favorites are keyed by
/// Radio Browser's stable `stationuuid`. History is local only (never in a
/// portable backup) and bounded.
@MainActor @Observable
final class KyroRadioLibrary {
    static let shared = KyroRadioLibrary()

    static let favoritesKey = "kyrox.radio.favorites.v1"
    static let historyKey = "kyrox.radio.history.v1"
    static let maxFavorites = 500
    static let maxHistory = 50

    /// Newest first.
    private(set) var favorites: [KyroRadioSavedStation] = []
    /// Most recently played first.
    private(set) var history: [KyroRadioSavedStation] = []
    private(set) var preferences = KyroRadioPreferences()

    func updatePreferences(_ change: (inout KyroRadioPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated = updated.normalized
        guard updated != preferences else { return }
        preferences = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: KyroRadioPreferences.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// Owner of IPTV music stations (Build 139). Their IDs are catalog channel
    /// IDs ("<provider>:<channel>"), never Radio Browser UUIDs.
    @ObservationIgnored weak var external: KyroRadioExternalStations?

    static func isExternalID(_ id: String) -> Bool { id.contains(":") }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        reload()
    }

    /// Re-reads everything (after a settings restore).
    func reload() {
        favorites = Self.load(Self.favoritesKey, from: defaults, limit: Self.maxFavorites)
        history = Self.load(Self.historyKey, from: defaults, limit: Self.maxHistory)
        if let data = defaults.data(forKey: KyroRadioPreferences.key),
           let saved = try? JSONDecoder().decode(KyroRadioPreferences.self, from: data) {
            preferences = saved.normalized
        } else {
            preferences = KyroRadioPreferences()
        }
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool {
        if Self.isExternalID(id) { return external?.isFavorite(id) ?? false }
        return favorites.contains { $0.id == id }
    }

    func setFavorite(_ station: KyroRadioStation, _ isFavorite: Bool) {
        if station.iptv != nil || Self.isExternalID(station.id) {
            if isFavorite != self.isFavorite(station.id) { external?.toggleFavorite(station) }
            return
        }
        favorites.removeAll { $0.id == station.id }
        if isFavorite {
            favorites.insert(.init(station: station, date: now()), at: 0)
            if favorites.count > Self.maxFavorites { favorites.removeLast(favorites.count - Self.maxFavorites) }
        }
        save(favorites, Self.favoritesKey)
    }

    func toggleFavorite(_ station: KyroRadioStation) {
        if station.iptv != nil || Self.isExternalID(station.id) { external?.toggleFavorite(station); return }
        setFavorite(station, !isFavorite(station.id))
    }

    /// Saved stations without a stream address (restored from a backup).
    var stationsNeedingDetails: [String] {
        (favorites + history).filter { $0.station.playbackCandidates.isEmpty }.map(\.id)
    }

    /// Updates saved details from fresh directory rows. Order, dates and
    /// stations the directory no longer returns are left as they are.
    func refreshDetails(_ stations: [KyroRadioStation]) {
        let fresh = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func update(_ list: inout [KyroRadioSavedStation]) -> Bool {
            var changed = false
            for index in list.indices {
                if let station = fresh[list[index].id], station != list[index].station {
                    list[index].station = station
                    changed = true
                }
            }
            return changed
        }
        if update(&favorites) { save(favorites, Self.favoritesKey) }
        if update(&history) { save(history, Self.historyKey) }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case recentlyAdded, name
        var id: String { rawValue }
        var title: String { self == .name ? "Name" : "Recently Added" }
    }

    func favorites(matching query: String, sort: Sort) -> [KyroRadioSavedStation] {
        let matching = favorites.filter { $0.station.matches(query) }
        switch sort {
        case .recentlyAdded: return matching
        case .name:
            return matching.sorted {
                $0.station.name.localizedCaseInsensitiveCompare($1.station.name) == .orderedAscending
            }
        }
    }

    // MARK: History

    /// A station started playing: it moves to the top, once.
    func recordPlay(_ station: KyroRadioStation) {
        if station.iptv != nil || Self.isExternalID(station.id) { external?.recordPlay(station); return }
        history.removeAll { $0.id == station.id }
        history.insert(.init(station: station, date: now()), at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        save(history, Self.historyKey)
    }

    func removeFromHistory(_ id: String) {
        history.removeAll { $0.id == id }
        save(history, Self.historyKey)
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
    }

    // MARK: Storage

    /// Portable favorites for Settings Backup: stations as saved, newest first.
    func replaceFavorites(_ saved: [KyroRadioSavedStation]) {
        var seen = Set<String>()
        favorites = Array(saved.filter { seen.insert($0.id).inserted }.prefix(Self.maxFavorites))
        save(favorites, Self.favoritesKey)
    }

    private func save(_ stations: [KyroRadioSavedStation], _ key: String) {
        guard let data = try? JSONEncoder().encode(stations) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(_ key: String, from defaults: UserDefaults, limit: Int) -> [KyroRadioSavedStation] {
        guard let data = defaults.data(forKey: key), data.count <= 4_000_000,
              let saved = try? JSONDecoder().decode(KyroRadioLossyArray<KyroRadioSavedStation>.self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(saved.elements.filter { UUID(uuidString: $0.id) != nil && seen.insert($0.id).inserted }.prefix(limit))
    }
}
#endif
