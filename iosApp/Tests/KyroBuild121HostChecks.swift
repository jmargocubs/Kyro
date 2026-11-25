#if KYRO_STANDALONE_TESTS
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

// Build 121 host checks (no Simulator): integrated Home arrangement, its
// storage and backup, the repaired sports shelves, and source/asset contracts
// for the launch animation, Crimson Noir accent and preserved features.
// Supersedes KyroBuild120HostChecks, whose append-only Home assertions no
// longer describe the product.

private final class HomeMemoryJournal: RestoreJournalStoring {
    var value: RestoreJournal?
    func load() throws -> RestoreJournal? { value }
    func save(_ journal: RestoreJournal) throws { value = journal }
    func clear() throws { value = nil }
}

@main @MainActor
enum KyroBuild121HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        count += 1
    }

    static func main() throws {
        try arrangement()
        try storageAndBackup()
        sports()
        navigationPills()
        try sourceAndAssetContracts()
        print("Build 121: \(count) focused host checks passed.")
    }

    // MARK: Arrangement

    static func arrangement() throws {
        func silo(_ id: String, _ type: String = "custom") -> KyroHomeSiloSection { .init(id: id, type: type, title: id) }
        let hero = silo("surprise", "random")
        let cw = silo("cw", "continue_watching")
        let nextUp = silo("nu", "next_up")
        let movies = silo("movies", "latest")
        let shows = silo("shows", "latest")
        let feed = [hero, cw, nextUp, movies, shows]
        let defaults = KyroHomeArrangement()
        let kyro = KyroHomeArrangement.defaultShelfOrder.map(KyroHomeEntry.kyro)

        check(defaults.entries(for: feed) == [.silo("cw"), .silo("nu")] + kyro
              + [.silo("surprise"), .silo("movies"), .silo("shows")],
              "default: Continue Watching, Next Up, six shelves, then remaining Silo rows in server order")
        check(defaults.entries(for: [hero, movies]) == kyro + [.silo("surprise"), .silo("movies")],
              "missing Continue Watching/Next Up: shelves lead, server rows keep order")
        check(defaults.entries(for: [cw, movies]) == [.silo("cw")] + kyro + [.silo("movies")],
              "missing Next Up handled")
        check(defaults.entries(for: []) == kyro, "empty server feed still lists every shelf")
        check(defaults.entries(for: [cw, cw, movies]).filter { $0 == .silo("cw") }.count == 1, "duplicate server ids drawn once")

        // Move My Teams after Movies by stable ids.
        var custom = defaults
        var all = custom.allEntries(for: feed)
        all.removeAll { $0 == .kyro(.myTeams) }
        all.insert(.kyro(.myTeams), at: all.firstIndex(of: .silo("movies"))! + 1)
        custom.setOrder(all)
        check(custom.entries(for: feed).firstIndex(of: .kyro(.myTeams))! == custom.entries(for: feed).firstIndex(of: .silo("movies"))! + 1,
              "shelf placed among Silo rows")
        check(custom.tokens?.contains("silo:movies") == true && custom.tokens?.contains("kyro:myTeams") == true,
              "stored as stable tokens, not offsets")
        let reordered = [shows, movies, hero, nextUp, cw]
        let afterReorder = custom.entries(for: reordered)
        check(afterReorder.firstIndex(of: .kyro(.myTeams))! == afterReorder.firstIndex(of: .silo("movies"))! + 1,
              "server reorder: shelf follows its anchor section")
        check(afterReorder.filter { if case .silo = $0 { return true }; return false }
              == [.silo("nu"), .silo("cw"), .silo("shows"), .silo("movies"), .silo("surprise")],
              "server reorder: Silo rows follow the server (leading rows first)")
        let removed = custom.entries(for: [hero, cw, nextUp, shows])
        check(removed.contains(.kyro(.myTeams)) && removed.count == 4 + 6, "server removal: shelf survives")
        check(removed.firstIndex(of: .kyro(.myTeams))! < removed.firstIndex(of: .silo("shows"))!,
              "server removal: shelf falls back to the previous surviving row")
        let added = custom.entries(for: [hero, cw, nextUp, silo("new"), movies, shows])
        check(added.firstIndex(of: .silo("new"))! < added.firstIndex(of: .silo("movies"))!
              && added.firstIndex(of: .kyro(.myTeams))! == added.firstIndex(of: .silo("movies"))! + 1,
              "server addition: new row in server order, shelves unaffected")

        // Hide keeps the position.
        var hidden = custom
        hidden.setHidden(.myTeams, true)
        check(!hidden.entries(for: feed).contains(.kyro(.myTeams)) && hidden.allEntries(for: feed).contains(.kyro(.myTeams)),
              "hidden shelf leaves Home but stays in Customize")
        hidden.setHidden(.myTeams, false)
        check(hidden.entries(for: feed) == custom.entries(for: feed), "showing again restores its place")

        var moved = defaults
        moved.move(.sportsToday, by: -1, sections: feed)
        check(moved.entries(for: feed).prefix(3) == [.silo("cw"), .kyro(.sportsToday), .silo("nu")], "move up one row")
        moved.move(.sportsToday, by: -1, sections: feed)
        moved.move(.sportsToday, by: -1, sections: feed)
        check(moved.entries(for: feed).first == .kyro(.sportsToday), "move to the very top")
        let top = moved
        moved.move(.sportsToday, by: -1, sections: feed)
        check(moved == top, "moving past the top is ignored")

        var partial = KyroHomeArrangement(tokens: ["kyro:upcomingSports", "bogus", "silo:", "kyro:future", "silo:movies"])
        check(partial.entries(for: feed).first == .kyro(.upcomingSports), "stored shelf at top")
        check(partial.entries(for: feed).filter { if case .kyro = $0 { return true }; return false }.count == 6,
              "invalid tokens ignored; unmentioned shelves take default places")
        partial.tokens = nil
        check(partial.isDefault, "reset is the default arrangement")
        check(KyroHomeEntry(token: KyroHomeEntry.silo("a:b").token) == .silo("a:b"), "section ids with colons round-trip")
    }

    // MARK: Storage and backup

    static func storageAndBackup() throws {
        let suite = "kyro.build121.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        check(KyroHomeArrangementStore.load(scope: "s.a.p1", from: defaults) == KyroHomeArrangement(), "first launch: default")
        defaults.set(Data(#"{"order":["myTeams"],"hidden":["sportsToday"]}"#.utf8), forKey: KyroHomeArrangementStore.legacyKey)
        check(KyroHomeArrangementStore.load(scope: "s.a.p1", from: defaults).hidden == [.sportsToday],
              "Build 120 hidden shelves carry over")
        check(KyroHomeArrangementStore.load(scope: "s.a.p1", from: defaults).tokens == nil,
              "Build 120 append-only order does not carry over")
        let mine = KyroHomeArrangement(tokens: ["silo:cw", "kyro:myTeams"], hidden: [.upcomingSports])
        KyroHomeArrangementStore.save(mine, scope: "s.a.p1", to: defaults)
        check(KyroHomeArrangementStore.load(scope: "s.a.p1", from: defaults) == mine, "relaunch keeps the arrangement")
        check(KyroHomeArrangementStore.load(scope: "s.a.p2", from: defaults).tokens == nil, "another profile keeps its own")
        check(KyroHomeArrangementStore.load(scope: "s2.a.p1", from: defaults).tokens == nil, "another server keeps its own")
        defaults.set(Data("corrupt".utf8), forKey: KyroHomeArrangementStore.key(scope: "s.a.p3"))
        check(KyroHomeArrangementStore.load(scope: "s.a.p3", from: defaults).tokens == nil, "corrupt data falls back safely")

        var scope: String? = "s.a.p1"
        let registry = SettingsBackupRegistry(settings: KyroHomeBackupSettings.make(defaults: defaults, scope: { scope }),
                                              deviceIdiom: "phone")
        let setting = registry.setting(id: "home.localShelves")!
        check(setting.read() == KyroHomeBackupSettings.encode(mine), "backup reads the active profile's arrangement")
        check(KyroHomeBackupSettings.decode(KyroHomeBackupSettings.encode(mine)) == mine, "v2 round trip")
        check(KyroHomeBackupSettings.decode(KyroHomeBackupSettings.encode(KyroHomeArrangement())) == KyroHomeArrangement(),
              "default round trip")
        let legacy = BackupValue.record([
            "order": .array(KyroHomeShelf.allCases.map { .string($0.rawValue) }),
            "hidden": .array([.string("myLeagues")]),
        ])
        check(KyroHomeBackupSettings.decode(legacy) == KyroHomeArrangement(hidden: [.myLeagues]), "Build 120 backup restores visibility")
        func v2(_ tokens: [BackupValue], hidden: [BackupValue] = [], version: Int = 2) -> BackupValue {
            .record(["version": .int(version), "order": .array(tokens), "hidden": .array(hidden)])
        }
        check(!setting.validate(v2([.string("javascript:alert")])), "unknown token kind rejected")
        check(!setting.validate(v2([.string("kyro:future")])), "unknown shelf rejected")
        check(!setting.validate(v2([.string("silo:a"), .string("silo:a")])), "duplicate tokens rejected")
        check(!setting.validate(v2([], version: 3)), "future version rejected")
        check(!setting.validate(v2([], hidden: [.string("nope")])), "unknown hidden shelf rejected")
        check(!setting.validate(.record(["version": .int(2), "order": .array([]), "hidden": .array([]), "x": .bool(true)])),
              "unrecognized fields rejected")
        check(!setting.validate(.record(["order": .array([]), "hidden": .array([])])), "incomplete Build 120 order rejected")

        let favorites = KyroSportsFavoritesStore(defaults: defaults)
        favorites.toggle(.nfl)
        let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
        let exported = try SettingsBackupExporter.export(registry: registry, groups: [.general, .sports],
            app: .init(version: "1.0.121", build: "121", platform: "iOS", idiom: "phone"), now: now)
        let decoded = try SettingsBackupCodec.decode(exported)
        check(decoded.groups["general"]?["home.localShelves"] == KyroHomeBackupSettings.encode(mine), "export includes arrangement")
        check(decoded.groups["sports"]?["sports.favoriteLeagues"] == .array([.string("nfl")]), "export includes shared favorites")

        // Restore into a fresh profile, then undo.
        scope = "s.a.p9"
        defaults.set([], forKey: KyroSportsFavorites.leaguesKey)
        let preview = SettingsBackupPlanner.preview(decoded, registry: registry)
        let applier = SettingsBackupApplier(registry: registry, journal: HomeMemoryJournal())
        guard case .applied(let changes, let undoAvailable) = applier.apply(preview: preview, selectedGroups: [.general, .sports]) else {
            fatalError("restore failed")
        }
        check(changes.count == 2 && undoAvailable, "restore applies arrangement and favorites")
        check(KyroHomeArrangementStore.load(scope: "s.a.p9", from: defaults) == mine, "restore writes the active profile")
        check(KyroHomeArrangementStore.load(scope: "s.a.p1", from: defaults) == mine, "restore leaves other profiles alone")
        let undo = applier.undo()
        check(undo.isClean, "undo succeeds")
        check(KyroHomeArrangementStore.load(scope: "s.a.p9", from: defaults).tokens == nil, "undo restores the previous arrangement")
    }

    // MARK: Sports shelves

    static func sports() {
        let suite = "kyro.build121.sports.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = KyroSportsFavoritesStore(defaults: defaults)
        let bears = KyroSportsTeam(id: "espn.nfl.3", league: .nfl, abbreviation: "CHI", nickname: "Bears", location: "Chicago")
        let sleeperBears = KyroSportsTeam(id: "sleeper.nfl.CHI", league: .nfl, abbreviation: "CHI", nickname: "Bears")
        let lions = KyroSportsTeam(id: "espn.nfl.8", league: .nfl, abbreviation: "DET", nickname: "Lions", location: "Detroit")
        let ucfKnights = KyroSportsTeam(id: "espn.cfb.2116", league: .collegeFootball, abbreviation: "UCF", nickname: "Knights", location: "UCF")
        let otherKnights = KyroSportsTeam(id: "espn.cfb.9", league: .collegeFootball, abbreviation: "FDU", nickname: "Knights")
        let jaxState = KyroSportsTeam(id: "espn.mbb.55", league: .collegeBasketballMen, abbreviation: "JXST",
                                      nickname: "Gamecocks", location: "Jacksonville State", alternateNames: ["Jax State"])

        favorites.toggle(bears)
        check(favorites.preferences.teams == ["nfl|Chicago Bears"], "favorite stored by league and full name")
        check(favorites.preferences.includes(sleeperBears), "Sleeper's city-less NFL team matches the ESPN favorite")
        check(!favorites.preferences.includes(lions), "other teams don't match")
        favorites.toggle(ucfKnights)
        check(favorites.preferences.includes(ucfKnights) && !favorites.preferences.includes(otherKnights),
              "college nicknames need the full name")
        favorites.preferences.teams.insert("collegeBasketballMen|Jax State")
        check(favorites.preferences.includes(jaxState), "provider alternate names match")
        favorites.toggle(sleeperBears)
        check(!favorites.preferences.teams.contains("nfl|Chicago Bears"), "unfavoriting removes the stored spelling")
        favorites.toggle(bears)
        favorites.toggle(.nba)
        check(favorites.preferences.relevantLeagues == [.nfl, .nba, .collegeFootball, .collegeBasketballMen],
              "My Teams/My Leagues fetch only the favorites' leagues")
        check(KyroSportsFavorites(defaults: defaults) == favorites.preferences, "favorites persist for Hub and Home")

        let now = ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func game(_ id: String, _ offset: TimeInterval?, _ status: KyroGameStatus, league: KyroSportLeague = .nfl,
                  home: KyroSportsTeam? = nil, away: KyroSportsTeam? = nil) -> KyroSportsGame {
            KyroSportsGame(id: .init(provider: "fixture", league: league, rawID: id), league: league,
                startTime: offset.map { now.addingTimeInterval($0) }, status: status,
                home: .init(team: home ?? lions), away: .init(team: away ?? bears))
        }
        let thanksgiving = game("thanksgiving", 66 * 3600, .scheduled)
        let live = game("live", -1800, .live)
        let finalToday = game("finalToday", -5 * 3600, .final)
        let finalYesterday = game("finalYesterday", -30 * 3600, .final)
        let canceled = game("canceled", 3 * 3600, .canceled)
        let nba = game("nba", 2 * 3600, .scheduled, league: .nba,
                       home: KyroSportsTeam(id: "n1", league: .nba, abbreviation: "BOS", nickname: "Celtics", location: "Boston"),
                       away: KyroSportsTeam(id: "n2", league: .nba, abbreviation: "NYK", nickname: "Knicks", location: "New York"))
        let games = [thanksgiving, live, finalToday, finalYesterday, canceled, nba, live]
        func pick(_ shelf: KyroHomeShelf) -> [KyroGameID] {
            KyroHomeSportsSelection.games(games, for: shelf, favorites: favorites.preferences, now: now, calendar: calendar).map(\.id)
        }
        check(pick(.myTeams) == [live.id, thanksgiving.id, finalToday.id],
              "My Teams: live first, next game days ahead, today's final; no old or canceled games")
        check(pick(.myLeagues) == [nba.id], "My Leagues: favorite league's events only")
        check(pick(.sportsToday) == [live.id, nba.id, finalToday.id], "Sports Today: live and today, deduplicated, no canceled")
        check(pick(.upcomingSports) == [nba.id, thanksgiving.id], "Upcoming: scheduled after now")
        check(pick(.recentLiveTV).isEmpty, "channel shelves never become sports lists")
        let many = (0..<60).map { game("m\($0)", Double($0 + 1) * 60, .scheduled) }
        check(KyroHomeSportsSelection.games(many, for: .myTeams, favorites: favorites.preferences, now: now, calendar: calendar).count
              == KyroHomeSportsSelection.maximumCards, "bounded cards")
    }

    /// Accepted Build 120 navigation pill policy, unchanged.
    static func navigationPills() {
        check(!TabDockScrollRange(content: 500, viewport: 800, insets: 0).permitsMinimizing(previous: true), "short page cannot minimize")
        check(TabDockScrollRange(content: 1100, viewport: 800, insets: 0).permitsMinimizing(previous: false), "long page can minimize")
        check(TabDockScrollRange(content: 880, viewport: 800, insets: 0).permitsMinimizing(previous: true), "accessory resize keeps minimized policy")
        check(!TabDockScrollRange(content: 880, viewport: 800, insets: 0).permitsMinimizing(previous: false), "accessory resize keeps expanded policy")
        check(!TabDockScrollRange(content: 1100, viewport: 0, insets: 0).permitsMinimizing(previous: true), "unmeasured page cannot minimize")
    }

    // MARK: Contracts

    static func sourceAndAssetContracts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func hash(_ path: String) throws -> String {
            SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path))).map { String(format: "%02x", $0) }.joined()
        }
        let assets = "iosApp/iosApp/Kyro/KyroBrand.xcassets/"
        check(try hash(assets + "KyroXWordmark.imageset/KyroXWordmark.png") == "1881e4b8444d6a7d4f3c84901b9de23ddde8481c269a44786362165fc58599a0",
              "approved wordmark unchanged")
        check(try hash(assets + "KyroXAppIcon.appiconset/KyroXAppIcon.png") == "4b23e166e3e77bd8ed17e8a9a76af3a53bb314593ac81bc6a0066432878d478d",
              "installed app icon unchanged")
        try layersRecomposeWordmark(root.appendingPathComponent(assets))

        let splash = try source("iosApp/iosApp/Kyro/KyroCinematicSplashView.swift")
        check(!splash.contains("logoImageName") && !splash.contains("KyroXLogo"), "launch shows no square app icon")
        check(splash.contains("\"KyroXWordmarkKyro\"") && splash.contains("\"KyroXWordmarkX\"")
              && splash.contains("KyroBrand.wordmarkImageName"), "one wordmark: animated layers settle into the approved image")
        check(splash.contains("accessibilityReduceMotion") && splash.contains("guard !Task.isCancelled"), "Reduce Motion and cancellation")
        check(!splash.contains("repeatForever") && !splash.contains("KyroHaloBloom"), "no looping animation or extra glow")
        let content = try source("iosApp/iosApp/ContentView.swift")
        check(content.contains("!didFinishStartupSplash || router.authState == .loading"), "splash plays only at launch")

        let theme = try source("iosApp/iosApp/KyroTheme/KyroTheme.swift")
        check(theme.contains("static let accent = Color(hex: \"#8C263B\")") && theme.contains("static let accentInk = Color(hex: \"#F06A7C\")"),
              "Crimson Noir accent and ink")
        check(!theme.contains("#0034FB") && !theme.contains("#738FFD"), "electric blue retired from Kyro chrome")
        check(theme.contains("static let live = Color(hex: \"#F50B4F\")"), "LIVE keeps its semantic color")

        let home = try source("iosApp/iosApp/Screens/Home/HomeView.swift")
        check(home.contains("kyroShelfHost.arrangement.entries(for: kyroSections)") && !home.contains("KyroHomeShelves()"),
              "shelves are placed inside the feed, not appended after it")
        check(home.contains("KyroHomeCustomizeButton()") && home.contains("kyroShelfHost.siloSections = sections"), "Customize Home at the top of Home, sharing Home's sections")
        let shelves = try source("iosApp/iosApp/Kyro/Home/KyroHomeShelves.swift")
        check(!shelves.contains("Text(\"Kyro Home\")"), "no separate Kyro Home heading")
        check(shelves.contains("liveTV.restoreCachedState(for: provider)"), "Home restores the cached Live TV catalog itself")
        check(shelves.contains("liveTV.choose(channel, from: .shell)"), "channel shelves play the exact channel")
        check(shelves.contains("liveTV.playSportsEvent(game)") && shelves.contains("KyroSportsEventPreview(game:")
              && shelves.contains(".secondaryDestination(.sports)"), "events keep the Sports details and playback route")
        check(shelves.contains("store.loadedGames(for: league)"), "My Teams/My Leagues read each favorite league's window")
        let registryFile = try source("iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupLiveRegistry.swift")
        check(registryFile.contains("scope: { KyroHomeShelfHost.currentScope() }"), "backup uses the active profile's arrangement")

        let capacity = try source("iosApp/iosApp/LiveTV/LiveTVModels.swift")
        check(capacity.contains("productionMaximumChannels = 100_000"), "100K production capacity retained")
        let project = try source("iosApp/project.yml")
        check(project.contains("revision: f470d8dc610537929c83ef31877287e9d2ad9d28"), "accepted Aether revision retained")
        check(project.components(separatedBy: "CURRENT_PROJECT_VERSION: 121").count == 4, "app and two extensions target Build 121")
        check(project.components(separatedBy: "MARKETING_VERSION: \"1.0.121\"").count == 4, "version 1.0.121")
        let libraries = try source("iosApp/iosApp/Screens/Browse/LibrariesTabView.swift")
        check(libraries.contains("LibraryDockModel()") && libraries.contains(".floatingPageDock(dock, isShown: !dockIsInSlot)"),
              "accepted navigation pills untouched")
    }

    /// The two launch layers draw the approved wordmark when composited.
    static func layersRecomposeWordmark(_ assets: URL) throws {
        func pixels(_ name: String) -> (Int, Int, [UInt8]) {
            let url = assets.appendingPathComponent("\(name).imageset/\(name).png")
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (image.width, image.height, data)
        }
        let original = pixels("KyroXWordmark"), word = pixels("KyroXWordmarkKyro"), x = pixels("KyroXWordmarkX")
        check(word.0 == original.0 && word.1 == original.1 && x.0 == original.0 && x.1 == original.1,
              "launch layers share the approved wordmark canvas")
        var off = 0
        for i in stride(from: 0, to: original.2.count, by: 4) {
            // Complementary premultiplied split: the layers' sum is the original.
            for c in 0..<4 where abs(Int(word.2[i + c]) + Int(x.2[i + c]) - Int(original.2[i + c])) > 2 {
                off += 1
                break
            }
        }
        check(off == 0, "launch layers add back up to the approved wordmark (\(off) pixels differ)")
    }
}
#endif
