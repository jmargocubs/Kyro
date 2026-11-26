#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

/// Settings Backup entries for Radio (Build 128), in their own group so
/// Build 127 and earlier skip them as unrecognized.
///
/// - `radio.favorites`: favorite stations as `"<stationuuid>|<name>"` strings
///   in pages of at most 64. Backups never hold links, so stream addresses
///   are not saved: a restored station gets its details from Radio Browser by
///   its ID the first time Radio needs them. Holds the newest 200 favorites.
/// - `radio.preferences`: Discover's country, region and language.
/// - `radio.homeShelves`: whether the two radio Home shelves are on.
/// - `radio.playerTheme` (Build 132): the expanded player's theme. Builds
///   128–131 skip it as an unrecognized setting; a backup without it leaves
///   the theme as it is (Crimson Noir on a fresh install).
///
/// Listening history is never included.
enum KyroRadioBackupSettings {
    private struct InvalidValue: Error {}

    static let maxBackupFavorites = 200
    static let maxNameLength = 80

    @MainActor
    static func make(library: KyroRadioLibrary, defaults: UserDefaults,
                     appearance: KyroRadioPlayerAppearance? = nil,
                     scope: @escaping @MainActor () -> String? = { nil }) -> [BackupSetting] {
        let appearance = appearance ?? .shared
        return [
            BackupSetting(id: "radio.favorites", group: .radio, title: "Favorite radio stations",
                validate: { favorites($0) != nil },
                read: { encodeFavorites(library.favorites) },
                write: { value in
                    guard let entries = favorites(value) else { throw InvalidValue() }
                    library.replaceFavorites(restored(entries, existing: library.favorites))
                },
                label: { value in
                    let count = favorites(value)?.count ?? 0
                    return count == 1 ? "1 station" : "\(count) stations"
                }),
            BackupSetting(id: "radio.preferences", group: .radio, title: "Radio region and language",
                validate: { preferences($0) != nil },
                read: { encodePreferences(library.preferences) },
                write: { value in
                    guard let prefs = preferences(value) else { throw InvalidValue() }
                    library.updatePreferences { $0 = prefs }
                },
                label: { value in preferences(value)?.regionTitle ?? "Custom" }),
            BackupSetting(id: "radio.homeShelves", group: .radio, title: "Radio Home shelves",
                validate: { shelves($0) != nil },
                read: {
                    let shown = KyroHomeArrangementStore.load(scope: scope(), from: defaults).shownOptIn
                    return .record(["favorites": .bool(shown.contains(.favoriteRadio)),
                                    "recent": .bool(shown.contains(.recentRadio))])
                },
                write: { value in
                    guard let shown = shelves(value) else { throw InvalidValue() }
                    var arrangement = KyroHomeArrangementStore.load(scope: scope(), from: defaults)
                    arrangement.shownOptIn = arrangement.shownOptIn.filter { !$0.isRadio }.union(shown)
                    KyroHomeArrangementStore.save(arrangement, scope: scope(), to: defaults)
                },
                label: { value in
                    let shown = shelves(value) ?? []
                    return shown.isEmpty ? "Off" : shown.count == 2 ? "Both on" : "One on"
                }),
            BackupSetting(id: "radio.playerTheme", group: .radio, title: "Radio player appearance",
                validate: { playerTheme($0) != nil },
                read: { .string(appearance.theme.rawValue) },
                write: { value in
                    guard let theme = playerTheme(value) else { throw InvalidValue() }
                    appearance.select(theme)
                },
                label: { value in playerTheme(value)?.title ?? "Custom" }),
        ]
    }

    // MARK: Favorites

    struct FavoriteEntry: Equatable {
        let id: String
        let name: String
    }

    static func encodeFavorites(_ saved: [KyroRadioSavedStation]) -> BackupValue {
        let strings = saved.prefix(maxBackupFavorites).map { "\($0.id)|\(portableName($0.station.name))" }
        return .array(stride(from: 0, to: strings.count, by: SettingsBackupSafety.maxArrayMembers).map { start in
            .array(strings[start..<min(start + SettingsBackupSafety.maxArrayMembers, strings.count)].map(BackupValue.string))
        })
    }

    static func favorites(_ value: BackupValue) -> [FavoriteEntry]? {
        guard case .array(let pages) = value, pages.count <= SettingsBackupSafety.maxArrayMembers else { return nil }
        var result: [FavoriteEntry] = []
        var seen = Set<String>()
        for page in pages {
            guard case .array(let members) = page, members.count <= SettingsBackupSafety.maxArrayMembers else { return nil }
            for member in members {
                guard case .string(let text) = member else { return nil }
                let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let uuid = UUID(uuidString: String(parts[0])),
                      parts[1].count <= maxNameLength else { return nil }
                let id = uuid.uuidString.lowercased()
                guard seen.insert(id).inserted else { return nil }
                result.append(.init(id: id, name: String(parts[1])))
                guard result.count <= maxBackupFavorites else { return nil }
            }
        }
        return result
    }

    /// Restored favorites in backup order. A station this device already has
    /// keeps its full saved details; others start with ID and name only.
    static func restored(_ entries: [FavoriteEntry], existing: [KyroRadioSavedStation], now: Date = Date()) -> [KyroRadioSavedStation] {
        let known = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated().map { index, entry in
            let date = now.addingTimeInterval(-Double(index))
            if let saved = known[entry.id] { return .init(station: saved.station, date: date) }
            let name = entry.name.isEmpty ? "Radio station" : entry.name
            return .init(station: KyroRadioStation(id: entry.id, name: name, streamURL: nil), date: date)
        }
    }

    /// A name a backup can carry: no link-like or path-like text, no control
    /// characters, at most `maxNameLength` characters.
    static func portableName(_ name: String) -> String {
        var text = name.unicodeScalars.filter { $0.value >= 0x20 && $0 != "|" }.map(String.init).joined()
        while text.contains("..") { text = text.replacingOccurrences(of: "..", with: ".") }
        text = text.replacingOccurrences(of: "://", with: " ")
        while text.hasPrefix("/") { text.removeFirst() }
        let lowered = text.lowercased()
        if lowered.contains("bearer ") { text = "" }
        return String(text.trimmingCharacters(in: .whitespaces).prefix(maxNameLength))
    }

    // MARK: Preferences

    static func encodePreferences(_ prefs: KyroRadioPreferences) -> BackupValue {
        .record(["country": .string(prefs.countryCode ?? ""), "countryName": .string(portableName(prefs.countryName ?? "")),
                 "region": .string(portableName(prefs.state ?? "")), "language": .string(portableName(prefs.language ?? ""))])
    }

    static func preferences(_ value: BackupValue) -> KyroRadioPreferences? {
        guard case .record(let fields) = value, Set(fields.keys) == ["country", "countryName", "region", "language"],
              case .string(let code) = fields["country"], case .string(let name) = fields["countryName"],
              case .string(let region) = fields["region"], case .string(let language) = fields["language"],
              code.isEmpty || (code.count == 2 && code.allSatisfy(\.isLetter)),
              [name, region, language].allSatisfy({ $0.count <= maxNameLength }) else { return nil }
        return KyroRadioPreferences(countryCode: code.isEmpty ? nil : code.uppercased(),
                                    countryName: name.isEmpty ? nil : name,
                                    state: region.isEmpty ? nil : region,
                                    language: language.isEmpty ? nil : language).normalized
    }

    // MARK: Player theme

    static func playerTheme(_ value: BackupValue) -> KyroRadioPlayerTheme? {
        guard case .string(let raw) = value else { return nil }
        return KyroRadioPlayerTheme(rawValue: raw)
    }

    // MARK: Home shelves

    static func shelves(_ value: BackupValue) -> Set<KyroHomeShelf>? {
        guard case .record(let fields) = value, Set(fields.keys) == ["favorites", "recent"],
              case .bool(let favorites) = fields["favorites"], case .bool(let recent) = fields["recent"] else { return nil }
        var shown = Set<KyroHomeShelf>()
        if favorites { shown.insert(.favoriteRadio) }
        if recent { shown.insert(.recentRadio) }
        return shown
    }
}
#endif
