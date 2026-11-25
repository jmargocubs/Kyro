#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

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
        [BackupSetting(id: "home.localShelves", group: .general, title: "Kyro Home arrangement",
            validate: { decode($0) != nil },
            read: { encode(KyroHomeArrangementStore.load(scope: scope(), from: defaults)) },
            write: { value in
                guard let arrangement = decode(value) else { throw InvalidValue() }
                KyroHomeArrangementStore.save(arrangement, scope: scope(), to: defaults)
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

    static func encode(_ arrangement: KyroHomeArrangement) -> BackupValue {
        .record([
            "version": .int(2),
            "order": .array((arrangement.tokens ?? []).map(BackupValue.string)),
            "hidden": .array(KyroHomeShelf.allCases.filter(arrangement.hidden.contains).map { .string($0.rawValue) }),
        ])
    }

    static func decode(_ value: BackupValue) -> KyroHomeArrangement? {
        guard case .record(let fields) = value, case .array(let hiddenValues) = fields["hidden"],
              let hidden = shelves(hiddenValues) else { return nil }
        switch Set(fields.keys) {
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
#endif
