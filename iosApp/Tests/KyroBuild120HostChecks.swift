#if KYRO_STANDALONE_TESTS
import Foundation
import CryptoKit

private final class HomeMemoryJournal: RestoreJournalStoring {
    var value: RestoreJournal?
    func load() throws -> RestoreJournal? { value }
    func save(_ journal: RestoreJournal) throws { value = journal }
    func clear() throws { value = nil }
}

@main @MainActor
enum KyroBuild120HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        count += 1
    }

    static func main() throws {
        let suite = "kyro.build120.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(KyroHomePreferences(data: nil).order == KyroHomeShelf.allCases, "default order")
        check(KyroHomePreferences(data: Data("bad".utf8)) == KyroHomePreferences(), "corrupt preferences fail safely")
        var preferences = KyroHomePreferences()
        preferences.order = [.myTeams, .myTeams, .favoriteLiveTV]
        preferences.hidden = [.sportsToday]
        preferences = .init(data: preferences.data)
        check(preferences.order.count == 6 && preferences.order.first == .myTeams, "normalize partial/duplicate order")
        check(preferences.enabled.count == 5 && !preferences.enabled.contains(.sportsToday), "visibility independent of order")
        preferences.save(to: defaults)
        check(KyroHomePreferences.load(from: defaults) == preferences, "preference relaunch")

        let favorites = KyroSportsFavoritesStore(defaults: defaults)
        let home = KyroSportsTeam(id: "fixture.home", league: .nba, abbreviation: "HOM", nickname: "Home", logoURL: nil)
        let away = KyroSportsTeam(id: "fixture.away", league: .nba, abbreviation: "AWY", nickname: "Away", logoURL: nil)
        favorites.toggle(.nba)
        favorites.toggle(home)
        check(KyroSportsFavorites(defaults: defaults) == favorites.preferences, "shared Hub/Home favorites persist")
        check(favorites.preferences.includes(home) && !favorites.preferences.includes(away), "exact favorite team")
        let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func game(_ id: String, _ offset: TimeInterval?, _ status: KyroGameStatus, league: KyroSportLeague = .nba) -> KyroSportsGame {
            KyroSportsGame(id: .init(provider: "fixture", league: league, rawID: id), league: league,
                startTime: offset.map { now.addingTimeInterval($0) }, status: status,
                home: .init(team: home), away: .init(team: away))
        }
        let live = game("live", -100, .live)
        let scheduled = game("scheduled", 3600, .scheduled)
        let tomorrow = game("tomorrow", 86400, .scheduled)
        let final = game("final", -3600, .final)
        let old = game("old", -172800, .final)
        let canceled = game("canceled", 7200, .canceled)
        let postponed = game("postponed", 7200, .postponed)
        let undatedLive = game("undated", nil, .live)
        let games = [live, scheduled, tomorrow, final, old, canceled, postponed, undatedLive, live]
        func selection(_ shelf: KyroHomeShelf) -> [KyroSportsGame] {
            KyroHomeSportsSelection.games(games, for: shelf, favorites: favorites.preferences, now: now, calendar: calendar)
        }
        check(selection(.sportsToday).count == 7 - 1, "today includes live undated, not yesterday or tomorrow, deduplicates")
        check(selection(.upcomingSports).map(\.id) == [scheduled.id, tomorrow.id], "upcoming excludes final/live/canceled/postponed")
        check(selection(.myTeams).contains { $0.id == tomorrow.id }, "favorite team future games")
        check(selection(.myLeagues).count == 7, "favorite league events")
        check(selection(.recentLiveTV).isEmpty, "media shelves never become sports lists")
        check(KyroHomeSportsSelection.games([], for: .myTeams, favorites: favorites.preferences, now: now).isEmpty, "genuinely empty sports shelf")
        check(KyroHomePreferences.load(from: defaults) == preferences, "empty results do not erase visibility/order")
        let many = (0..<60).map { game("\($0)", Double($0 + 1), .scheduled) }
        check(KyroHomeSportsSelection.games(many, for: .sportsToday, favorites: favorites.preferences, now: now, calendar: calendar).count == 40, "bounded sports cards")

        let registry = SettingsBackupRegistry(settings: KyroHomeBackupSettings.make(defaults: defaults), deviceIdiom: "phone")
        let setting = registry.setting(id: "home.localShelves")!
        check(setting.validate(setting.read()!), "registered preference value valid")
        check(!setting.validate(.record(["order": .array([]), "hidden": .array([])])), "incomplete backup order rejected")
        check(!setting.validate(.record(["order": .array(KyroHomeShelf.allCases.map { .string($0.rawValue) }), "hidden": .array([.string("future")])])), "unknown shelf rejected")
        check(!setting.validate(.record(["order": .array(KyroHomeShelf.allCases.map { .string($0.rawValue) }), "hidden": .array([]), "extra": .bool(true)])), "unrecognized fields rejected")
        let teamSetting = registry.setting(id: "sports.favoriteTeams")!
        check(!teamSetting.validate(.array([.string("https://fixture.invalid/secret")])), "arbitrary team values rejected")
        check(!teamSetting.validate(.array([.string("nba|Home"), .string("nba|Home")])), "duplicate favorite values rejected")
        let exported = try SettingsBackupExporter.export(registry: registry, groups: [.general, .sports],
            app: .init(version: "1.0.120", build: "120", platform: "iOS", idiom: "phone"), now: now)
        let decoded = try SettingsBackupCodec.decode(exported)
        check(decoded.schemaVersion == 4, "structured preferences use existing schema 4")
        check(decoded.groups["general"]?["home.localShelves"] == setting.read(), "export includes local order/visibility")
        check(decoded.groups["sports"]?["sports.favoriteTeams"] == teamSetting.read(), "export includes shared favorites")
        check(!String(decoding: exported, as: UTF8.self).contains("fixture.invalid"), "no playback/provider URLs in settings")
        KyroHomePreferences().save(to: defaults)
        defaults.set([], forKey: KyroSportsFavorites.teamsKey)
        defaults.set([], forKey: KyroSportsFavorites.leaguesKey)
        let preview = SettingsBackupPlanner.preview(decoded, registry: registry)
        check(preview.totalChanges == 3, "restore preview includes all three durable preferences")
        let applier = SettingsBackupApplier(registry: registry, journal: HomeMemoryJournal())
        guard case .applied(let changes, let undoAvailable) = applier.apply(preview: preview, selectedGroups: [.general, .sports]) else {
            fatalError("restore failed")
        }
        check(changes.count == 3 && undoAvailable, "restore reads back all values")
        check(KyroHomePreferences.load(from: defaults) == preferences, "restore order/visibility")
        favorites.reload()
        check(favorites.preferences.includes(home), "restore refreshes shared favorites")
        let undo = applier.undo()
        check(undo.isClean && undo.reverted.count == 3, "undo all local preferences")
        check(KyroHomePreferences.load(from: defaults) == KyroHomePreferences(), "reset snapshot restored by undo")
        check(KyroHomePreferences(data: nil).hidden.isEmpty, "reset enables default shelves")

        check(!TabDockScrollRange(content: 500, viewport: 800, insets: 0).permitsMinimizing(previous: true), "short page cannot minimize")
        check(TabDockScrollRange(content: 1100, viewport: 800, insets: 0).permitsMinimizing(previous: false), "long page can minimize")
        check(TabDockScrollRange(content: 880, viewport: 800, insets: 0).permitsMinimizing(previous: true), "accessory resize keeps minimized policy")
        check(!TabDockScrollRange(content: 880, viewport: 800, insets: 0).permitsMinimizing(previous: false), "accessory resize keeps expanded policy")
        check(!TabDockScrollRange(content: 1100, viewport: 0, insets: 0).permitsMinimizing(previous: true), "unmeasured page cannot minimize")

        try sourceAndAssetContracts()
        print("Build 120: \(count) focused host checks passed (behavior + source/asset contracts).")
    }

    static func sourceAndAssetContracts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func hash(_ path: String) throws -> String {
            SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path))).map { String(format: "%02x", $0) }.joined()
        }
        let assets = "iosApp/iosApp/Kyro/KyroBrand.xcassets/"
        check(try hash(assets + "KyroXWordmark.imageset/KyroXWordmark.png") == "1881e4b8444d6a7d4f3c84901b9de23ddde8481c269a44786362165fc58599a0", "approved wordmark bytes")
        check(try hash(assets + "KyroXAppIcon.appiconset/KyroXAppIcon.png") == "4b23e166e3e77bd8ed17e8a9a76af3a53bb314593ac81bc6a0066432878d478d", "approved K/X icon bytes")
        check(try hash(assets + "KyroXLogo.imageset/KyroXAppIcon.png") == hash(assets + "KyroXAppIcon.appiconset/KyroXAppIcon.png"), "launch reuses actual K/X logo")
        let brand = try source("iosApp/iosApp/Components/AppBrand.swift")
        check(brand.contains("static let name = \"Kyro X\"") && brand.contains("static let name = \"Silo\""), "iOS identity with other platforms unchanged")
        let splash = try source("iosApp/iosApp/Kyro/KyroCinematicSplashView.swift")
        check(splash.contains("accessibilityReduceMotion") && splash.contains("guard !Task.isCancelled"), "launch accessibility and cancellation")
        let home = try source("iosApp/iosApp/Screens/Home/HomeView.swift")
        check(home.components(separatedBy: "ForEach(sections)").last!.contains("KyroHomeShelves()"), "additive shelves follow unchanged server feed")
        let shelves = try source("iosApp/iosApp/Kyro/Home/KyroHomeShelves.swift")
        check(shelves.contains("liveTV.choose(channel, from: .shell)"), "channel routes exact original channel through existing PiP/shell owner")
        check(shelves.contains("liveTV.playSportsEvent(game)") && shelves.contains("KyroSportsEventPreview(game:"), "sports routes existing details/playback")
        check(shelves.contains(".secondaryDestination(.sports)"), "Sports fallback uses the secondary route type")
        let routes = try source("iosApp/iosApp/Navigation/Route.swift")
        let shell = try source("iosApp/iosApp/ContentView.swift")
        check(routes.contains("case sports") && shell.contains("case .sports: self = .kyroRoot(.sports)"), "secondary Sports route resolves to existing Hub")
        check(shell.contains("KyroMoreMenuItem(id: \"kyro-sports\"") && shell.contains("return MainTabDestination.global(.sports)"), "Sports remains reachable when not a primary tab")
        let libraries = try source("iosApp/iosApp/Screens/Browse/LibrariesTabView.swift")
        check(libraries.contains("LibraryDockModel()") && libraries.contains("LibraryPageScrollClaim("), "actual upstream dock/model and scroll claim")
        check(libraries.contains(".floatingPageDock(dock, isShown: !dockIsInSlot)"), "floating fallback when native slot is occupied/unavailable")
        check(libraries.contains("NowPlayingShelf.hasActiveAccessory"), "audio/remote retains accessory priority")
        check(libraries.contains("router.path.isEmpty && secondaryTitle == nil"), "pushed library keeps dock in its page, not hidden tab accessory")
        let hub = try source("iosApp/iosApp/Kyro/Sports/KyroSportsHubView.swift")
        check(hub.contains(".toolbar(isSecondaryDestination ? .visible : .hidden"), "secondary Sports Hub retains native Back navigation")
        check(home.contains("homeWithoutServerRows") && shelves.contains("NavigationLink(\"Sports Hub\")"), "local shelves and Sports entry survive empty Silo feed")
        let dock = try source("iosApp/iosApp/iOS/PageDock.swift")
        check(dock.contains("if #available(iOS 26.1"), "native stable accessory availability guard")
        let tabs = try source("iosApp/iosApp/Navigation/SiloTabBar.swift")
        check(tabs.contains("TabView(selection:") && tabs.contains("Tab(shell.title"), "existing primary/menu and Live TV shell retained")
        let capacity = try source("iosApp/iosApp/LiveTV/LiveTVModels.swift")
        check(capacity.contains("productionMaximumChannels = 100_000"), "100K production capacity retained")
        let project = try source("iosApp/project.yml")
        check(project.contains("revision: f470d8dc610537929c83ef31877287e9d2ad9d28"), "accepted Aether revision retained")
        check(project.components(separatedBy: "CURRENT_PROJECT_VERSION: 120").count == 4, "iOS app and two extensions target Build 120")
    }
}
#endif
