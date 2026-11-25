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

/// The device-local Home arrangement (Build 121). Silo's feed stays
/// authoritative: its sections, their content and their relative order come
/// from the server on every load, and nothing here is written back. Kyro only
/// decides where its six shelves sit among those sections, and which are
/// hidden.
///
/// Placement is stored as an ordered token list (`KyroHomeEntry.token`): each
/// Kyro shelf is anchored after the nearest Silo section before it in that
/// list, so server additions, removals and reordering never shift a shelf by
/// array offset. A shelf whose anchor disappears falls back to the previous
/// surviving section (or the top); new server sections appear in server order.
struct KyroHomeArrangement: Codable, Equatable, Sendable {
    /// Kyro's default shelf order, after Continue Watching and Next Up.
    static let defaultShelfOrder: [KyroHomeShelf] = [
        .sportsToday, .recentLiveTV, .favoriteLiveTV, .myTeams, .myLeagues, .upcomingSports,
    ]

    /// Customized placement; nil keeps the default, which adapts to the feed.
    var tokens: [String]?
    var hidden: Set<KyroHomeShelf> = []

    init(tokens: [String]? = nil, hidden: Set<KyroHomeShelf> = []) {
        self.tokens = tokens
        self.hidden = hidden
    }

    var isDefault: Bool { tokens == nil && hidden.isEmpty }

    /// Silo sections in Home order: server order, except that Continue
    /// Watching and Next Up lead (their own server order kept).
    static func siloOrder(_ sections: [KyroHomeSiloSection]) -> [KyroHomeSiloSection] {
        sections.filter(\.leadsHome) + sections.filter { !$0.leadsHome }
    }

    /// Every row, hidden shelves included, for the customization list.
    func allEntries(for sections: [KyroHomeSiloSection]) -> [KyroHomeEntry] {
        let silo = Self.siloOrder(deduplicated(sections))
        let present = Set(silo.map(\.id))
        var groups: [String?: [KyroHomeShelf]] = [:]
        var placed = Set<KyroHomeShelf>()

        if let tokens {
            var anchor: String?
            for token in tokens {
                switch KyroHomeEntry(token: token) {
                case .silo(let id)?:
                    if present.contains(id) { anchor = id }
                case .kyro(let shelf)?:
                    guard placed.insert(shelf).inserted else { continue }
                    groups[anchor, default: []].append(shelf)
                case nil:
                    continue
                }
            }
        }
        // Default placement, and any shelf a stored list does not mention yet.
        let defaultAnchor = silo.last(where: \.leadsHome)?.id
        for shelf in Self.defaultShelfOrder where !placed.contains(shelf) {
            groups[defaultAnchor, default: []].append(shelf)
        }

        var result = (groups[nil] ?? []).map(KyroHomeEntry.kyro)
        for section in silo {
            result.append(.silo(section.id))
            result += (groups[section.id] ?? []).map(KyroHomeEntry.kyro)
        }
        return result
    }

    /// The rows Home draws, without hidden shelves.
    func entries(for sections: [KyroHomeSiloSection]) -> [KyroHomeEntry] {
        allEntries(for: sections).filter {
            if case .kyro(let shelf) = $0 { return !hidden.contains(shelf) }
            return true
        }
    }

    /// Records a customized order (the customization list after a move).
    /// Silo rows only anchor; their order still comes from the server.
    mutating func setOrder(_ entries: [KyroHomeEntry]) {
        tokens = entries.map(\.token)
    }

    /// Moves one Kyro shelf a row up or down among all rows.
    mutating func move(_ shelf: KyroHomeShelf, by delta: Int, sections: [KyroHomeSiloSection]) {
        var entries = allEntries(for: sections)
        guard let index = entries.firstIndex(of: .kyro(shelf)) else { return }
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
        setOrder(entries)
    }

    mutating func setHidden(_ shelf: KyroHomeShelf, _ isHidden: Bool) {
        if isHidden { hidden.insert(shelf) } else { hidden.remove(shelf) }
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
        var hidden: Set<KyroHomeShelf>?
    }

    static func legacyHidden(from defaults: UserDefaults) -> Set<KyroHomeShelf> {
        guard let data = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode(LegacyPreferences.self, from: data) else { return [] }
        return legacy.hidden ?? []
    }
}
#endif
