#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

/// One row of Kyro's integrated Home: a Silo server section, by its stable
/// server `id`, or one of Kyro's six local shelves.
enum KyroHomeEntry: Hashable, Sendable {
    case silo(String)
    case kyro(KyroHomeShelf)

    /// Stable, offset-free token stored in the local arrangement.
    var token: String {
        switch self {
        case .silo(let id): "silo:\(id)"
        case .kyro(let shelf): "kyro:\(shelf.rawValue)"
        }
    }

    init?(token: String) {
        if token.hasPrefix("silo:") {
            let id = String(token.dropFirst(5))
            guard !id.isEmpty else { return nil }
            self = .silo(id)
        } else if token.hasPrefix("kyro:"), let shelf = KyroHomeShelf(rawValue: String(token.dropFirst(5))) {
            self = .kyro(shelf)
        } else {
            return nil
        }
    }
}

/// What the arrangement needs to know about a Silo Home section.
struct KyroHomeSiloSection: Equatable, Sendable {
    let id: String
    let type: String
    var title: String = ""

    /// Continue Watching (and its `in_progress` alias) and Next Up lead the
    /// default arrangement, ahead of Kyro's shelves.
    var leadsHome: Bool {
        let type = type.lowercased()
        return type == "continue_watching" || type == "in_progress" || type == "next_up"
    }
}

/// Device-local presentation order. Server rows remain server-owned; missing
/// identifiers stay in the preference list so a temporarily absent row returns
/// to its chosen position without matching another row by title.
struct KyroHomeArrangement: Codable, Equatable, Sendable {
    /// Kyro's default shelf order, after Continue Watching and Next Up.
    /// Build 128 appends the opt-in radio shelves, which start hidden.
    static let defaultShelfOrder: [KyroHomeShelf] = [
        .sportsToday, .recentLiveTV, .favoriteLiveTV, .myTeams, .myLeagues, .upcomingSports,
        .favoriteRadio, .recentRadio,
    ]

    /// Customized placement; nil keeps the default, which adapts to the feed.
    var tokens: [String]?
    /// Hidden shelves among those shown by default. Opt-in shelves never live here.
    var hidden: Set<KyroHomeShelf> = []
    var hiddenSilo: Set<String> = []
    /// Opt-in shelves (radio) the user turned on. Kept apart from `hidden` so
    /// arrangements and backups saved before Build 128 keep them off.
    var shownOptIn: Set<KyroHomeShelf> = []

    init(tokens: [String]? = nil, hidden: Set<KyroHomeShelf> = [], hiddenSilo: Set<String> = [],
         shownOptIn: Set<KyroHomeShelf> = []) {
        self.tokens = tokens
        self.hidden = hidden.filter { !$0.isOptIn }
        self.hiddenSilo = hiddenSilo
        self.shownOptIn = shownOptIn.filter(\.isOptIn)
    }

    private enum CodingKeys: String, CodingKey { case tokens, hidden, hiddenSilo, shownOptIn }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try values.decodeIfPresent([String].self, forKey: .tokens)
        // Unknown shelf names (a newer build's) are skipped, not fatal.
        hidden = Set((try? values.decodeIfPresent([String].self, forKey: .hidden))??
            .compactMap(KyroHomeShelf.init(rawValue:)).filter { !$0.isOptIn } ?? [])
        hiddenSilo = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenSilo) ?? []
        shownOptIn = Set((try? values.decodeIfPresent([String].self, forKey: .shownOptIn))??
            .compactMap(KyroHomeShelf.init(rawValue:)).filter(\.isOptIn) ?? [])
    }

    var isDefault: Bool { tokens == nil && hidden.isEmpty && hiddenSilo.isEmpty && shownOptIn.isEmpty }

    /// Whether Home leaves the shelf out: opt-in shelves unless turned on,
    /// other shelves when hidden.
    func isHidden(_ shelf: KyroHomeShelf) -> Bool {
        shelf.isOptIn ? !shownOptIn.contains(shelf) : hidden.contains(shelf)
    }

    /// Silo sections in Home order: server order, except that Continue
    /// Watching and Next Up lead (their own server order kept).
    static func siloOrder(_ sections: [KyroHomeSiloSection]) -> [KyroHomeSiloSection] {
        sections.filter(\.leadsHome) + sections.filter { !$0.leadsHome }
    }

    /// Every row, hidden shelves included, for the customization list.
    func allEntries(for sections: [KyroHomeSiloSection]) -> [KyroHomeEntry] {
        let silo = Self.siloOrder(deduplicated(sections))
        guard let tokens else {
            let leadCount = silo.prefix(while: \.leadsHome).count
            return silo.prefix(leadCount).map { .silo($0.id) }
                + Self.defaultShelfOrder.map(KyroHomeEntry.kyro)
                + silo.dropFirst(leadCount).map { .silo($0.id) }
        }
        var result: [KyroHomeEntry] = []
        var seen = Set<KyroHomeEntry>()
        for token in tokens {
            guard let entry = KyroHomeEntry(token: token), seen.insert(entry).inserted else { continue }
            result.append(entry)
        }
        // New server rows are appended in server order; existing positions do
        // not move when the server changes its order or a row disappears.
        for section in silo {
            let entry = KyroHomeEntry.silo(section.id)
            if seen.insert(entry).inserted { result.append(entry) }
        }
        for shelf in Self.defaultShelfOrder {
            let entry = KyroHomeEntry.kyro(shelf)
            if seen.insert(entry).inserted { result.append(entry) }
        }
        return result
    }

    /// The rows Home draws, without hidden shelves.
    func entries(for sections: [KyroHomeSiloSection]) -> [KyroHomeEntry] {
        let present = Set(sections.map(\.id))
        return allEntries(for: sections).filter {
            if case .kyro(let shelf) = $0 { return !isHidden(shelf) }
            if case .silo(let id) = $0 { return present.contains(id) && !hiddenSilo.contains(id) }
            return false
        }
    }

    /// Records a customized order (the customization list after a move).
    mutating func setOrder(_ entries: [KyroHomeEntry]) {
        tokens = entries.map(\.token)
    }

    /// Moves either row type, including currently unavailable server rows.
    mutating func move(_ entry: KyroHomeEntry, by delta: Int, sections: [KyroHomeSiloSection]) {
        var entries = allEntries(for: sections)
        guard let index = entries.firstIndex(of: entry) else { return }
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
        setOrder(entries)
    }

    mutating func move(_ shelf: KyroHomeShelf, by delta: Int, sections: [KyroHomeSiloSection]) {
        move(.kyro(shelf), by: delta, sections: sections)
    }

    mutating func setHidden(_ shelf: KyroHomeShelf, _ isHidden: Bool) {
        if shelf.isOptIn {
            if isHidden { shownOptIn.remove(shelf) } else { shownOptIn.insert(shelf) }
        } else if isHidden { hidden.insert(shelf) } else { hidden.remove(shelf) }
    }

    mutating func setHiddenSilo(_ id: String, _ isHidden: Bool) {
        if isHidden { hiddenSilo.insert(id) } else { hiddenSilo.remove(id) }
    }

    private func deduplicated(_ sections: [KyroHomeSiloSection]) -> [KyroHomeSiloSection] {
        var seen = Set<String>()
        return sections.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Storage

/// Per server, account and profile; never sent to the server.
enum KyroHomeArrangementStore {
    static let keyPrefix = "kyrox.home.arrangement.v2"
    /// Build 120's device-wide shelf preferences. Its hidden shelves seed the
    /// first scoped arrangement; its append-only order does not apply.
    static let legacyKey = "kyrox.home.localShelves.v1"
    /// Without a signed-in profile (empty or failed feed before sign-in).
    static let unscopedSuffix = "device"

    static func key(scope: String?) -> String {
        "\(keyPrefix).\(scope ?? unscopedSuffix)"
    }

    static func load(scope: String?, from defaults: UserDefaults) -> KyroHomeArrangement {
        if let data = defaults.data(forKey: key(scope: scope)),
           let decoded = try? JSONDecoder().decode(KyroHomeArrangement.self, from: data) {
            return decoded
        }
        return KyroHomeArrangement(hidden: legacyHidden(from: defaults))
    }

    static func save(_ arrangement: KyroHomeArrangement, scope: String?, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(arrangement) else { return }
        defaults.set(data, forKey: key(scope: scope))
    }

    private struct LegacyPreferences: Decodable {
        var hidden: [String]?
    }

    static func legacyHidden(from defaults: UserDefaults) -> Set<KyroHomeShelf> {
        guard let data = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode(LegacyPreferences.self, from: data) else { return [] }
        return Set((legacy.hidden ?? []).compactMap(KyroHomeShelf.init(rawValue:)))
    }
}
#endif
