#if KYRO_STANDALONE_TESTS
import Foundation
import Observation
import os

@main @MainActor
enum KyroBuild136HostChecks {
    private static var count = 0

    static func main() async throws {
        try appearance()
        try await directory()
        try presentationContracts()
        print("Build 136: \(count) appearance, backup, directory and presentation checks passed.")
    }

    private static func check(_ value: Bool, _ title: String) {
        precondition(value, title)
        count += 1
    }

    private static func appearance() throws {
        let suite = "kyro.136.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = KyroAppAppearanceStore(defaults: defaults)
        let radio = KyroRadioPlayerAppearance(defaults: defaults)
        radio.select(.modernStream)
        check(appearance.selection == .signature, "Signature is the default")
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = appearance.selection } onChange: { changes.withLock { $0 += 1 } }
        appearance.select(.classicDark)
        check(changes.withLock { $0 } == 1 && radio.theme == .modernStream, "app switches live without changing Radio theme")
        check(KyroAppAppearanceStore(defaults: defaults).selection == .classicDark, "Classic Dark persists")

        let entry = appearance.backupSetting()
        check(!entry.group.isServerSynced && !entry.group.isDeviceSpecific, "appearance is portable device-local data")
        check(!entry.validate(.string("unknown")), "unsupported future appearance cannot be written")
        let app = SettingsBackupAppInfo(version: "1.0.136", build: "136", platform: "iOS", idiom: "phone")
        let registry = SettingsBackupRegistry(settings: [entry], deviceIdiom: "phone")
        let data = try SettingsBackupCodec.encode(values: [(entry.id, entry.group, entry.read()!)], app: app, now: Date())
        appearance.select(.signature)
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: registry)
        check(preview.totalChanges == 1 && preview.groups.first?.items.first?.incoming == "Classic Dark", "export has a named restore choice")
        let applier = SettingsBackupApplier(registry: registry, journal: Journal())
        if case .applied = applier.apply(preview: preview, selectedGroups: [.general]) {
            check(appearance.selection == .classicDark && radio.theme == .modernStream, "restoring applies only global appearance")
        } else { check(false, "global appearance restored") }

        let legacy = try SettingsBackupCodec.encode(values: [("general.launchBehavior", .general, .string("afterOneHour"))],
            app: SettingsBackupAppInfo(version: "1.0.135", build: "135", platform: "iOS", idiom: "phone"), now: Date())
        let oldPreview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(legacy), registry: registry)
        _ = applier.apply(preview: oldPreview, selectedGroups: [.general])
        check(appearance.selection == .classicDark && oldPreview.totalChanges == 0, "omitted older appearance does not reset the current choice")
    }

    private static func directory() async throws {
        let suite = "kyro.136.directory.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["hosts": ["de1.api.radio-browser.info"], "date": Date()], forKey: KyroRadioBrowserClient.mirrorsKey)
        let client = KyroRadioBrowserClient(transport: { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let order = items.first { $0.name == "order" }?.value ?? ""
            let name = order == "votes" ? "Voted Station" : "Clicked Station"
            let uuid = order == "votes" ? "9617a958-0601-11e8-ae97-52543be04c81" : "9617a958-0601-11e8-ae97-52543be04c82"
            let response = """
            [{"stationuuid":"\(uuid)","name":"\(name)",
              "url":"https://radio.example.com/stream","codec":"MP3","lastcheckok":1}]
            """
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, defaults: defaults, cacheDirectory: nil)
        let featured = KyroRadioDiscoverModel(client: client)
        let popular = KyroRadioDiscoverModel(client: client)
        featured.loadIfNeeded(.init(ranking: .communityVotes))
        popular.loadIfNeeded(.worldwide())
        await featured.waitForLoad()
        await popular.waitForLoad()
        check(featured.stations.first?.name == "Voted Station" && popular.stations.first?.name == "Clicked Station",
              "Featured and Popular ingest independently ranked directory stations")
        let allFeatured = KyroRadioDiscoverModel(client: client)
        allFeatured.loadIfNeeded(featured.query)
        await allFeatured.waitForLoad()
        let initialRequests = await client.sentRequests
        check(initialRequests.count == 2 && allFeatured.stations == featured.stations, "See All reuses the cached first ranked page")
        let local = KyroRadioPreferences(countryCode: "CA", countryName: "Canada", state: "Ontario", language: "english").discoveryQuery
        let localItems = local.queryItems(offset: 40)
        for item in [URLQueryItem(name: "countrycode", value: "CA"), .init(name: "state", value: "Ontario"),
                     .init(name: "language", value: "english"), .init(name: "offset", value: "40"),
                     .init(name: "hidebroken", value: "true"), .init(name: "order", value: "clickcount")] {
            check(localItems.contains(item), "Local and pagination preserve \(item.name)")
        }
        let library = KyroRadioLibrary(defaults: defaults)
        library.setFavorite(featured.stations[0], true)
        library.setFavorite(popular.stations[0], true)
        check(library.favorites(matching: "station", sort: .recentlyAdded).map(\.id) ==
              [popular.stations[0].id, featured.stations[0].id], "Library uses existing newest-first sort across both presentations")
        library.setFavorite(popular.stations[0], false)
        check(library.favorites(matching: "voted", sort: .recentlyAdded).count == 1 &&
              library.favorites(matching: "other", sort: .recentlyAdded).isEmpty,
              "Library filter and favorite removal use the existing store")
    }

    private static func presentationContracts() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOfFile: "iosApp/iosApp/" + path, encoding: .utf8)
        }
        let shells = try read("Kyro/Radio/KyroRadioDiscoverShelves.swift")
        let radio = try read("Kyro/Radio/KyroRadioViews.swift")
        let podcast = try read("Kyro/Podcasts/KyroPodcastBrowser.swift")
        let palette = try read("KyroTheme/KyroTheme.swift")
        let home = try read("Kyro/Home/KyroHomeShelves.swift")
        check(shells.contains("LazyHStack") && shells.contains("prefix(12)") && shells.contains("decodeSize: 144"),
              "directory previews cap items and reuse a fixed artwork decode size")
        check(radio.contains("LazyVGrid") && radio.contains(".swipeActions") && radio.contains("favorites(matching: searchText, sort: sort)"),
              "grid and list share existing search/sort with removal retained")
        check(podcast.contains("KyroAudioHeader") && radio.contains("KyroAudioHeader") &&
              podcast.contains("KyroRadioPageNowPlayingBar()") && radio.contains("KyroRadioPageNowPlayingBar()"),
              "audio destinations share stable chrome and the same pushed mini-player")
        check(!palette.contains("TimelineView") && !palette.contains(".animation(") && home.contains("KyroHomeSportsHeightProbe.games(games)"),
              "static backdrops don't schedule frames or disturb Home's height probe")
        let modern = try read("Kyro/Podcasts/KyroModernPlayers.swift")
        check(!modern.contains("KyroAppAppearanceStore") && !radio.contains("KyroRadioPlayer()"),
              "appearance does not own or restart playback sessions")
    }

    private final class Journal: RestoreJournalStoring {
        private var value: RestoreJournal?
        func load() throws -> RestoreJournal? { value }
        func save(_ journal: RestoreJournal) throws { value = journal }
        func clear() throws { value = nil }
    }
}
#endif
