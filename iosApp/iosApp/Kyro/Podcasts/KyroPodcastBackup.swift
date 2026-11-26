#if os(iOS) || KYRO_PODCAST_HOST_TESTS
import Foundation

enum KyroPodcastBackup {
    private struct InvalidValue: Error {}
    private struct Portable {
        var shows: [PodcastShow] = []
        var progress: [String: PodcastProgress] = [:]
        var saved: Set<String> = []
        var favorites: Set<String> = []
    }

    @MainActor
    static func make(library: KyroPodcastLibrary, defaults: UserDefaults,
                     scope: @escaping @MainActor () -> String? = { nil }) -> [BackupSetting] {
        [
            BackupSetting(id: "podcasts.preferences", group: .podcasts, title: "Podcast preferences",
                validate: { preferences($0) != nil }, read: { preferenceValue(library.preferences) },
                write: {
                    guard let value = preferences($0) else { throw InvalidValue() }
                    library.updatePreferences(value)
                }, label: { preferences($0)?.theme.title ?? "Podcast preferences" }),
            BackupSetting(id: "podcasts.publicLibrary", group: .podcasts, title: "Public podcast library and progress",
                validate: { decode($0) != nil }, read: { libraryValue(library.snapshot()) },
                write: {
                    guard let value = decode($0) else { throw InvalidValue() }
                    library.mergePortable(shows: value.shows, progress: value.progress,
                                          saved: value.saved, favorites: value.favorites)
                }, label: { "\(decode($0)?.shows.count ?? 0) public subscriptions" }),
            BackupSetting(id: "podcasts.homeShelves", group: .podcasts, title: "Podcast Home shelves",
                validate: { shelfValue($0) != nil },
                read: {
                    let shown = KyroHomeArrangementStore.load(scope: scope(), from: defaults).shownOptIn
                    return .array(shown.filter(\.isPodcast).sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) })
                }, write: {
                    guard let shelves = shelfValue($0) else { throw InvalidValue() }
                    var arrangement = KyroHomeArrangementStore.load(scope: scope(), from: defaults)
                    arrangement.shownOptIn = arrangement.shownOptIn.filter { !$0.isPodcast }.union(shelves)
                    KyroHomeArrangementStore.save(arrangement, scope: scope(), to: defaults)
                }, label: { "\(shelfValue($0)?.count ?? 0) enabled" })
        ]
    }

    static func preferenceValue(_ prefs: PodcastPreferences) -> BackupValue {
        .record(["theme": .string(prefs.theme.rawValue), "speed": .int(Int(prefs.speed * 100)),
                 "back": .int(prefs.back), "forward": .int(prefs.forward), "refresh": .int(prefs.refreshHours),
                 "wifi": .bool(prefs.wifiOnly), "remove": .bool(prefs.removeCompleted), "sleep": .int(prefs.sleepMinutes)])
    }

    static func preferences(_ value: BackupValue) -> PodcastPreferences? {
        guard case .record(let r) = value, r.count == 8, case .string(let theme) = r["theme"],
              let theme = KyroRadioPlayerTheme(rawValue: theme), case .int(let speed) = r["speed"],
              case .int(let back) = r["back"], case .int(let forward) = r["forward"],
              case .int(let refresh) = r["refresh"], case .int(let sleep) = r["sleep"],
              case .bool(let wifi) = r["wifi"], case .bool(let remove) = r["remove"] else { return nil }
        let prefs = PodcastPreferences(theme: theme, speed: Double(speed) / 100, back: back, forward: forward,
            refreshHours: refresh, wifiOnly: wifi, removeCompleted: remove, sleepMinutes: sleep)
        return prefs.isValid ? prefs : nil
    }

    private static func shelfValue(_ value: BackupValue) -> Set<KyroHomeShelf>? {
        guard case .array(let values) = value, values.count <= 3 else { return nil }
        let shelves = Set(values.compactMap {
            if case .string(let name) = $0, let shelf = KyroHomeShelf(rawValue: name), shelf.isPodcast { return shelf }
            return nil
        } as [KyroHomeShelf])
        return shelves.count == values.count ? shelves : nil
    }

    static func libraryValue(_ state: KyroPodcastLibrary.State) -> BackupValue {
        var identities: [String: String] = [:]
        var known = Set<String>()
        let subscriptions: [BackupValue] = state.shows.reversed().compactMap { show in
            guard let feed = show.portableFeed, let address = portableAddress(feed) else { return nil }
            let id = PodcastAddress.fingerprint(feed.absoluteString)
            guard known.insert(id).inserted else { return nil }
            identities[show.id] = id
            let name = KyroRadioBackupSettings.portableName(show.title)
            let flags = state.favoriteShows.contains(show.id) ? "1" : "0"
            let text = [address, flags, name].joined(separator: "|")
            guard text.count <= 256 else { identities[show.id] = nil; return nil }
            return .string(text)
        }
        func portableID(_ id: String) -> String? {
            let parts = id.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let show = identities[String(parts[0])], isHash(parts[1]) else { return nil }
            return show + ":" + parts[1]
        }
        // History is intentionally absent. Only current progress/played flags
        // and saved IDs are portable, without timestamps, enclosures or titles.
        let ids = state.saved.sorted() + state.progress.keys.filter { !state.saved.contains($0) }.sorted()
        let entries: [BackupValue] = ids.compactMap { id in
            guard let key = portableID(id) else { return nil }
            let p = state.progress[id]
            return .string([key, String(Int(p?.position ?? 0)), String(Int(p?.duration ?? 0)),
                            p?.played == true ? "1" : "0", state.saved.contains(id) ? "1" : "0"].joined(separator: "|"))
        }
        return .record(["shows": pages(Array(subscriptions.prefix(150))), "episodes": pages(Array(entries.prefix(200)))])
    }

    private static func decode(_ value: BackupValue) -> Portable? {
        guard case .record(let fields) = value, fields.count == 2,
              let shows = strings(fields["shows"], maximum: 150),
              let episodes = strings(fields["episodes"], maximum: 200) else { return nil }
        var result = Portable()
        var known = Set<String>()
        for row in shows {
            let parts = row.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let address = PodcastAddress.url("https://" + parts[0]),
                  portableAddress(address) == String(parts[0]), ["0", "1"].contains(parts[1]),
                  KyroRadioBackupSettings.portableName(String(parts[2])) == String(parts[2]) else { return nil }
            let id = PodcastAddress.fingerprint(address.absoluteString)
            guard known.insert(id).inserted else { return nil }
            result.shows.append(.init(id: id, feed: address, title: parts[2].isEmpty ? address.host() ?? "Podcast" : String(parts[2]),
                                      portableFeed: address))
            if parts[1] == "1" { result.favorites.insert(id) }
        }
        result.shows.reverse()
        for row in episodes {
            let parts = row.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 5, let position = Int(parts[1]), let duration = Int(parts[2]),
                  (0...604_800).contains(position), (0...604_800).contains(duration),
                  duration == 0 || position <= duration,
                  ["0", "1"].contains(parts[3]), ["0", "1"].contains(parts[4]) else { return nil }
            let ids = parts[0].split(separator: ":", maxSplits: 1)
            let id = String(parts[0])
            guard ids.count == 2, known.contains(String(ids[0])), isHash(ids[1]), result.progress[id] == nil else { return nil }
            result.progress[id] = .init(position: Double(position), duration: Double(duration), played: parts[3] == "1")
            if parts[4] == "1" { result.saved.insert(id) }
        }
        return result
    }

    /// Canonical HTTPS site and path, with no userinfo, port, query, encoded
    /// characters or fragments. The global Settings Backup rejection rules
    /// remain unchanged, and only this explicit entry can interpret the form.
    private static func portableAddress(_ url: URL) -> String? {
        guard PodcastAddress.portable(url) else { return nil }
        let address = String(url.absoluteString.dropFirst("https://".count))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~/-")
        guard address.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return address
    }

    private static func isHash(_ text: Substring) -> Bool {
        text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func pages(_ values: [BackupValue]) -> BackupValue {
        .array(stride(from: 0, to: values.count, by: 64).map { .array(Array(values[$0..<min($0 + 64, values.count)])) })
    }

    private static func strings(_ value: BackupValue?, maximum: Int) -> [String]? {
        guard case .array(let pages) = value, pages.count <= 4 else { return nil }
        var result: [String] = []
        for page in pages {
            guard case .array(let values) = page, values.count <= 64 else { return nil }
            for value in values {
                guard case .string(let text) = value, !SettingsBackupSafety.isSuspiciousValue(value) else { return nil }
                result.append(text)
            }
        }
        return result.count <= maximum ? result : nil
    }
}
#endif
