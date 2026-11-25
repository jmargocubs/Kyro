#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

enum KyroHomeBackupSettings {
    private struct InvalidValue: Error {}
    @MainActor
    static func make(defaults: UserDefaults) -> [BackupSetting] {
        [BackupSetting(id: "home.localShelves", group: .general, title: "Kyro Home shelves",
            validate: { decode($0) != nil },
            read: {
                let preferences = KyroHomePreferences.load(from: defaults)
                return .record([
                    "order": .array(preferences.order.map { .string($0.rawValue) }),
                    "hidden": .array(preferences.order.filter { preferences.hidden.contains($0) }.map { .string($0.rawValue) })])
            },
            write: { value in
                guard let preferences = decode(value) else { throw InvalidValue() }
                preferences.save(to: defaults)
            }, label: { _ in "Local shelf order and visibility" })] + [
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

    static func decode(_ value: BackupValue) -> KyroHomePreferences? {
        guard case .record(let fields) = value, Set(fields.keys) == ["order", "hidden"],
              case .array(let order) = fields["order"], case .array(let hidden) = fields["hidden"] else { return nil }
        func parse(_ values: [BackupValue]) -> [KyroHomeShelf]? {
            let parsed = values.compactMap { value -> KyroHomeShelf? in
                guard case .string(let raw) = value else { return nil }
                return KyroHomeShelf(rawValue: raw)
            }
            return parsed.count == values.count && Set(parsed).count == parsed.count ? parsed : nil
        }
        guard let order = parse(order), Set(order) == Set(KyroHomeShelf.allCases), let hidden = parse(hidden) else { return nil }
        var result = KyroHomePreferences()
        result.order = order
        result.hidden = Set(hidden)
        return result
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
