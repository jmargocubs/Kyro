#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import CryptoKit

/// Settings Backup entries for Kyro's Home (Build 121).
///
/// `home.localShelves` holds the current profile's Home arrangement:
/// `{"version": 2, "order": [...], "hidden": [...]}`. `order` holds
/// `silo:<server section id>` anchors and `kyro:<shelf>` entries; an empty list
/// means the default arrangement. (Backup field names may not contain
/// "token", so the stored tokens travel as `order`.) Build 120 files (`{"order", "hidden"}`, its
/// device-wide append-only shelves) still restore: their hidden shelves apply
/// and the arrangement returns to the default.
enum KyroHomeBackupSettings {
    private struct InvalidValue: Error {}

    @MainActor
    static func make(defaults: UserDefaults, scope: @escaping @MainActor () -> String? = { nil }) -> [BackupSetting] {
        [BackupSetting(id: "sports.dashboard", group: .sports, title: "Sports dashboard",
            validate: { dashboard($0) != nil },
            read: { dashboardValue(.load(defaults)) },
            write: { value in
                guard let prefs = dashboard(value) else { throw InvalidValue() }
                defaults.set(try JSONEncoder().encode(prefs), forKey: KyroSportsDashboardPreferences.key)
            }, label: { _ in "Sports dashboard visibility, order and default" }),
         BackupSetting(id: "home.localShelves", group: .general, title: "Kyro Home arrangement",
            validate: { decode($0) != nil },
            read: { encode(KyroHomeArrangementStore.load(scope: scope(), from: defaults), scope: scope()) },
            write: { value in
                guard let arrangement = decode(value) else { throw InvalidValue() }
                KyroHomeArrangementStore.save(arrangement, scope: scope(), to: defaults)
            }, normalize: { value in
                guard let arrangement = decode(value) else { return value }
                let portable = arrangement.forRestore(
                    matchingOrigin: origin(for: scope()), sourceOrigin: sourceOrigin(value))
                return encode(portable, scope: scope())
            }, label: { _ in "Home shelf order and visibility" })] + [
                ("sports.favoriteLeagues", KyroSportsFavorites.leaguesKey, "Favorite sports leagues"),
                ("sports.favoriteTeams", KyroSportsFavorites.teamsKey, "Favorite sports teams")
            ].map { id, key, title in
                BackupSetting(id: id, group: .sports, title: title,
                    validate: { strings($0, team: key == KyroSportsFavorites.teamsKey) != nil },
                    read: { .array((defaults.stringArray(forKey: key) ?? []).sorted().map(BackupValue.string)) },
                    write: { value in
                        guard let values = strings(value, team: key == KyroSportsFavorites.teamsKey) else { throw InvalidValue() }
                        defaults.set(values, forKey: key)
                    }, label: { _ in "Sports favorites" })
            }
    }

    private static let maxArrangementEntries = 512

    static func dashboardValue(_ prefs: KyroSportsDashboardPreferences) -> BackupValue {
        .record(["order": .array(prefs.order.map { .string($0.rawValue) }),
                 "hidden": .array(prefs.order.filter(prefs.hidden.contains).map { .string($0.rawValue) }),
                 "live": .bool(prefs.showLive), "upcoming": .bool(prefs.showUpcoming),
                 "completed": .bool(prefs.showCompleted), "default": .string(prefs.defaultLeague)])
    }
    static func dashboard(_ value: BackupValue) -> KyroSportsDashboardPreferences? {
        guard case .record(let f) = value, Set(f.keys) == ["order", "hidden", "live", "upcoming", "completed", "default"],
              case .array(let order) = f["order"], case .array(let hidden) = f["hidden"],
              case .bool(let live) = f["live"], case .bool(let upcoming) = f["upcoming"],
              case .bool(let completed) = f["completed"], case .string(let start) = f["default"],
              ["all", "lastUsed"].contains(start) || KyroSportLeague(rawValue: start) != nil else { return nil }
        func leagues(_ values: [BackupValue]) -> [KyroSportLeague]? {
            let parsed = values.compactMap { value -> KyroSportLeague? in
                guard case .string(let raw) = value else { return nil }; return KyroSportLeague(rawValue: raw)
            }
            return parsed.count == values.count && Set(parsed).count == parsed.count ? parsed : nil
        }
        guard let ordered = leagues(order), Set(ordered) == Set(KyroSportLeague.allCases), let hidden = leagues(hidden) else { return nil }
        return .init(order: ordered, hidden: Set(hidden), showLive: live, showUpcoming: upcoming,
                     showCompleted: completed, defaultLeague: start)
    }

    static func encode(_ arrangement: KyroHomeArrangement, scope: String? = nil) -> BackupValue {
        .record([
            "version": .int(3),
            "origin": .string(origin(for: scope)),
            "order": chunks(arrangement.tokens ?? []),
            "hidden": .array(KyroHomeShelf.allCases.filter(arrangement.hidden.contains).map { .string($0.rawValue) }),
            "siloHidden": chunks(arrangement.hiddenSilo.sorted()),
        ])
    }

    private static func origin(for scope: String?) -> String {
        let digest = SHA256.hash(data: Data((scope ?? "device").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceOrigin(_ value: BackupValue) -> String? {
        guard case .record(let fields) = value, case .string(let origin) = fields["origin"] else { return nil }
        return origin
    }

    private static func chunks(_ strings: [String]) -> BackupValue {
        .array(stride(from: 0, to: strings.count, by: SettingsBackupSafety.maxArrayMembers).map { start in
            .array(strings[start..<min(start + SettingsBackupSafety.maxArrayMembers, strings.count)].map(BackupValue.string))
        })
    }

    private static func unchunk(_ value: BackupValue?) -> [String]? {
        guard case .array(let pages) = value, pages.count <= SettingsBackupSafety.maxArrayMembers else { return nil }
        var result: [String] = []
        for page in pages {
            guard case .array(let members) = page, members.count <= SettingsBackupSafety.maxArrayMembers else { return nil }
            for member in members {
                guard case .string(let text) = member, !text.isEmpty, text.count <= 256 else { return nil }
                result.append(text)
                guard result.count <= maxArrangementEntries else { return nil }
            }
        }
        return Set(result).count == result.count ? result : nil
    }

    static func decode(_ value: BackupValue) -> KyroHomeArrangement? {
        guard case .record(let fields) = value, case .array(let hiddenValues) = fields["hidden"],
              let hidden = shelves(hiddenValues) else { return nil }
        switch Set(fields.keys) {
        case ["version", "origin", "order", "hidden", "siloHidden"]:
            guard fields["version"] == .int(3),
                  case .string(let origin) = fields["origin"], origin.count == 64,
                  origin.allSatisfy({ $0.isHexDigit }),
                  let tokens = unchunk(fields["order"]),
                  let hiddenIDs = unchunk(fields["siloHidden"]),
                  tokens.allSatisfy({ KyroHomeEntry(token: $0) != nil }),
                  hiddenIDs.allSatisfy({ !$0.isEmpty && $0.count <= 251 }) else { return nil }
            return KyroHomeArrangement(tokens: tokens.isEmpty ? nil : tokens, hidden: Set(hidden),
                                       hiddenSilo: Set(hiddenIDs))
        case ["version", "order", "hidden"]:
            guard fields["version"] == .int(2), case .array(let tokenValues) = fields["order"],
                  tokenValues.count <= SettingsBackupSafety.maxArrayMembers else { return nil }
            var tokens: [String] = []
            var seen = Set<String>()
            for value in tokenValues {
                guard case .string(let token) = value, token.count <= SettingsBackupSafety.maxStringValueLength,
                      KyroHomeEntry(token: token) != nil, seen.insert(token).inserted else { return nil }
                tokens.append(token)
            }
            return KyroHomeArrangement(tokens: tokens.isEmpty ? nil : tokens, hidden: Set(hidden))
        case ["order", "hidden"]:
            // Build 120: device-wide order below the Silo feed. Only visibility carries over.
            guard case .array(let order) = fields["order"], let parsed = shelves(order),
                  Set(parsed) == Set(KyroHomeShelf.allCases) else { return nil }
            return KyroHomeArrangement(hidden: Set(hidden))
        default:
            return nil
        }
    }

    private static func shelves(_ values: [BackupValue]) -> [KyroHomeShelf]? {
        let parsed = values.compactMap { value -> KyroHomeShelf? in
            guard case .string(let raw) = value else { return nil }
            return KyroHomeShelf(rawValue: raw)
        }
        return parsed.count == values.count && Set(parsed).count == parsed.count ? parsed : nil
    }

    private static func strings(_ value: BackupValue, team: Bool) -> [String]? {
        guard case .array(let values) = value, values.count <= SettingsBackupSafety.maxArrayMembers else { return nil }
        let strings = values.compactMap { value -> String? in
            guard case .string(let raw) = value, !raw.isEmpty, raw.count <= SettingsBackupSafety.maxStringValueLength else { return nil }
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, KyroSportLeague(rawValue: String(first)) != nil,
                  team ? parts.count == 2 && !parts[1].isEmpty : parts.count == 1 else { return nil }
            return raw
        }
        return strings.count == values.count && Set(strings).count == strings.count ? strings : nil
    }
}

private extension KyroHomeArrangement {
    func forRestore(matchingOrigin destination: String, sourceOrigin: String?) -> Self {
        guard sourceOrigin == destination else {
            return Self(tokens: tokens?.filter { if case .kyro? = KyroHomeEntry(token: $0) { return true }; return false },
                        hidden: hidden)
        }
        return self
    }
}
#endif
